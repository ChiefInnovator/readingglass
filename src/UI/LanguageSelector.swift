import SwiftUI

struct LanguageSelector: View {
    let title: String
    let selected: String?
    let languages: [String: String]
    let automatic: Bool
    let select: (String?) -> Void
    @State private var open = false
    @State private var search = ""

    private var filtered: [String] {
        languages.keys.filter {
            search.isEmpty || (languages[$0] ?? $0).localizedCaseInsensitiveContains(search) ||
                $0.localizedCaseInsensitiveContains(search)
        }.sorted { (languages[$0] ?? $0) < (languages[$1] ?? $1) }
    }

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(selected.flatMap { languages[$0] } ?? "Automatic").lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .popover(isPresented: $open) {
            VStack(spacing: 8) {
                TextField("Search languages", text: $search).textFieldStyle(.roundedBorder)
                if automatic {
                    Button("Detect automatically") { select(nil); open = false }.frame(maxWidth: .infinity)
                }
                List(filtered, id: \.self) { code in
                    Button {
                        select(code)
                        open = false
                    } label: {
                        HStack {
                            Text(languages[code] ?? code)
                            Spacer()
                            if selected == code { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(12).frame(width: 300, height: 340)
        }
    }
}

struct FullTranslationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            Text(model.translatedText.isEmpty ? "No current translation." : model.translatedText)
                .font(.system(size: 18)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.frame(minWidth: 400, minHeight: 300)
    }
}
