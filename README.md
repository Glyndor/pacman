# pacman

[![CI](https://github.com/Glyndor/pacman/actions/workflows/tests.yml/badge.svg)](https://github.com/Glyndor/pacman/actions/workflows/tests.yml)

The pacman repository of Glyndor for Arch Linux, served at `https://pacman.glyndor.net`. It carries Podman and the
Glyndor products as signed packages, for `x86_64`.

## Install

Take `podup` as the example; the same line works for each package the repository carries
(`podman`, `podman-docker`, `podup`, `epistle`, `helmly-agent`, and `helmly` and `epistle-panel` once they publish
one).

```sh
curl -fsSL https://pacman.glyndor.net/install/podup | sudo sh
```

The script adds the key of the repository, adds a `[glyndor]` block to `/etc/pacman.conf` (a copy of the old file stays beside
it) and runs `pacman -Syu --needed podup glyndor-keyring`. **That upgrades the whole system**, not only the package: the repository replaces
`netavark` and `aardvark-dns` with its own Podman (the `containers-common` of Arch stays, and its policy file with it),
and pacman applies a replacement only in a system upgrade. `pacman -Sy podup` on its own would be a partial upgrade, and it fails on a host that has the Podman of `extra`.

The script is served from the same storage as the packages, so it cannot vouch for itself. Read it first, or do the three
steps by hand:

1. Download the key and compare its fingerprint with the one below before you trust it.

   ```sh
   curl -fsSL https://pacman.glyndor.net/glyndor-pacman-key.asc -o glyndor-pacman-key.asc
   gpg --show-keys --with-fingerprint glyndor-pacman-key.asc
   sudo pacman-key --add glyndor-pacman-key.asc
   sudo pacman-key --lsign-key 0EE5C891235BE1CAD2E0ABA477E416B24362E256
   ```

2. Put this block in `/etc/pacman.conf` **above** `[core]`:

   ```ini
   [glyndor]
   SigLevel = Required DatabaseRequired TrustedOnly
   Server = https://pacman.glyndor.net/arch/x86_64
   ```

3. Install, which upgrades the system:

   ```sh
   sudo pacman -Syu --needed podup glyndor-keyring
   ```

## The key

The packages and the database are signed with an OpenPGP Ed25519 key that belongs to this repository alone. Its public half is
`keyring/glyndor-pacman-key.asc`, and its fingerprint is:

```text
0EE5 C891 235B E1CA D2E0 ABA4 77E4 16B2 4362 E256
```

The tests of this repository fail if the key in `keyring/` is not the one written here.

## What to know

- **The block goes before `[core]`** because pacman takes a package from the first repository that has it. Glyndor's Podman has
  to win over the one in `extra`, and a name this repository carries is taken from here until you say otherwise. To leave a
  package to Arch, add it to `IgnorePkg` in `/etc/pacman.conf`. When Arch is newer than this repository for a package it
  carries, a check of this repository fails and the owner is told; pacman itself does not.
- **Only `x86_64` hosts.** Arch Linux has no official `aarch64` port (Arch Linux ARM is another distribution with other
  repositories), so nothing is built or tested for it. A package of architecture `any` is served from the same
  directory as the others.
- **No pacman client checks a post-quantum signature.** Releases of the products are signed twice when the second key exists
  and the repository checks both before it admits a package, but the signature pacman checks on your machine is the Ed25519 one
  above. This is a limit of pacman and GnuPG today.
- **pacman cannot tell a frozen repository from a current one**, since its database has no expiry. The repository publishes
  `arch/x86_64/glyndor.state`, signed, with a sequence number and a time until which it is valid (14 days), and a check of this
  repository reads it. You can read it yourself with `gpgv`.
- A package is only replaced by a newer one. An older release, or the same version with other bytes, is refused before it is
  published.

## Contributing

The guide is in [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests are invitation-only; issues are open to everyone. What a
product has to attach to its release is in [docs/product-contract.md](docs/product-contract.md). How the repository
publishes itself, and what each workflow does, is in [docs/operations.md](docs/operations.md).

## License

[MIT](LICENSE)
