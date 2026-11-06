import Foundation
import TranslationRuntime

actor RuntimeTranslationBackend: TextTranslating {
    private let runtime = LocalTranslator()
    private let scheduler: InferenceScheduler
    private var cancellationEpoch: UInt64 = 0
    private var loading = false

    init(scheduler: InferenceScheduler = InferenceScheduler()) { self.scheduler = scheduler }

    func load(directory: URL) async throws {
        loading = true
        defer { loading = false }
        try await runtime.load(directory: directory)
        // Compile first-use Metal kernels before declaring the model ready.
        // This fixed, synthetic request contains no captured user content.
        let warmup = try await translate(text: "Bonjour.", source: "fr", target: "en",
                                         maximumOutputTokens: 32, deadline: .seconds(30))
        guard warmup.finish == .complete else { throw TranslationFailure.incomplete }
    }
    func unload() async { await runtime.unload() }
    func countTokens(_ text: String) async throws -> Int { try await runtime.countTokens(text) }
    func cancel() async {
        // Geometry changes invalidate captured text, not model preparation.
        guard !loading else { return }
        cancellationEpoch &+= 1
        await runtime.cancel()
    }

    func translate(text: String, source: String, target: String,
                   maximumOutputTokens: Int, deadline: Duration) async throws -> TextTranslationResult {
        let epoch = cancellationEpoch
        try await scheduler.acquire(.translation)
        let result: TranslationRuntime.TranslationOutput
        do {
            try Task.checkCancellation()
            guard epoch == cancellationEpoch else { throw CancellationError() }
            result = try await runtime.translate(text: text, sourceLanguage: source, targetLanguage: target,
                                                maximumOutputTokens: maximumOutputTokens, deadline: deadline)
            await scheduler.release()
        } catch {
            await scheduler.release()
            throw error
        }
        let finish: TextTranslationFinish
        switch result.finish {
        case .complete: finish = .complete
        case .outputLimit: finish = .outputLimit
        case .timedOut: finish = .timedOut
        case .cancelled: finish = .cancelled
        }
        return TextTranslationResult(text: result.text, finish: finish)
    }
}
