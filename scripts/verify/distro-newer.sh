#!/usr/bin/env bash
#
# Fail when Arch itself carries a newer version of a package than this repository serves.
#
#   distro-newer.sh --served <file>        (inside an Arch container, with the network, as root)
#
# A repository that comes before [core] wins every name it carries, so a fix that Arch ships while this repository lags
# never reaches a host and nothing says so. This reads the databases of Arch alone (no [glyndor] block in the container),
# and for each served package that Arch also has compares the two versions with vercmp. A package that Arch does not
# carry (the explicit answer that it was not found) is skipped, and so is one that is newer here; any other failure to read a package stops the run.
set -euo pipefail
export LC_ALL=C

served=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::distro-newer.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--served) served="$2" ;;
		*) echo "::error::distro-newer.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
[ -f "$served" ] || { echo "::error::usage: distro-newer.sh --served <file>" >&2; exit 2; }
pacman -Sy --noconfirm > /dev/null
newer=0
while IFS=$'\t' read -r name version _sha _file; do
	[ -n "$name" ] || continue
	[[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]+$ ]] || { echo "::error::refusing the name '$name'" >&2; exit 1; }
	# Only the explicit answer that the package is not there means "Arch does not carry it"; any other failure stops the run, since a
	# package that could not be read is not a package that is absent. The version is what follows the label, whole: an epoch
	# (1:2.3-1) holds a colon of its own.
	rc=0
	info="$(pacman -Si -- "$name" 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		[ "$info" = "error: package '$name' was not found" ] && continue
		echo "::error::cannot read $name from the databases of Arch: $info" >&2
		exit 1
	fi
	theirs="$(printf '%s\n' "$info" | awk '/^Version[[:space:]]*:/ && !v { sub(/^[^:]*:[[:space:]]*/, ""); v=$0 } END { print v }')"
	[ -n "$theirs" ] || { echo "::error::pacman -Si $name answered with no Version" >&2; exit 1; }
	if [ "$(vercmp "$theirs" "$version")" -gt 0 ]; then
		echo "::error::Arch has $name $theirs and this repository serves $version; the repository wins the name, so hosts do not get the newer one" >&2
		newer=1
	fi
done < "$served"
exit "$newer"
