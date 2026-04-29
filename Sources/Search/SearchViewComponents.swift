import SwiftUI

enum SearchBarGlassStyle {
    static let usesSolidBarBackground = false
    static let fieldCornerRadius: CGFloat = 22
    static let lightFieldWhiteOpacity: Double = 0.86
    static let darkFieldThemeOpacity: Double = 0.78
    static let darkFieldWhiteOverlayOpacity: Double = 0.10
    static let rimHighlightLineWidth: CGFloat = 1.2
    static let innerBorderLineWidth: CGFloat = 0.75
    static let lightRimHighlightOpacity: Double = 0.88
    static let darkRimHighlightOpacity: Double = 0.24
    static let lightInnerBorderOpacity: Double = 0.20
    static let darkInnerBorderOpacity: Double = 0.34
    static let lightDropShadowOpacity: Double = 0.16
    static let darkDropShadowOpacity: Double = 0.10
    static let fieldShadowRadius: CGFloat = 18
    static let fieldShadowYOffset: CGFloat = 8
}

private struct SearchListRowStyle: ViewModifier {
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let separatorVisibility: Visibility
    let separatorTint: Color?

    func body(content: Content) -> some View {
        let row = content
            .listRowInsets(
                EdgeInsets(
                    top: verticalInset,
                    leading: horizontalInset,
                    bottom: verticalInset,
                    trailing: horizontalInset
                )
            )
            .listRowSeparator(separatorVisibility)
            .listRowBackground(Color.clear)

        if let separatorTint {
            row.listRowSeparatorTint(separatorTint)
        } else {
            row
        }
    }
}

extension View {
    func searchListRow(
        horizontalInset: CGFloat,
        verticalInset: CGFloat = 8,
        separatorVisibility: Visibility = .hidden,
        separatorTint: Color? = nil
    ) -> some View {
        modifier(
            SearchListRowStyle(
                horizontalInset: horizontalInset,
                verticalInset: verticalInset,
                separatorVisibility: separatorVisibility,
                separatorTint: separatorTint
            )
        )
    }
}

struct SearchSectionHeader: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(appSettings.themePalette.secondaryForeground)
            .textCase(nil)
    }
}

struct SearchSuggestionSection: View {
    let suggestion: SearchViewModel.SuggestedContentSearch
    let isActive: Bool
    let isPinned: Bool
    let horizontalInset: CGFloat
    let onActivate: () -> Void
    let onTogglePinned: () -> Void

    var body: some View {
        SearchActionCard(
            suggestion: suggestion,
            isActive: isActive,
            isPinned: isPinned,
            onActivate: onActivate,
            onTogglePinned: onTogglePinned
        )
        .searchListRow(horizontalInset: horizontalInset)
    }
}

struct SearchLoadingSection: View {
    let rowCount: Int
    let horizontalInset: CGFloat

    var body: some View {
        ForEach(0..<rowCount, id: \.self) { _ in
            SearchLoadingRow()
                .searchListRow(horizontalInset: horizontalInset, verticalInset: 0)
        }
    }
}

struct SearchProfileResultsSection<RowContent: View>: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let title: String
    let profiles: [SearchViewModel.ProfileMatch]
    let horizontalInset: CGFloat
    private let rowContent: (SearchViewModel.ProfileMatch) -> RowContent

    init(
        title: String,
        profiles: [SearchViewModel.ProfileMatch],
        horizontalInset: CGFloat,
        @ViewBuilder rowContent: @escaping (SearchViewModel.ProfileMatch) -> RowContent
    ) {
        self.title = title
        self.profiles = profiles
        self.horizontalInset = horizontalInset
        self.rowContent = rowContent
    }

    var body: some View {
        if !profiles.isEmpty {
            Section {
                ForEach(profiles) { profile in
                    rowContent(profile)
                        .searchListRow(
                            horizontalInset: horizontalInset,
                            separatorVisibility: .visible,
                            separatorTint: appSettings.themePalette.chromeBorder
                        )
                }
            } header: {
                SearchSectionHeader(title: title)
            }
        }
    }
}

