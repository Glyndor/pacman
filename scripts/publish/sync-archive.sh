#!/usr/bin/env bash
#
# Upload the signed tree to the bucket without ever leaving a repository that does not hold together.
#
#   sync-archive.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> [--now <time>]
#   sync-archive.sh --restore --previous <dir> --public-key <file> --bucket <name> [--tree <dir>]
#   sync-archive.sh --cleanup --tree <dir> --bucket <name> [--now <time>]
#
# The credentials are the R2 ones, in the environment. This step holds no signing key, so before it
# writes anything it reads every signature in the tree back with gpgv against the public key: a tree
# that was altered after the signer is not uploaded.
#
# What is put back (--previous) is verified before it is written, in a restore as in a publication: the database and the state
# against the key of the repository, and the database has to be the one the state names. What is already in the bucket under
# the name of a package to publish is read back and verified: the package is the same bytes, and its signature verifies it.
#
# Before anything is written, and again before the database group, the state that the bucket serves NOW is read and has to be
# exactly the one the run was built on (--previous), absent only when there was none, and the new sequence is that one plus one:
# a publication that raced another, or a copy of an older repository, writes nothing. The packages that are uploaded are exactly
# the ones the signed database lists, with the sha256 it gives.
#
# ORDER, which is the whole point of the script.
#   1. Packages and their signatures, the signature first, so that a package is never there without it. They are named for their version and never change: an object that
#      is already there is left alone, and one that is there with another SHA-256 stops the run (a
#      published identity does not change bytes, and nothing signed by hash is compared by size).
#   2. The key and the pages (key file, index page, installers). Mutable, outside the repository.
#   3. The database group, together and last: glyndor.db.tar.zst, its signature, glyndor.db, its signature,
#      the state and its signature. A client that reads the database sees every package it names, since
#      step 1 is over. If a write of this group fails, the previous group (--previous, read from the
#      repository before this run, signatures verified) is put back, and the run still fails; where there is
#      no previous one the objects written are deleted. Reading back is the caller's check, restoring is
#      this script's.
#   4. Cleanup, by `--cleanup` and after the caller has read the repository back: only packages the state lists as retired and whose delete-after time has gone by,
#      and never one the new database names. Old files stay while a signed database that a client could
#      still hold names them.
set -euo pipefail
export LC_ALL=C
# Exit status 5 is a refusal that came before the first write: nothing in the bucket was touched, so the caller has nothing to put back.
started=no write_mode=no work=""
on_exit() {
	local code=$?
	[ -z "$work" ] || rm -rf "$work"
	if [ "$code" -ne 0 ] && [ "$started" = no ] && [ "$write_mode" = yes ]; then exit 5; fi
}
trap on_exit EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="" previous="" pub="" bucket="" restore_only=no cleanup_only=no
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ "$#" -gt 0 ]; do
	if [ "$1" = --restore ]; then
		restore_only=yes
		shift
		continue
	fi
	if [ "$1" = --cleanup ]; then
		cleanup_only=yes
		shift
		continue
	fi
	[ "$#" -ge 2 ] || { echo "::error::sync-archive.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--tree) tree="$2" ;;
		--previous) previous="$2" ;;
		--public-key) pub="$2" ;;
		--bucket) bucket="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::sync-archive.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$bucket" ] || { [ "$cleanup_only" = no ] && [ -z "$previous" ]; } || { [ "$restore_only" = no ] && [ -z "$tree" ]; } \
	|| { [ "$cleanup_only" = no ] && [ -z "$pub" ]; }; then
	echo "::error::usage: sync-archive.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> | --restore --previous <dir> --bucket <name> | --cleanup --tree <dir> --bucket <name>" >&2
	exit 2
fi
[ "$restore_only" = yes ] || [ "$cleanup_only" = yes ] || write_mode=yes
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL; do
	if [ -z "${!v:-}" ]; then
		echo "::error::$v is not configured" >&2
		exit 1
	fi
done
# The endpoint travels in the environment and not in argv. A CLI too old to read it would send the requests to
# AWS instead (2.13 / 1.29 read it), and two other variables decide the endpoint ahead of it.
cli="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\)\.\([0-9]*\)\..*|\1 \2|p')"
read -r cli_major cli_minor <<< "$cli" || true
case "${cli_major:-}:${cli_minor:-}" in
	2:*) [ "$cli_minor" -ge 13 ] ;;
	1:*) [ "$cli_minor" -ge 29 ] ;;
	*) false ;;
