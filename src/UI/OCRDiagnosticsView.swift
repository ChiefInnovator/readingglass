import SwiftUI

struct OCRDiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ReadingGlass").font(.title2.bold())
                Spacer()
                Text("LOCAL ONLY").font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text("Move the glass using its hand grip. Clicks and scrolling inside its outline pass through to the app below.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.status).font(.callout).accessibilityIdentifier("captureStatus")
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.hasPermission { SetupView(model: model) }
            if !model.modelReady || model.preparingModel { ModelSetupView(model: model) }
            LanguageSelector(title: "Source language", selected: model.sourceLanguage,
                             languages: model.sourceLanguageNames, automatic: true) { model.setSourceLanguage($0) }
                .frame(width: 220)
            Picker("Display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                ForEach(model.displays) { display in Text(display.name).tag(display.id) }
            }.frame(maxWidth: 300)
            if model.canRetryTranslation {
                Button("Retry failed regions") { model.retryTranslation() }
            }
            if !model.measurement.isEmpty {
                Text(model.measurement).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let image = model.preview, model.translatedText.isEmpty {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxHeight: 165).background(.white)
                    .accessibilityLabel("Captured region, excluding ReadingGlass windows")
            }
            HStack {
                Text(model.translatedText.isEmpty ? "Recognized text" : "Translation · \(model.targetName)").font(.headline)
                Spacer()
                if model.supportedLanguageCount > 0 {
                    Text("\(model.supportedLanguageCount) Vision language identifiers")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(model.translatedText.isEmpty ? (model.recognizedText.isEmpty ? "Place the glass over text to begin." : model.recognizedText) : model.translatedText)
                    .font(.system(size: 16)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(.background.secondary, in: Rectangle())
            .accessibilityIdentifier("recognizedText")
            Text("Recognition and translation run locally. Hold the eye button to see the original; Read full text opens overflow text. Captures and text remain in memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 410, minHeight: 360)
    }
}
