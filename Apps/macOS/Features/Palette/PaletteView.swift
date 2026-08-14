import ClipboardCore
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: PaletteViewModel
    let settings: MacSettingsModel

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search Clipboard", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.handle(.returnKey) } }
                .onChange(of: model.query) { _, _ in Task { await model.search(scope: model.scope) } }
            Picker("Scope", selection: $model.scope) {
                ForEach(PaletteScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.scope) { _, scope in Task { await model.search(scope: scope) } }
            if !settings.statusLabels.isEmpty {
                Text(settings.statusLabels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            List(model.items, selection: Binding(
                get: { model.selectedItemID },
                set: { model.select(id: $0) }
            )) { item in
                HStack {
                    Text(item.preview).lineLimit(1)
                    Spacer()
                    Text(item.contentKind.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                .tag(item.id)
            }
            .onMoveCommand { direction in
                Task { await model.handle(direction == .up ? .upArrow : .downArrow) }
            }
            HStack {
                Button("Pin") { Task { await model.pinSelected() } }
                Menu("Copy As") {
                    ForEach(CopyFormat.allCases, id: \.self) { format in
                        Button(format.rawValue) { Task { await model.copySelected(as: format) } }
                    }
                }
                Button("Export") { Task { await model.exportSelected() } }
                Button("Delete") { Task { await model.deleteSelected() } }
                Button("Pause Capture for 60 Seconds") { settings.pauseCaptureFor60Seconds() }
                SettingsLink { Text("Settings") }
            }
        }
        .padding(12)
        .frame(width: 520, height: 420)
        .task { await model.search(scope: model.scope) }
    }
}
