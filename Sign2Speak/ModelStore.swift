import CryptoKit
import Darwin
import Foundation

enum AppStorage {
    // Old names are migration inputs only. Moving within each Library directory
    // preserves large model files without copying or hashing them at startup.
    static func supportDirectory(in base: URL, files: FileManager = .default) -> URL {
        migrateDirectory(in: base, from: "Gate0Probe", to: "Sign2Speak", files: files)
    }

    static func cacheDirectory(in base: URL) -> URL {
        migrateDirectory(in: base, from: "Gate0Runtime", to: "Sign2SpeakRuntime", files: .default)
    }

    private static func migrateDirectory(in base: URL, from oldName: String, to newName: String,
                                         files: FileManager) -> URL {
        let current = base.appendingPathComponent(newName, isDirectory: true)
        let legacy = base.appendingPathComponent(oldName, isDirectory: true)
        guard !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) else {
            return current
        }
        do {
            try files.moveItem(at: legacy, to: current)
            return current
        } catch {
            // Keep using existing data if the rename fails; retry on next launch.
            return legacy
        }
    }
}

struct ModelManifest: Codable, Equatable, Sendable {
    let filename: String
    let revision: String
    let bytes: Int64
    let sha256: String

    static let gemma = ModelManifest(
        filename: "gemma-4-E2B-it.litertlm",
        revision: "6e5c4f1e395deb959c494953478fa5cec4b8008f",
        bytes: 2_588_147_712,
        sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    )

    var downloadURL: URL {
        URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/\(revision)/\(filename)")!
    }
}
actor ModelStore {
    let directory: URL
    let manifest: ModelManifest
    private var verifiedStamp: FileStamp?
    private(set) var lastValidationUsedCache = false

    // Session-only cache for an app-owned file. Nanosecond change time also
    // invalidates writes whose modification time was deliberately restored.
    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: time_t
        let modifiedNanos: Int
        let changedSeconds: time_t
        let changedNanos: Int

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG else {
                throw AppError.invalidModel("Installed model is missing or is not a regular file.")
            }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    init(directory: URL, manifest: ModelManifest = .gemma) {
        self.directory = directory
        self.manifest = manifest
    }

    func install(from source: URL) throws {
        verifiedStamp = nil
        lastValidationUsedCache = false
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try verifySize(source)
        try prepareDirectory()
        try removeInterruptedImports()
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let important = capacity.volumeAvailableCapacityForImportantUsage
        let available = important.flatMap { $0 > 0 ? $0 : nil }
            ?? capacity.volumeAvailableCapacity.map { Int64($0) }
        if let available,
           available < manifest.bytes + 256 * 1_048_576 {
            throw AppError.invalidModel("Not enough space for the model import and temporary files.")
        }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try verify(staging)
        let destination = directory.appendingPathComponent(manifest.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    func validatedModelURL() throws -> URL {
        lastValidationUsedCache = false
        let url = directory.appendingPathComponent(manifest.filename)
        let stamp = try FileStamp(url)
        if stamp == verifiedStamp {
            lastValidationUsedCache = true
            return url
        }
        verifiedStamp = nil
        try verify(url)
        guard try FileStamp(url) == stamp else {
            throw AppError.invalidModel("Installed model changed during verification. Retry or import it again.")
        }
        verifiedStamp = stamp
        return url
    }

    func prepareDownload() throws {
        try prepareDirectory()
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = capacity.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            ?? capacity.volumeAvailableCapacity.map { Int64($0) }
        if let available, available < manifest.bytes + 256 * 1_048_576 {
            throw AppError.invalidModel("Not enough free space for the sentence model. Free about 2.9 GB, then retry.")
        }
    }

    // The durable URLSession file is already inside this app's data volume.
    // Verify it before replacing anything, then move rather than copy 2.59 GB.
    func installDownloadedFile(_ source: URL) throws {
        verifiedStamp = nil
        lastValidationUsedCache = false
        try prepareDirectory()
        try verify(source)
        let destination = directory.appendingPathComponent(manifest.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        verifiedStamp = try FileStamp(destination)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func verifySize(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(manifest.bytes) else {
            throw AppError.invalidModel("Wrong model size. Import the pinned native E2B artifact from the runbook.")
        }
    }

    private func removeInterruptedImports() throws {
        // Process termination skips defer. Only remove this store's UUID staging files.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            guard url.pathExtension == "partial",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func verify(_ url: URL) throws {
        try verifySize(url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            // FileHandle can return autoreleased Foundation buffers. Drain each chunk
            // here so a long actor job cannot retain an entire model's worth of data.
            let hasChunk = try autoreleasepool {
                guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !hasChunk { break }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256 else {
            throw AppError.invalidModel("SHA-256 mismatch. The existing installed model was not replaced.")
        }
    }
}
