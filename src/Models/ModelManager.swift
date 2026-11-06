import CryptoKit
import Darwin
import Foundation

actor ModelManager {
    private let rootDirectory: URL
    private let manifestOverride: TranslationManifest?
    private let downloader: any ModelDownloading
    private var preparing = false

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
        manifestOverride = nil
        downloader = ModelDownloader()
    }

    /// Dependency injection keeps installation tests small and entirely local.
    init(rootDirectory: URL, manifest: TranslationManifest, downloader: any ModelDownloading) {
        self.rootDirectory = rootDirectory
        manifestOverride = manifest
        self.downloader = downloader
    }

    static var defaultRootDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ReadingGlass/Models/TranslateGemma", isDirectory: true)
    }

    func prepare(downloadIfMissing: Bool,
                 progress: @escaping @Sendable (ModelInstallProgress) async -> Void) async throws -> URL {
        guard !preparing else { throw ModelInstallError.alreadyPreparing }
        preparing = true
        defer { preparing = false }
        let manifest = try manifestOverride ?? TranslationManifest.load()
        try manifest.validate()
        try Task.checkCancellation()
        let destination = rootDirectory.appendingPathComponent(manifest.revision, isDirectory: true)
        await progress(ModelInstallProgress(phase: "Verifying local model", completedBytes: 0,
                                            totalBytes: manifest.totalTransferBytes))
        if try isVerified(directory: destination, manifest: manifest) {
            await progress(ModelInstallProgress(phase: "Model ready", completedBytes: manifest.totalTransferBytes,
                                                totalBytes: manifest.totalTransferBytes))
            return destination
        }
        guard downloadIfMissing else { throw ModelInstallError.missingModel }
        let manager = FileManager.default
        try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let values = try rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < manifest.requiredFreeSpaceBytes { throw ModelInstallError.insufficientSpace }

        let staging = rootDirectory.appendingPathComponent(".\(manifest.revision).staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try rejectSymbolicLink(staging)
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.filename)
            if try isVerified(file: target, expected: file) {
                completed += file.bytes
                continue
            }
            // The captured prefix is immutable; progress never includes another file's bytes.
            let prefix = completed
            guard let remote = URL(string: file.filename, relativeTo: URL(string: manifest.baseURL))?.absoluteURL else {
                throw ModelInstallError.invalidManifest
            }
            try await downloader.download(url: remote, to: target, expectedBytes: file.bytes) { bytes in
                await progress(ModelInstallProgress(phase: "Downloading \(file.filename)",
                                                    completedBytes: prefix + min(max(bytes, 0), file.bytes),
                                                    totalBytes: manifest.totalTransferBytes))
            }
            await progress(ModelInstallProgress(phase: "Verifying \(file.filename)", completedBytes: completed + file.bytes,
                                                totalBytes: manifest.totalTransferBytes))
            guard try isVerified(file: target, expected: file) else {
                try? manager.removeItem(at: target)
                throw ModelInstallError.invalidFile(file.filename)
            }
            completed += file.bytes
        }
        try Task.checkCancellation()
        guard try isVerified(directory: staging, manifest: manifest) else {
            throw ModelInstallError.unexpectedFiles
        }
        try activate(staging: staging, destination: destination)
        await progress(ModelInstallProgress(phase: "Model ready", completedBytes: completed,
                                            totalBytes: manifest.totalTransferBytes))
        return destination
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ModelInstallError.unexpectedFiles }
    }

    private func isVerified(directory: URL, manifest: TranslationManifest) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        try rejectSymbolicLink(directory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard Set(entries.map(\.lastPathComponent)) == Set(manifest.files.map(\.filename)) else { return false }
        for file in manifest.files {
            guard try isVerified(file: directory.appendingPathComponent(file.filename), expected: file) else { return false }
        }
        return true
    }

    private func isVerified(file: URL, expected: ModelFile) throws -> Bool {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == expected.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        // Bounded reads keep the 2.2 GB weight file out of process memory.
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expected.sha256
    }

    private func activate(staging: URL, destination: URL) throws {
        // Both directories share a parent/volume. Swapping retains the old
        // installation until the verified replacement becomes visible atomically.
        if FileManager.default.fileExists(atPath: destination.path) {
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw ModelInstallError.activationFailed(errno)
            }
            try? FileManager.default.removeItem(at: staging)
        } else {
            guard rename(staging.path, destination.path) == 0 else {
                throw ModelInstallError.activationFailed(errno)
            }
        }
    }
}
