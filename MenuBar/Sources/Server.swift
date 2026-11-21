import Foundation
import Network

/// The web server for the install pages: the builds folder, on 127.0.0.1 only (Tailscale passes it on to the tailnet over
/// HTTPS). GET and HEAD, one request per connection, files sent whole, with the types iOS expects for an over-the-air
/// install and no caching, so the pages and a rebuilt app are always the current ones.
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
        guard let file = resolve(String(parts[1])) else { return send(c, 404, "text/plain", Data("Not found".utf8)) }
        guard let body = try? Data(contentsOf: file, options: .alwaysMapped) else { return send(c, 404, "text/plain", Data("Not found".utf8)) }
        send(c, 200, Self.type(of: file), body, headOnly: headOnly)
    }

    /// The file a URL path names inside the builds folder (a folder means its index.html), or nil. Nothing outside it.
    private func resolve(_ target: String) -> URL? {
        let path = (target.split(separator: "?").first.map(String.init) ?? "/").removingPercentEncoding ?? ""
        let base = root.standardizedFileURL.path
        var url = URL(fileURLWithPath: base + path).standardizedFileURL
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { url.appendPathComponent("index.html") }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func type(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "plist": "text/xml"
        case "json": "application/json"
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
