import ClipboardCore
import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardViewModel

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search pinned items", text: Binding(
                get: { model.query },
                set: { model.search($0) }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                categoryButton("All", category: nil)
                categoryButton("Prompts", category: .prompts)
                categoryButton("Code", category: .code)
                categoryButton("Everyday", category: .everyday)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.items, id: \.id) { item in
                        Button(item.title) { model.insert(itemID: item.id) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text(model.instruction)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func categoryButton(_ title: String, category: ClipCategory?) -> some View {
        Button(title) { model.selectedCategory = category }
            .buttonStyle(.bordered)
            .tint(model.selectedCategory == category ? .accentColor : .secondary)
    }
}
