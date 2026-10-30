# Serves the repository root with cross-origin isolation, which browsers
# require before they give performance.now() and GPU timestamps fine
# resolution. From the repository root:
#
#   python3 benchmarks/wgsl-rot13/serve.py 4277
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 4277
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