esac || { echo "::error::this AWS CLI does not read AWS_ENDPOINT_URL; refusing to write to an endpoint it would ignore" >&2; exit 1; }
for v in AWS_ENDPOINT_URL_S3 AWS_IGNORE_CONFIGURED_ENDPOINT_URLS; do
	if [ -n "${!v+set}" ]; then
		echo "::error::$v is set and would decide the endpoint instead of AWS_ENDPOINT_URL" >&2
		exit 1
	fi
done
dir="$tree/arch/x86_64"
prefix="arch/x86_64"

work="$(mktemp -d)"
home="$work/gnupg"
mkdir -m 700 "$home"
declare -a packages=() group=()
if [ "$cleanup_only" = no ]; then
	gpg --homedir "$home" --batch --quiet --import "$pub" 2> /dev/null || { echo "::error::cannot import the public key" >&2; exit 2; }
	gpg --homedir "$home" --batch --export > "$work/ring.gpg"
	# The previous repository is what a restore writes: it is checked before anything is, and a failure is a refusal, status 5.
	if [ ! -e "$previous/no-state" ]; then
		for f in glyndor.db.tar.zst:glyndor.db.tar.zst.sig state:state.sig; do
			gpgv --keyring "$work/ring.gpg" "$previous/${f#*:}" "$previous/${f%%:*}" > /dev/null 2>&1 \
				|| { echo "::error::${f%%:*} of the previous repository does not verify with the key of the repository; it is not written, or put back" >&2; exit 5; }
		done
		want="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$previous/state" db-sha256)" || exit 5
		[ "$(sha256sum "$previous/glyndor.db.tar.zst" | cut -d' ' -f1)" = "$want" ] \
			|| { echo "::error::the previous database is not the one the previous state names; it is not written, or put back" >&2; exit 5; }
	fi
fi
if [ "$restore_only" = no ] && [ "$cleanup_only" = no ]; then
	# The tree is what the signer left: every file is signed, every signature verifies.
	listing="$(cd "$dir" && ls -- *.pkg.tar.zst)" || { echo "::error::cannot list the packages of the tree" >&2; exit 1; }
	while IFS= read -r f; do
		packages+=("$f")
	done <<< "$listing"
	[ "${#packages[@]}" -gt 0 ] || { echo "::error::the tree holds no package" >&2; exit 1; }
	for f in "${packages[@]}" glyndor.db.tar.zst glyndor.state; do
		gpgv --keyring "$work/ring.gpg" "$dir/$f.sig" "$dir/$f" > /dev/null 2>&1 \
			|| { echo "::error::the signature of $f does not verify with the key of the repository; nothing is uploaded" >&2; exit 1; }
	done
	if ! cmp -s "$dir/glyndor.db" "$dir/glyndor.db.tar.zst" || ! cmp -s "$dir/glyndor.db.sig" "$dir/glyndor.db.tar.zst.sig"; then
		echo "::error::glyndor.db is not a copy of glyndor.db.tar.zst with its signature" >&2
		exit 1
	fi
	python3 -I "$HERE/scripts/metadata/dbtool.py" state-check "$dir/glyndor.state" --db "$dir/glyndor.db.tar.zst" --now "$now"
	# The packages to upload are exactly the ones the signed database lists, each with the sha256 it gives.
	entries="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$dir/glyndor.db.tar.zst")" \
		|| { echo "::error::cannot read the signed database" >&2; exit 1; }
	listed="$(printf '%s\n' "$entries" | cut -f3 | sort)"
	if [ "$listed" != "$(printf '%s\n' "${packages[@]}" | sort)" ]; then
		echo "::error::the packages of the tree are not the ones the signed database lists; nothing is uploaded" >&2
		exit 1
	fi
	while IFS=$'\t' read -r _name _ver file _size sha _arch; do
		[ "$(sha256sum "$dir/$file" | cut -d' ' -f1)" = "$sha" ] \
			|| { echo "::error::$file is not the file whose sha256 the signed database gives; nothing is uploaded" >&2; exit 1; }
	done <<< "$entries"

