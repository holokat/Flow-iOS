import SwiftUI

@MainActor
final class KlipyGIFPickerViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published private(set) var items: [KlipyGIFItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    private let accountPubkey: String?
    private let service: KlipyGIFService
    private var activeMode: KlipyGIFPickerMode = .trending
    private var currentPage = 0
    private var canLoadMore = true
    private var hasLoadedInitialPage = false
    private var currentCustomerID = ""
    private var searchDebounceTask: Task<Void, Never>?

    init(
        accountPubkey: String?,
        service: KlipyGIFService = .shared
    ) {
        self.accountPubkey = accountPubkey
        self.service = service
    }

    var isShowingTrending: Bool {
        activeMode == .trending
    }

    func loadInitialIfNeeded() async {
        guard !hasLoadedInitialPage else { return }
        hasLoadedInitialPage = true
        await reload()
    }

    func searchTextDidChange() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func loadMoreIfNeeded(currentItem: KlipyGIFItem) {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        guard let currentIndex = items.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let triggerIndex = max(items.count - 6, 0)
        guard currentIndex >= triggerIndex else { return }

        Task {
            await loadPage(currentPage + 1, for: activeMode, replacing: false)
        }
    }

    func selection(for item: KlipyGIFItem) -> KlipyGIFAttachmentCandidate? {
        item.makeAttachmentCandidate(
            customerID: currentCustomerID,
            searchQuery: activeMode.searchQuery
        )
    }

    private func reload() async {
        let nextMode = KlipyGIFPickerMode(searchText: searchText)
        activeMode = nextMode
        currentPage = 0
        canLoadMore = true
        errorMessage = nil
        items = []

        await loadPage(1, for: nextMode, replacing: true)
    }

    private func loadPage(
        _ page: Int,
        for mode: KlipyGIFPickerMode,
        replacing: Bool
    ) async {
        if replacing {
            isLoading = true
        } else {
            isLoadingMore = true
        }

        defer {
            if replacing {
                isLoading = false
            } else {
                isLoadingMore = false
            }
        }

        do {
            let customerID = await service.customerID(for: accountPubkey)
            let fetchedItems: [KlipyGIFItem]

            switch mode {
            case .trending:
                fetchedItems = try await service.trendingGIFs(
                    customerID: customerID,
                    page: page
                )
            case .search(let query):
                fetchedItems = try await service.searchGIFs(
                    query: query,
                    customerID: customerID,
                    page: page
                )
            }

            guard mode == activeMode else { return }

            currentCustomerID = customerID
            currentPage = page
            canLoadMore = fetchedItems.count >= KlipyGIFService.defaultPageSize
            errorMessage = nil

            if replacing {
                items = fetchedItems
            } else {
                items = deduplicated(items + fetchedItems)
            }
        } catch {
            guard mode == activeMode else { return }
            if replacing {
                items = []
            }
            canLoadMore = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't load GIFs right now."
        }
    }

    private func deduplicated(_ items: [KlipyGIFItem]) -> [KlipyGIFItem] {
        var seen = Set<String>()
        var uniqueItems: [KlipyGIFItem] = []
        uniqueItems.reserveCapacity(items.count)

        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            uniqueItems.append(item)
        }

        return uniqueItems
    }
}

private enum KlipyGIFPickerMode: Equatable {
    case trending
    case search(String)

    init(searchText: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .trending
        } else {
            self = .search(trimmed)
        }
    }

    var searchQuery: String? {
        switch self {
        case .trending:
            return nil
        case .search(let query):
            return query
        }
    }
}

