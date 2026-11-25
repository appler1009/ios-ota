import AppIntents
import AppKit
import ServiceManagement
import SwiftUI

/// iOS OTA: serves the over-the-air install pages for your iOS apps (see the ios-ota command in this repository) and shows
/// what is published, from the menu bar. Projects publish with `ios-ota publish`; this app picks the builds up by itself.
@main
struct IOSOTAApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings { EmptyView() }          // the menu is AppKit's (see MenuController); the app has no other window of its own
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The install pages are served only while this app runs, so it starts at login unless that was turned off in the menu.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
        let store = Store(), menu = MenuController(store: store)
        self.menu = menu
        // What the App Intents (Intents.swift) act through, when Siri, Spotlight or Shortcuts run one.
        AppDependencyManager.shared.add(dependency: store)
        AppDependencyManager.shared.add(dependency: menu)
    }
}

/// The menu bar item and its menu, in AppKit: a menu item there can have a subtitle (a smaller grey second line, used for
/// versions and dates) and its own icon, which SwiftUI's menu bar menus drop. Rebuilt each time it opens, from the store.
@MainActor final class MenuController: NSObject, NSMenuDelegate {
    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var qrWindows: [NSWindow] = []

    init(store: Store) {
        self.store = store
        super.init()
        // A solid shape, so it holds its own next to the other menu bar icons; an outline symbol looked faint there.
        let symbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold, scale: .large)
        item.button?.image = NSImage(systemSymbolName: "arrow.down.app.fill", accessibilityDescription: "iOS OTA")?
            .withSymbolConfiguration(symbol)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Server and tailnet.
        if let problem = store.serverProblem {
            menu.addItem(note(problem))
            menu.addItem(action("Restart Server") { [store] in store.restartServer() })
        } else {
            menu.addItem(note("Serving on 127.0.0.1:\(Store.port)"))
        }
        if store.host == nil {
            menu.addItem(note("Tailscale is off: the iPhone cannot reach the pages"))
        } else if store.shared {
            menu.addItem(note("Shared on the tailnet at port \(Store.tailnetPort)"))
        } else {
            menu.addItem(action("Share on the Tailnet (Port \(Store.tailnetPort))") { [store] in Task { await store.share() } })
        }
        if let url = store.pageURL {
            menu.addItem(action("Open the Apps Page") { NSWorkspace.shared.open(url) })
            menu.addItem(action("Show the Apps Page as a QR Code") { [weak self] in self?.showQR(url.absoluteString) })
        }
        menu.addItem(.separator())

        // Apps: the name, the version under it, the app's icon.
        if store.apps.isEmpty { menu.addItem(note("Nothing published yet. In a project: ios-ota publish")) }
        for app in store.apps {
            let entry = NSMenuItem(title: app.newest.title, action: nil, keyEquivalent: "")
            subtitle(entry, app.newest.versionText)
            entry.image = store.icon(app)
            showImage(entry)
            entry.submenu = appMenu(app)
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let notify = action("Notify About New Builds") { [store] in store.notify.toggle() }
        notify.state = store.notify ? .on : .off
        menu.addItem(notify)
        let login = action("Start at Login") {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit (Installs Stop Until It Runs Again)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func appMenu(_ app: PublishedApp) -> NSMenu {
        let menu = NSMenu()
        let b = app.newest
        menu.addItem(note("Built \(b.whenText) \u{00B7} \(b.sizeText)"))
        if !b.commit.isEmpty { menu.addItem(note([b.commit, b.committedText].compactMap { $0 }.joined(separator: " \u{00B7} "))) }
        if let url = store.pageURL(app) {
            menu.addItem(action("Copy Install Page Link") { Self.copy(url.absoluteString) })
            menu.addItem(action("Show Install Page as a QR Code") { [weak self] in self?.showQR(url.absoluteString) })
            menu.addItem(action("Open Install Page") { NSWorkspace.shared.open(url) })
        }
        let ipa = store.folder(b).appendingPathComponent("App.ipa")
        menu.addItem(action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ipa]) })
        if !b.project.isEmpty {
            let project = URL(fileURLWithPath: b.project)
            menu.addItem(action("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) })
        }
        menu.addItem(.separator())

        let all = NSMenuItem(title: "All Builds (\(app.builds.count))", action: nil, keyEquivalent: "")
        let builds = NSMenu()
        for build in app.builds {
            let entry = NSMenuItem(title: build.versionText, action: nil, keyEquivalent: "")
            subtitle(entry, build.whenText)
            let sub = NSMenu()
            if !build.commit.isEmpty { sub.addItem(note(build.commit)) }
            sub.addItem(action("Copy Direct Install Link") { Self.copy(build.installLink) })
            sub.addItem(action("Show Direct Install Link as a QR Code") { [weak self] in self?.showQR(build.installLink) })
            let file = store.folder(build).appendingPathComponent("App.ipa")
            sub.addItem(action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            sub.addItem(.separator())
            sub.addItem(action("Delete This Build") { [store] in store.delete(build) })
            entry.submenu = sub
            builds.addItem(entry)
        }
        all.submenu = builds
        menu.addItem(all)
        return menu
    }

    // MARK: Items

    /// A line that only tells something (greyed, not clickable).
    private func note(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureItem(title: title, run: run)
        i.target = i
        return i
    }

    /// The smaller grey second line of a menu item.
    private func subtitle(_ item: NSMenuItem, _ text: String) { item.subtitle = text }

    /// macOS 27 hides menu item images by default; this item's image is meant to be seen.
    private func showImage(_ item: NSMenuItem) {
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func showQR(_ text: String) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: QRWindow(text: text)))
        w.title = "Install on iPhone"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        qrWindows.removeAll { !$0.isVisible }
        qrWindows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// A menu item that runs a closure when chosen.
private final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