fi

s3api() { timeout 600 aws s3api "$@"; }
IMMUTABLE="public, max-age=31536000, immutable"
MUTABLE="public, max-age=86400"
# head <key>: prints the SHA-256 kept in the object's metadata; status 3 when there is no such object
head_sha() {
	local out
	if out="$(s3api head-object --bucket "$bucket" --key "$1" --output text --query 'Metadata.sha256' 2>&1)"; then
		printf '%s\n' "$out"
		return 0
	fi
	# Only the exact answer of a head of an object that is not there is "no such object"; any other text, a 404 of something else
	# among them, is a failure that stops the run.
	[ "$out" != "An error occurred (404) when calling the HeadObject operation: Not Found" ] || return 3
	echo "::error::cannot read $1: $out" >&2
	return 1
}
NOSUCHKEY="An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist."
# fetch <key> <file>: 0 read, 3 there is no such object, 1 anything else
fetch() {
	local out
	if out="$(s3api get-object --bucket "$bucket" --key "$1" "$2" 2>&1)"; then
		return 0
	fi
	[ "$out" != "$NOSUCHKEY" ] || return 3
	echo "::error::cannot read $1: $out" >&2
	return 1
}
# check_live <dir of the state the run was built on> [<dir with the new state>]: the state served now is that one, byte for byte,
# or absent when the run was built on none; and, when a second folder is given (a restore), that one is accepted too.
check_live() {
	local rc=0 d ok=no
	fetch "$prefix/glyndor.state" "$work/live.state" || rc=$?
	if [ "$rc" -eq 3 ]; then
		[ -e "$1/no-state" ] || { echo "::error::the bucket has no state and this run was built on one; another run or a restore changed it; nothing is written" >&2; return 1; }
		return 0
	fi
	[ "$rc" -eq 0 ] || return 1
	fetch "$prefix/glyndor.state.sig" "$work/live.state.sig" || { echo "::error::the bucket has a state with no signature or one that cannot be read; nothing is written" >&2; return 1; }
	if [ ! -e "$1/no-state" ] && cmp -s "$work/live.state" "$1/state" && cmp -s "$work/live.state.sig" "$1/state.sig"; then
		ok=yes
	fi
	if [ "$ok" = no ] && [ -n "${2:-}" ]; then
		d="$2/arch/x86_64"
		if [ -f "$d/glyndor.state" ] && cmp -s "$work/live.state" "$d/glyndor.state" && cmp -s "$work/live.state.sig" "$d/glyndor.state.sig"; then
			ok=yes
		fi
	fi
	[ "$ok" = yes ] || { echo "::error::the state the bucket serves now is not the one this run was built on; another publication or a copy of an older repository got there first; nothing is written" >&2; return 1; }
}
# Immutable objects are written with a condition that they do not exist, when the CLI has one: a copy that appeared since
# the head is read again and has to be the same bytes. A CLI without the condition is said aloud, and the head alone stands.
cond=no
if timeout 60 aws s3api put-object help 2>&1 < /dev/null | grep -q -e '--if-none-match'; then
	cond=yes
else
	echo "::notice::this AWS CLI has no --if-none-match: immutable objects are protected by the head before the write alone" >&2
fi
put() { # <key> <file> <cache-control> [content-type]
	local sha
	sha="$(sha256sum "$2" | cut -d' ' -f1)"
	s3api put-object --bucket "$bucket" --key "$1" --body "$2" --cache-control "$3" --metadata "sha256=$sha" \
		${4:+--content-type "$4"} > /dev/null
}

