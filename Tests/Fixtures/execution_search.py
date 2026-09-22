"""Disposable loopback search/navigation fixture with independent request readback."""
import html
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query).get("q", [""])[0]
        if url.path == "/state":
            return self.send_body(json.dumps(self.server.state), "application/json")
        if url.path == "/scroll":
            position = int(parse_qs(url.query).get("top", ["0"])[0])
            if position not in self.server.state["scroll_positions"]:
                self.server.state["scroll_positions"].append(position)
            return self.send_body("{}", "application/json")
        if url.path == "/":
            body = '<h1>Local search fixture</h1><form action="/search"><input name="q" aria-label="Search query"><button>Search</button></form>'
        elif url.path == "/search":
            self.server.state["query"] = query
            body = '<h1>Search results for ' + html.escape(query) + '</h1><a href="/destination?q=' + quote(query) + '">Copper Lantern Guide</a>'
        elif url.path == "/destination":
            self.server.state["destination_query"] = query
            body = '<h1>Copper Lantern Guide</h1><p>Navigation completed for ' + html.escape(query) + '</p>'
        elif url.path == "/scrolling":
            body = '<h1>Scroll fixture</h1><div role="region" aria-label="Scrollable guide" tabindex="0" style="height:240px;overflow:auto" onscroll="fetch(\'/scroll?top=\'+this.scrollTop)"><div style="height:5000px">Disposable guide content</div></div>'
        else:
            self.send_error(404)
            return
        self.send_body('<!doctype html><html lang="en"><meta charset="utf-8"><title>Disposable search</title><style>body{font:22px system-ui;padding:48px}input,button{font:inherit;padding:12px}</style>' + body + '</html>', "text/html; charset=utf-8")

    def send_body(self, body, content_type):
        payload = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address):
        super().__init__(address, Handler)
        self.state = {"query": None, "destination_query": None, "scroll_positions": []}
