#!/usr/bin/env python3
"""The .PKGINFO of each package given, as the admission keeps it: {file name: {key: [values]}}. For the tests."""
import io
import json
import os
import subprocess
import sys
import tarfile

out = {}
for path in sys.argv[1:]:
	data = subprocess.run(["zstd", "-dc", "-q", path], stdout=subprocess.PIPE, check=True).stdout
	with tarfile.open(fileobj=io.BytesIO(data)) as archive:
		text = archive.extractfile(".PKGINFO").read().decode()
	info = {}
	for line in text.splitlines():
		if line and not line.startswith("#"):
			key, _, value = line.partition(" = ")
			info.setdefault(key, []).append(value)
	out[os.path.basename(path)] = info
print(json.dumps(out, sort_keys=True))
