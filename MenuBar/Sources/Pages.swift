import Foundation

/// The install pages, made by the server for each request from the published builds (nothing is stored): one page per
/// app (/<app key>/: its newest build, with the Install button and a details table) and one listing every app, sorted by
/// when each app's code last changed.
enum Pages {
    static func appPage(_ b: Build) -> String {
        let title = esc(b.title)
        let link = "itms-services://?action=download-manifest&amp;url=" + quote(b.manifest)
        let rows = details(b).map { "<tr><td class=\"k\">\(esc($0.0))</td><td class=\"v\">\(esc($0.1))</td></tr>" }.joined()
        return "\(head)<title>Install \(title)</title>\(style)</head><body><main><a class=\"back\" href=\"../\">\u{2039} All Apps</a>"
            + "<div class=\"card center\">\(icon(b, "big"))<h1>\(title)</h1><a class=\"install\" href=\"\(link)\">Install</a></div>"
            + "<div class=\"card details\"><table>\(rows)</table></div></main></body></html>"
    }

    static func listPage(_ apps: [PublishedApp]) -> String {
        let cards = apps.map { app in
            let b = app.newest
            return "<a class=\"app\" href=\"\(quote(app.key))/\"><div class=\"card row\">\(icon(b, "icon", prefix: quote(app.key) + "/"))"
                + "<div><h2>\(esc(b.title))</h2><p>Version \(esc(b.versionText))</p></div></div></a>"
        }.joined()
        return "\(head)<title>Install apps</title>\(style)</head><body><main><h1>Apps</h1>"
            + (cards.isEmpty ? "<p>Nothing published yet.</p>" : cards) + "</main></body></html>"
    }

    /// The rows of an app page's details table.
    private static func details(_ b: Build) -> [(String, String)] {
        var rows = [("Version", b.versionText), ("Built", when(b.time))]
        if let at = b.commit.range(of: " @ ") {
            let branch = String(b.commit[..<at.lowerBound])
            let rest = b.commit[at.upperBound...]
            let sha = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(rest)
            rows += [("Branch", branch), ("Commit", sha)]
            if rest.contains(",") { rows.append(("Changes", "Uncommitted, included")) }
            else if let c = b.changed, c != b.time { rows.append(("Committed", when(c))) }
        } else if !b.commit.isEmpty {
            rows.append(("From", b.commit))          // an app file published with --ipa
        }
        rows.append(("Download size", b.sizeText))
        return rows
    }

    private static func icon(_ b: Build, _ cls: String, prefix: String = "") -> String {
        guard let name = b.icon, !name.isEmpty else { return "" }
        return "<img class=\"\(cls)\" src=\"\(prefix)\(quote(b.id))/\(quote(name))\" alt=\"\">"
    }

    // MARK: Helpers

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy, HH:mm"            // Nov 20, 2026, 21:59 (this Mac's time zone)
        return f
    }()

    private static func when(_ iso: String) -> String {
        ISO8601DateFormatter().date(from: iso).map { dateFormat.string(from: $0) } ?? iso
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// Percent-encodes everything but letters, digits and -._~ (what a URL inside a URL or a path segment needs).
    private static func quote(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private static let head = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

    private static let style = """
    <style>
      :root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --dim: #6e6e73; --accent: #0a84ff; }
      @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --dim: #98989d; } }
      body { margin: 0; background: var(--bg); color: var(--text); font: 17px -apple-system, system-ui, sans-serif; }
      main { padding: 40px 16px; display: flex; flex-direction: column; gap: 14px; }
      .card { background: var(--card); border-radius: 18px; padding: 20px; }
      h1 { font-size: 24px; margin: 0 0 6px; }
      h2 { font-size: 19px; margin: 0 0 4px; }
      p { margin: 3px 0; color: var(--dim); font-size: 15px; }
      a.install { display: block; margin-top: 16px; padding: 14px; border-radius: 14px; background: var(--accent);
                  color: #fff; font-weight: 600; text-decoration: none; font-size: 18px; text-align: center; }
      a.app { color: inherit; text-decoration: none; display: block; }
      .row { display: flex; gap: 14px; align-items: center; }
      .icon { width: 60px; height: 60px; border-radius: 13.5px; flex: none; }
      .big { width: 96px; height: 96px; border-radius: 21.5px; display: block; margin: 0 auto 12px; }
      .center { text-align: center; }
      a.back { color: var(--accent); text-decoration: none; font-size: 17px; align-self: flex-start; padding: 4px 0; }
      .details { padding: 0 20px; }
      .details table { width: 100%; border-collapse: collapse; font-size: 16px; }
      .details td { padding: 12px 0; border-bottom: 0.5px solid rgba(128, 128, 128, 0.3); vertical-align: top; }
      .details tr:last-child td { border-bottom: none; }
      .details td.k { color: var(--dim); padding-right: 16px; white-space: nowrap; }
      .details td.v { text-align: right; word-break: break-word; }
    </style>
    """
}
