import Foundation
import MLXLMCommon
import Tokenizers

/// The model factory must resolve the already verified installation locally.
/// No network client is supplied to inference, even when an asset is missing.
struct OfflineOnlyDownloader: MLXLMCommon.Downloader {
    func download(id: String, revision: String?, matching patterns: [String],
                  useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw TranslationError.unexpectedDownloadAttempt
    }
}

struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let template: String
        do {
            template = try String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        } catch {
            throw TranslationError.invalidTemplate
        }
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidTemplate
        }
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory, strict: true)
        return TokenizerAdapter(tokenizer: tokenizer, template: template)
    }
}

/// Both tokenizer protocols are Sendable. Forward structured message dictionaries
/// intact; TranslateGemma needs the nested text/language record, not a chat string.
struct TokenizerAdapter: MLXLMCommon.Tokenizer {
    let tokenizer: any Tokenizers.Tokenizer
    let template: String

    var bosToken: String? { tokenizer.bosToken }
    var eosToken: String? { tokenizer.eosToken }
    var unknownToken: String? { tokenizer.unknownToken }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: .literal(template),
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