struct SearchNotesResultsSection<RowContent: View, EmptyState: View>: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let activeContentSearch: SearchViewModel.SuggestedContentSearch?
    let items: [FeedItem]
    let horizontalInset: CGFloat
    private let emptyState: (SearchViewModel.SuggestedContentSearch) -> EmptyState
    private let rowContent: (FeedItem) -> RowContent

    init(
        activeContentSearch: SearchViewModel.SuggestedContentSearch?,
        items: [FeedItem],
        horizontalInset: CGFloat,
        @ViewBuilder emptyState: @escaping (SearchViewModel.SuggestedContentSearch) -> EmptyState,
        @ViewBuilder rowContent: @escaping (FeedItem) -> RowContent
    ) {
        self.activeContentSearch = activeContentSearch
        self.items = items
        self.horizontalInset = horizontalInset
        self.emptyState = emptyState
        self.rowContent = rowContent
    }

    var body: some View {
        if let activeContentSearch {
            if items.isEmpty {
                emptyState(activeContentSearch)
                    .searchListRow(horizontalInset: horizontalInset, verticalInset: 0)
            } else {
                Section {
                    ForEach(items) { item in
                        rowContent(item)
                            .searchListRow(
                                horizontalInset: horizontalInset,
                                verticalInset: 0,
                                separatorVisibility: .visible,
                                separatorTint: appSettings.themePalette.chromeBorder
                            )
                    }
                } header: {
                    SearchSectionHeader(title: activeContentSearch.sectionTitle)
                }
            }
        }
    }
}

struct SearchPaginationRow: View {
    let horizontalInset: CGFloat

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 8)
        .searchListRow(horizontalInset: horizontalInset, verticalInset: 0)
    }
}

struct SearchBottomSpacerRow: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: height)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct SearchBarSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore

    @Binding var searchText: String
    var placeholder = "Search notes, profiles, and hashtags"
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(appSettings.themePalette.mutedForeground)

                TextField(placeholder, text: $searchText)
                    .font(appSettings.appFont(.body))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .tint(appSettings.primaryColor)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(onSubmit)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(appSettings.themePalette.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background {
                searchFieldGlassBackground
            }
            .overlay {
                searchFieldGlassRim
            }
            .shadow(
                color: Color.white.opacity(searchFieldTopGlowOpacity),
                radius: 1.2,
                x: 0,
                y: -0.7
            )
            .shadow(
                color: Color.black.opacity(searchFieldDropShadowOpacity),
                radius: SearchBarGlassStyle.fieldShadowRadius,
                x: 0,
                y: SearchBarGlassStyle.fieldShadowYOffset
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var searchFieldGlassBackground: some View {
        RoundedRectangle(cornerRadius: SearchBarGlassStyle.fieldCornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: SearchBarGlassStyle.fieldCornerRadius, style: .continuous)
                    .fill(searchFieldGlassTint)
            }
            .overlay {
                if effectiveSearchColorScheme == .dark {
                    RoundedRectangle(cornerRadius: SearchBarGlassStyle.fieldCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(SearchBarGlassStyle.darkFieldWhiteOverlayOpacity))
                }
            }
    }

    private var searchFieldGlassRim: some View {
        let shape = RoundedRectangle(cornerRadius: SearchBarGlassStyle.fieldCornerRadius, style: .continuous)

        return shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(searchFieldRimHighlightOpacity),
                        Color.white.opacity(searchFieldRimHighlightOpacity * 0.44),
                        appSettings.themePalette.chromeBorder.opacity(searchFieldInnerBorderOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: SearchBarGlassStyle.rimHighlightLineWidth
            )
            .overlay {
                shape
                    .inset(by: 1.3)
                    .strokeBorder(
                        appSettings.themePalette.chromeBorder.opacity(searchFieldInnerBorderOpacity),
                        lineWidth: SearchBarGlassStyle.innerBorderLineWidth
                    )
            }
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(searchFieldRimHighlightOpacity * 0.32),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(shape)
                .allowsHitTesting(false)
            }
    }

    private var searchFieldGlassTint: Color {
        if effectiveSearchColorScheme == .light {
            return Color.white.opacity(SearchBarGlassStyle.lightFieldWhiteOpacity)
        }

        return appSettings.themePalette.chromeBackground.opacity(SearchBarGlassStyle.darkFieldThemeOpacity)
    }

    private var searchFieldRimHighlightOpacity: Double {
        effectiveSearchColorScheme == .light
            ? SearchBarGlassStyle.lightRimHighlightOpacity
            : SearchBarGlassStyle.darkRimHighlightOpacity
    }

    private var searchFieldInnerBorderOpacity: Double {
        effectiveSearchColorScheme == .light
            ? SearchBarGlassStyle.lightInnerBorderOpacity
            : SearchBarGlassStyle.darkInnerBorderOpacity
    }

    private var searchFieldDropShadowOpacity: Double {
        effectiveSearchColorScheme == .light
            ? SearchBarGlassStyle.lightDropShadowOpacity
            : SearchBarGlassStyle.darkDropShadowOpacity
    }

    private var searchFieldTopGlowOpacity: Double {
        effectiveSearchColorScheme == .light ? 0.78 : 0.08
    }

    private var effectiveSearchColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }
}

