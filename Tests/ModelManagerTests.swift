import CryptoKit
import XCTest
@testable import ReadingGlass

final class ModelManagerTests: XCTestCase, @unchecked Sendable {
    func testInstallVerifiesFilesAndReusesThemWithoutNetwork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let downloader = FixtureModelDownloader(files: fixture.data)
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest, downloader: downloader)
        let updates = InstallProgressRecorder()
        let installed = try await manager.prepare(downloadIfMissing: true) { await updates.append($0) }
        XCTAssertEqual(installed.lastPathComponent, fixture.manifest.revision)
        for file in fixture.manifest.files {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(file.filename)), fixture.data[file.filename])
        }
        let reused = try await manager.prepare(downloadIfMissing: false) { _ in }
        let calls = await downloader.calls
        let progress = await updates.values
        XCTAssertEqual(reused, installed)
        XCTAssertEqual(calls, ["config.json", "tokenizer.json"])
        XCTAssertEqual(progress.last?.completedBytes, fixture.manifest.totalTransferBytes)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    }

    func testCorruptDownloadNeverActivates() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let corrupt = Data(repeating: 0x41, count: fixture.data["config.json"]!.count)
        let downloader = FixtureModelDownloader(files: ["config.json": corrupt])
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest, downloader: downloader)
        do {
            _ = try await manager.prepare(downloadIfMissing: true) { _ in }
            XCTFail("Corrupt bytes must not activate")
        } catch ModelInstallError.invalidFile(let name) {
            XCTAssertEqual(name, "config.json")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(fixture.manifest.revision).path))
    }

    func testFailedRepairPreservesExistingDirectoryAndCompletedStagingFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let installed = root.appendingPathComponent(fixture.manifest.revision)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let oldContent = Data("old content retained until successful activation".utf8)
        try oldContent.write(to: installed.appendingPathComponent("config.json"))
        let downloader = FixtureModelDownloader(files: fixture.data, failOnce: "tokenizer.json")
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest, downloader: downloader)
        do {
            _ = try await manager.prepare(downloadIfMissing: true) { _ in }
            XCTFail("Injected failure must surface")
        } catch ModelInstallError.downloadFailed { }
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("config.json")), oldContent)
        let repaired = try await manager.prepare(downloadIfMissing: true) { _ in }
        let calls = await downloader.calls
        XCTAssertEqual(calls, ["config.json", "tokenizer.json", "tokenizer.json"])
        XCTAssertEqual(try Data(contentsOf: repaired.appendingPathComponent("config.json")), fixture.data["config.json"])
    }

    func testOfflinePrepareRejectsMissingAndCorruptModelWithoutDownloading() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let downloader = FixtureModelDownloader(files: fixture.data)
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest, downloader: downloader)
        do {
            _ = try await manager.prepare(downloadIfMissing: false) { _ in }
            XCTFail("Missing offline model must fail")
        } catch ModelInstallError.missingModel { }
        let installed = root.appendingPathComponent(fixture.manifest.revision)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        for (name, bytes) in fixture.data { try bytes.write(to: installed.appendingPathComponent(name)) }
        try Data("corrupt".utf8).write(to: installed.appendingPathComponent("config.json"))
        do {
            _ = try await manager.prepare(downloadIfMissing: false) { _ in }
            XCTFail("Corrupt offline model must fail")
        } catch ModelInstallError.missingModel { }
        let calls = await downloader.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancellationDuringPrepareDoesNotDownloadOrActivate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let downloader = FixtureModelDownloader(files: fixture.data)
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest, downloader: downloader)
        let preparing = expectation(description: "Preparation entered progress callback")
        let gate = InstallGate()
        let task = Task {
            return try await manager.prepare(downloadIfMissing: true) { _ in
                preparing.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [preparing], timeout: 3)
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation must not succeed")
        } catch is CancellationError { }
        let calls = await downloader.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testManifestRejectsUnsafeNamesHashesDuplicatesAndTotals() throws {
        let manifest = makeFixture().manifest
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        let variations: [(String, (inout [String: Any]) -> Void)] = [
            ("traversal", { object in var files = object["files"] as! [[String: Any]]; files[0]["filename"] = "../config.json"; object["files"] = files }),
            ("absolute", { object in var files = object["files"] as! [[String: Any]]; files[0]["filename"] = "/config.json"; object["files"] = files }),
            ("unexpected file", { object in var files = object["files"] as! [[String: Any]]; files[0]["filename"] = "executable"; object["files"] = files }),
            ("duplicate", { object in var files = object["files"] as! [[String: Any]]; files[1]["filename"] = files[0]["filename"]; object["files"] = files }),
            ("hash", { object in var files = object["files"] as! [[String: Any]]; files[0]["sha256"] = String(repeating: "X", count: 64); object["files"] = files }),
            ("size", { object in var files = object["files"] as! [[String: Any]]; files[0]["bytes"] = -1; object["files"] = files }),
            ("total", { $0["totalTransferBytes"] = 1 }),
            ("plain HTTP", { $0["baseURL"] = "http://example.com/\(manifest.revision)/" })
        ]
        for (name, change) in variations {
            var changed = source
            change(&changed)
            let decoded = try JSONDecoder().decode(TranslationManifest.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try decoded.validate(), name)
        }
    }

    func testUnexpectedInstalledFilesAreNotAcceptedOffline() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeFixture()
        let installed = root.appendingPathComponent(fixture.manifest.revision)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        for (name, bytes) in fixture.data { try bytes.write(to: installed.appendingPathComponent(name)) }
        try Data().write(to: installed.appendingPathComponent("unexpected"))
        let manager = ModelManager(rootDirectory: root, manifest: fixture.manifest,
                                   downloader: FixtureModelDownloader(files: fixture.data))
        do {
            _ = try await manager.prepare(downloadIfMissing: false) { _ in }
            XCTFail("Unexpected files must invalidate the installed model")
        } catch ModelInstallError.missingModel { }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ReadingGlass-ModelTests-\(UUID().uuidString)")
    }

    private func makeFixture() -> (manifest: TranslationManifest, data: [String: Data]) {
        let data = ["config.json": Data("config fixture".utf8), "tokenizer.json": Data("tokenizer fixture".utf8)]
        let files = ["config.json", "tokenizer.json"].map { name in
            let bytes = data[name]!
            return ModelFile(filename: name, bytes: Int64(bytes.count),
                             sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let revision = String(repeating: "a", count: 40)
        let total = files.reduce(0) { $0 + $1.bytes }
        return (TranslationManifest(schemaVersion: 1, modelID: "test", revision: revision,
                                    baseURL: "https://example.com/\(revision)/", totalTransferBytes: total,
                                    requiredFreeSpaceBytes: total, promptRevision: "test",
                                    supportedTranslationCodes: ["en"], noticeResource: "test",
                                    languageNames: ["en": "English"], files: files), data)
    }
}

private actor FixtureModelDownloader: ModelDownloading {
    let files: [String: Data]
    var failOnce: String?
    private(set) var calls: [String] = []

    init(files: [String: Data], failOnce: String? = nil) {
        self.files = files
        self.failOnce = failOnce
    }

    func download(url: URL, to destination: URL, expectedBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws {
        calls.append(url.lastPathComponent)
        if failOnce == url.lastPathComponent {
            failOnce = nil
            throw ModelInstallError.downloadFailed(-1)
        }
        try Task.checkCancellation()
        guard let data = files[url.lastPathComponent] else { throw ModelInstallError.downloadFailed(-2) }
        try data.write(to: destination)
        await progress(Int64(data.count))
    }
}

private actor InstallProgressRecorder {
    private(set) var values: [ModelInstallProgress] = []
    func append(_ progress: ModelInstallProgress) { values.append(progress) }
}

private actor InstallGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
