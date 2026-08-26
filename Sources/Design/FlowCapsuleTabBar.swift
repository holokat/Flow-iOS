import SwiftUI

enum FlowCapsuleTabBarStylePreset {
    enum NotificationTabs {
        static let selectedBackground: Color? = nil
        static let selectedForeground: Color? = nil
        static let selectedStroke: Color? = nil
    }

    enum HomeFeedModeTabs {
        static let selectedBackground = NotificationTabs.selectedBackground
        static let selectedForeground = NotificationTabs.selectedForeground
        static let selectedStroke = NotificationTabs.selectedStroke
    }
}

struct FlowCapsuleTabBar<Selection: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @Binding private var selection: Selection

    private let items: [Selection]
    private let title: (Selection) -> String
    private let selectedBackgroundOverride: Color?
    private let selectedForegroundOverride: Color?
    private let selectedStrokeOverride: Color?
    @Namespace private var selectionNamespace

    init(
        selection: Binding<Selection>,
        items: [Selection],
        selectedBackground: Color? = nil,
        selectedForeground: Color? = nil,
        selectedStroke: Color? = nil,
        title: @escaping (Selection) -> String
    ) {
        _selection = selection
        self.items = items
        self.selectedBackgroundOverride = selectedBackground
        self.selectedForegroundOverride = selectedForeground
        self.selectedStrokeOverride = selectedStroke
        self.title = title
    }

    @ViewBuilder
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    tabItems
                }
            } else {
                tabItems
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabItems: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { item in
                tabButton(for: item)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 1)
        .animation(
            FlowHorizontalPagingBehavior.selectionAnimation(
                reduceMotion: accessibilityReduceMotion
            ),
            value: selection
        )
    }

    @ViewBuilder
    private func tabButton(for item: Selection) -> some View {
        let isSelected = selection == item

        if #available(iOS 26.0, *) {
            Button {
                select(item)
            } label: {
                tabLabel(for: item, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .glassEffect(nativeGlass(isSelected: isSelected), in: Capsule(style: .continuous))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        } else {
            Button {
                select(item)
            } label: {
                tabLabel(for: item, isSelected: isSelected)
                    .background {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(unselectedFill)

                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(selectedFill)
                                    .matchedGeometryEffect(id: "selected-pill", in: selectionNamespace)
                                    .shadow(
                                        color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06),
                                        radius: colorScheme == .dark ? 8 : 6,
                                        x: 0,
                                        y: 2
                                    )
                            }
                        }
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(isSelected ? selectedStroke : unselectedStroke, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    private func select(_ item: Selection) {
        guard selection != item else { return }
        selection = item
    }

    private func tabLabel(for item: Selection, isSelected: Bool) -> some View {
        Text(title(item))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isSelected ? selectedForeground : unselectedForeground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
    }

    @available(iOS 26.0, *)
    private func nativeGlass(isSelected: Bool) -> Glass {
        if isSelected {
            return Glass.regular
                .tint(selectedFill)
                .interactive()
        }
        return Glass.clear.interactive()
    }

    private var unselectedFill: Color {
        appSettings.themePalette.capsuleTabStyle?.background ?? .clear
    }

    private var selectedFill: Color {
        if let selectedBackgroundOverride {
            return selectedBackgroundOverride
        }
        return appSettings.themePalette.capsuleTabStyle?.selectedBackground
            ?? (colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color.black.opacity(0.06))
    }

    private var unselectedStroke: Color {
        appSettings.themePalette.capsuleTabStyle?.border
            ?? (colorScheme == .dark
                ? Color.white.opacity(0.14)
                : Color.black.opacity(0.12))
    }

    private var selectedStroke: Color {
        if let selectedStrokeOverride {
            return selectedStrokeOverride
        }
        return appSettings.themePalette.capsuleTabStyle?.selectedBorder
            ?? (colorScheme == .dark
                ? Color.white.opacity(0.2)
                : Color.black.opacity(0.14))
    }

    private var unselectedForeground: Color {
        appSettings.themePalette.capsuleTabStyle?.foreground
            ?? (colorScheme == .dark
                ? Color.white.opacity(0.9)
                : Color.black.opacity(0.84))
    }

    private var selectedForeground: Color {
        if let selectedForegroundOverride {
            return selectedForegroundOverride
        }
        return appSettings.themePalette.capsuleTabStyle?.selectedForeground
            ?? (colorScheme == .dark
                ? .white
                : .black)
    }
}
