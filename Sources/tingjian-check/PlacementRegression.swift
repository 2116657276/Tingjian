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
    } catch {
        await check("占位目录测试运行", false, error.localizedDescription)
    }
}
