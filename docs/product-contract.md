# Pacman packages in a product release

This is what a Glyndor product has to attach to a GitHub release for `pacman.glyndor.net` to serve it.
The channel declares each product in `scripts/admit/products.txt`. A product that follows this page enters
without a change to the channel, the day its release carries the files below.

## What the release carries

One GitHub release per tag `vX.Y.Z`. Only stable tags are read: the channel takes the release GitHub
marks as latest, which is never a pre-release. For each package the product ships on pacman:

| asset | content |
|---|---|
| `<name>-<X.Y.Z>-1-<arch>.pkg.tar.zst` | the package, a tar compressed with zstd, as `makepkg` writes it (`.BUILDINFO`, `.MTREE`, `.PKGINFO`, then the files) |
| `<name>-<X.Y.Z>-1-<arch>.pkg.tar.zst.sig` | the raw 64-byte Ed25519 signature of the exact bytes of the package |
| `<name>-<X.Y.Z>-1-<arch>.pkg.tar.zst.mldsa65.sig` | the ML-DSA-65 signature (3309 bytes) of the same bytes, once the second key exists |

- `<arch>` is `x86_64` or `any`. There is no `aarch64`: Arch Linux has no official port, and the channel
  refuses any other value. A product with a static binary ships `x86_64`, one with no compiled code `any`.
- The version is the tag without the `v`, and the revision is always `-1`: tag `v1.4.2` gives
  `pkgver = 1.4.2-1` and the file `podup-1.4.2-1-x86_64.pkg.tar.zst`. A rebuild is a new tag, because
  releases are immutable. The tag must match `^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$`; the `+rN` form is the one
  Podman uses, and gives `X.Y.Z+rN-1`.
- `.sig` and `.mldsa65.sig` are made with the Glyndor release key, the one in
  `keyring/glyndor-release-ed25519.b64`, and are checked by `scripts/admit/verify-sig.py`. The product does not
  sign with an OpenPGP key: the channel signs the package when it admits it.
- Every asset above, signatures included, carries a provenance attestation (`actions/attest-build-provenance`).
  The channel runs `gh attestation verify` on each package with `--repo Glyndor/<product>`, the signing workflow
  named in `scripts/admit/signer-workflows.txt`, `--source-ref refs/tags/<tag>`, `--source-digest` of the commit the
  tag points at, and `--deny-self-hosted-runners`: an attestation of another release of the same product does not pass.
- The release carries no other asset that ends in `.pkg.tar.zst`, `.pkg.tar.zst.sig` or
  `.pkg.tar.zst.mldsa65.sig`, nor another `.pkg.tar.*` file, than the exact set above. An extra one, one of
  another version or architecture, or a name with `/`, `\`, `..` or a glob character makes the channel refuse the
  whole release. Other assets (binaries, `.deb`, SBOMs, installers) are ignored.
- Bounds: a package is at most 300 MiB, a signature at most 4096 bytes, the release at most 1000 assets (GitHub's own limit; what counts is the exact set above), and a
  package unpacks to at most 2 GiB in at most 100000 entries.

## What the channel checks in `.PKGINFO`

It reads the file from the bytes the release key verified:

| field | required |
|---|---|
| `pkgname` | the declared package name, and the file name starts with it |
| `pkgver` | exactly `<version>-1` of the file name |
| `arch` | exactly the `<arch>` of the file name, and one the products file declares for that package |
| `packager` | exactly `Glyndor <noreply@glyndor.net>`; this is the vendor field of pacman |
| `pkgbase` | absent, equal to `pkgname`, or the name of another package of the same product (`podman` for both members of the split package) |
| `provides` | absent, or the package itself (with no version or with its own `<version>-1`), or a form its line of the products file lists letter for letter (`netavark=2.1.0`), or a listed name with no version or with the `<version>-1` of this very package; any other version of a name is refused (`docker=99.0`) |
| `conflict`, `replaces` | absent, or the package itself, or a form its line of the products file lists letter for letter: a name, or a name with the one constraint listed (`netavark`, `netavark<1.14`); any other constraint is refused. The keys are spelled as `.PKGINFO` spells them (`conflict` in the singular) |
| `group` | absent, or a name its line of the products file lists |
| `backup` | files of the package itself: a path with no leading `/` and no `..`, in a place the package may install |
| `depend` | free, except that a dependency on another package of the same product is exactly `<name>=<pkgver>` of the same release (`podman-docker` depends on `podman=6.2.0+r12-1`); a dependency of another product on `podman` says `podman>=6.2.0` |

`.PKGINFO` is read strictly: every line is `key = value` or a `#` comment and the file ends with a line feed; no control
character (NUL, tab, carriage return, vertical tab, form feed) is in it; the key is one of `pkgname`, `pkgbase`, `pkgver`,
`pkgdesc`, `url`, `builddate`, `packager`, `size`, `arch`, `license`, `replaces`, `group`, `conflict`, `provides`, `backup`,
`depend`, `optdepend`, `makedepend`, `checkdepend` or `xdata`, and any other key refuses the package; the names in the
relation keys are package or soname names. The archive is read twice and the two readings must agree member by member (type, name, size, link target) and on
the bytes of `.PKGINFO`: once by Python and once by `bsdtar`, the reader pacman uses, from the Arch image of
`scripts/assemble/arch-image.txt`. Only regular files, folders, symbolic links and hard links are admitted; a member
that is not a regular file and has a size, a global pax header, a sparse or contiguous member, or a member of any other
type refuses the package. Nothing may follow the end of the archive but zero blocks, the end mark among them.

