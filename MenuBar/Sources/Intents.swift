import AppIntents
import AppKit
import CoreSpotlight

/// The published apps and what can be done with them, for Siri, Spotlight and Shortcuts: the same things the menu offers
/// for an app (its install page, as a link, a QR code, or in the browser). Publishing and deleting builds stay out: one is a
/// build run from the project's folder, the other is not something to do by voice.

/// A published app, as its newest build describes it. Indexed in Spotlight (see `Store.index`), so Siri can find it by name
/// and answer questions about it ("when did I last publish Quiet Email?").
struct PublishedAppEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Published App", numericFormat: "\(placeholder: .int) published apps")
    static let defaultQuery = PublishedAppQuery()

    let id: String             // the app's key (see Store.key)

    @Property(title: "Name") var name: String
    @Property(title: "Version") var version: String
    @Property(title: "Published") var published: Date
    @Property(title: "Source") var source: String           // "main @ 1a2b3c4", maybe "with uncommitted changes"
    @Property(title: "Builds Kept") var buildCount: Int

    private let iconData: Data?

    init(_ app: PublishedApp) {
        let b = app.newest
        id = app.key
        iconData = app.builds.lazy.compactMap { b in
            (b.icon ?? "").isEmpty ? nil : try? Data(contentsOf: Store.folder(b).appendingPathComponent(b.icon!))
        }.first
        name = b.title
        version = b.versionText
        published = b.date
        source = b.commit
        buildCount = app.builds.count
    }

    var displayRepresentation: DisplayRepresentation {
        // A fixed date, not "3 hours ago": Spotlight keeps this text as it was when the app was indexed.
        DisplayRepresentation(title: "\(name)", subtitle: "\(version) \u{00B7} published \(published.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()))",
                              image: iconData.map { .init(data: $0) })
    }
}

struct PublishedAppQuery: EntityStringQuery {
    func entities(for identifiers: [PublishedAppEntity.ID]) async throws -> [PublishedAppEntity] {
        Store.load().filter { identifiers.contains($0.key) }.map(PublishedAppEntity.init)
    }

    func entities(matching string: String) async throws -> [PublishedAppEntity] {
        Store.load().filter { $0.newest.title.localizedStandardContains(string) }.map(PublishedAppEntity.init)
    }

    func suggestedEntities() async throws -> [PublishedAppEntity] {
        Store.load().map(PublishedAppEntity.init)
    }
}

enum InstallPageError: Error, CustomLocalizedStringResourceConvertible {
    case noTailnet
    case gone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noTailnet: "Tailscale is off on this Mac, so the iPhone cannot reach the install pages."
        case .gone: "That app has no published builds any more."
        }
    }
}

/// The install page of an app, checking that it is still published and that the tailnet is up (asking Tailscale again if
/// the store has not heard yet, as when the app was launched just for this).
@MainActor private func installPage(_ app: PublishedAppEntity, _ store: Store) async throws -> URL {
    guard Store.load().contains(where: { $0.key == app.id }) else { throw InstallPageError.gone }
    if store.host == nil { await store.checkTailnet() }
    guard let url = store.pageURL(key: app.id) else { throw InstallPageError.noTailnet }
    return url
}

struct OpenInstallPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Install Page"
    static let description = IntentDescription("Opens a published app's install page in the browser.")

    @Parameter(title: "App") var app: PublishedAppEntity
    @Dependency private var store: Store

    static var parameterSummary: some ParameterSummary { Summary("Open the install page of \(\.$app)") }

    @MainActor func perform() async throws -> some IntentResult {
        NSWorkspace.shared.open(try await installPage(app, store))
        return .result()
    }
}

struct ShowInstallQRCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Install Page as a QR Code"
    static let description = IntentDescription("Shows a QR code of a published app's install page, for the iPhone's camera.")

    @Parameter(title: "App") var app: PublishedAppEntity
    @Dependency private var store: Store
    @Dependency private var menu: MenuController

    static var parameterSummary: some ParameterSummary { Summary("Show the install page of \(\.$app) as a QR code") }

    @MainActor func perform() async throws -> some IntentResult {
        menu.showQR(try await installPage(app, store).absoluteString)
        return .result()
    }
}

struct CopyInstallLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Install Page Link"
    static let description = IntentDescription("Copies the link to a published app's install page, and gives it to the next action.")

    @Parameter(title: "App") var app: PublishedAppEntity
    @Dependency private var store: Store

    static var parameterSummary: some ParameterSummary { Summary("Copy the install page link of \(\.$app)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let url = try await installPage(app, store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        return .result(value: url, dialog: "Copied the install page link of \(app.name).")
    }
}

struct IOSOTAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowInstallQRCodeIntent(), phrases: [
            "Show the \(.applicationName) QR code for \(\.$app)",
            "Install \(\.$app) with \(.applicationName)",
        ], shortTitle: "Install QR Code", systemImageName: "qrcode")
        AppShortcut(intent: OpenInstallPageIntent(), phrases: [
            "Open the \(.applicationName) page for \(\.$app)",
        ], shortTitle: "Open Install Page", systemImageName: "safari")
        AppShortcut(intent: CopyInstallLinkIntent(), phrases: [
            "Copy the \(.applicationName) link for \(\.$app)",
        ], shortTitle: "Copy Install Link", systemImageName: "link")
    }
}

extension Store {
    /// Keeps Spotlight's index of the published apps (and the app names the phrases above offer) in step with the builds
    /// folder: called after a scan finds a different set of builds. `removed` is nil on the first scan, which starts the
    /// index afresh, since apps may have been deleted while this app was not running.
    nonisolated static func index(_ apps: [PublishedApp], removed: [String]?) {
        Task.detached {
            let index = CSSearchableIndex.default()
            if let removed {
                if !removed.isEmpty { try? await index.deleteAppEntities(identifiedBy: removed, ofType: PublishedAppEntity.self) }
            } else {
                try? await index.deleteAppEntities(ofType: PublishedAppEntity.self)
            }
            try? await index.indexAppEntities(apps.map(PublishedAppEntity.init))
            IOSOTAShortcuts.updateAppShortcutParameters()
        }
    }
}
