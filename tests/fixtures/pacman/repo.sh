# shellcheck shell=bash
# Fixtures for the suites that sign and read a repository: a throwaway OpenPGP key, and a tree built the way
# stage-packages.sh leaves it. Source it after lib.sh; it needs HERE, WORK and FIXTURES.

# make_gpg_key <dir>: <dir>/pub.asc, <dir>/secret.asc and <dir>/fpr for a key that signs and never expires
make_gpg_key() {
	local home="$1/home"
	mkdir -p "$1"
	mkdir -m 700 "$home"
	gpg --homedir "$home" --batch --quiet --passphrase '' --quick-generate-key "Test <test@example.org>" ed25519 sign never 2> /dev/null
	local fpr
	fpr="$(gpg --homedir "$home" --batch --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
	gpg --homedir "$home" --batch --armor --export "$fpr" > "$1/pub.asc"
	gpg --homedir "$home" --batch --armor --export-secret-keys "$fpr" > "$1/secret.asc"
	printf '%s\n' "$fpr" > "$1/fpr"
	gpgconf --homedir "$home" --kill all > /dev/null 2>&1 || true
}

# make_tree <dest> <package file>...: <dest>/arch/x86_64 with the packages (no database, nothing signed), and
# <dest>.manifest, the manifest of the admission for them, and <dest>.pkginfo.json, what the admission read in them
make_tree() {
	local dest="$1" dir file name version arch
	shift
	dir="$dest/arch/x86_64"
	mkdir -p "$dir"
	: > "$dest.manifest"
	for file in "$@"; do
		cp "$file" "$dir/"
		name="$(basename "$file")"
		version="$(python3 -I "$FIXTURES/pkgver.py" "$file")"
		arch="${name##*-}"
		arch="${arch%.pkg.tar.zst}"
		printf 'r\t%s\t%s\t%s\t%s\t%s\t%s\tno\n' "${name%%-[0-9]*}" "$version" "$arch" "$name" "$(stat -c%s "$file")" \
			"$(sha256sum "$file" | cut -d' ' -f1)" >> "$dest.manifest"
	done
	python3 -I "$FIXTURES/pkginfo.py" "$dir"/*.pkg.tar.zst > "$dest.pkginfo.json"
}

# make_db <out> <package file>...: the database mkdb.py writes for those packages (a manifest and the .PKGINFO data are made on the way)
make_db() {
	local out="$1" scratch
	shift
	scratch="$(mktemp -d)"
	make_tree "$scratch/t" "$@"
	python3 -I "$HERE/scripts/metadata/mkdb.py" --manifest "$scratch/t.manifest" --pkginfo "$scratch/t.pkginfo.json" --packages "$scratch/t/arch/x86_64" --out "$out" > /dev/null
	rm -rf "$scratch"
}
