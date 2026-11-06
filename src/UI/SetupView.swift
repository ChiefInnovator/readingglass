import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow screen recording to recognize text beneath the glass.").font(.headline)
            Text("ReadingGlass uses macOS screen capture and on-device Vision. Screen content is not uploaded or saved.")
                .font(.callout)
            HStack {
                Button("Grant Screen Recording") { model.requestPermission() }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings") { model.openPrivacySettings() }
                Button("Check Again") { model.checkPermission() }
            }.controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: Rectangle())
    }
}