struct SearchEmptyStateSection: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let errorMessage: String?
    let isSearching: Bool
    let searchText: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)

                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            } else if isSearching {
                Text("No people match \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else {
                Text("Popular people will appear here.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct SearchNotesEmptyStateSection: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let errorMessage: String?
    let activeContentSearch: SearchViewModel.SuggestedContentSearch

    var body: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            } else {
                Text("No results for \(activeContentSearch.title.lowercased()).")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct SearchLoadingRow: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(appSettings.themePalette.secondaryFill)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(height: 14)

                RoundedRectangle(cornerRadius: 4)
                    .fill(appSettings.themePalette.secondaryFill)
                    .frame(width: 180, height: 14)
            }
        }
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}

struct SearchProfileResultRow: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var appSettings: AppSettingsStore
    @ObservedObject private var followStore = FollowStore.shared

    let profile: SearchViewModel.ProfileMatch
    let onOpenProfile: (String) -> Void

    var body: some View {
        let isCurrentUser = profile.pubkey.lowercased() == auth.currentAccount?.pubkey.lowercased()
        let isFollowing = followStore.isFollowing(profile.pubkey)

        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                AvatarView(url: profile.avatarURL, fallback: profile.displayName, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Text(profile.handle)
                        .font(.footnote)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onOpenProfile(profile.pubkey)
            }

            Spacer(minLength: 0)

            if isCurrentUser {
                Label("You", systemImage: "person.crop.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appSettings.themePalette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        appSettings.themePalette.secondaryGroupedBackground,
                        in: Capsule(style: .continuous)
                    )
            } else {
                Button {
                    followStore.toggleFollow(profile.pubkey)
                } label: {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isFollowing ? appSettings.themePalette.mutedForeground : appSettings.buttonTextColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isFollowing
                                        ? AnyShapeStyle(appSettings.themePalette.secondaryGroupedBackground)
                                        : AnyShapeStyle(appSettings.primaryGradient)
                                )
                        )
                        .overlay {
                            if isFollowing {
                                Capsule(style: .continuous)
                                    .stroke(appSettings.themePalette.separator, lineWidth: 0.8)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SearchActionCard: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let suggestion: SearchViewModel.SuggestedContentSearch
    let isActive: Bool
    let isPinned: Bool
    let onActivate: () -> Void
    let onTogglePinned: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onActivate) {
                HStack(spacing: 12) {
                    Image(systemName: actionIcon)
                        .font(.headline)
                        .foregroundStyle(isActive ? appSettings.buttonTextColor : appSettings.primaryColor)

                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isActive ? appSettings.buttonTextColor : appSettings.themePalette.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isActive ? appSettings.buttonTextColor.opacity(0.9) : appSettings.themePalette.secondaryForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if suggestion.isPinnable {
                Button(action: onTogglePinned) {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(
                            isActive
                                ? appSettings.buttonTextColor
                                : (isPinned ? appSettings.primaryColor : appSettings.themePalette.secondaryForeground)
                        )
                        .frame(width: 34, height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isActive
                                        ? appSettings.buttonTextColor.opacity(0.16)
                                        : appSettings.themePalette.tertiaryFill
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPinned ? "Unsave feed" : "Save feed")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isActive ? AnyShapeStyle(appSettings.primaryGradient) : AnyShapeStyle(appSettings.themePalette.secondaryBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionIcon: String {
        switch suggestion.kind {
        case .notes:
            return "doc.text.magnifyingglass"
        case .hashtag:
            return "number"
        case .eventReference:
            return "quote.bubble"
        }
    }
}
