import SwiftUI

/// Uses the system segmented picker so iOS owns the selection treatment,
/// including Liquid Glass on current releases and the native fallback on iOS 17.
struct FlowNativeGlassSegmentedPicker<Selection: Hashable>: View {
    @Binding private var selection: Selection

    private let items: [Selection]
    private let title: (Selection) -> String

    init(
        selection: Binding<Selection>,
        items: [Selection],
        title: @escaping (Selection) -> String
    ) {
        _selection = selection
        self.items = items
        self.title = title
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(items, id: \.self) { item in
                Text(title(item))
                    .tag(item)
            }
        } label: {
            Text(title(selection))
        }
        .pickerStyle(.segmented)
    }
}
