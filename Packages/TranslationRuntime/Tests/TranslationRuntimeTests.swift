import Foundation
import MLXLLM
import MLXLMCommon
import XCTest
@testable import TranslationRuntime

final class TranslationRuntimeTests: XCTestCase, @unchecked Sendable {
    func testLocalConfigurationPreservesTranslateGemmaBehavior() throws {
        let directory = URL(fileURLWithPath: "/tmp/verified-translategemma", isDirectory: true)
        let configuration = LocalTranslator.localConfiguration(for: directory)
        let preset = LLMRegistry.translategemma_4b_it_4bit
        XCTAssertEqual(configuration.id, .directory(directory))
        XCTAssertEqual(configuration.tokenizerSource, .directory(directory))
        XCTAssertEqual(configuration.extraEOSTokens, preset.extraEOSTokens)
        XCTAssertEqual(configuration.stopStrings, preset.stopStrings)
        XCTAssertEqual(configuration.eosTokenIds, preset.eosTokenIds)
        XCTAssertEqual(configuration.weightFileSelection, preset.weightFileSelection)
        let generator = try XCTUnwrap(configuration.messageGenerator)
        let messages = generator.generate(from: UserInput(prompt: "Bonjour.", additionalContext: [
            "source_lang_code": "fr", "target_lang_code": "en"
        ]))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "text", "source_lang_code": "fr",
                                  "target_lang_code": "en", "text": "Bonjour."]])
    }

    func testUnexpectedDownloadIsRejected() async {
        do {
            _ = try await OfflineOnlyDownloader().download(
                id: "example/model", revision: "main", matching: ["*"],
                useLatest: true, progressHandler: { _ in }
            )
            XCTFail("Inference must not be able to download assets")
        } catch {
            guard case TranslationError.unexpectedDownloadAttempt = error else {
                return XCTFail("Unexpected error type")
            }
        }
    }

    func testInstalledTokenizerUsesStandaloneTranslationTemplate() async throws {
        let directory = try installedModel()
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let configuration = LocalTranslator.localConfiguration(for: directory)
        let context: [String: any Sendable] = ["source_lang_code": "fr", "target_lang_code": "en"]
        let generator = try XCTUnwrap(configuration.messageGenerator)
        let messages = generator.generate(from: UserInput(prompt: "Bonjour.", additionalContext: context))
        let tokens = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: context)
        let decoded = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        XCTAssertTrue(decoded.contains("Bonjour."))
        XCTAssertTrue(decoded.contains("French"))
        XCTAssertTrue(decoded.contains("English"))
        XCTAssertTrue(decoded.contains("<start_of_turn>user"))
        XCTAssertTrue(decoded.hasSuffix("<start_of_turn>model\n"))
        XCTAssertNotNil(tokenizer.convertTokenToId("<end_of_turn>"))
    }

    func testInstalledLocalModelTranslatesFrenchToEnglish() async throws {
        guard ProcessInfo.processInfo.environment["READINGGLASS_TEST_REAL_MODEL"] == "1" else {
            throw XCTSkip("Set READINGGLASS_TEST_REAL_MODEL=1 for local weight execution")
        }
        let directory = try installedModel()
        let translator = LocalTranslator()
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await translator.load(directory: directory)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        do {
            let count = try await translator.countTokens("Le train part demain à neuf heures.")
            XCTAssertGreaterThan(count, 0)
            let translationStart = ProcessInfo.processInfo.systemUptime
            let output = try await translator.translate(
                text: "Le train part demain à neuf heures.", sourceLanguage: "fr", targetLanguage: "en",
                maximumOutputTokens: 96, deadline: .seconds(3)
            )
            let translationSeconds = ProcessInfo.processInfo.systemUptime - translationStart
            XCTAssertEqual(output.finish, .complete)
            let lowercased = output.text.lowercased()
            XCTAssertTrue(lowercased.contains("train"), output.text)
            XCTAssertTrue(lowercased.contains("tomorrow"), output.text)
            XCTAssertTrue(lowercased.contains("nine") || lowercased.contains("9"), output.text)
            print("Synthetic French-to-English result: \(output.text)")
            print(String(format: "Translation timing: load=%.3fs inference=%.3fs sourceTokens=%d deadline=3s",
                         loadSeconds, translationSeconds, count))
            await translator.unload()
        } catch {
            await translator.unload()
            throw error
        }
    }

    func testInstalledLocalModelTimeoutCancellationAndReuse() async throws {
        guard ProcessInfo.processInfo.environment["READINGGLASS_TEST_REAL_MODEL"] == "1" else {
            throw XCTSkip("Set READINGGLASS_TEST_REAL_MODEL=1 for local weight execution")
        }
        let translator = LocalTranslator()
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await translator.load(directory: installedModel())
        print(String(format: "Cancellation test load=%.3fs", ProcessInfo.processInfo.systemUptime - loadStart))
        do {
            let timeoutStart = ProcessInfo.processInfo.systemUptime
            let timedOut = try await translator.translate(
                text: "Le train part demain à neuf heures.", sourceLanguage: "fr", targetLanguage: "en",
                maximumOutputTokens: 96, deadline: .milliseconds(1)
            )
            XCTAssertEqual(timedOut.finish, .timedOut)
            XCTAssertEqual(timedOut.text, "")
            print(String(format: "1ms deadline settled in %.3fs", ProcessInfo.processInfo.systemUptime - timeoutStart))

            let running = Task {
                try await translator.translate(
                    text: "Le train part demain à neuf heures. Le voyage dure cinq heures et traverse plusieurs villes. Les voyageurs doivent arriver à la gare avant le départ.",
                    sourceLanguage: "fr", targetLanguage: "en",
                    maximumOutputTokens: 256, deadline: .seconds(90)
                )
            }
            try await Task.sleep(for: .milliseconds(20))
            do {
                _ = try await translator.translate(
                    text: "Bonjour.", sourceLanguage: "fr", targetLanguage: "en",
                    maximumOutputTokens: 96, deadline: .seconds(90)
                )
                XCTFail("A second generation must not overlap the active request")
            } catch {
                guard case TranslationError.busy = error else { throw error }
            }
            let cancellationStart = ProcessInfo.processInfo.systemUptime
            await translator.cancel()
            let cancelled = try await running.value
            XCTAssertEqual(cancelled.finish, .cancelled)
            XCTAssertEqual(cancelled.text, "")
            print(String(format: "Cancellation settled in %.3fs", ProcessInfo.processInfo.systemUptime - cancellationStart))

            let resumedStart = ProcessInfo.processInfo.systemUptime
            let resumed = try await translator.translate(
                text: "Bonjour.", sourceLanguage: "fr", targetLanguage: "en",
                maximumOutputTokens: 96, deadline: .seconds(3)
            )
            XCTAssertEqual(resumed.finish, .complete)
            XCTAssertFalse(resumed.text.isEmpty)
            print(String(format: "Post-cancellation inference=%.3fs deadline=3s", ProcessInfo.processInfo.systemUptime - resumedStart))
            await translator.unload()
        } catch {
            await translator.unload()
            throw error
        }
    }

    private func installedModel() throws -> URL {
        let override = ProcessInfo.processInfo.environment["READINGGLASS_MODEL_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ReadingGlass/Models/TranslateGemma/5788ec08c047f3f2e17808101b8d9566ac930d58", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path) else {
            throw XCTSkip("Verified local model is not installed")
        }
        return directory
    }
}
