import Foundation
import Network

/// The web server for the install pages, on 127.0.0.1 only (Tailscale passes it on to the tailnet over HTTPS). The pages
/// are made for each request from the builds folder: / lists the apps, /<app key>/ is an app's page. Everything else is a
/// file from the builds folder (the app, its manifest, its icon). GET and HEAD, one request per connection, files sent
/// whole, with the types iOS expects for an over-the-air install and no caching.
final class Server: @unchecked Sendable {
    let port: UInt16
    let root: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ios-ota.server")
    /// Called on the main queue: nil while serving, or why not.
    var onState: (String?) -> Void = { _ in }

    init(port: UInt16, root: URL) { self.port = port; self.root = root }

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] state in
                let problem: String?
                switch state {
                case .ready: problem = nil
                case .failed(let e): problem = "Cannot serve on port \(self?.port ?? 0): \(e.localizedDescription)"
                case .waiting(let e): problem = "Waiting for port \(self?.port ?? 0): \(e.localizedDescription)"
                default: return
                }
                DispatchQueue.main.async { self?.onState(problem) }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            onState("Cannot serve: \(error.localizedDescription)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    // MARK: Requests

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || done || buffer.count > 65_536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buffer)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return send(c, 405, "text/plain", Data("Method not allowed".utf8)) }
        let headOnly = parts[0] == "HEAD"
        let path = (String(parts[1]).split(separator: "?").first.map(String.init) ?? "/").removingPercentEncoding ?? ""
        let segments = path.split(separator: "/").map(String.init)

        // The pages, made now from what is published.
        if segments.isEmpty { return send(c, 200, "text/html; charset=utf-8", Data(Pages.listPage(Store.load()).utf8), headOnly: headOnly) }
        if segments.count == 1 {
            guard let app = Store.load().first(where: { $0.key == segments[0] }) else { return send(c, 404, "text/plain", Data("Not found".utf8)) }
            // Pages link relative to their folder, so the address must end in a slash.
            if !path.hasSuffix("/") { return redirect(c, to: "/\(app.key)/") }
            return send(c, 200, "text/html; charset=utf-8", Data(Pages.appPage(app.newest).utf8), headOnly: headOnly)
        }

        // Files of a build. build.json is for the menu bar app only: it names the bundle id and the project's folder.
        guard let file = resolve(path), file.lastPathComponent != "build.json" else { return send(c, 404, "text/plain", Data("Not found".utf8)) }
        guard let body = try? Data(contentsOf: file, options: .alwaysMapped) else { return send(c, 404, "text/plain", Data("Not found".utf8)) }
        send(c, 200, Self.type(of: file), body, headOnly: headOnly)
    }

    /// The file a URL path names inside the builds folder, or nil. Nothing outside it, and no folders.
    private func resolve(_ path: String) -> URL? {
        let base = root.standardizedFileURL.path
        let url = URL(fileURLWithPath: base + path).standardizedFileURL
        guard url.path.hasPrefix(base + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    private func redirect(_ c: NWConnection, to location: String) {
        let head = "HTTP/1.1 301 Moved Permanently\r\nLocation: \(location)\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    private static func type(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "plist": "text/xml"
        case "json": "application/json"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, headOnly: Bool = false) {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        if !headOnly { out.append(body) }
        c.send(content: out, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