struct ComposeKlipyGIFPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettingsStore
    @StateObject private var viewModel: KlipyGIFPickerViewModel

    let onSelect: (KlipyGIFAttachmentCandidate) -> Void

    private let gifGridSpacing: CGFloat = 12

    init(
        currentAccountPubkey: String?,
        onSelect: @escaping (KlipyGIFAttachmentCandidate) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: KlipyGIFPickerViewModel(accountPubkey: currentAccountPubkey)
        )
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                searchField
                sectionLabel

                if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                    errorCard(message: errorMessage)
                }

                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await viewModel.loadInitialIfNeeded()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)

            TextField("Search", text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: viewModel.searchText) { _, _ in
                    viewModel.searchTextDidChange()
                }
                .onSubmit {
                    viewModel.searchTextDidChange()
                }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.searchTextDidChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(0.18), lineWidth: 0.8)
        )
    }

    private var sectionLabel: some View {
        HStack {
            Text(viewModel.isShowingTrending ? "Trending right now" : "Search results")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading GIFs...")
                    .font(.footnote)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                Text("No GIFs found")
                    .font(.headline)
                Text("Try a different search term or check back for new trending GIFs.")
                    .font(.footnote)
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        } else {
            GeometryReader { proxy in
                let columnWidth = gifGridColumnWidth(for: proxy.size.width)
                let tileHeight = columnWidth / KlipyGIFGridTile.tileAspectRatio

                ScrollView {
                    LazyVGrid(
                        columns: gifGridColumns(columnWidth: columnWidth),
                        spacing: gifGridSpacing
                    ) {
                        ForEach(viewModel.items) { item in
                            Button {
                                guard let selection = viewModel.selection(for: item) else { return }
                                onSelect(selection)
                                dismiss()
                            } label: {
                                KlipyGIFGridTile(item: item)
                                    .frame(width: columnWidth, height: tileHeight)
                            }
                            .buttonStyle(.plain)
                            .frame(width: columnWidth, height: tileHeight)
                            .clipped()
                            .disabled(viewModel.selection(for: item) == nil)
                            .onAppear {
                                viewModel.loadMoreIfNeeded(currentItem: item)
                            }
                        }
                    }
                    .padding(.bottom, 14)

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                    }
                }
                .scrollIndicators(.hidden)
                .safeAreaPadding(.bottom, 16)
            }
        }
    }

    private func gifGridColumnWidth(for availableWidth: CGFloat) -> CGFloat {
        max((availableWidth - gifGridSpacing) / 2, 1)
    }

    private func gifGridColumns(columnWidth: CGFloat) -> [GridItem] {
        [
            GridItem(.fixed(columnWidth), spacing: gifGridSpacing, alignment: .top),
            GridItem(.fixed(columnWidth), spacing: gifGridSpacing, alignment: .top)
        ]
    }

    private func errorCard(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(appSettings.themePalette.sheetCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(appSettings.themePalette.separator.opacity(0.18), lineWidth: 0.8)
        )
    }
}

private struct KlipyGIFGridTile: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var isVisible = false

    static let tileAspectRatio: CGFloat = 1.08
    private static let cornerRadius: CGFloat = 18

    let item: KlipyGIFItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            appSettings.themePalette.secondaryGroupedBackground

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if !trimmedTitle.isEmpty {
                Text(trimmedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(tileShape)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            tileShape
                .stroke(appSettings.themePalette.separator.opacity(0.16), lineWidth: 0.8)
        )
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if isVisible, let animatedURL = item.preferredAnimatedPreviewAsset?.url {
            KlipyAnimatedGIFGridPreview(
                animatedURL: animatedURL,
                fallbackPreviewURL: item.preferredPreviewAsset?.url
            )
        } else {
            staticPreviewContent
        }
    }

    private var trimmedTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    private var fallbackTile: some View {
        appSettings.themePalette.tertiaryFill
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(appSettings.themePalette.secondaryForeground)
            }
    }

    @ViewBuilder
    private var staticPreviewContent: some View {
        if let previewURL = item.preferredPreviewAsset?.url {
            AsyncImage(url: previewURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    fallbackTile
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    fallbackTile
                }
            }
        } else {
            fallbackTile
        }
    }
}

private struct KlipyAnimatedGIFGridPreview: View {
    let animatedURL: URL
    let fallbackPreviewURL: URL?

    var body: some View {
        NoteRemoteMediaView(url: animatedURL) { asset in
            NoteMediaAssetContentView(asset: asset, scaling: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } placeholder: {
            animatedPlaceholder
        } failure: {
            animatedFallback
        }
    }

    @ViewBuilder
    private var animatedPlaceholder: some View {
        if let fallbackPreviewURL {
            AsyncImage(url: fallbackPreviewURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var animatedFallback: some View {
        if let fallbackPreviewURL {
            AsyncImage(url: fallbackPreviewURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure, .empty:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
        } else {
            Color.clear
        }
    }
}