# verify_existing <key of a signature> <package>: the signature in the bucket is read back and verifies the package to publish
verify_existing() {
	fetch "$1" "$work/existing.sig" || { echo "::error::$1 is in the bucket and cannot be read back" >&2; return 1; }
	if ! gpgv --keyring "$work/ring.gpg" "$work/existing.sig" "$2" > /dev/null 2>&1; then
		echo "::error::$1 in the bucket does not verify $(basename "$2") with the key of the repository; nothing is written" >&2
		rm -f "$work/existing.sig"
		return 1
	fi
	rm -f "$work/existing.sig"
}
# put_new <key> <file> <cache-control> <compare> [<package the object is the signature of>]: write an object that must not be there. compare=yes: an object that is there
# has to be the same bytes (packages); compare=no: any object that is there is left as it is (a signature of the same package).
put_new() {
	local sha out have rc
	if [ "$cond" = no ]; then
		put "$1" "$2" "$3"
		return
	fi
	sha="$(sha256sum "$2" | cut -d' ' -f1)"
	if out="$(s3api put-object --bucket "$bucket" --key "$1" --body "$2" --cache-control "$3" --metadata "sha256=$sha" --if-none-match '*' 2>&1)"; then
		return 0
	fi
	case "$out" in
		*PreconditionFailed* | *"(412)"*) ;;
		*) echo "::error::cannot write $1: $out" >&2; return 1 ;;
	esac
	# it appeared since the head: a signature is read and verified, a package has to be the same bytes
	if [ "$4" = no ]; then
		[ -z "${5:-}" ] || verify_existing "$1" "$5"
		return
	fi
	rc=0
	have="$(head_sha "$1")" || rc=$?
	if [ "$rc" -ne 0 ] || [ "$have" != "$sha" ]; then
		echo "::error::$1 appeared in the bucket while it was being written and it is not the same bytes" >&2
		return 1
	fi
}
# ensure <key> <file> <cache-control> <compare> [<package it signs>]: the object is there, written first if it is not
ensure() {
	local sha rc=0 have
	sha="$(sha256sum "$2" | cut -d' ' -f1)"
	have="$(head_sha "$1")" || rc=$?
	if [ "$rc" -eq 0 ]; then
		if [ "$4" = yes ] && [ "$have" != "$sha" ]; then
			echo "::error::$1 is in the bucket with another SHA-256 than the one to publish; bytes that change need a new version" >&2
			return 1
		fi
		[ -z "${5:-}" ] || verify_existing "$1" "$5"
		return
	fi
	[ "$rc" -eq 3 ] || return 1
	put_new "$1" "$2" "$3" "$4" "${5:-}"
}

# restore_previous <files of the group that may have been written>: the previous database group goes back, or, on a
# first publication, what was written is removed. Said aloud, and a failure to put back is a failure of the run.
restore_previous() {
	local restored=0 f src old
	if [ -e "$previous/no-state" ]; then
		for f in "$@"; do
			s3api delete-object --bucket "$bucket" --key "$prefix/$f" > /dev/null 2>&1 || restored=1
		done
	else
		old=(glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig)
		for f in "${old[@]}"; do
			src="$previous/$f"
			[ "$f" != glyndor.state ] || src="$previous/state"
			[ "$f" != glyndor.state.sig ] || src="$previous/state.sig"
			[ -f "$src" ] || { restored=1; continue; }
			put "$prefix/$f" "$src" "$MUTABLE" || restored=1
		done
		for f in glyndor.db glyndor.db.sig; do
			src="$previous/glyndor.db.tar.zst"
			[ "$f" != glyndor.db.sig ] || src="$previous/glyndor.db.tar.zst.sig"
			put "$prefix/$f" "$src" "$MUTABLE" || restored=1
		done
	fi
	if [ "$restored" -eq 0 ]; then
		echo "::error::the previous repository was put back" >&2
	else
		echo "::error::the previous repository could NOT be put back; the bucket may hold a database that does not match its signature" >&2
	fi
	return "$restored"
}
if [ "$restore_only" = yes ]; then
	# What is there now is the state of the previous repository or the one of the tree that was being written, and nothing else.
	check_live "$previous" "$tree" || exit 1
	rc=0
	restore_previous glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.db glyndor.db.sig glyndor.state glyndor.state.sig || rc=$?
	exit "$rc"
fi

if [ "$cleanup_only" = yes ]; then
	dir="$tree/arch/x86_64"
	# 5. Cleanup, by what the signed state says, never by what is merely absent from the tree.
	retired="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$dir/glyndor.state" retired)" \
		|| { echo "::error::cannot read the retired packages of the state" >&2; exit 1; }
	current="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$dir/glyndor.db.tar.zst" | cut -f3)"
	while read -r file _retired_at delete_after; do
		[ -n "$file" ] || continue
		if printf '%s\n' "$current" | grep -qxF -- "$file"; then
			continue
		fi
		if [ "$delete_after" \< "$now" ]; then
			s3api delete-object --bucket "$bucket" --key "$prefix/$file" > /dev/null
			s3api delete-object --bucket "$bucket" --key "$prefix/$file.sig" > /dev/null
			echo "deleted $file, retired and past $delete_after"
		fi
	done <<< "$retired"
	echo "cleanup done"
	exit 0
