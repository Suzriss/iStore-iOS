import SwiftUI
/// Apps tab — a compact storefront for apps discovered from connected sources.
struct AppsView: View {
    @EnvironmentObject private var repositories: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var selectedApp: RepoApp?
    @State private var searchText = ""
    @State private var displayedApps: [RepoApp] = []
    @State private var didInitialRefresh = false
    @State private var selectedCategory: String?
    @FocusState private var searchFieldFocused: Bool

    /// How many rows are revealed at a time. Keeps a big catalog from
    /// dumping thousands of rows into the list the instant a fetch
    /// completes — it reveals in App Store-sized batches as you scroll.
    private static let pageSize = 25
    @State private var visibleCount = pageSize

    private var visibleApps: [RepoApp] {
        Array(displayedApps.prefix(visibleCount))
    }

    /// Called as rows scroll into view; grows the visible window one page
    /// early (a few rows before the end) so the next batch is ready before
    /// the user hits the bottom.
    private func loadMoreIfNeeded(index: Int) {
        guard visibleCount < displayedApps.count, index >= visibleApps.count - 5 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            visibleCount = min(visibleCount + Self.pageSize, displayedApps.count)
        }
    }

    private var allApps: [RepoApp] {
        repositories.repositories.flatMap { repo in
            repositories.catalog[repo.id]?.apps ?? []
        }
    }

    /// Categories that currently have apps, ranked by Ceresify's own admin
    /// panel order (`repositories.categoryOrder`). Any category present in
    /// the catalog but missing from that ranking — e.g. brand new, not yet
    /// filed in the admin panel — falls back to the end, first-seen first.
    private var categories: [String] {
        var seen = Set<String>()
        var present: [String] = []
        for app in allApps {
            guard let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !category.isEmpty, seen.insert(category).inserted else { continue }
            present.append(category)
        }
        let order = repositories.categoryOrder
        guard !order.isEmpty else { return present }
        // `uniquingKeysWith` guards against a duplicate name in the server's
        // ranking ever crashing this instead of just picking one rank for it.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return present.sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
    }

    /// True while the store catalog (or, with a category selected, that
    /// category's own admin-ordered list) is being fetched and nothing has
    /// loaded yet.
    private var isLoadingCatalog: Bool {
        if let selectedCategory {
            return repositories.loadingCategoryApps.contains(selectedCategory)
                && (repositories.categoryApps[selectedCategory]?.isEmpty ?? true)
        }
        return repositories.loadingRepoID != nil && allApps.isEmpty
    }

    /// The most recent fetch failure, if nothing loaded for the active view.
    private var catalogErrorMessage: String? {
        if let selectedCategory {
            guard repositories.categoryApps[selectedCategory]?.isEmpty ?? true else { return nil }
            return repositories.categoryAppsError[selectedCategory]
        }
        guard allApps.isEmpty else { return nil }
        return repositories.repositories.compactMap { repositories.fetchError[$0.id] }.first
    }

    private func refreshDisplayedApps() {
        // A selected category shows its own admin-ordered list (fetched
        // on demand); "All" is the full catalog, already newest-first.
        let apps = selectedCategory.map { repositories.categoryApps[$0] ?? [] } ?? allApps
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        displayedApps = query.isEmpty ? apps : apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) ||
            (app.developerName?.localizedCaseInsensitiveContains(query) ?? false) ||
            (app.localizedDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
        // A new base list (fresh fetch, category switch, search) starts back
        // at one page — never carry over a scroll-grown window onto content
        // the user hasn't scrolled to yet.
        visibleCount = Self.pageSize
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if displayedApps.isEmpty {
                                if isLoadingCatalog {
                                    loadingState
                                } else if let catalogErrorMessage {
                                    errorState(catalogErrorMessage)
                                } else {
                                    emptyState
                                }
                            } else {
                                // Do not nest a LazyVStack inside the section's
                                // lazy container: nested lazy layout can preserve
                                // stale row positions while filtering.
                                ForEach(visibleApps.indices, id: \.self) { index in
                                    appRow(visibleApps[index])
                                        .padding(.horizontal, T.pad)
                                        .padding(.bottom, 12)
                                        .transaction { transaction in
                                            transaction.animation = nil
                                        }
                                        .onAppear { loadMoreIfNeeded(index: index) }
                                }
                            }
                        } header: {
                            VStack(spacing: 0) {
                                titleHeader
                                searchBar
                                    .padding(.horizontal, T.pad)
                                    .padding(.vertical, 8)
                                if !categories.isEmpty {
                                    categorySlider
                                        .padding(.bottom, 10)
                                }
                            }
                            .background(T.bg.opacity(T.isDark ? 0.90 : 0.94))
                            .zIndex(2)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            T.bg.opacity(0.98),
                            T.bg.opacity(0.72),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 92)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
                .task {
                    guard !didInitialRefresh else { return }
                    await refreshAll()
                    refreshDisplayedApps()
                    didInitialRefresh = true
                }
                .refreshable {
                    await refreshAll()
                    if let selectedCategory {
                        await repositories.refreshCategoryApps(selectedCategory)
                    }
                    refreshDisplayedApps()
                }
                .task(id: searchText) {
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    refreshDisplayedApps()
                }
                .task(id: selectedCategory) {
                    if let selectedCategory {
                        await repositories.loadCategoryApps(selectedCategory)
                    }
                    refreshDisplayedApps()
                }
            }
            .contentShape(Rectangle())
            .sheet(item: $selectedApp) { app in
                RepoAppDetailSheet(app: app)
            }
            .alert(
                languageCode == AppLanguage.arabic.rawValue ? "تعذر تثبيت التطبيق" : "App Installation Failed",
                isPresented: Binding(
                    get: { repositories.downloadError != nil || repositories.installError != nil },
                    set: { isPresented in
                        if !isPresented {
                            repositories.downloadError = nil
                            repositories.installError = nil
                        }
                    }
                )
            ) {
                Button(languageCode == AppLanguage.arabic.rawValue ? "حسناً" : "OK", role: .cancel) {
                    repositories.downloadError = nil
                    repositories.installError = nil
                }
            } message: {
                Text(repositories.downloadError ?? repositories.installError ?? "")
            }
        }
    }

    private func refreshAll() async {
        let repos = repositories.repositories
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask {
                    await repositories.refresh(repo)
                }
            }
        }
    }

    private var titleHeader: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        return Text(isArabic ? "التطبيقات" : "Apps")
            .font(T.sans(32, .bold))
            .foregroundColor(T.ink)
            // Use the selected language as the source of truth. The parent
            // layout direction can be LTR while the app language is Arabic.
            .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
            .padding(.horizontal, T.pad)
            .padding(.top, 24)
            .padding(.bottom, 16)
            // Soft App Store-style separation: a blurred fade keeps the pinned
            // title readable without creating a hard horizontal edge above search.
            .background {
                LinearGradient(
                    colors: [
                        T.bg.opacity(T.isDark ? 0.96 : 0.92),
                        T.bg.opacity(T.isDark ? 0.68 : 0.56),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: 14)
                .padding(.horizontal, -22)
                .padding(.top, -12)
                .padding(.bottom, -8)
                .allowsHitTesting(false)
            }
            // Keep the title's physical placement stable: Arabic text remains
            // Arabic, while trailing maps to the right edge of the screen.
            .environment(\.layoutDirection, .leftToRight)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            if languageCode == AppLanguage.arabic.rawValue {
                searchField
                searchIcon
            } else {
                searchIcon
                searchField
            }
        }
        // Keep the explicit semantic order above from being mirrored a second time.
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .fMilkGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            interactive: true
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: languageCode)
    }

    private var categorySlider: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(
                    title: isArabic ? "الكل" : "All",
                    isSelected: selectedCategory == nil
                ) {
                    selectCategory(nil)
                }
                ForEach(categories, id: \.self) { category in
                    categoryChip(title: category, isSelected: selectedCategory == category) {
                        selectCategory(selectedCategory == category ? nil : category)
                    }
                }
            }
            .padding(.horizontal, T.pad)
        }
        // Chips always read start-to-end in the language's own direction,
        // independent of each label's own script (emoji + Arabic text).
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }

    private func selectCategory(_ category: String?) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedCategory = category
        }
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(T.sans(13, .semibold))
                .foregroundColor(isSelected ? (T.isDark ? .black : .white) : T.ink)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(T.isDark ? Color.white : Color.black)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .fClearGlass(in: Capsule(), interactive: true)
                .scaleEffect(isSelected ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var searchIcon: some View {
        Button {
            searchFieldFocused = false
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(T.isDark ? .white : .black)
                .frame(width: 30, height: 30, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        let textAlignment: TextAlignment = isArabic ? .trailing : .leading
        let frameAlignment: Alignment = isArabic ? .trailing : .leading
        let placeholder = isArabic ? "ألعاب وتطبيقات والمزيد" : "Games, apps and more"

        return ZStack(alignment: frameAlignment) {
            if searchText.isEmpty {
                Text(placeholder)
                    .font(T.sans(15, .bold))
                    .foregroundColor(T.isDark ? .white.opacity(0.48) : .black.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .allowsHitTesting(false)
            }

            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(T.sans(15, .bold))
                .foregroundColor(T.isDark ? .white : .black)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searchFieldFocused)
                .onSubmit { searchFieldFocused = false }
        }
        .environment(\.layoutDirection, .leftToRight)
        .layoutPriority(1)
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "لا توجد تطبيقات بعد" : "No apps yet")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
            MonoText(text: languageCode == AppLanguage.arabic.rawValue ? "لم يرسل المتجر أي تطبيقات حالياً." : "The store didn't return any apps right now.", size: 10, color: T.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private var loadingState: some View {
        VStack(spacing: T.gap) {
            ProgressView()
                .tint(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "جارِ تحميل المتجر…" : "Loading the store…")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: T.gap) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "تعذر تحميل المتجر" : "Couldn't load the store")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
            MonoText(text: message, size: 10, color: T.ink3)
            Button {
                Task {
                    if let selectedCategory {
                        await repositories.refreshCategoryApps(selectedCategory)
                    } else {
                        await refreshAll()
                    }
                    refreshDisplayedApps()
                }
            } label: {
                Text(languageCode == AppLanguage.arabic.rawValue ? "إعادة المحاولة" : "Retry")
                    .font(T.sans(13, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(T.accent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func appRow(_ app: RepoApp) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedApp = app
            } label: {
                HStack(spacing: 12) {
                    CachedAppIcon(url: app.iconURL, size: 44, cornerRadius: 11)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name)
                            .font(T.sans(15, .medium))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            getButton(app)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassSurface(.card, cornerRadius: 18)
        .modifier(RowRevealAnimation())
    }

    private func getButton(_ app: RepoApp) -> some View {
        let isLoading = repositories.activeInstallID == app.id
        return GlassGetButton(
            isLoading: isLoading,
            isInstalled: false,
            disabled: app.downloadURL == nil ||
                (repositories.activeInstallID != nil && repositories.activeInstallID != app.id)
        ) {
            if repositories.activeInstallID == app.id {
                repositories.cancelInstallAttempt(app.id)
            } else {
                // The primary button always means a normal installation. The
                // explicit second-copy action lives in the detail sheet so a stale
                // local record can never change this button's meaning.
                repositories.clearInstalled(app.id)
                Task { await repositories.download(app) }
            }
        }
    }
}

/// Fades + settles a row in the moment it first scrolls on screen, instead
/// of it popping in fully-formed. Keyed to this view instance, so it fires
/// once per row and stays out of the way of `appRow`'s own transaction
/// (which intentionally suppresses animation on filter/category swaps).
private struct RowRevealAnimation: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    appeared = true
                }
            }
    }
}
