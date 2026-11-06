import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayGeometry] = []
    @Published private(set) var selectedDisplayID: UInt32 = 0
    @Published private(set) var glassFrame = CGRect.zero
    @Published private(set) var status = "Screen Recording permission is required."
    @Published private(set) var hasPermission = false
    @Published private(set) var isPaused = false
    @Published private(set) var isHidden = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var preview: NSImage?
    @Published private(set) var measurement = ""
    @Published private(set) var supportedLanguageCount = 0
    @Published private(set) var targetLanguage = "en"
    @Published private(set) var sourceLanguage: String?
    @Published private(set) var translatedText = ""
    @Published private(set) var overflow: [RegionTranslation] = []
    @Published private(set) var modelReady = false
    @Published private(set) var preparingModel = false
    @Published private(set) var modelStatus = "Preparing local translation…"
    @Published private(set) var modelProgress: Double?
    @Published private(set) var showingOriginal = false
    @Published private(set) var sourceLanguageNames: [String: String] = [:]
    @Published private(set) var backgroundReady = false
    @Published private(set) var translationProgress: TranslationProgress?
    @Published var showsSizeControls = false {
        didSet { onToolbarLayoutChanged?() }
    }
    let languageNames: [String: String]

    var onGeometryChanged: ((CGRect) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onShowDiagnostics: (() -> Void)?
    var onPresentation: ((TranslationPresentation?) -> Void)?
    var onOriginal: ((Bool) -> Void)?
    var onShowFullTranslation: (() -> Void)?
    var onRefinedBackground: ((RasterSurface) -> Void)?
    var onToolbarLayoutChanged: (() -> Void)?

    private let capture = CaptureService()
    private let recognizer = TextRecognizer()
    private let modelManager = ModelManager()
    private let inferenceScheduler = InferenceScheduler()
    private lazy var backend = RuntimeTranslationBackend(scheduler: inferenceScheduler)
    private lazy var restorer = BackgroundInpainter(scheduler: inferenceScheduler)
    private let manifest: TranslationManifest?
    private lazy var pipeline = ReadingPipeline(recognizer: recognizer) { [weak self] event in
        self?.accept(event)
    }
    private lazy var translation = TranslationPipeline(translator: backend, languageNames: languageNames) { [weak self] event in
        self?.acceptTranslation(event)
    }
    private var revision: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var captureTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var currentOCRSignature: String?
    private var languageRevision: UInt64 = 0
    private var visionTags: [String: String] = [:]
    private var refinementTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var currentPresentation: (TranslationPresentation, String)?
    private var unloadingModel = false
    private var screenObserver: NSObjectProtocol?

    var currentDisplay: DisplayGeometry? { displays.first { $0.id == selectedDisplayID } }
    var toolbarStatus: String {
        if isPaused { return "Paused" }
        if !hasPermission { return "Screen access needed" }
        if !modelReady { return "Preparing model…" }
        if let progress = translationProgress {
            if progress.finished, progress.clipped == 0, progress.failed == 0, progress.uncertain == 0,
               !overflow.isEmpty { return "Read full text · \(overflow.count) overflow" }
            return progress.compactStatus
        }
        if status.hasPrefix("Recognizing") { return "Recognizing text…" }
        if status.hasPrefix("Waiting") { return "Position the glass…" }
        if status.hasPrefix("Starting") { return "Starting capture…" }
        return status
    }
    var canRetryTranslation: Bool { (translationProgress?.failed ?? 0) > 0 }
    private var currentStamp: RevisionStamp {
        RevisionStamp(geometry: revision, language: languageRevision, model: manifest?.revision ?? "missing-model")
    }

    init() {
        let manifest = try? TranslationManifest.load()
        self.manifest = manifest
        self.languageNames = manifest?.languageNames ?? ["en": "English"]
        let languages = LanguageCatalog(languageNames: languageNames)
        let saved = UserDefaults.standard.string(forKey: "targetLanguage")
        targetLanguage = languages.normalize(saved ?? Locale.preferredLanguages.first ?? "en") ?? "en"
        updateDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDisplays() }
        }
    }

    func launch() {
        hasPermission = CGPreflightScreenCaptureAccess()
        scheduleCapture()
        prepareModel(downloadIfMissing: false)
        prepareRestoration()
    }

    var targetName: String { languageNames[targetLanguage] ?? targetLanguage }

    func setTargetLanguage(_ language: String) {
        guard languageNames[language] != nil, targetLanguage != language else { return }
        targetLanguage = language
        UserDefaults.standard.set(language, forKey: "targetLanguage")
        languageRevision &+= 1
        scheduleCapture()
    }

    func setSourceLanguage(_ language: String?) {
        sourceLanguage = language
        languageRevision &+= 1
        scheduleCapture()
    }

    func holdOriginal(_ value: Bool) {
        showingOriginal = value
        onOriginal?(value)
    }

    func showFullTranslation() { onShowFullTranslation?() }
    func retryTranslation() { Task { await translation.retryLatest() } }

    func prepareModel(downloadIfMissing: Bool) {
        guard modelTask == nil, !modelReady, !unloadingModel else { return }
        preparingModel = true
        modelStatus = downloadIfMissing ? "Downloading the local model…" : "Verifying local model…"
        modelTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try await self.modelManager.prepare(downloadIfMissing: downloadIfMissing) { [weak self] progress in
                    await MainActor.run {
                        self?.modelStatus = progress.phase
                        self?.modelProgress = progress.totalBytes > 0 ? Double(progress.completedBytes) / Double(progress.totalBytes) : nil
                    }
                }
                self.modelStatus = "Preparing local translation model…"
                self.modelProgress = nil
                try await self.backend.load(directory: directory)
                try Task.checkCancellation()
                self.modelReady = true
                self.modelStatus = "Local translation ready"
                self.scheduleCapture()
            } catch {
                self.modelReady = false
                self.modelStatus = error is CancellationError ? "Model preparation cancelled." : error.localizedDescription
            }
            self.preparingModel = false
            self.modelProgress = nil
            self.modelTask = nil
        }
    }

    func cancelModelPreparation() { modelTask?.cancel() }

    private func prepareRestoration() {
        restorationTask = Task { [weak self] in
            guard let self, let url = Bundle.main.url(forResource: "LaMa512", withExtension: "mlmodelc") else { return }
            do {
                try await self.restorer.prepare(modelURL: url)
                self.backgroundReady = true
                if let (presentation, signature) = self.currentPresentation {
                    self.beginRefinement(presentation, signature: signature)
                }
            } catch { self.backgroundReady = false }
        }
    }

    func requestPermission() {
        guard permissionTask == nil else { return }
        status = "Checking Screen Recording permission…"
        permissionTask = Task { [weak self] in
            guard let self else { return }
            // Use the same asynchronous API that will supply captured frames.
            // It performs the system consent check without blocking UI handling.
            do {
                try await self.capture.verifyAccess()
                self.hasPermission = true
            } catch {
                self.hasPermission = false
            }
            self.permissionTask = nil
            if self.hasPermission {
                self.scheduleCapture()
            } else {
                self.status = "Allow ReadingGlass in System Settings → Privacy & Security → Screen Recording. Then click Check Again; macOS may require a relaunch."
            }
        }
    }

    func checkPermission() {
        requestPermission()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func updateDisplays() {
        let updated = NSScreen.screens.compactMap { screen -> DisplayGeometry? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return DisplayGeometry(id: id, name: screen.localizedName, frame: screen.frame,
                                   visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
        }
        guard updated != displays else { return }
        displays = updated
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id ?? 0
        }
        if let display = currentDisplay {
            glassFrame = glassFrame.isEmpty ? CaptureGeometry.initialGlassFrame(on: display) :
                CaptureGeometry.clampedGlassFrame(glassFrame, on: display)
            onGeometryChanged?(glassFrame)
        }
        scheduleCapture()
    }

    func selectDisplay(_ id: UInt32) {
        guard let target = displays.first(where: { $0.id == id }) else { return }
        selectedDisplayID = id
        var proposed = glassFrame
        proposed.origin = CGPoint(x: target.visibleFrame.midX - proposed.width / 2,
                                  y: target.visibleFrame.midY - proposed.height / 2)
        setGlassFrame(proposed)
    }

    func resetGlassToDisplay() {
        guard let display = currentDisplay else { return }
        setGlassFrame(CaptureGeometry.initialGlassFrame(on: display))
    }

    func setGlassFrame(_ proposed: CGRect) {
        guard let display = currentDisplay else { return }
        glassFrame = CaptureGeometry.clampedGlassFrame(proposed, on: display)
        onGeometryChanged?(glassFrame)
        scheduleCapture()
    }

    func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
        var proposed = glassFrame
        // Keep the top left attached to the toolbar when changing height.
        if let height { proposed.origin.y += proposed.height - height; proposed.size.height = height }
        if let width { proposed.size.width = width }
        setGlassFrame(proposed)
    }

    @discardableResult
    func automaticallyWiden(to width: CGFloat) -> Bool {
        guard !isPaused, !isHidden, let display = currentDisplay,
              let frame = CaptureGeometry.automaticallyWidenedFrame(glassFrame, requestedWidth: width,
                                                                   on: display) else { return false }
        setGlassFrame(frame)
        status = "Widening glass to fit text…"
        return true
    }

    func togglePause() { isPaused.toggle(); scheduleCapture(); scheduleModelUnload() }
    func toggleVisibility() {
        isHidden.toggle()
        onVisibilityChanged?(!isHidden)
        scheduleCapture()
        scheduleModelUnload()
    }
    func showDiagnostics() { onShowDiagnostics?() }

    func shutdown() {
        settleTask?.cancel()
        captureTask?.cancel()
        recognizedText = ""
        preview = nil
        modelTask?.cancel()
        unloadTask?.cancel()
        refinementTask?.cancel()
        restorationTask?.cancel()
        Task { await pipeline.stop(); await translation.stop(); await capture.stop(); await backend.unload() }
    }

    private func scheduleModelUnload() {
        unloadTask?.cancel()
        if isPaused || isHidden {
            unloadTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, self.isPaused || self.isHidden, self.modelReady else { return }
                self.modelReady = false
                self.unloadingModel = true
                await self.backend.unload()
                self.unloadingModel = false
                self.modelStatus = "Local model unloaded while idle."
                if !self.isPaused && !self.isHidden { self.prepareModel(downloadIfMissing: false) }
            }
        } else if !modelReady { prepareModel(downloadIfMissing: false) }
    }

    private func scheduleCapture() {
        revision &+= 1
        let stamp = currentStamp
        sourceRevision = 0
        recognizedText = ""
        preview = nil
        measurement = ""
        translatedText = ""
        overflow = []
        translationProgress = nil
        currentOCRSignature = nil
        currentPresentation = nil
        onPresentation?(nil)
        refinementTask?.cancel()
        settleTask?.cancel()
        captureTask?.cancel()
        status = isHidden ? "Glass hidden." : isPaused ? "Paused." :
            hasPermission ? "Waiting for the glass to settle…" : "Screen Recording permission is required."
        settleTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            await self.pipeline.stop()
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            await self.translation.stop()
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            await self.capture.stop()
            guard !Task.isCancelled, self.currentStamp == stamp,
                  self.hasPermission, !self.isPaused, !self.isHidden,
                  let display = self.currentDisplay else { return }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            let configuration = CaptureConfiguration(display: display, rect: self.glassFrame, stamp: stamp)
            await self.pipeline.activate(stamp: stamp)
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            await self.recognizer.setSourceLanguage(self.sourceLanguage.flatMap { self.visionTags[$0] })
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            await self.translation.activate(stamp: stamp, target: self.targetLanguage, manualSource: self.sourceLanguage,
                maximumWidth: Double(display.visibleFrame.maxX - CaptureGeometry.margin - self.glassFrame.minX))
            guard !Task.isCancelled, self.currentStamp == stamp else { return }
            self.startCapture(configuration)
        }
    }

    private func startCapture(_ configuration: CaptureConfiguration) {
        captureTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.currentStamp == configuration.stamp else { return }
            do {
                self.status = "Starting screen capture…"
                let frames = try await self.capture.start(configuration: configuration)
                for try await frame in frames {
                    guard !Task.isCancelled, self.currentStamp == configuration.stamp else { return }
                    await self.pipeline.consume(frame)
                }
            } catch {
                guard !Task.isCancelled, self.currentStamp == configuration.stamp else { return }
                self.revision &+= 1
                self.recognizedText = ""
                self.preview = nil
                self.translatedText = ""
                self.overflow = []
                self.currentOCRSignature = nil
                self.currentPresentation = nil
                self.refinementTask?.cancel()
                self.onPresentation?(nil)
                self.hasPermission = CGPreflightScreenCaptureAccess()
                self.status = self.hasPermission
                    ? "Capture unavailable: \(error.localizedDescription). Try Pause, then Resume."
                    : "Screen Recording access is unavailable. Enable ReadingGlass in System Settings and relaunch if requested."
                await self.pipeline.stop()
                await self.translation.stop()
            }
        }
    }

    private func accept(_ event: PipelineEvent) {
        switch event {
        case let .pending(stamp, source):
            guard stamp == currentStamp, !isPaused, !isHidden else { return }
            translationProgress = nil
            sourceRevision = source
            recognizedText = ""
            preview = nil
            translatedText = ""
            overflow = []
            currentOCRSignature = nil
            currentPresentation = nil
            onPresentation?(nil)
            refinementTask?.cancel()
            status = "Recognizing… First use of a language can take 25 seconds or longer."
        case let .recognized(result, source):
            guard result.frame.stamp == currentStamp, source == sourceRevision, !isPaused, !isHidden else { return }
            recognizedText = result.lines.map(\.text).joined(separator: "\n")
            if let image = try? result.frame.surface.makeCGImage() {
                preview = NSImage(cgImage: image, size: NSSize(width: result.frame.surface.size.width,
                                                             height: result.frame.surface.size.height))
            }
            supportedLanguageCount = result.supportedLanguages.count
            let catalog = LanguageCatalog(languageNames: languageNames)
            for tag in result.supportedLanguages {
                if let code = catalog.normalize(tag) {
                    visionTags[code] = tag
                    sourceLanguageNames[code] = languageNames[code] ?? code
                }
            }
            measurement = "\(result.frame.surface.size.width) × \(result.frame.surface.size.height) pixels · OCR \(Int(result.elapsedSeconds * 1000)) ms · \(result.lines.count) lines"
            status = result.lines.isEmpty ? "No text detected in this region." : "Recognized · automatic source language"
            currentOCRSignature = TranslationPipeline.signature(result)
            if modelReady { Task { await translation.consume(result) } }
        case let .failed(stamp, source, message):
            guard stamp == currentStamp, source == sourceRevision else { return }
            recognizedText = ""
            preview = nil
            status = message
        }
    }

    private func acceptTranslation(_ event: TranslationEvent) {
        switch event {
        case let .working(stamp, signature):
            guard stamp == currentStamp, signature == currentOCRSignature, !isPaused, !isHidden else { return }
            translationProgress = nil
            refinementTask?.cancel()
            status = "Translating locally to \(targetName)…"
        case let .progress(stamp, signature, progress):
            guard stamp == currentStamp, signature == currentOCRSignature, !isPaused, !isHidden else { return }
            translationProgress = progress
            status = progress.summary
            if progress.finished, let (presentation, currentSignature) = currentPresentation,
               currentSignature == signature {
                beginRefinement(presentation, signature: signature)
            }
        case let .requestWidth(stamp, signature, width):
            guard stamp == currentStamp, signature == currentOCRSignature else { return }
            automaticallyWiden(to: CGFloat(width))
        case let .presented(presentation, signature):
            guard presentation.frame.stamp == currentStamp, signature == currentOCRSignature,
                  !isPaused, !isHidden else { return }
            translatedText = presentation.regions.map(\.text).joined(separator: "\n\n")
            overflow = presentation.overflow
            onPresentation?(presentation.regions.isEmpty ? nil : presentation)
            currentPresentation = presentation.regions.isEmpty ? nil : (presentation, signature)
            if translationProgress == nil {
                status = presentation.regions.isEmpty ? "No translation needed or no readable text." : "Translated locally to \(targetName)"
            }
        case let .unavailable(stamp, signature, message):
            guard stamp == currentStamp, signature == currentOCRSignature, !isPaused, !isHidden else { return }
            status = message
            currentPresentation = nil
            refinementTask?.cancel()
            onPresentation?(nil)
        }
    }

    private func beginRefinement(_ presentation: TranslationPresentation, signature: String) {
        refinementTask?.cancel()
        guard backgroundReady, !presentation.regions.isEmpty, currentStamp == presentation.frame.stamp,
              currentOCRSignature == signature, !isPaused, !isHidden else { return }
        refinementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refined = try await self.restorer.restore(presentation: presentation)
                guard !Task.isCancelled, self.currentStamp == presentation.frame.stamp,
                      self.currentOCRSignature == signature,
                      self.currentPresentation?.0.frame.id == presentation.frame.id,
                      !self.isPaused, !self.isHidden else { return }
                self.onRefinedBackground?(refined)
                if let progress = self.translationProgress, progress.finished {
                    self.status = progress.summary + " · background refined"
                }
            } catch { /* Retain the readable translation if cosmetic refinement fails. */ }
        }
    }
}
