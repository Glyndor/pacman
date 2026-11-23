# pacman

[![CI](https://github.com/Glyndor/pacman/actions/workflows/tests.yml/badge.svg)](https://github.com/Glyndor/pacman/actions/workflows/tests.yml)

The pacman package repository for Glyndor's products, to be served at
`pacman.glyndor.net`.

## Status

This channel does not publish anything yet. There is no package to install and no
repository to add, so this page has no install commands. I will document the
installation here when the channel starts to publish.

What the repository holds today is its CI and the public key it will be signed with.

## Signing key

The packages and the repository metadata will be signed with an OpenPGP Ed25519 key
that belongs to this channel alone. Its public half is `keyring/glyndor-pacman-key.asc`, and its
fingerprint is:

```text
0EE5 C891 235B E1CA D2E0 ABA4 77E4 16B2 4362 E256
```

Check a key you are handed against this fingerprint before you trust it. The
repository tests fail if the key in `keyring/` is not the one written here.

## Contributing

The guide is in [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests are invitation-only;
issues are open to everyone.

## License

[MIT](LICENSE)
