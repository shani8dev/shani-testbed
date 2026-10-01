#!/usr/bin/env python3
"""Serve a static site the way GitHub Pages does, for `web --site`.

All four ShaniOS sites (shani-website, -wiki, -docs, -blog) are GitHub Pages
sites (a CNAME file, and a 404.html as the SPA fallback). Python's plain
http.server differs in the one way that matters to a single-page app: a path
with no file is a bare 404 there, while GitHub Pages answers it with the
site's 404.html - still with HTTP status 404. So an SPA route like the blog's
/bookmarks renders in production but is reported 404 to crawlers and link
previews; a checker against plain http.server would instead see an empty page.
Here both are true: 404.html's content, status 404.

  web_serve.py <dir> <port> [--bind=127.0.0.1]
"""
import functools
import http.server
import os
import sys


class PagesHandler(http.server.SimpleHTTPRequestHandler):
    def send_error(self, code, message=None, explain=None):
        fallback = os.path.join(self.directory, "404.html")
        if code == 404 and os.path.isfile(fallback):
            with open(fallback, "rb") as fh:
                body = fh.read()
            self.send_response(404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        super().send_error(code, message, explain)

    def log_message(self, fmt, *args):
        pass


def main():
    directory, port = sys.argv[1], int(sys.argv[2])
    bind = next((a.split("=", 1)[1] for a in sys.argv[3:] if a.startswith("--bind=")), "127.0.0.1")
    handler = functools.partial(PagesHandler, directory=directory)
    with http.server.ThreadingHTTPServer((bind, port), handler) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    main()
