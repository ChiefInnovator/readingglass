# TranslationRuntime

Embedded, local-only TranslateGemma inference for ReadingGlass. The library product and import name are both `TranslationRuntime`; source code is in `src/`.

Dependencies are pinned in `Package.swift` and `Package.resolved`:

- `mlx-swift-lm` 3.32.3, revision `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`, without the Foundation Models trait.
- `mlx-swift` 0.32.3.
- `swift-transformers` 1.3.0.

The application must verify the pinned model manifest before passing its installation directory to `load(directory:)`. The runtime checks required files exist, loads the standalone `chat_template.jinja`, and rejects any inference-time download. It preserves the upstream TranslateGemma preset and its structured language fields.

```swift
import TranslationRuntime

let translator = LocalTranslator()
try await translator.load(directory: verifiedInstallation)
let result = try await translator.translate(
    text: sourceText, sourceLanguage: "fr", targetLanguage: "en",
    maximumOutputTokens: 128, deadline: .seconds(3)
)
if result.finish == .complete {
    // Publish only after the application's geometry/content revision checks.
}
```

`countTokens(_:)` counts raw source tokens without added special tokens. Each translation creates a fresh, greedy session with no conversation history. The formatted prompt and requested output must fit 4,096 tokens; output limits must be 1–512 tokens. The application owns chunking and bounded retries; `.outputLimit`, `.timedOut`, and `.cancelled` are incomplete results.

Only one generation may run at once. `cancel()` and `unload()` wait for the cancelled generation to release its session/cache. A deadline cancels cooperatively; a running Metal operation may take additional time to finish safely. Keep weights loaded between blocks and unload them according to the application's idle policy.

`swift build -c release` checks native compilation. On the verified Swift 6.4.2/Xcode 27.2 toolchain its integrated build system also emits `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`; older SwiftPM build modes may require Xcode for shaders. Retain that resource bundle when packaging the application. Compilation alone does not establish GPU inference acceptance.

`swift test -c release` checks local configuration and tokenizer behavior. With a verified model installed at the application's standard path, set `READINGGLASS_TEST_REAL_MODEL=1` to additionally run the synthetic French-to-English inference test. `READINGGLASS_MODEL_DIR` can override the test's installation directory.
