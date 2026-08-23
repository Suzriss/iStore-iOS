import Foundation

// MARK: - Persisted repository record

/// An app source (AltStore-style catalog). iStore is locked to a single,
/// fixed Ceresify repository — see `RepositoryStore.ceresifyRepository`.
struct Repository: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, name: String, addedAt: Date = .now) {
        self.id = id
        self.url = url
        self.name = name
        self.addedAt = addedAt
    }
}

// MARK: - AltStore source JSON (lenient)

/// A decoded AltStore/SideStore source. Decoding is deliberately forgiving: one
/// malformed app entry is skipped rather than failing the whole feed, and every
/// non-essential field is optional — this is untrusted data off the network.
struct RepoSource: Codable, Equatable, Sendable {
    let name: String?
    let identifier: String?
    let iconURL: URL?
    let apps: [RepoApp]

    private enum CodingKeys: String, CodingKey { case name, identifier, iconURL, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        identifier = try? c.decodeIfPresent(String.self, forKey: .identifier)
        iconURL = LenientDecode.url(c, .iconURL)
        // Skip individual bad entries instead of nuking the entire list.
        let raw = (try? c.decode([FailableApp].self, forKey: .apps)) ?? []
        apps = raw.compactMap(\.value)
    }

    /// Wrapper so a single un-decodable app doesn't fail the whole array.
    private struct FailableApp: Decodable {
        let value: RepoApp?
        init(from decoder: Decoder) throws { value = try? RepoApp(from: decoder) }
    }
}

/// A published version in a source catalog. Keeping the complete version list
/// lets the UI explain update history while the existing download path still
/// uses the same first-version fields as before.
struct RepoVersion: Codable, Equatable, Identifiable, Sendable {
    let version: String?
    let downloadURL: URL?
    let size: Int64?
    let date: Date?

    var id: String {
        "\(version ?? "")|\(downloadURL?.absoluteString ?? "")"
    }

    init(version: String?, downloadURL: URL?, size: Int64?, date: Date? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case version, downloadURL, size, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = LenientDecode.url(c, .downloadURL)
        size = LenientDecode.int64(c, .size)
        date = LenientDecode.date(c, .date)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
        try c.encodeIfPresent(size, forKey: .size)
        // Encoded as epoch seconds (not JSONEncoder's default reference-date
        // seconds) so it round-trips through `LenientDecode.date` unchanged.
        try c.encodeIfPresent(date?.timeIntervalSince1970, forKey: .date)
    }
}

