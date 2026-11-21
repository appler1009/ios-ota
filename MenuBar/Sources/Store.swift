import AppKit
import Foundation
import Observation
import UserNotifications

/// One published build, as `ios-ota publish` describes it in build.json (see pages.py for the fields).
struct Build: Codable, Identifiable, Hashable {
    let id: String
    let bundle: String
    let title: String
    let version: String
    let build: String
    let time: String
    let commit: String
    let project: String
    let size: Int
    let manifest: String
    let icon: String?          // "icon.png" in the build folder; nil or empty when the app has none (or an older build)

    var date: Date { ISO8601DateFormatter().date(from: time) ?? .distantPast }
    var whenText: String { date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
    var versionText: String { "\(version) (\(build))" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    /// Opens the install prompt straight away (this build, not just the newest).
    var installLink: String {
        "itms-services://?action=download-manifest&url=" + (manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? manifest)
    }
}

/// An app and its builds, newest first.
struct PublishedApp: Identifiable {
    var id: String { bundle }
    let bundle: String
    let builds: [Build]
    var newest: Build { builds[0] }
}

/// What the menu shows: the server, the tailnet share, and every published app. Watches the builds folder, so a build
/// that `ios-ota publish` adds (from any project) shows up at once, with a notification.
@MainActor @Observable final class Store {
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iOS-OTA")
    nonisolated static let port: UInt16 = 8445            // where this app serves
    nonisolated static let tailnetPort = 8444             // what Tailscale shares it as

    private(set) var apps: [PublishedApp] = []
    private(set) var serverProblem: String? = "Starting\u{2026}"
    private(set) var host: String?            // this Mac's tailnet name, nil if Tailscale is off
    private(set) var shared = false           // Tailscale passes 8444 on to this server
    var notify: Bool {
        didSet {
            UserDefaults.standard.set(notify, forKey: "notify")
            if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
    }

    var pageURL: URL? { host.map { URL(string: "https://\($0):\(Self.tailnetPort)/")! } }
    func pageURL(_ app: PublishedApp) -> URL? { host.map { URL(string: "https://\($0):\(Self.tailnetPort)/\(app.bundle)/")! } }

    private let server = Server(port: Store.port, root: Store.root)
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var known: Set<String>?       // build ids seen so far; nil before the first scan
    @ObservationIgnored private var timer: Timer?

    init() {
        notify = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        server.onState = { [weak self] in self?.serverProblem = $0 }
        server.start()
        scan()
        watch()
        Task { await checkTailnet() }
        // The folder watcher catches publishes (each one rewrites the top page); this also catches Tailscale changing.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(); await self?.checkTailnet() }
        }
        if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    // MARK: Builds

    func scan() {
        let fm = FileManager.default
        var found: [PublishedApp] = []
        for bundle in (try? fm.contentsOfDirectory(atPath: Self.root.path)) ?? [] {
            let folder = Self.root.appendingPathComponent(bundle)
            let builds = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { id -> Build? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(id).appendingPathComponent("build.json")) else { return nil }
                return try? JSONDecoder().decode(Build.self, from: data)
            }
            if !builds.isEmpty { found.append(PublishedApp(bundle: bundle, builds: builds.sorted { $0.time > $1.time })) }
        }
        found.sort { $0.newest.time > $1.newest.time }
        let ids = Set(found.flatMap { $0.builds.map(\.id) })
        if let known, notify {
            for b in found.flatMap(\.builds) where !known.contains(b.id) { announce(b) }
        }
        known = ids
        apps = found
    }

    private func watch() {
        let fd = open(Self.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // pages.py writes the top page last, once the build is complete; a moment later everything is in place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.scan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func announce(_ b: Build) {
        let c = UNMutableNotificationContent()
        c.title = "\(b.title) \(b.versionText) is ready"
        c.body = b.commit.isEmpty ? "Install it from the iPhone." : b.commit
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: b.id, content: c, trigger: nil))
    }

    /// Deletes a build, then rewrites the pages so they offer what is left.
    func delete(_ b: Build) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(b.bundle).appendingPathComponent(b.id))
        if let script = Bundle.main.url(forResource: "pages", withExtension: "py") {
            _ = try? run("/usr/bin/python3", [script.path, Self.root.path])
        }
        scan()
    }

    func folder(_ b: Build) -> URL { Self.root.appendingPathComponent(b.bundle).appendingPathComponent(b.id) }

    /// The app's icon at menu size, from its newest build that has one.
    func icon(_ app: PublishedApp) -> NSImage? {
        guard let b = app.builds.first(where: { !($0.icon ?? "").isEmpty }),
              let image = NSImage(contentsOf: folder(b).appendingPathComponent(b.icon!)) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    // MARK: Server and tailnet

    func restartServer() { serverProblem = "Starting\u{2026}"; server.start() }

    nonisolated private static var tailscale: String {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/tailscale"
    }

    func checkTailnet() async {
        let status = await Task.detached { try? Self.json(Self.tailscale, ["status", "--json"]) }.value
        let serve = await Task.detached { try? Self.json(Self.tailscale, ["serve", "status", "--json"]) }.value
        host = ((status?["Self"] as? [String: Any])?["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        shared = (serve?["TCP"] as? [String: Any])?["\(Self.tailnetPort)"] != nil
    }

    /// Turns on Tailscale's share of this server (port 8444, tailnet only), as `ios-ota publish` does.
    func share() async {
        _ = await Task.detached { try? Self.run(Self.tailscale, ["serve", "--bg", "--https=\(Self.tailnetPort)", "http://127.0.0.1:\(Self.port)"]) }.value
        await checkTailnet()
    }

    nonisolated private static func json(_ tool: String, _ args: [String]) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(run(tool, args).utf8)) as? [String: Any]
    }

    @discardableResult nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func run(_ tool: String, _ args: [String]) throws -> String { try Self.run(tool, args) }
}
