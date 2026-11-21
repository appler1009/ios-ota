# The local web server behind `tailscale serve` for ios-ota: the builds folder, with the types iOS expects for an
# over-the-air install, and no caching (so the pages and a rebuilt app are always the current ones).
#
#     python3 serve.py <port> <folder>       (run by the com.appler.ios-ota login item; listens on 127.0.0.1 only)

import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".plist": "text/xml",
        ".ipa": "application/octet-stream",
        ".html": "text/html; charset=utf-8",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


port, folder = int(sys.argv[1]), sys.argv[2]
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=folder)).serve_forever()
