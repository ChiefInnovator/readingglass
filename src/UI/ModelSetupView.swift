import SwiftUI

struct ModelSetupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.modelReady ? "Translation runs on this Mac" : "Local translation model").font(.headline)
            Text(model.modelStatus).font(.callout)
            if model.preparingModel {
                if let value = model.modelProgress { ProgressView(value: value) }
                else { ProgressView().controlSize(.small) }
                Button("Cancel") { model.cancelModelPreparation() }
            } else if !model.modelReady {
                Text("One-time download: 2.22 GB. Screen content stays on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download translation model") { model.prepareModel(downloadIfMissing: true) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: Rectangle())
    }
}
