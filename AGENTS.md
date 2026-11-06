# ReadingGlass

- Follow `~/AGENTS.md` and the approved contracts in `docs/designs/`.
- Read `docs/SESSION_CONTEXT.md` before continuing work. It records evidence and decisions; agent instructions belong here.
- Current milestone: finish the local translation glass, including the approved model download/runtime and translated-text presentation. Preserve the working capture/OCR behavior.
- Application code lives under `src/`, grouped by responsibility. Keep tests in `Tests/`, build settings in `ReadingGlass.xcodeproj/Configuration/`, scripts in `scripts/`, and documentation in `docs/`.
- Preserve historical design/review evidence. Update `docs/SESSION_CONTEXT.md` and `docs/acceptance.md` when implementation or verified results change.
- Keep the glass click-through and on one display. Exclude the entire app from capture. Never persist captured images or recognized private text in logs, tests, or telemetry.
- Build with `scripts/build.sh`; test with `scripts/test.sh`. Keep generated output under ignored `.build/`.
- Distinguish build/test success from live permission, capture, and visual acceptance. Record untested cases explicitly.
