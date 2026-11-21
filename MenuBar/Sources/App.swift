import AppKit
import ServiceManagement
import SwiftUI

/// iOS OTA: serves the over-the-air install pages for your iOS apps (see the ios-ota command in this repository) and shows
/// what is published, from the menu bar. Projects publish with `ios-ota publish`; this app picks the builds up by itself.
@main
struct IOSOTAApp: App {
    @State private var store = Store()

    init() {
        // The install pages are served only while this app runs, so it starts at login unless that was turned off in the menu.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(systemName: "iphone.and.arrow.forward")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Install on iPhone", id: "qr", for: String.self) { $text in
            if let text { QRWindow(text: text) }
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Server and tailnet.
        if let problem = store.serverProblem {
            Text(problem)
            Button("Restart Server") { store.restartServer() }
        } else {
            Text("Serving on 127.0.0.1:\(String(Store.port))")
        }
        if store.host == nil {
            Text("Tailscale is off: the iPhone cannot reach the pages")
        } else if store.shared {
            Text("Shared on the tailnet at port \(String(Store.tailnetPort))")
        } else {
            Button("Share on the Tailnet (Port \(String(Store.tailnetPort)))") { Task { await store.share() } }
        }
        if let url = store.pageURL {
            Button("Open the Apps Page") { NSWorkspace.shared.open(url) }
            Button("Show the Apps Page as a QR Code") { show(url.absoluteString) }
        }
        Divider()

        // Apps.
        if store.apps.isEmpty {
            Text("Nothing published yet. In a project: ios-ota publish")
        }
        ForEach(store.apps) { app in
            Menu {
                appItems(app)
            } label: {
                if let icon = store.icon(app) {
                    Label { Text("\(app.newest.title)  \(app.newest.versionText)") } icon: { Image(nsImage: icon) }
                } else {
                    Text("\(app.newest.title)  \(app.newest.versionText)")
                }
            }
        }
        Divider()

        Toggle("Notify About New Builds", isOn: Binding(get: { store.notify }, set: { store.notify = $0 }))
        Toggle("Start at Login", isOn: Binding(get: { startsAtLogin }, set: { setStartsAtLogin($0) }))
        Button("Quit (Installs Stop Until It Runs Again)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private func appItems(_ app: PublishedApp) -> some View {
        let b = app.newest
        Text("\(b.whenText) \u{00B7} \(b.sizeText)")
        if !b.commit.isEmpty { Text(b.commit) }
        if let url = store.pageURL(app) {
            Button("Copy Install Page Link") { copy(url.absoluteString) }
            Button("Show Install Page as a QR Code") { show(url.absoluteString) }
            Button("Open Install Page") { NSWorkspace.shared.open(url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(b).appendingPathComponent("App.ipa")]) }
        if !b.project.isEmpty {
            Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b.project)]) }
        }
        Divider()
        Menu("All Builds (\(app.builds.count))") {
            ForEach(app.builds) { build in
                Menu("\(build.versionText)  \(build.whenText)") {
                    if !build.commit.isEmpty { Text(build.commit) }
                    Button("Copy Direct Install Link") { copy(build.installLink) }
                    Button("Show Direct Install Link as a QR Code") { show(build.installLink) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(build).appendingPathComponent("App.ipa")]) }
                    Divider()
                    Button("Delete This Build") { store.delete(build) }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func show(_ s: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "qr", value: s)
    }

    private func setStartsAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }
}
