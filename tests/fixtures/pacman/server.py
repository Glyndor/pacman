#!/usr/bin/env python3
"""A server on the loopback for the tests: it serves a folder, and answers the purge API of Cloudflare.

  server.py ROOT PORT_FILE [--state DIR]

It writes the port it listens on to PORT_FILE. GET and HEAD serve ROOT (a file named `<DIR>/stale/<path>` is served
instead of <path> while `<DIR>/stale-count` holds a positive number, which each such answer decrements: the edge that
still holds the old copy after a purge). POST /zones/<zone>/purge_cache appends the body to `<DIR>/purged.log`, and
answers `{"success": false}` with 400 when `<DIR>/purge-fails` exists, else `{"success": true}`. Every request is
appended to `<DIR>/requests.log` as `METHOD PATH`.
"""
import http.server
import os
import sys

root, port_file = os.path.abspath(sys.argv[1]), sys.argv[2]
state = sys.argv[sys.argv.index("--state") + 1] if "--state" in sys.argv else None


def log(name, line):
	if state:
		with open(os.path.join(state, name), "a") as f:
			f.write(line + "\n")


class Handler(http.server.SimpleHTTPRequestHandler):
	def __init__(self, *args, **kwargs):
		super().__init__(*args, directory=root, **kwargs)

	def translate_path(self, path):
		real = super().translate_path(path)
		if state:
			count_file = os.path.join(state, "stale-count")
			rel = os.path.relpath(real, root)
			stale = os.path.join(state, "stale", rel)
			if os.path.isfile(stale) and os.path.isfile(count_file):
				left = int(open(count_file).read().strip() or 0)
				if left > 0:
					open(count_file, "w").write(str(left - 1))
					return stale
		return real

	def do_GET(self):
		log("requests.log", f"GET {self.path}")
		super().do_GET()

	def do_HEAD(self):
		log("requests.log", f"HEAD {self.path}")
		super().do_HEAD()

	def do_POST(self):
		length = int(self.headers.get("Content-Length", 0))
		body = self.rfile.read(length).decode()
		log("requests.log", f"POST {self.path}")
		log("purged.log", body)
		log("auth.log", self.headers.get("Authorization", ""))
		failing = state and os.path.exists(os.path.join(state, "purge-fails"))
		answer = b'{"success": false}' if failing else b'{"success": true}'
		self.send_response(400 if failing else 200)
		self.send_header("Content-Length", str(len(answer)))
		self.end_headers()
		self.wfile.write(answer)

	def log_message(self, *args):
		pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
	f.write(str(server.server_address[1]))
server.serve_forever()
