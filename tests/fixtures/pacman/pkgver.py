#!/usr/bin/env python3
"""Print the pkgver of a .pkg.tar.zst, read from its .PKGINFO. For the tests."""
import io
import subprocess
import sys
import tarfile

data = subprocess.run(["zstd", "-dc", "-q", sys.argv[1]], stdout=subprocess.PIPE, check=True).stdout
with tarfile.open(fileobj=io.BytesIO(data)) as archive:
	text = archive.extractfile(".PKGINFO").read().decode()
print(dict(line.split(" = ", 1) for line in text.splitlines() if " = " in line)["pkgver"])
