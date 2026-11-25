import AppKit
import CryptoKit
import Foundation
import Observation
import UserNotifications

/// One published build, as `ios-ota publish` describes it in build.json (written last, once the build is complete).
struct Build: Codable, Identifiable, Hashable {
    let id: String
    let bundle: String
    let title: String
    let version: String
    let build: String
    let time: String
    let changed: String?       // when its code last changed (commit date, or the publish time); nil on older builds
    let commit: String
    let project: String
    let size: Int
    let manifest: String
    let icon: String?          // "icon.png" in the build folder; nil or empty when the app has none (or an older build)

    var date: Date { ISO8601DateFormatter().date(from: time) ?? .distantPast }
    var whenText: String { date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()) }
    /// What the list of apps sorts by: when the code last changed.
    var changedKey: String { changed ?? time }
    /// "committed Nov 19, 10:02" for a clean commit, else nil.
    var committedText: String? {
        guard let c = changed, c != time, !commit.contains("uncommitted"),
              let d = ISO8601DateFormatter().date(from: c) else { return nil }
        return "committed " + d.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }
    var versionText: String { "\(version) (\(build))" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    /// Opens the install prompt straight away (this build, not just the newest).
    var installLink: String {
        "itms-services://?action=download-manifest&url=" + (manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? manifest)
    }
}

/// An app and its builds, newest first.
struct PublishedApp: Identifiable {
    var id: String { key }
    let key: String            // its folder and address (see Store.key)
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
    func pageURL(_ app: PublishedApp) -> URL? { pageURL(key: app.key) }
    func pageURL(key: String) -> URL? { host.map { URL(string: "https://\($0):\(Self.tailnetPort)/\(key)/")! } }

    /// An app's folder and address: the first 12 hex digits of the SHA-256 of its bundle id, as `ios-ota publish` names it,
    /// so the bundle id is not in any address.
    nonisolated static func key(_ bundle: String) -> String {
        SHA256.hash(data: Data(bundle.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private let server = Server(port: Store.port, root: Store.root)
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var pendingScan: DispatchWorkItem?
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
        // The folder watcher catches publishes and deletions; this also catches Tailscale changing.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(); await self?.checkTailnet() }
        }
        if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    // MARK: Builds

    /// Every published app in the builds folder, apps whose code changed last first, each app's builds newest first.
    /// Read fresh each time (a few small files): the menu calls it after the folder changes, the server for every page.
    nonisolated static func load() -> [PublishedApp] {
        let fm = FileManager.default
        var found: [PublishedApp] = []
        for key in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folder = root.appendingPathComponent(key)
            let builds = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { id -> Build? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(id).appendingPathComponent("build.json")) else { return nil }
                return try? JSONDecoder().decode(Build.self, from: data)
            }
            if !builds.isEmpty { found.append(PublishedApp(key: key, builds: builds.sorted { $0.time > $1.time })) }
        }
        return found.sorted { $0.newest.changedKey > $1.newest.changedKey }
    }

    func scan() {
        let found = Self.load()
        let ids = Set(found.flatMap { $0.builds.map(\.id) })
        if let known, notify {
            for b in found.flatMap(\.builds) where !known.contains(b.id) { announce(b) }
        }
        if ids != known {
            let keys = Set(found.map(\.key))
            Self.index(found, removed: known == nil ? nil : apps.map(\.key).filter { !keys.contains($0) })
        }
        known = ids
        apps = found
    }

    /// Watches the whole builds folder, subfolders included: a publish adds a build inside an app's folder, which a watch on
    /// the top folder alone does not see. Events are gathered for a moment, then the folder is scanned once.
    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<Store>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { store.scanSoon() } }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [Self.root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// A scan a moment from now, replacing one already waiting (a publish writes several files in a row).
    private func scanSoon() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func announce(_ b: Build) {
        let c = UNMutableNotificationContent()
        c.title = "\(b.title) \(b.versionText) is ready"
        c.body = b.commit.isEmpty ? "Install it from the iPhone." : b.commit
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: b.id, content: c, trigger: nil))
    }

    /// Deletes a build. The pages are made per request, so they offer what is left straight away.
    func delete(_ b: Build) {
        try? FileManager.default.removeItem(at: folder(b))
        scan()
    }

    func folder(_ b: Build) -> URL { Self.folder(b) }
    nonisolated static func folder(_ b: Build) -> URL { root.appendingPathComponent(key(b.bundle)).appendingPathComponent(b.id) }

    /// The app's icon at menu size, from its newest build that has one, with rounded corners as the iPhone shows it (the
    /// file is a full square). Drawn at the screen's resolution, so the edges stay smooth.
    func icon(_ app: PublishedApp) -> NSImage? {
        guard let b = app.builds.first(where: { !($0.icon ?? "").isEmpty }),
              let source = NSImage(contentsOf: folder(b).appendingPathComponent(b.icon!)) else { return nil }
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
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
}
