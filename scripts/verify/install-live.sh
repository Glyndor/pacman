#!/usr/bin/env bash
#
# Install from the repository the way the README says, on a host of Arch Linux, and check what came out. Runs INSIDE an
# Arch container with the network, as root (run-live.sh starts it).
#
#   install-live.sh install --base <url> --package <name> --expect <pkgver> [--fpr <hex>] [--distro <package>] [--run <command>]
#   install-live.sh upgrade --package <name> --expect <pkgver> [--run <command>]
#
# `install` brings the image up to date (a rolling distribution is only what it is today), optionally installs the
# distribution's own package first (a host that already has the Podman of `extra`), downloads the installer of the
# repository, runs it (the README's command with its prompts answered), and checks the version that pacman reports, that
# the keyring package came in, and that a second system upgrade finds nothing to do. `upgrade` is run later, on the same
# host, after the repository published a newer version, and checks that `pacman -Syu` brings it.
set -euo pipefail
export LC_ALL=C

mode="${1:-}"
shift || true
base="" package="" expect="" fpr="" distro="" run=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::install-live.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--base) base="$2" ;;
		--package) package="$2" ;;
		--expect) expect="$2" ;;
		--fpr) fpr="$2" ;;
		--distro) distro="$2" ;;
		--run) run="$2" ;;
		*) echo "::error::install-live.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
case "$mode" in install | upgrade) ;; *) echo "::error::usage: install-live.sh install|upgrade ..." >&2; exit 2 ;; esac
[[ "$package" =~ ^[a-z0-9@_+][a-z0-9@._+-]+$ ]] || { echo "::error::--package is a package name" >&2; exit 2; }
[[ "$expect" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?-1$ ]] || { echo "::error::--expect is a pkgver of the form X.Y.Z[+rN]-1" >&2; exit 2; }
[ "$mode" = upgrade ] || [ -n "$base" ] || { echo "::error::install needs --base" >&2; exit 2; }
[ -z "$distro" ] || [[ "$distro" =~ ^[a-z0-9@_+][a-z0-9@._+-]+$ ]] || { echo "::error::--distro is a package name" >&2; exit 2; }

installed() { pacman -Q "$package" | awk '{ print $2 }'; }
if [ "$mode" = install ]; then
	# A container image of Arch has the keys of the distribution but no master key of its own; an installed host has one. The
	# installer signs the repository key locally with it, so the container gets what any installed Arch has before the
	# commands of the README run.
	if ! compgen -G "${PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}/private-keys-v1.d/*.key" > /dev/null; then
		prepared="$(pacman-key --init 2>&1 && pacman-key --populate archlinux 2>&1)" || { printf '%s\n' "$prepared" >&2; echo "::error::the keyring of the container could not be prepared" >&2; exit 1; }
	fi
	pacman -Syu --noconfirm > /dev/null
	[ -z "$distro" ] || pacman -S --noconfirm "$distro" > /dev/null
	installer="$(mktemp)"
	curl --silent --show-error --fail --location --proto '=https,http' --max-time 60 --connect-timeout 20 --output "$installer" "$base/install/$package"
	# The command of the README, with its prompts answered: pacman asks before it removes what a package replaces.
	# shellcheck disable=SC2016 # the inner shell expands INSTALLER
	env GLYNDOR_PACMAN_BASE="$base" ${fpr:+GLYNDOR_PACMAN_FPR="$fpr"} INSTALLER="$installer" sh -c 'yes | sh "$INSTALLER"'
	pacman -Q glyndor-keyring > /dev/null || { echo "::error::the keyring package did not come in with $package" >&2; exit 1; }
else
	pacman -Syu --noconfirm > /dev/null
fi
got="$(installed)"
[ "$got" = "$expect" ] || { echo "::error::pacman reports $package $got, expected $expect" >&2; exit 1; }
if [ -n "$run" ]; then
	sh -c "$run" > /dev/null || { echo "::error::'$run' failed after the install" >&2; exit 1; }
fi
again="$(pacman -Syu --noconfirm 2>&1 || true)"
case "$again" in *"there is nothing to do"*) ;; *) echo "::error::a second system upgrade still had something to do:" >&2; printf '%s\n' "$again" | tail -5 >&2; exit 1 ;; esac
echo "$package $got is installed from $([ "$mode" = install ] && echo "$base" || echo "the upgrade")"
