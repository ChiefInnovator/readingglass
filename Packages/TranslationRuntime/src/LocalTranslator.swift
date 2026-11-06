import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public enum TranslationFinish: Sendable, Equatable {
    case complete
    case outputLimit
    case timedOut
    case cancelled
}

public struct TranslationOutput: Sendable, Equatable {
    public let text: String
    public let finish: TranslationFinish

    public init(text: String, finish: TranslationFinish) {
        self.text = text
        self.finish = finish
    }
}

/// Associated input, paths and underlying library error strings are deliberately
/// absent: errors may be displayed or logged without retaining captured text.
public enum TranslationError: LocalizedError, Sendable {
    case notLoaded
    case busy
    case invalidInput
    case contextLimit
    case invalidAssets
    case invalidTemplate
    case unexpectedDownloadAttempt
    case modelLoadFailed
    case generationFailed

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The local translation model is not loaded."
        case .busy: "The translator is finishing an earlier operation."
        case .invalidInput: "The translation request is invalid."
        case .contextLimit: "The text exceeds the local translation context limit."
        case .invalidAssets: "The verified local model files are unavailable."
        case .invalidTemplate: "The local translation template is unavailable or invalid."
        case .unexpectedDownloadAttempt: "Inference attempted an unexpected model download."
        case .modelLoadFailed: "The local translation model could not be loaded."
        case .generationFailed: "Local translation could not complete."
        }
    }
}

