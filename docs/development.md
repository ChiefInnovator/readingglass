# Development

## Requirements

- Apple silicon and macOS 15 or later.
- Xcode with Swift 6.2 or later and its command-line tools selected.
- `uv` for the one-time pinned Python environment used to convert the background model.

`./scripts/build.sh` prepares the background model if necessary, resolves Swift packages and builds the app. The script prefers an available Developer ID Application identity, otherwise it signs ad hoc. Set `READINGGLASS_SIGN_IDENTITY=-` to request ad-hoc signing. Ad-hoc rebuilds can require renewed Screen Recording consent.

The running app does not require Python, uv, Ollama, an external model server or a user account. It downloads the pinned translation model through its own setup UI.

## Layout

| Directory | Responsibility |
| --- | --- |
| `src/App` | Application lifecycle, state and menu-bar controls |
| `src/UI` | Coordinated toolbar/glass windows and settings |
| `src/Capture` | ScreenCaptureKit capture and app exclusion |
| `src/OCR` | Vision recognition, language selection and region grouping |
| `src/Pipeline` | Bounded scheduling, translation, cancellation and revision checks |
| `src/Rendering` | Core Text layout and Core ML background refinement |
| `src/Models` | Manifest, download verification and installation |
| `src/Core` | Display and capture geometry |
| `Packages/TranslationRuntime` | Embedded MLX/Tokenizer adapter |
| `Tests` | Synthetic fixtures and native tests |
| `site` | Static GitHub Pages website |

Xcode uses folder-synchronized groups for application code, resources and tests. Generated output belongs under ignored `.build/` directories.

## Geometry and interaction

The glass is nonactivating and mouse-transparent. Its separate toolbar controls dragging. Both remain on one selected display. Initial dimensions use usable screen points: 70% width up to 1,400 points and 28% height up to 420 points. Capture applies backing scale only when producing pixel dimensions.

Dragging uses the pointer offset from mouse-down and keeps the toolbar/glass relationship fixed. Manual resize buttons retain their toolbar anchor. Automatic widening preserves the glass origin and stops at the selected display’s right margin. A menu-bar action restores the display-relative initial size.

## Processing and privacy

Capture runs at 15 fps with bounded frame delivery. Accurate Vision OCR is limited to one active job and one newest pending frame. Geometry/language changes invalidate stale work. Translation caches and captured content remain in memory.

Vision input is bounded to 3,072 pixels per side and four megapixels; OCR coordinates map back to the full-resolution capture. Changed background pixels do not indefinitely invalidate stable recognized text. Each published line is checked against the latest capture before reuse.

Overlapping OCR fragments are resolved before paragraph grouping. Compact numeric labels, uncertain regions and clipped input retain original pixels. Translation output must preserve numeric tokens. Progress distinguishes translated, unchanged, uncertain, clipped and failed regions.

Core Text produces separate foreground and background rasters. Output rectangles cannot overlap. OCR glyph measurements guide source-matched font size, ink position and color. The original text footprint is preferred; nearby space is bounded by other content and visible separators. Size adjustment is limited to 10% below the source estimate, with a 10-point floor; missing glyph measurements retain the 16-point fallback. Unsafe fits use Read full text. Translation and restoration share an inference gate so cosmetic work cannot monopolize the model runtime. Background refinement does not alter foreground pixels.

Copy Screenshot uses a fresh ScreenCaptureKit one-shot capture with the entire app excluded. It works independently of translation and pause state, verifies that the glass has not moved, and writes an in-memory PNG to the system clipboard. It neither saves a file nor sends the image to another service. Tests use an isolated pasteboard.

## Validation

```sh
./scripts/build.sh
./scripts/test.sh
READINGGLASS_TEST_REAL_MODEL=1 \
READINGGLASS_VALIDATION_DIR="$PWD/.build/validation" ./scripts/test.sh
python3 scripts/check-site.py
```

The test script forwards model and export settings into Xcode’s hosted runner. All exported images use synthetic content. Passing builds/tests does not establish live permissions, real-world translation accuracy, physical multi-display behavior or notarized distribution acceptance.

Never commit captured private content, local model weights, credentials, signing material, build logs or machine-specific diagnostic evidence.

## Website

The Pages workflow validates and uploads only `site/`. No app binaries or local model weights are deployed. See [site publishing](site-publishing.md) for search metadata and deployment details.

Version-matched `vMAJOR.MINOR.PATCH` tags run the preview release workflow. `scripts/package-release.sh` builds arm64 Release configuration, checks the bundle signature and required resources, and creates a ZIP plus SHA-256 checksum. CI packages use ad-hoc signing and are not notarized.
