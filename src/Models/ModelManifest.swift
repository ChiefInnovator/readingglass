import Foundation

struct ModelFile: Codable, Sendable, Equatable {
    let filename: String
    let bytes: Int64
    let sha256: String
}

struct TranslationManifest: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let revision: String
    let baseURL: String
    let totalTransferBytes: Int64
    let requiredFreeSpaceBytes: Int64
    let promptRevision: String
    let supportedTranslationCodes: [String]
    let noticeResource: String
    let languageNames: [String: String]
    let files: [ModelFile]

    static let pinnedModelID = "mlx-community/translategemma-4b-it-4bit"
    static let pinnedRevision = "5788ec08c047f3f2e17808101b8d9566ac930d58"
    static let filenames: Set<String> = [
        "model.safetensors", "tokenizer.json", "config.json", "generation_config.json",
        "added_tokens.json", "special_tokens_map.json", "chat_template.jinja",
        "tokenizer_config.json", "model.safetensors.index.json"
    ]

    static func load(from bundle: Bundle = .main) throws -> TranslationManifest {
        guard let url = bundle.url(forResource: "TranslationManifest", withExtension: "json") else {
            throw ModelInstallError.missingManifest
        }
        let manifest: TranslationManifest
        do { manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw ModelInstallError.invalidManifest }
        try manifest.validate()
        guard manifest.modelID == pinnedModelID, manifest.revision == pinnedRevision,
              manifest.baseURL == "https://huggingface.co/\(pinnedModelID)/resolve/\(pinnedRevision)/",
              Set(manifest.files.map(\.filename)) == filenames,
              manifest.totalTransferBytes == 2_217_936_348,
              manifest.requiredFreeSpaceBytes == 3_000_000_000,
              manifest.promptRevision == "translategemma-structured-v1" else {
            throw ModelInstallError.invalidManifest
        }
        return manifest
    }

    func validate() throws {
        guard schemaVersion == 1,
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              baseURL.hasSuffix("/\(revision)/"),
              !files.isEmpty, totalTransferBytes > 0, requiredFreeSpaceBytes >= totalTransferBytes,
              !supportedTranslationCodes.isEmpty,
              Set(supportedTranslationCodes).count == supportedTranslationCodes.count,
              supportedTranslationCodes.allSatisfy({ languageNames[$0]?.isEmpty == false }) else {
            throw ModelInstallError.invalidManifest
        }
        var total: Int64 = 0
        var names = Set<String>()
        for file in files {
            guard Self.filenames.contains(file.filename),
                  !file.filename.contains("/"), !file.filename.contains("\\"),
                  names.insert(file.filename).inserted, file.bytes > 0,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ModelInstallError.invalidManifest
            }
            let addition = total.addingReportingOverflow(file.bytes)
            guard !addition.overflow else { throw ModelInstallError.invalidManifest }
            total = addition.partialValue
        }
        guard total == totalTransferBytes else { throw ModelInstallError.invalidManifest }
    }
}

struct ModelInstallProgress: Sendable {
    let phase: String
    let completedBytes: Int64
    let totalBytes: Int64
}

enum ModelInstallError: LocalizedError, Sendable {
    case missingManifest
    case invalidManifest
    case missingModel
    case alreadyPreparing
    case insufficientSpace
    case invalidFile(String)
    case unexpectedFiles
    case downloadFailed(Int)
    case httpStatus(Int)
    case activationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingManifest: "The bundled translation manifest is missing. Rebuild or reinstall ReadingGlass."
        case .invalidManifest: "The translation manifest is invalid. Rebuild or reinstall ReadingGlass."
        case .missingModel: "Download the translation model to enable local translation."
        case .alreadyPreparing: "The translation model is already being prepared."
        case .insufficientSpace: "At least 3 GB of free disk space is required to install the translation model."
        case .invalidFile(let filename): "The model file \(filename) failed its size or SHA-256 check. Retry the download."
        case .unexpectedFiles: "The model directory contains unexpected files. Download a verified copy."
        case .downloadFailed(let code): "The model download failed (network code \(code)). Check the connection and retry."
        case .httpStatus(let code): "The model download server returned HTTP \(code). Retry later."
        case .activationFailed(let code): "The verified model could not be activated (file system code \(code))."
        }
    }
}

protocol ModelDownloading: Sendable {
    func download(url: URL, to destination: URL, expectedBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws
}
