import Foundation
import Darwin
import TingjianCore

@MainActor
func recordingPlacementChecks() async {
    section("草稿占位目录与交付")
    let root = fresh("placement-root")
    let firstParent = root.appendingPathComponent("甲", isDirectory: true)
    let secondParent = root.appendingPathComponent("乙", isDirectory: true)
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondParent, withIntermediateDirectories: true)
        let library = ProjectLibrary(root: root)
        let placement = try await library.createRecordingPlacement(named: "课堂", in: firstParent)
        let sameName = try await library.createRecordingPlacement(named: "课堂", in: firstParent)
        try placement.validateEmpty()
        await check("创建独立占位目录并避让同名", placement.directory.lastPathComponent == "课堂" && sameName.directory.lastPathComponent == "课堂_2")
        let conflict = try await library.createRecordingPlacement(named: "课堂", in: secondParent)
        do {
            _ = try await library.moveRecordingPlacement(placement, into: secondParent)
            await check("移动遇同名时拒绝且保留原目录", false)
        } catch {
            await check("移动遇同名时拒绝且保留原目录",
                        (try? placement.validateEmpty()) != nil && (try? conflict.validateEmpty()) != nil)
        }
        let moved = try await library.moveRecordingPlacement(placement, into: root)
        await check("移动后身份有效且原路径不再存在",
                    (try? moved.validateEmpty()) != nil && !fm.fileExists(atPath: placement.directory.path))
        let sources = fresh("placement-sources")
        let md = sources.appendingPathComponent("录音.md")
        let audio = sources.appendingPathComponent("录音.m4a")
        try Data("合成音频".utf8).write(to: audio)
        try Data("# 合成转写".utf8).write(to: md)
        let publicationID = UUID()
        let delivered = try Deliverer.fill(moved, audio: audio, markdown: md, id: publicationID)
        let again = try Deliverer.fill(moved, audio: audio, markdown: md, id: publicationID)
        await check("写入原目录且重试不产生副本",
                    delivered.directory == moved.directory && again.directory == moved.directory
                    && (try? Data(contentsOf: delivered.markdown)) == Data("# 合成转写".utf8)
                    && (try? Data(contentsOf: delivered.audio!)) == Data("合成音频".utf8)
                    && ((try? fm.contentsOfDirectory(atPath: root.path).filter { $0 == "课堂" }.count) == 1))

        let partial = try await library.createRecordingPlacement(named: "中断恢复", in: root)
        let partialID = UUID()
        let stage = root.appendingPathComponent(".tingjian-delivery-" + partialID.uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        let placementMarker = try fm.contentsOfDirectory(atPath: partial.directory.path)
            .first { $0.hasPrefix(".tingjian-placement-") }!
        try Data().write(to: stage.appendingPathComponent(placementMarker))
        var identities: [String: [String: UInt64]] = [:]
        for source in [audio, md] {
            let staged = stage.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: staged)
            var info = stat()
            guard lstat(staged.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            identities[source.lastPathComponent] = [
                "device": UInt64(bitPattern: Int64(info.st_dev)),
                "inode": UInt64(info.st_ino)
            ]
        }
        try JSONSerialization.data(withJSONObject: identities).write(to: stage.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: stage.appendingPathComponent(audio.lastPathComponent),
                        to: partial.directory.appendingPathComponent(audio.lastPathComponent))
        let resumed = try Deliverer.fill(partial, audio: audio, markdown: md, id: partialID)
        await check("已发布音频后中断可继续交付文稿",
                    (try? Data(contentsOf: resumed.audio!)) == Data("合成音频".utf8)
                    && (try? Data(contentsOf: resumed.markdown)) == Data("# 合成转写".utf8))

        let occupied = try await library.createRecordingPlacement(named: "被占用", in: root)
        let foreign = occupied.directory.appendingPathComponent("外部文件")
        try Data("用户文件".utf8).write(to: foreign)
        do {
            _ = try Deliverer.fill(occupied, audio: audio, markdown: md, id: UUID())
            await check("外部写入阻止交付并保留原文件", false)
        } catch {
            await check("外部写入阻止交付并保留原文件",
                        (try? Data(contentsOf: foreign)) == Data("用户文件".utf8)
                        && !fm.fileExists(atPath: occupied.directory.appendingPathComponent(md.lastPathComponent).path))
        }

        let replaced = try await library.createRecordingPlacement(named: "被替换", in: root)
        let replacementPath = replaced.directory
        let displaced = root.appendingPathComponent("被替换的原目录")
        try fm.moveItem(at: replacementPath, to: displaced)
        try fm.createDirectory(at: replacementPath, withIntermediateDirectories: false)
        do {
            _ = try Deliverer.fill(replaced, audio: audio, markdown: md, id: UUID())
            await check("同路径目录被替换时拒绝交付", false)
        } catch {
            await check("同路径目录被替换时拒绝交付", (try? fm.contentsOfDirectory(atPath: replacementPath.path).isEmpty) == true)
        }

        let intended = try await library.createRecordingPlacement(named: "需要重试", in: root)
        let source = GateSource()
        let recorder = Recorder(saveRoot: root, localRoot: fresh("placement-local"),
                                makeEngine: { MockEngine(.normal) }, makeSource: { _ in source })
        await recorder.start(course: "测试", draftID: UUID(), destination: root, placement: intended)
        _ = await waitUntil(2) { recorder.phase == .recording && recorder.transcribe == .running }
        let blocker = intended.directory.appendingPathComponent("外部文件")
        try Data("保留".utf8).write(to: blocker)
        source.push(frames: 24000)
        _ = await waitUntil(2) { recorder.duration >= 0.9 }
        await recorder.stop()
        let wasPending: Bool
        if case .pending = recorder.save { wasPending = true } else { wasPending = false }
        await recorder.retrySave(in: secondParent)
        await check("占位目录冲突后保留录音并可重选保存位置",
                    wasPending && recorder.deliveredDir?.deletingLastPathComponent().standardizedFileURL == secondParent.standardizedFileURL
                    && (try? Data(contentsOf: blocker)) == Data("保留".utf8))

        // Build 32 P1-1: .DS_Store 不阻断判空/移动/交付/断点续传；其他隐藏文件仍判占用
        let dsPlacement = try await library.createRecordingPlacement(named: "含DSStore", in: firstParent)
        try Data([0x00, 0x01]).write(to: dsPlacement.directory.appendingPathComponent(".DS_Store"))
        let dsValid = (try? dsPlacement.validateEmpty()) != nil
        let dsMoved = try await library.moveRecordingPlacement(dsPlacement, into: secondParent)
        try Data([0x02, 0x03]).write(to: dsMoved.directory.appendingPathComponent(".DS_Store"))
        let dsPubID = UUID()
        let dsDelivered = try Deliverer.fill(dsMoved, audio: audio, markdown: md, id: dsPubID)
        let dsAgain = try Deliverer.fill(dsMoved, audio: audio, markdown: md, id: dsPubID)
        await check("占位目录含 .DS_Store 时判空/移动/交付与幂等重试均通过",
                    dsValid && dsDelivered.directory == dsMoved.directory && dsAgain.directory == dsMoved.directory
                    && (try? Data(contentsOf: dsDelivered.markdown)) == Data("# 合成转写".utf8))

        let dsPartial = try await library.createRecordingPlacement(named: "含DSStore续传", in: root)
        let dsPartialID = UUID()
        let dsStage = root.appendingPathComponent(".tingjian-delivery-" + dsPartialID.uuidString, isDirectory: true)
        try fm.createDirectory(at: dsStage, withIntermediateDirectories: false)
        let dsMarker = try fm.contentsOfDirectory(atPath: dsPartial.directory.path)
            .first { $0.hasPrefix(".tingjian-placement-") }!
        try Data().write(to: dsStage.appendingPathComponent(dsMarker))
        var dsIdentities: [String: [String: UInt64]] = [:]
        for src in [audio, md] {
            let staged = dsStage.appendingPathComponent(src.lastPathComponent)
            try fm.copyItem(at: src, to: staged)
            var info = stat()
            guard lstat(staged.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            dsIdentities[src.lastPathComponent] = [
                "device": UInt64(bitPattern: Int64(info.st_dev)),
                "inode": UInt64(info.st_ino)
            ]
        }
        try JSONSerialization.data(withJSONObject: dsIdentities).write(to: dsStage.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: dsStage.appendingPathComponent(audio.lastPathComponent),
                        to: dsPartial.directory.appendingPathComponent(audio.lastPathComponent))
        try Data([0x04]).write(to: dsPartial.directory.appendingPathComponent(".DS_Store"))
        let dsResumed = try Deliverer.fill(dsPartial, audio: audio, markdown: md, id: dsPartialID)
        await check("占位目录断点续传存在 .DS_Store 时仍可补完交付",
                    (try? Data(contentsOf: dsResumed.audio!)) == Data("合成音频".utf8)
                    && (try? Data(contentsOf: dsResumed.markdown)) == Data("# 合成转写".utf8))

        let hiddenOccupied = try await library.createRecordingPlacement(named: "含隐藏冲突", in: root)
        try Data("hidden".utf8).write(to: hiddenOccupied.directory.appendingPathComponent(".foreign"))
        var hiddenValidateRejected = false
        do { try hiddenOccupied.validateEmpty() }
        catch RecordingPlacementError.occupied { hiddenValidateRejected = true }
        var hiddenFillRejected = false
        do { _ = try Deliverer.fill(hiddenOccupied, audio: audio, markdown: md, id: UUID()) }
        catch RecordingPlacementError.occupied { hiddenFillRejected = true }
        await check("占位目录含非 .DS_Store 隐藏文件仍抛 .occupied",
                    hiddenValidateRejected && hiddenFillRejected)
    } catch {
        await check("占位目录测试运行", false, error.localizedDescription)
    }
}
