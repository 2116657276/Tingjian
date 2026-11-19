import Darwin
import Foundation

public enum RecordingPlacementError: LocalizedError {
    case changed, occupied

    public var errorDescription: String? {
        switch self {
        case .changed: "绑定的录音文件夹已删除、移动或替换，请重新选择保存位置。"
        case .occupied: "绑定的录音文件夹已有其他内容，请重新选择保存位置。"
        }
    }
}

struct RecordingFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }

    init(at url: URL, type: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type else {
            throw RecordingPlacementError.changed
        }
        self.init(info)
    }
}

/// 标记和文件系统身份共同绑定原目录，移动同一目录后身份保持有效。
public struct RecordingPlacement: Codable, Equatable, Sendable {
    public var directory: URL
    let id: UUID
    private let identity: RecordingFileIdentity

    var marker: String { ".tingjian-placement-" + id.uuidString }

    init(directory: URL) throws {
        self.directory = directory
        id = UUID()
        identity = try RecordingFileIdentity(at: directory, type: S_IFDIR)
        try Data().write(to: directory.appendingPathComponent(marker), options: .withoutOverwriting)
    }

    func openDirectory() throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw RecordingPlacementError.changed }
        var info = stat()
        var markerInfo = stat()
        guard fstat(fd, &info) == 0, RecordingFileIdentity(info) == identity,
              fstatat(fd, marker, &markerInfo, AT_SYMLINK_NOFOLLOW) == 0,
              markerInfo.st_mode & S_IFMT == S_IFREG, markerInfo.st_size == 0 else {
            close(fd)
            throw RecordingPlacementError.changed
        }
        return fd
    }

    public func validateEmpty() throws {
        let fd = try openDirectory()
        defer { close(fd) }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path) == [marker] else {
            throw RecordingPlacementError.occupied
        }
    }
}

extension Deliverer {
    /// Publishes verified files into the original directory. The manifest survives interrupted publication.
    public static func fill(_ placement: RecordingPlacement, audio: URL?, markdown: URL,
                            id: UUID) throws -> DeliveryResult {
        let folder = placement.directory
        let fd = try placement.openDirectory()
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fm = FileManager.default
        let sources = [audio, markdown].compactMap { $0 }
        let marker = ".tingjian-delivery-" + id.uuidString
        let stage = folder.deletingLastPathComponent().appendingPathComponent(marker, isDirectory: true)
        let manifest = stage.appendingPathComponent("manifest.json")
        let result = DeliveryResult(directory: folder,
                                    audio: audio.map { folder.appendingPathComponent($0.lastPathComponent) },
                                    markdown: folder.appendingPathComponent(markdown.lastPathComponent))
        let owner = stage.appendingPathComponent(placement.marker)
        if try placementPublication(placement, audioName: audio?.lastPathComponent,
                                    markdownName: markdown.lastPathComponent, id: id) != nil {
            if (try? RecordingFileIdentity(at: stage, type: S_IFDIR)) != nil,
               (try? RecordingFileIdentity(at: owner, type: S_IFREG)) != nil {
                try? fm.trashItem(at: stage, resultingItemURL: nil)
            }
            return result
        }
        let files: [String: RecordingFileIdentity]
        if fm.fileExists(atPath: stage.path) {
            _ = try RecordingFileIdentity(at: stage, type: S_IFDIR)
            _ = try RecordingFileIdentity(at: owner, type: S_IFREG)
            if !fm.fileExists(atPath: manifest.path) {
                try placement.validateEmpty()
                try fm.trashItem(at: stage, resultingItemURL: nil)
            }
        }
        if fm.fileExists(atPath: stage.path) {
            files = try JSONDecoder().decode([String: RecordingFileIdentity].self,
                                             from: Data(contentsOf: manifest))
        } else {
            try placement.validateEmpty()
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            try Data().write(to: owner, options: .withoutOverwriting)
            var prepared: [String: RecordingFileIdentity] = [:]
            for source in sources {
                let target = stage.appendingPathComponent(source.lastPathComponent)
                try copyVerified(source, to: target)
                prepared[source.lastPathComponent] = try RecordingFileIdentity(at: target, type: S_IFREG)
            }
            try JSONEncoder().encode(prepared).write(to: manifest, options: .atomic)
            files = prepared
        }

        guard Set(files.keys) == Set(sources.map(\.lastPathComponent)) else { throw RecordingPlacementError.changed }
        let existing = try fm.contentsOfDirectory(atPath: folder.path)
        guard existing.allSatisfy({ $0 == placement.marker || files[$0] != nil }) else {
            throw RecordingPlacementError.occupied
        }
        for (name, identity) in files.sorted(by: { $0.key < $1.key }) {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, RecordingFileIdentity(info) == identity else {
                    throw RecordingPlacementError.occupied
                }
                continue
            }
            let staged = stage.appendingPathComponent(name)
            guard try RecordingFileIdentity(at: staged, type: S_IFREG) == identity else {
                throw RecordingPlacementError.changed
            }
            guard renameatx_np(AT_FDCWD, staged.path, fd, name, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // Verify that the path still denotes the original directory before confirming delivery.
        let currentFD = try placement.openDirectory()
        close(currentFD)
        guard Set(try fm.contentsOfDirectory(atPath: folder.path)) == Set(files.keys).union([placement.marker]) else {
            throw RecordingPlacementError.occupied
        }
        let receipt = openat(fd, marker, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
        guard receipt >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(receipt)
        try? fm.trashItem(at: stage, resultingItemURL: nil)
        return result
    }

    static func placementPublication(_ placement: RecordingPlacement, audioName: String?,
                                     markdownName: String, id: UUID) throws -> DeliveryResult? {
        let fd = try placement.openDirectory()
        defer { close(fd) }
        var info = stat()
        let marker = ".tingjian-delivery-" + id.uuidString
        guard fstatat(fd, marker, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size == 0 else { throw RecordingPlacementError.changed }
        for name in [audioName, markdownName].compactMap({ $0 }) {
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw RecordingPlacementError.changed
            }
        }
        return DeliveryResult(directory: placement.directory,
                              audio: audioName.map { placement.directory.appendingPathComponent($0) },
                              markdown: placement.directory.appendingPathComponent(markdownName))
    }
}