/// One app in a source. Handles both the flat v1 shape (`version`,
/// `downloadURL`, `size` at the top level) and the newer v2 shape where those
/// live in a `versions` array — the first version still drives downloads.
struct RepoApp: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let localizedDescription: String?
    let category: String?
    let iconURL: URL?
    let urlSchemes: [String]
    let screenshotURLs: [URL]
    let version: String?
    let downloadURL: URL?
    let size: Int64?
    let versions: [RepoVersion]
    /// When this app's current version was published. Falls back to the
    /// first entry in `versions` when the feed omits the flat field.
    let lastUpdated: Date?

    var id: String { bundleIdentifier.isEmpty ? name : bundleIdentifier }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, localizedDescription, category
        case iconURL, urlSchemes, urlScheme, screenshotURLs, screenshots, version, downloadURL, size, versions, versionDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        bundleIdentifier = (try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        developerName = try? c.decodeIfPresent(String.self, forKey: .developerName)
        localizedDescription = try? c.decodeIfPresent(String.self, forKey: .localizedDescription)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        iconURL = LenientDecode.url(c, .iconURL)
        var decodedSchemes = (try? c.decodeIfPresent([String].self, forKey: .urlSchemes)) ?? []
        if let singleScheme = try? c.decode(String.self, forKey: .urlScheme) {
            decodedSchemes.append(singleScheme)
        }
        urlSchemes = decodedSchemes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, scheme in
                if !result.contains(scheme) { result.append(scheme) }
            }

        let primaryScreenshots = (try? c.decodeIfPresent([String].self, forKey: .screenshotURLs)) ?? []
        let fallbackScreenshots = (try? c.decodeIfPresent([String].self, forKey: .screenshots)) ?? []
        screenshotURLs = (primaryScreenshots + fallbackScreenshots).compactMap(URL.init(string:))

        let flatVersion = try? c.decodeIfPresent(String.self, forKey: .version)
        let flatURL = LenientDecode.url(c, .downloadURL)
        let flatSize = LenientDecode.int64(c, .size)
        let decodedVersions = (try? c.decodeIfPresent([RepoVersion].self, forKey: .versions)) ?? []
        var uniqueVersions: [RepoVersion] = []
        var seenVersionIDs = Set<String>()
        for candidate in decodedVersions where seenVersionIDs.insert(candidate.id).inserted {
            uniqueVersions.append(candidate)
        }
        let first = uniqueVersions.first
        versions = uniqueVersions.isEmpty && (flatVersion != nil || flatURL != nil || flatSize != nil)
            ? [RepoVersion(version: flatVersion, downloadURL: flatURL, size: flatSize)]
            : uniqueVersions
        version = flatVersion ?? first?.version
        downloadURL = flatURL ?? first?.downloadURL
        size = flatSize ?? first?.size
        let flatDate = LenientDecode.date(c, .versionDate)
        lastUpdated = flatDate ?? first?.date
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encodeIfPresent(developerName, forKey: .developerName)
        try c.encodeIfPresent(localizedDescription, forKey: .localizedDescription)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(iconURL?.absoluteString, forKey: .iconURL)
        try c.encode(urlSchemes, forKey: .urlSchemes)
        try c.encode(screenshotURLs.map(\.absoluteString), forKey: .screenshotURLs)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encode(versions, forKey: .versions)
        try c.encodeIfPresent(lastUpdated?.timeIntervalSince1970, forKey: .versionDate)
    }
}

/// URLs and numbers in real-world feeds are inconsistent (bad URL strings,
/// sizes as strings). Decode them without throwing so one odd value can't sink
/// the whole parse.
private enum LenientDecode {
    static func url<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: s)
    }
    static func int64<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let n = try? c.decodeIfPresent(Int64.self, forKey: key) { return n }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    // Only ever touched from the single background task that decodes a feed,
    // never concurrently — safe despite ISO8601DateFormatter not being Sendable.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    /// Accepts either an ISO 8601 string from the network feed (with or
    /// without fractional seconds) or a `timeIntervalSince1970` number, which
    /// is how this app's own on-disk catalog cache round-trips dates.
    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }
}

// MARK: - Store