/// Owns one warm model and at most one generation. Every request uses a fresh
/// ChatSession; cancelling/unloading waits for its actual generation to settle.
public actor LocalTranslator {
    private var model: ModelContainer?
    private var directory: URL?
    private var loading: Task<ModelContainer, Error>?
    private var active: Task<TranslationOutput, Error>?
    private var activeID: UUID?
    private var revision: UInt64 = 0
    private var unloading = false

    public init() {}

    /// Call only with the installation already checked against the pinned
    /// manifest by the application's model manager. This method never downloads.
    public func load(directory: URL) async throws {
        try Task.checkCancellation()
        guard !unloading, loading == nil, active == nil else { throw TranslationError.busy }
        let local = directory.standardizedFileURL
        guard local.isFileURL else { throw TranslationError.invalidAssets }
        if model != nil, self.directory == local { return }
        revision &+= 1
        let token = revision
        let task = Task { try await Self.loadModel(in: local) }
        loading = task
        defer { if revision == token { loading = nil } }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard revision == token, !unloading else { throw CancellationError() }
            model = loaded
            self.directory = local
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.modelLoadFailed
        }
    }

    /// Counts source tokens, without adding BOS/EOS or a conversation template.
    public func countTokens(_ text: String) async throws -> Int {
        try Task.checkCancellation()
        guard !unloading, loading == nil else { throw TranslationError.busy }
        guard let model else { throw TranslationError.notLoaded }
        return await model.tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    public func translate(text: String, sourceLanguage: String, targetLanguage: String,
                          maximumOutputTokens: Int, deadline: Duration) async throws -> TranslationOutput {
        try Task.checkCancellation()
        guard !unloading, loading == nil, active == nil else { throw TranslationError.busy }
        guard let model else { throw TranslationError.notLoaded }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceLanguage.isEmpty, !targetLanguage.isEmpty,
              (1...512).contains(maximumOutputTokens), deadline > .zero else {
            throw TranslationError.invalidInput
        }
        let id = UUID()
        let task = Task {
            try await Self.runWithDeadline(model: model, text: text, source: sourceLanguage,
                                           target: targetLanguage, maximumTokens: maximumOutputTokens,
                                           deadline: deadline)
        }
        active = task
        activeID = id
        defer { if activeID == id { active = nil; activeID = nil } }
        do {
            let output = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            if Task.isCancelled { return TranslationOutput(text: "", finish: .cancelled) }
            return output
        } catch is CancellationError {
            return TranslationOutput(text: "", finish: .cancelled)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.generationFailed
        }
    }

    public func cancel() async {
        guard let task = active else { return }
        let id = activeID
        task.cancel()
        _ = try? await task.value
        if activeID == id { active = nil; activeID = nil }
    }

    public func unload() async {
        guard !unloading else { return }
        unloading = true
        revision &+= 1
        let loadTask = loading
        loadTask?.cancel()
        await cancel()
        if let loadTask { _ = try? await loadTask.value }
        loading = nil
        model = nil
        directory = nil
        Memory.clearCache()
        unloading = false
    }

    private static func loadModel(in directory: URL) async throws -> ModelContainer {
        let required = ["config.json", "model.safetensors", "tokenizer.json",
                        "tokenizer_config.json", "chat_template.jinja"]
        for filename in required {
            let values = try directory.appendingPathComponent(filename).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw TranslationError.invalidAssets
            }
        }
        let configuration = localConfiguration(for: directory)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: OfflineOnlyDownloader(), using: LocalTokenizerLoader(),
            configuration: configuration, useLatest: false
        )
        try Task.checkCancellation()
        return loaded
    }

    /// tokenizerSource is immutable in the pinned MLX API. Copy every behavioral
    /// field through its initializer while replacing both asset locations.
    static func localConfiguration(for directory: URL) -> ModelConfiguration {
        let preset = LLMRegistry.translategemma_4b_it_4bit
        var configuration = ModelConfiguration(
            directory: directory, tokenizerSource: .directory(directory),
            defaultPrompt: preset.defaultPrompt, extraEOSTokens: preset.extraEOSTokens,
            stopStrings: preset.stopStrings, eosTokenIds: preset.eosTokenIds,
            toolCallFormat: preset.toolCallFormat, reasoningConfig: preset.reasoningConfig,
            messageGenerator: preset.messageGenerator
        )
        configuration.weightFileSelection = preset.weightFileSelection
        return configuration
    }

    private static func runWithDeadline(model: ModelContainer, text: String, source: String,
                                        target: String, maximumTokens: Int,
                                        deadline: Duration) async throws -> TranslationOutput {
        try await withThrowingTaskGroup(of: TranslationOutput.self) { group in
            group.addTask {
                try await generate(model: model, text: text, source: source,
                                   target: target, maximumTokens: maximumTokens)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                return TranslationOutput(text: "", finish: .timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
            // Structured concurrency waits for the cancelled generation child's
            // synchronize/clear cleanup before releasing the model to callers.
        }
    }

    private static func generate(model: ModelContainer, text: String, source: String,
                                 target: String, maximumTokens: Int) async throws -> TranslationOutput {
        let context: [String: any Sendable] = ["source_lang_code": source, "target_lang_code": target]
        let configuration = await model.configuration
        guard let messageGenerator = configuration.messageGenerator else {
            throw TranslationError.invalidTemplate
        }
        let tokenizer = await model.tokenizer
        let messages = messageGenerator.generate(from: UserInput(prompt: text, additionalContext: context))
        let prompt = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: context)
        guard prompt.count + maximumTokens <= 4096 else { throw TranslationError.contextLimit }
        try Task.checkCancellation()

        let session = ChatSession(
            model, generateParameters: GenerateParameters(maxTokens: maximumTokens, temperature: 0),
            additionalContext: context
        )
        do {
            var output = ""
            var reason: GenerateStopReason?
            for try await event in session.streamDetails(to: text) {
                try Task.checkCancellation()
                switch event {
                case .chunk(let chunk): output += chunk
                case .info(let info): reason = info.stopReason
                case .toolCall, .rejectedToolCall: throw TranslationError.generationFailed
                }
            }
            await session.synchronize()
            await session.clear()
            try Task.checkCancellation()
            switch reason {
            case .stop:
                let final = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { throw TranslationError.generationFailed }
                return TranslationOutput(text: final, finish: .complete)
            case .length: return TranslationOutput(text: output, finish: .outputLimit)
            case .cancelled: return TranslationOutput(text: "", finish: .cancelled)
            case nil: throw TranslationError.generationFailed
            }
        } catch {
            // Cancellation of the AsyncThrowingStream stops its underlying
            // generation task. synchronize waits for cache/GPU use to finish.
            await session.synchronize()
            await session.clear()
            throw error
        }
    }
}
