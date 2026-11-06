# ReadingGlass

<img src="site/assets/app-icon.png" width="128" height="128" alt="ReadingGlass app icon">

**Read your screen in your language.** ReadingGlass is a native macOS utility that translates text inside a movable, click-through reading glass. Recognition, translation and background refinement run on your Mac.

[Product website](https://chiefinnovator.github.io/readingglass/) · [Build guide](docs/development.md) · [Report an issue](https://github.com/ChiefInnovator/readingglass/issues)

## Current status

Version 0.1.0 is a source-build preview. A notarized installer and Mac App Store release are not currently provided. Translation quality, complex layouts and multi-display behavior still need broader real-world validation.

## Features

- Translate screen text in place using local Vision, MLX and Core ML processing.
- Keep interacting with the application beneath the click-through glass.
- Start with a display-relative reading area; adjust width and height independently.
- Automatically widen for clipped or width-limited text, within the selected display.
- Preserve uncertain text and numeric labels; show explicit progress and failures.
- Hold Original to compare, or open Read full text when a translation cannot fit.
- Control visibility, pause/resume and size reset from the macOS menu bar.

## Build and run

Requires an Apple silicon Mac, macOS 15 or later, Xcode with Swift 6.2 or later, and [uv](https://docs.astral.sh/uv/) for the one-time background-model conversion. Python is used during development, not by the running application.

```sh
git clone https://github.com/ChiefInnovator/readingglass.git
cd readingglass
./scripts/build.sh
open .build/DerivedData/Build/Products/Debug/ReadingGlass.app
```

The first build downloads the pinned background-model conversion dependencies. In the app, grant **Screen Recording** permission and install the local translation model (approximately 2.22 GB). Model files are verified before activation.

## Use

1. Move the glass with the toolbar’s hand grip.
2. Choose a target language. Source-language detection is automatic; override it in settings when needed.
3. Use Resize controls to reveal the independent width/height buttons. Hold a button to repeat.
4. Hold the eye button to view the original. Use **Read full text** for output that does not fit safely.
5. Use the menu-bar icon to hide/show, pause/resume, reset the size for the current display, or quit.

The initial glass uses 70% of usable display width, capped at 1,400 logical points, and 28% of usable height, capped at 420 points. Retina scale affects capture pixels, not the apparent size of the reading area.

## Privacy

Screen recognition, translation and background refinement run locally. Captured images and recognized text are kept in memory and are not uploaded by the app. Every ReadingGlass window and the pointer are excluded from capture. Model downloads require network access; translation runs locally after installation.

## Test

```sh
./scripts/test.sh
# Include the installed models and export synthetic visual fixtures:
READINGGLASS_TEST_REAL_MODEL=1 \
READINGGLASS_VALIDATION_DIR="$PWD/.build/validation" ./scripts/test.sh
```

All test fixtures are synthetic. Do not add private screen captures or recognized private text to tests, logs or issues. See [development](docs/development.md) for the architecture and validation boundaries.

## Models and dependencies

ReadingGlass uses a pinned MLX conversion of TranslateGemma and a Core ML conversion of Big LaMa. Model weights are downloaded or prepared separately and are not stored in this repository. Their licenses and notices are separate from the application source; see [third-party notices](Resources/ThirdPartyNotices.md).

## Source license

A project source license has not been selected yet. Public visibility does not grant additional reuse rights. Third-party components remain subject to their own licenses.