/// Fetches the Ceresify catalog (AltStore-shaped JSON) and downloads an app's
/// IPA into the container. A completed download is surfaced via `pendingIPA`
/// for the silent installer to adopt.
@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []

    /// Last successfully fetched catalog per repository (in memory only).
    @Published var catalog: [UUID: RepoSource] = [:]
    @Published var fetchError: [UUID: String] = [:]
    @Published var loadingRepoID: UUID?

    /// Bundle id of the app currently downloading, if any.
    @Published var activeDownloadID: String?
    /// Remains active from GET through signing and the iOS install handoff.
    @Published var activeInstallID: String?
    @Published var downloadError: String?
    @Published var installError: String?
    /// Source apps that have reached the iOS installer. The UI verifies this
    /// state when Open is tapped and clears it if iOS cannot open the app.
    @Published private(set) var installedAppIDs: Set<String>
    @Published var pendingAppID: String?
    @Published var pendingAppName: String?
    /// True only when the user explicitly requested a separately signed copy.
    @Published var pendingInstallAsAdditionalCopy = false

    /// Set when a download finishes — the silent installer observes this and loads it.
    @Published var pendingIPA: URL?

    private let indexURL: URL
    private let cacheURL: URL
    private let downloadsDir: URL
    private var installWatchdogTask: Task<Void, Never>?

    private struct Index: Codable { var repositories: [Repository] = [] }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        indexURL = base.appendingPathComponent("repositories.json")
        cacheURL = base.appendingPathComponent("repository-catalog-cache.json")
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        installedAppIDs = Set(UserDefaults.standard.stringArray(forKey: "istore.installed-app-ids") ?? [])
        load()
        seedCeresifyRepository()
        Task { @MainActor [weak self] in
            await self?.loadCatalogCache()
        }
        #if DEBUG
        RepoSource._selfTest()
        #endif
    }

    // MARK: Fixed source

    /// The single catalog iStore is locked to. Fixed id/date so the seed is a
    /// no-op (and the in-memory catalog cache still hits) once already saved.
    private static let ceresifyRepository = Repository(
        id: UUID(uuidString: "5B1D7C8A-1CE6-4A00-8000-000000000001")!,
        url: URL(string: "https://dev.ceresify.com/api/repo.json?ch=ahmad")!,
        name: "Ceresify",
        addedAt: Date(timeIntervalSince1970: 0)
    )

    private func seedCeresifyRepository() {
        guard repositories != [Self.ceresifyRepository] else { return }
        repositories = [Self.ceresifyRepository]
        catalog = [:]
        fetchError = [:]
        save()
    }

    // MARK: Networking

    func refresh(_ repo: Repository) async {
        loadingRepoID = repo.id
        fetchError[repo.id] = nil
        defer { if loadingRepoID == repo.id { loadingRepoID = nil } }
        do {
            var req = URLRequest(url: repo.url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 120
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                fetchError[repo.id] = "The repository server returned an error."
                return
            }
            let source = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(RepoSource.self, from: data)
            }.value
            catalog[repo.id] = source
            saveCatalogCache()
            // Adopt the source's own display name once we know it.
            if let name = source.name, !name.isEmpty,
               let i = repositories.firstIndex(where: { $0.id == repo.id }),
               repositories[i].name != name {
                repositories[i].name = name
                save()
            }
        } catch {
            fetchError[repo.id] = error.localizedDescription
        }
    }

    func beginInstallAttempt(_ appID: String) {
        installWatchdogTask?.cancel()
        activeInstallID = appID
        installError = nil
        installWatchdogTask = Task { @MainActor [weak self] in
            do {
                // No attempt should permanently disable every GET button after
                // a broken download, signing run, or iOS handoff.
                try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard let self, self.activeInstallID == appID else { return }
            self.installError = "The installation timed out. Please try again."
            self.activeInstallID = nil
            self.activeDownloadID = nil
            self.pendingIPA = nil
            self.pendingAppID = nil
            self.pendingAppName = nil
            self.pendingInstallAsAdditionalCopy = false
            self.installWatchdogTask = nil
        }
    }

    func completeInstallAttempt(_ appID: String?, error: String? = nil) {
        if let error, !error.isEmpty {
            installError = error
        }
        if activeInstallID == appID {
            activeInstallID = nil
            activeDownloadID = nil
            pendingIPA = nil
            pendingAppID = nil
            pendingAppName = nil
            pendingInstallAsAdditionalCopy = false
            installWatchdogTask?.cancel()
            installWatchdogTask = nil
        }
    }

    func cancelInstallAttempt(_ appID: String) {
        guard activeInstallID == appID else { return }
        activeInstallID = nil
        activeDownloadID = nil
        pendingAppID = nil
        pendingAppName = nil
        pendingInstallAsAdditionalCopy = false
        pendingIPA = nil
        installError = nil
        installWatchdogTask?.cancel()
        installWatchdogTask = nil
    }

    func markInstalled(_ appID: String) {
        installedAppIDs.insert(appID)
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
    }

    func clearInstalled(_ appID: String) {
        installedAppIDs.remove(appID)
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
    }

    func download(_ app: RepoApp, asAdditionalCopy: Bool = false) async {
        guard let url = app.downloadURL else {
            downloadError = "This app has no download URL."
            return
        }
        activeDownloadID = app.id
        beginInstallAttempt(app.id)
        pendingAppID = app.id
        pendingAppName = app.name
        pendingInstallAsAdditionalCopy = asAdditionalCopy
        downloadError = nil
        defer { if activeDownloadID == app.id { activeDownloadID = nil } }
        do {
            // Streams to a temp file — safe for large IPAs (no full in-memory load).
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            let (tempURL, resp) = try await URLSession.shared.download(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                let message = "Download failed — the server returned an error."
                downloadError = message
                completeInstallAttempt(app.id, error: message)
                return
            }
            // Never reuse the previous path: iOS can still be reading the old
            // served IPA while the user retries after deleting the app. A unique
            // destination also guarantees pendingIPA emits a new value.
            let baseName = (Self.ipaName(for: app) as NSString).deletingPathExtension
            let destination = downloadsDir.appendingPathComponent(
                "\(baseName)-\(UUID().uuidString).ipa"
            )
            // A cross-volume move can become a large copy. Keep it away from
            // the main actor so the app remains responsive when downloads end.
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: tempURL, to: destination)
            }.value
            pendingIPA = destination
        } catch {
            let message = error.localizedDescription
            downloadError = message
            completeInstallAttempt(app.id, error: message)
        }
    }

    /// A safe on-disk filename like `AppName-1.2.3.ipa`.
    private static func ipaName(for app: RepoApp) -> String {
        let base = app.name.isEmpty ? app.id : app.name
        let stem = base.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let version = app.version.map { "-\($0)" } ?? ""
        return "\(stem)\(version).ipa"
    }

    // MARK: Persistence

    private func loadCatalogCache() async {
        let sourceURL = cacheURL
        let cached: [UUID: RepoSource]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: sourceURL) else { return nil }
            return try? JSONDecoder().decode([UUID: RepoSource].self, from: data)
        }.value
        guard let cached else { return }
        for repo in repositories {
            if let source = cached[repo.id] {
                catalog[repo.id] = source
            }
        }
    }

    private func saveCatalogCache() {
        let snapshot = catalog
        let destination = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        repositories = index.repositories
    }

    private func save() {
        let index = Index(repositories: repositories)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .completeFileProtection)
        }
    }
}

