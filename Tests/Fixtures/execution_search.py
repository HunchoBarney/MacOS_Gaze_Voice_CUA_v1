"""Disposable loopback search/navigation fixture with independent request readback."""
import html
import hashlib
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
        if url.path == "/pointer-event":
            event = parse_qs(url.query).get("event", [""])[0]
            if event:
                self.server.state["pointer_events"].append(event)
            return self.send_body("{}", "application/json")
        if url.path == "/":
            seed = ' value="copper"' if parse_qs(url.query).get("fixture", [""])[0] == "prefilled" else ""
            body = '<h1>Local search fixture</h1><form action="/search"><input name="q" aria-label="Search query"' + seed + '><button>Search</button></form>'
            if seed:
                body += '<script>const field=document.querySelector("input[name=q]");field.focus();field.setSelectionRange(field.value.length,field.value.length)</script>'
        elif url.path == "/search":
            self.server.state["query"] = query
            body = '<h1>Search results for ' + html.escape(query) + '</h1><a href="/destination?q=' + quote(query) + '">Copper Lantern Guide</a>'
        elif url.path == "/destination":
            self.server.state["destination_query"] = query
            body = '<h1>Copper Lantern Guide</h1><p>Navigation completed for ' + html.escape(query) + '</p>'
        elif url.path == "/scrolling":
            body = '<h1>Scroll fixture</h1><div role="region" aria-label="Scrollable guide" tabindex="0" style="height:240px;overflow:auto" onscroll="fetch(\'/scroll?top=\'+this.scrollTop)"><div style="height:5000px">Disposable guide content</div></div>'
        elif url.path == "/pointer":
            body = '<h1>Pointer fixture</h1><a href="#" aria-label="Pointer target" onmouseenter="fetch(\'/pointer-event?event=mouseenter\')" onclick="event.preventDefault()">Pointer target</a>'
        elif url.path == "/drag":
            body = ('<h1>Drag fixture</h1><button draggable="true" aria-label="Start">Start</button>'
                    '<button aria-label="Finish" ondragover="event.preventDefault()" '
                    'ondrop="event.preventDefault(); this.textContent=\'Dropped\'; fetch(\'/pointer-event?event=drop\')">Finish</button>')
        elif url.path == "/upload":
            body = '<h1>Disposable upload fixture</h1><input type="file" aria-label="verification file"><output>waiting</output><script>document.querySelector("input").addEventListener("change", async event => { const file = event.target.files[0]; if (file) await fetch("/upload?name=" + encodeURIComponent(file.name), {method:"POST", body:file}); });</script>'
        elif url.path == "/dialog":
            decision = parse_qs(url.query).get("decision", [None])[0]
            if decision in {"accepted", "dismissed"}:
                self.server.state["dialog_decision"] = decision
                body = '<h1>Disposable dialog fixture</h1><p>Dialog decision recorded: ' + decision + '</p>'
            else:
                body = '<h1>Disposable dialog fixture</h1><p>Waiting for the fixture confirmation.</p><script>setTimeout(()=>{const accepted=window.confirm(\'Accept disposable fixture?\');fetch(\'/dialog?decision=\'+(accepted?\'accepted\':\'dismissed\'))},500)</script>'
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

    def do_POST(self):
        url = urlsplit(self.path)
        if url.path != "/upload":
            self.send_error(404)
            return
        length = min(int(self.headers.get("Content-Length", "0")), 1_000_000)
        content = self.rfile.read(length)
        name = parse_qs(url.query).get("name", [""])[0]
        self.server.state["upload"] = {"name": name, "size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
        return self.send_body(json.dumps(self.server.state["upload"]), "application/json")

    def log_message(self, *_):
        pass


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address):
        super().__init__(address, Handler)
        self.state = {"query": None, "destination_query": None, "scroll_positions": [], "pointer_events": [], "upload": None, "dialog_decision": None}