## What a package may install

By default nothing: `scripts/admit/package-paths.txt` lists, for each package, the places it may install, and a member
that no pattern of its line names refuses the whole release (the patterns are in the file; `*` is any characters inside
a component, a trailing `/` is a folder and what is under it). Never allowed, whatever the file says, and a line that
names one makes the file refuse to load: `etc/pacman.conf`, `etc/pacman.d`, `usr/share/pacman` (the keyrings),
`usr/share/libalpm` (the hooks), `etc/sudoers*`, the users and passwords, the login and the loader, cron, udev rules,
`etc/systemd`, `etc/ssh`. Units, sysusers and tmpfiles are allowed only under the name of the package. A symbolic or hard
link may point only at a place its package may install (or at one the line marks with `>` for a file that the other
package of the same release installs), with the target resolved, so `..` and an absolute target that lead anywhere else are
refused; the links are read strictly (no `..` after a name, no `.` or `..` in an absolute target, no member inside a link of the
same package, no name twice, a chain of links followed to its end). No member is setuid or setgid, and no member carries an
extended attribute, an ACL, a file capability or a security label: the pax headers of every member are `path`, `linkpath`,
`size`, `mtime`, `atime`, `ctime`, `uname` and `gname` and nothing else, and the `bsdtar` of the pinned image is asked to write
the archive out again to find the ones a listing does not show. `.MTREE`, when the package has one, is exactly one complete gzip
member, with no continued lines and no command but `/set` and `/unset`, and has to list exactly the members of the archive: no path
more, none less, none twice, none outside the tree, and the same paths that `bsdtar` reads in it. A product that needs another place asks
for it in a reviewed change to that file; the lines there today are what the channel expects of each package, and they have
not yet been measured against a real release of each product.

Also required: one `.PKGINFO` among the leading dot entries, before the first ordinary entry, a regular file of at most 64 KiB; no member with an absolute name, a `..`
component or a device node; no hard link out of the tree. `.INSTALL` scripts are allowed and run as root on
the host, so the signature is what binds them to the product; prefer `sysusers.d` and `tmpfiles.d` over scripts
that create users. The name `glyndor-keyring` is reserved for the channel and refused in a product.

## Where a package is served

There is one repository, `glyndor`, under `arch/x86_64/`. A static binary serves every Arch installation, so the
file name carries no distribution id. An `any` package is served from the same directory.

## What the channel does with a release

It resolves the latest release of each declared product once, downloads the exact names, verifies and admits
them, and publishes the newest version of each package (latest only). A version older than the served one is
refused, and so is the same version with different bytes. A product that was served and whose latest release
no longer carries its packages stops the publication instead of disappearing from the repository.

## The second signature

**Read this before attaching a `.mldsa65.sig`.** While no ML-DSA key is configured (`keyring/glyndor-release-mldsa65.b64`
holds only comments), a release that carries a `.mldsa65.sig` is refused whole: the channel fails closed and cannot yet check
it, so a product must not attach one until the key exists. And while the key is configured, `keyring/pq-required-products`
cannot be empty: the channel stops with a configuration error instead of accepting a second signature that protects nothing.

`<asset>.mldsa65.sig` follows the six cases of the post-quantum design. Absent and not required: accepted.
Absent and required: refused. Present and no ML-DSA key configured: refused. Present and invalid, of another
length or made by another key: refused. Valid: accepted, as long as the Ed25519 signature is valid too. A
package becomes required when its name is added to `keyring/pq-required-products`, after one of its releases was
verified with both signatures.