#if DEBUG
extension RepoSource {
    /// Smallest check that fails if the lenient decoder breaks — decodes both the
    /// flat (v1) and versioned (v2) AltStore shapes. Called once at debug launch.
    static func _selfTest() {
        guard let flat = """
        {"name":"Flat","apps":[{"name":"A","bundleIdentifier":"com.a",
        "version":"1.0","downloadURL":"https://e.com/a.ipa","size":123}]}
        """.data(using: .utf8),
        let versioned = """
        {"name":"V2","apps":[{"name":"B","bundleIdentifier":"com.b","versions":[
        {"version":"2.0","downloadURL":"https://e.com/b.ipa","size":"456"}]}]}
        """.data(using: .utf8),
        let f = try? JSONDecoder().decode(RepoSource.self, from: flat),
        let v = try? JSONDecoder().decode(RepoSource.self, from: versioned)
        else { return }
        assert(f.apps.first?.downloadURL?.absoluteString == "https://e.com/a.ipa")
        assert(f.apps.first?.size == 123)
        assert(f.apps.first?.versions.count == 1)
        assert(v.apps.first?.version == "2.0")
        assert(v.apps.first?.downloadURL?.absoluteString == "https://e.com/b.ipa")
        assert(v.apps.first?.size == 456)
        assert(v.apps.first?.versions.count == 1)
    }
}
#endif
