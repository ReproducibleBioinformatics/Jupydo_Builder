#!/usr/bin/env python3
"""IGV module: serves the IGV-Web app and lets it read the environment's own files,
started by JupyterLab (jupyter-server-proxy) as the user, on 127.0.0.1 only.

In IGV (Genome > URL, Tracks > URL) users type the REAL path of a file, as they see it
in JupyterLab or in the terminal, e.g.  /sharedFolder/project/sample.bam  (and the
index, e.g. /sharedFolder/project/sample.bam.bai). How: IGV-Web runs in the browser,
which can only ask web addresses; a path starting with "/" would go to the root of the
site (the hub). So the app page is served with a small script on top that sends every
such request to this server, which reads the file from the disk of the environment,
with HTTP range requests (IGV reads only the part of a BAM it shows). Nothing more
than the user can already read from the terminal (this runs as the user).
  /            the IGV-Web app (/opt/igv-webapp), with the script
  /__fs__/<p>  the file /<p> of the environment
Usage: igv-serve.py <port>"""
import os
import re
import sys
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

APP = os.environ.get("IGV_APP_ROOT", "/opt/igv-webapp")
CHUNK = 1024 * 1024

# Requests IGV makes to paths that start with "/" go to /__fs__/ of this server
# (whose own address, behind JupyterLab's proxy, is the folder of the app page).
REWRITE = b"""<script>
(function () {
  var base = location.pathname.replace(/[^\\/]*$/, "");
  function fix(u) {
    return (typeof u === "string" && u.charAt(0) === "/" && u.charAt(1) !== "/"
            && u.indexOf(base) !== 0) ? base + "__fs__" + u : u;
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    var a = Array.prototype.slice.call(arguments); a[1] = fix(u); return open.apply(this, a);
  };
  var f = window.fetch;
  window.fetch = function (r, o) { return f.call(this, typeof r === "string" ? fix(r) : r, o); };
})();
</script>
"""


class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = urllib.parse.unquote(urllib.parse.urlsplit(path).path)
        if path.startswith("/__fs__/"):
            return os.path.normpath(path[len("/__fs__"):])  # a real path of the environment
        full = os.path.realpath(os.path.join(APP, os.path.normpath("/" + path).lstrip("/")))
        return full if full == APP or full.startswith(APP + os.sep) else os.path.join(APP, ".does-not-exist")

    def list_directory(self, path):
        self.send_error(404, "folders are not listed")
        return None

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) and not self.path.startswith("/__fs__/"):
            path = os.path.join(path, "index.html")
        if os.path.basename(path) == "index.html" and path.startswith(APP):
            # the app page, with the script that sends "/..." paths to this server
            with open(path, "rb") as f:
                page = f.read()
            i = page.lower().find(b"<head>")
            page = page[:i + 6] + REWRITE + page[i + 6:] if i >= 0 else REWRITE + page
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self._page = page
            return None
        rng = self.headers.get("Range")
        m = re.match(r"bytes=(\d*)-(\d*)$", (rng or "").strip())
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start, end = m.group(1), m.group(2)
        if start == "":  # the last N bytes
            start, end = max(size - int(end or 0), 0), size - 1
        else:
            start, end = int(start), min(int(end) if end else size - 1, size - 1)
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.end_headers()
            return None
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(403, "cannot read this file")
            return None
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self._remaining = end - start + 1
        return f

    def do_GET(self):
        self._page = None
        f = self.send_head()
        if self._page is not None:
            self.wfile.write(self._page)
        elif f:
            try:
                self.copyfile(f, self.wfile)
            finally:
                f.close()

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_remaining", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        while remaining > 0:
            data = source.read(min(CHUNK, remaining))
            if not data:
                break
            outputfile.write(data)
            remaining -= len(data)
        self._remaining = None

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass  # quiet: JupyterLab's log is not the place for every request


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
