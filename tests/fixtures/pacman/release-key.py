#!/usr/bin/env python3
"""A throwaway release key for the tests.

  release-key.py new KEYDIR        writes KEYDIR/release.seed (hex) and KEYDIR/release.b64 (the public half, unpadded)
  release-key.py sign KEYDIR FILE  writes FILE.sig, the raw 64-byte Ed25519 signature of FILE
  release-key.py garbage FILE      writes FILE with 64 bytes that are not a signature
"""
import base64
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

mode = sys.argv[1]
if mode == "new":
	key = Ed25519PrivateKey.generate()
	seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
	pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
	with open(os.path.join(sys.argv[2], "release.seed"), "w") as f:
		f.write(seed.hex() + "\n")
	with open(os.path.join(sys.argv[2], "release.b64"), "w") as f:
		f.write(base64.b64encode(pub).decode().rstrip("=") + "\n")
elif mode == "sign":
	with open(os.path.join(sys.argv[2], "release.seed")) as f:
		key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(f.read().strip()))
	with open(sys.argv[3], "rb") as f:
		data = f.read()
	with open(sys.argv[3] + ".sig", "wb") as f:
		f.write(key.sign(data))
elif mode == "garbage":
	with open(sys.argv[2], "wb") as f:
		f.write(bytes(range(64)))
else:
	sys.exit("usage: release-key.py new|sign|garbage")