fi

# 0. Nothing is written unless the bucket still holds what this run was built on, and the sequence goes up by one.
check_live "$previous" || exit 1
new_seq="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$dir/glyndor.state" sequence)"
if [ -e "$previous/no-state" ]; then
	want_seq=1
else
	want_seq=$(($(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$previous/state" sequence) + 1))
fi
[ "$new_seq" = "$want_seq" ] || { echo "::error::the state to publish is sequence $new_seq and the one served makes it $want_seq; nothing is written" >&2; exit 1; }

# A package that is in the bucket with other bytes is refused before the first write of any kind. One that is there is read back:
# its bytes are the ones to publish (the metadata is only what was said when it was written), and the signature that is there,
# if any, verifies it. "It is there, so I go on" is never enough for an object that clients install.
for f in "${packages[@]}"; do
	rc=0
	have="$(head_sha "$prefix/$f")" || rc=$?
	if [ "$rc" -eq 0 ]; then
		[ "$have" = "$(sha256sum "$dir/$f" | cut -d' ' -f1)" ] \
			|| { echo "::error::$f is in the bucket with another SHA-256 than the one to publish; bytes that change need a new version" >&2; exit 1; }
		fetch "$prefix/$f" "$work/existing.pkg" || { echo "::error::$f is in the bucket and cannot be read back" >&2; exit 1; }
		[ "$(sha256sum "$work/existing.pkg" | cut -d' ' -f1)" = "$(sha256sum "$dir/$f" | cut -d' ' -f1)" ] \
			|| { echo "::error::$f in the bucket is not the file to publish, whatever its metadata says; nothing is written" >&2; exit 1; }
		rm -f "$work/existing.pkg"
	elif [ "$rc" -ne 3 ]; then
		exit 1
	fi
	# A signature that is there is read and verified whether or not its package is: one left by an upload that stopped halfway, or
	# put there by somebody, would otherwise be taken as the signature of the package that is written next to it.
	src=0
	head_sha "$prefix/$f.sig" > /dev/null || src=$?
	if [ "$src" -eq 0 ]; then
		verify_existing "$prefix/$f.sig" "$dir/$f" || exit 1
	elif [ "$src" -ne 3 ]; then
		exit 1
	fi
done
started=yes
# 1. Packages and their signatures: immutable, and never replaced. The signature goes first, so that a package is never there
# without it, and one that is missing is written even when the package already is.
for f in "${packages[@]}"; do
	ensure "$prefix/$f.sig" "$dir/$f.sig" "$IMMUTABLE" no "$dir/$f" || exit 1
	ensure "$prefix/$f" "$dir/$f" "$IMMUTABLE" yes || exit 1
done

# 2. What lives beside the repository (optional: a tree without them uploads none).
for f in glyndor-pacman-key.asc index.html; do
	[ ! -f "$tree/$f" ] || put "$f" "$tree/$f" "$MUTABLE"
done
if [ -d "$tree/install" ]; then
	for f in "$tree"/install/*; do
		[ ! -f "$f" ] || put "install/$(basename "$f")" "$f" "$MUTABLE" "text/plain; charset=utf-8"
	done
fi

# 4. The database group, together, and put back if it is cut. The bucket is read once more: nothing may have changed meanwhile.
check_live "$previous" || exit 1
group=(glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.db glyndor.db.sig glyndor.state glyndor.state.sig)
written=()
failed=0
for f in "${group[@]}"; do
	if put "$prefix/$f" "$dir/$f" "$MUTABLE"; then
		written+=("$f")
	else
		failed=1
		break
	fi
done
if [ "$failed" -eq 1 ]; then
	echo "::error::a write of the database group failed after ${#written[@]} of ${#group[@]}; putting the previous one back" >&2
	rc=0
	restore_previous "${written[@]}" "${group[${#written[@]}]}" || rc=$?
	exit 1
fi

echo "uploaded ${#packages[@]} package(s) and the database group"
