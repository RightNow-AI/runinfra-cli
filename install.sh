#!/bin/sh
#
# RunInfra CLI installer for Linux and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.sh | sh
#
# Installs the standalone `runinfra` binary, which needs no Node and no Python
# runtime on the host. The binary is verified against the release's SHA256SUMS
# file, and SHA256SUMS is itself checked against an Ed25519 signature made by a
# key pinned inside this script, before anything is written into place.
#
# That check can be skipped, so it is not promised unconditionally here. It is
# skipped when the host has no openssl able to do Ed25519, when the artifacts
# came from a --base-url mirror that serves no signature, when a temporary file
# for the pinned key cannot be written, and when RUNINFRA_ALLOW_UNSIGNED=1 says
# to skip it. Every one of those says on its own line that it was skipped and
# why, and the checksum comparison still runs and still refuses a bad file.
# What is never skipped: a signature that fails, and a release that serves no
# signature at all. Both end the install.
# A remote BusyBox wget download always requires a verified signature, because
# its redirects cannot be restricted to HTTPS. The skip cases above only apply
# to HTTPS-enforcing downloaders or an explicitly selected local file mirror.
#
# The installer never edits a shell profile: if the install directory is not on
# PATH it prints the line to add and the file to add it to, and leaves that
# decision to you.
#
# OPTIONS. Most options are an environment variable and a flag. Use the flags
# when the script is piped, since a pipe has no place to put an assignment:
#
#   curl -fsSL <url> | sh -s -- --version 0.1.1 --install-dir /usr/local/bin
#
#   RUNINFRA_VERSION       --version       Pin a release, "0.1.1" or "v0.1.1".
#                                          Default: the newest release.
#   RUNINFRA_INSTALL_DIR   --install-dir   Default: $HOME/.local/bin
#   RUNINFRA_REPO          --repo          owner/name holding the releases.
#   RUNINFRA_INSTALL_BASE_URL --base-url   Take the artifacts from this
#                                          directory URL instead of a release.
#                                          HTTPS or an explicit file:/// mirror.
#                                          Skips the
#                                          version lookup entirely.
#   RUNINFRA_TARGET        --target        Force the build to fetch, for example
#                                          "linux-x64". Default: detected from
#                                          uname. Use it to stage a build for a
#                                          machine you are not standing on.
#
# RUNINFRA_ALLOW_UNSIGNED=1 is the one escape hatch, and it has no flag on
# purpose: it is not part of a normal install. Set it to install from a release
# that serves no SHA256SUMS.sig, which is a thing a deliberate mirror operator
# does and a thing an ordinary user never needs. Without it, a release with no
# signature ends the install.
#
# THE RELEASE LAYOUT THIS EXPECTS. Each release is tagged "v<version>" and
# carries these files as flat assets, with no directory components in the name:
#
#   runinfra-linux-x64           runinfra-darwin-x64
#   runinfra-linux-x64-musl      runinfra-darwin-arm64
#   runinfra-linux-arm64         runinfra-windows-x64.exe
#   runinfra-linux-arm64-musl    SHA256SUMS
#                                SHA256SUMS.sig
#                                THIRD-PARTY-NOTICES.txt
#
# SHA256SUMS is coreutils format: one "<64 lowercase hex>  <artifact>" line per
# artifact. If a build is missing from a release, the machine that needs it
# gets a refusal naming the exact file, which is the correct outcome. Installing
# a glibc build on a musl host would produce a loader error nobody can read.
#
# WHAT THE SIGNATURE PROVES, stated plainly, because a security claim that
# oversells itself is worse than none at all.
#
# SHA256SUMS.sig is an Ed25519 signature over SHA256SUMS. The public half of
# that key is pinned in this file as a literal and is never downloaded, so the
# chain a good signature establishes is: this script trusts one key, that key
# signed this SHA256SUMS, and this SHA256SUMS names the hash of the binary now
# on disk.
#
# It proves the file came out of the RunInfra release pipeline. It does NOT
# prove the pipeline was not subverted. The signing key is held by CI, so
# whoever can steal the release token or edit the release workflow can also
# reach the key. What this defends against is a release asset altered after
# publication, and a hostile mirror or CDN serving something other than what
# was published. Those are real attacks and this closes them. It is not the
# same thing as the download being tamper proof, and this installer does not
# claim that.

set -eu

# pipefail is not in POSIX sh. dash does not have it, bash, ksh, zsh and
# busybox ash do. Turn it on where it exists rather than demanding a shell.
# An `if` condition is exempt from `set -e`, which a bare `&&` is not.
# shellcheck disable=SC3040
if (set -o pipefail 2>/dev/null); then set -o pipefail; fi

RELEASE_REPO_DEFAULT="RightNow-AI/runinfra-cli"
BINARY_NAME="runinfra"
NOTICES_NAME="THIRD-PARTY-NOTICES.txt"

# Every build the release publishes. A target that is not on this list is
# refused before anything is downloaded.
SUPPORTED_TARGETS="linux-x64 linux-x64-musl linux-arm64 linux-arm64-musl darwin-x64 darwin-arm64"

tmp_dir=""
download_headers=""
staged_path=""
staged_notices_path=""
notices_backup_path=""
notices_destination=""
notices_replaced=no
keep_notices_backup=no
# Which openssl performs the signature check. Resolved for real below, because
# the one on PATH is not always one that can do the job. Defaulted here so no
# path can reach it unset.
openssl_bin="openssl"

# ---------------------------------------------------------------- output ---

say() {
	printf '%s\n' "$*"
}

# First argument is the failure. Every argument after it is an indented line of
# context under it. Always the last thing this script does.
die() {
	printf 'runinfra install: %s\n' "$1" >&2
	shift
	for die_line in "$@"; do
		printf '  %s\n' "$die_line" >&2
	done
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

cleanup() {
	if [ -n "$download_headers" ]; then rm -f "$download_headers"; fi
	# The binary rename is the commit point. Until its staged copy disappears,
	# restore attribution too, including a notices rename that failed midway.
	if [ "$notices_replaced" = yes ] && [ -n "$staged_path" ] && [ -e "$staged_path" ]; then
		if [ -n "$notices_backup_path" ] && { [ -e "$notices_backup_path" ] || [ -L "$notices_backup_path" ]; }; then
			if ! mv -f "$notices_backup_path" "$notices_destination"; then
				printf 'runinfra install: could not restore previous notices. They remain at %s\n' "$notices_backup_path" >&2
				keep_notices_backup=yes
			fi
		elif [ -e "$notices_destination" ] || [ -L "$notices_destination" ]; then
			rm -f "$notices_destination" || printf 'runinfra install: could not remove notices at %s\n' "$notices_destination" >&2
		fi
	fi
	if [ -n "$staged_notices_path" ] && [ -e "$staged_notices_path" ]; then
		rm -f "$staged_notices_path"
	fi
	if [ "$keep_notices_backup" = no ] && [ -n "$notices_backup_path" ] && { [ -e "$notices_backup_path" ] || [ -L "$notices_backup_path" ]; }; then
		rm -f "$notices_backup_path"
	fi
	if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
		rm -rf "$tmp_dir"
	fi
	# A half-written binary in the install directory is worse than no binary,
	# and it is a dotfile the user did not ask for. It never survives us.
	if [ -n "$staged_path" ] && [ -e "$staged_path" ]; then
		rm -f "$staged_path"
	fi
}

trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

usage() {
	cat <<'USAGE'
Installs the runinfra CLI.

  --version VALUE       Release to install, "0.1.1" or "v0.1.1". Default: newest.
  --install-dir PATH    Where to put the binary. Default: $HOME/.local/bin
  --repo OWNER/NAME     Repository holding the releases.
  --base-url URL        HTTPS directory URL or an explicit file:/// mirror.
  --target NAME         Build to fetch, for example linux-x64. Default: detected.
  -h, --help            This text.

The same values are read from RUNINFRA_VERSION, RUNINFRA_INSTALL_DIR,
RUNINFRA_REPO, RUNINFRA_INSTALL_BASE_URL and RUNINFRA_TARGET.

RUNINFRA_ALLOW_UNSIGNED=1 installs from a release that serves no
SHA256SUMS.sig. It has no flag, and without it a missing release signature
ends the install.
USAGE
}

# ----------------------------------------------------------- the options ---

version_req="${RUNINFRA_VERSION:-}"
install_dir="${RUNINFRA_INSTALL_DIR:-}"
release_repo="${RUNINFRA_REPO:-$RELEASE_REPO_DEFAULT}"
base_url="${RUNINFRA_INSTALL_BASE_URL:-}"
forced_target="${RUNINFRA_TARGET:-}"
# Read once, compared against the literal 1 and nothing else. A hatch that
# opens for "0", "false" or an empty accident is not a deliberate act.
allow_unsigned="${RUNINFRA_ALLOW_UNSIGNED:-}"

# Flags win over the environment: they are the more recent, more deliberate
# statement of intent, and on a piped install they are the only one available.
while [ "$#" -gt 0 ]; do
	case "$1" in
	--version)
		[ "$#" -ge 2 ] || die "--version needs a value, for example --version 0.1.1."
		version_req="$2"
		shift
		;;
	--version=*) version_req="${1#--version=}" ;;
	--install-dir)
		[ "$#" -ge 2 ] || die "--install-dir needs a path."
		install_dir="$2"
		shift
		;;
	--install-dir=*) install_dir="${1#--install-dir=}" ;;
	--repo)
		[ "$#" -ge 2 ] || die "--repo needs an owner/name value."
		release_repo="$2"
		shift
		;;
	--repo=*) release_repo="${1#--repo=}" ;;
	--base-url)
		[ "$#" -ge 2 ] || die "--base-url needs a URL."
		base_url="$2"
		shift
		;;
	--base-url=*) base_url="${1#--base-url=}" ;;
	--target)
		[ "$#" -ge 2 ] || die "--target needs a value, for example linux-x64."
		forced_target="$2"
		shift
		;;
	--target=*) forced_target="${1#--target=}" ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1" "Run with --help to see what this accepts."
		;;
	esac
	shift
done

if [ -z "$install_dir" ]; then
	if [ -z "${HOME:-}" ]; then
		die "HOME is not set, so there is no default install directory." \
			"Pass one: --install-dir /usr/local/bin"
	fi
	install_dir="$HOME/.local/bin"
fi

# ------------------------------------------------------- what machine is this

if [ -n "$forced_target" ]; then
	target="$forced_target"
	target_supported=no
	for candidate in $SUPPORTED_TARGETS; do
		if [ "$candidate" = "$target" ]; then target_supported=yes; fi
	done
	if [ "$target_supported" != yes ]; then
		die "unknown target: $target" \
			"Builds that exist: $SUPPORTED_TARGETS"
	fi
	detected_as="forced with --target"
else
	uname_s="$(uname -s 2>/dev/null || echo unknown)"
	uname_m="$(uname -m 2>/dev/null || echo unknown)"

	case "$uname_s" in
	Linux) target_os=linux ;;
	Darwin) target_os=darwin ;;
	MINGW* | MSYS* | CYGWIN* | Windows_NT)
		die "this is Windows, and this script installs the Linux and macOS builds." \
			"Windows has its own installer. In PowerShell, run:" \
			"irm https://raw.githubusercontent.com/$release_repo/main/install.ps1 | iex"
		;;
	*)
		die "unsupported operating system: uname -s reported '$uname_s'." \
			"There are builds for Linux and macOS only." \
			"If that report is wrong, force it: --target linux-x64"
		;;
	esac

	case "$uname_m" in
	x86_64 | amd64 | x64) target_arch=x64 ;;
	aarch64 | arm64) target_arch=arm64 ;;
	*)
		die "unsupported CPU architecture: uname -m reported '$uname_m'." \
			"There are builds for x86_64 and arm64 only."
		;;
	esac

	# musl is a different C library, not a different flavour of the same one.
	# A glibc binary on Alpine dies with a loader error that reads like a
	# corrupt download, so detect it here and ask for the right file.
	target_libc=""
	if [ "$target_os" = linux ]; then
		if have ldd; then
			# No pipeline: musl's ldd exits non-zero even when it answers,
			# and under pipefail that would swallow the detection.
			ldd_report="$( (ldd --version) 2>&1 || true)"
			case "$ldd_report" in
			*musl*) target_libc="-musl" ;;
			esac
		fi
		if [ -z "$target_libc" ]; then
			for loader in /lib/ld-musl-*.so.1; do
				if [ -e "$loader" ]; then target_libc="-musl"; fi
				break
			done
		fi
	fi

	# The musl build links against libstdc++ and libgcc, which a bare Alpine
	# does not carry. Without them the binary installs perfectly and then dies
	# on first run with a wall of "Error relocating ... symbol not found" and
	# exit 127, which reads like a corrupt download and is not. Say so now,
	# while the reader is still looking at this terminal, rather than letting
	# them discover it later. This is a note, not a refusal: the file may
	# already be present under a name we did not look for, and being wrong
	# here must not stop an install that would have worked.
	if [ "$target_libc" = "-musl" ]; then
		if ! ls /usr/lib/libstdc++.so.* >/dev/null 2>&1; then
			say ""
			say "Note: this looks like a musl system without libstdc++, which the"
			say "binary needs in order to start. If it fails with \"Error relocating\""
			say "then install it and run runinfra again:"
			say ""
			say "  apk add --no-cache libstdc++"
			say ""
		fi
	fi

	target="${target_os}-${target_arch}${target_libc}"
	detected_as="$uname_s $uname_m"
fi

artifact="${BINARY_NAME}-${target}"

# ---------------------------------------------------------------- the tools

# Everything that could refuse is checked before a single byte is transferred.
# Discovering there is no way to verify a checksum after pulling down a hundred
# megabytes would be an insult.
download_tool=""
if have curl; then
	download_tool=curl
elif have wget; then
	if wget --no-config --version >/dev/null 2>&1; then
		download_tool=wget
	else
		case "$(wget --help 2>&1 || true)" in
		*BusyBox*) download_tool=wget-busybox ;;
		esac
	fi
fi
if [ -z "$download_tool" ]; then
	case "$base_url" in
	file:///*) download_tool=local ;;
	*) die "curl is required unless GNU or BusyBox wget is available." ;;
	esac
fi

if have sha256sum; then
	sha_tool=sha256sum
elif have shasum; then
	sha_tool=shasum
elif have openssl; then
	sha_tool=openssl
else
	die "no way to verify a checksum: none of sha256sum, shasum or openssl is installed." \
		"Refusing to install bytes that cannot be checked against the published hash." \
		"Install coreutils (sha256sum) or openssl, then run this again."
fi

sha256_of() {
	case "$sha_tool" in
	sha256sum) sha256sum "$1" | awk '{print $1}' ;;
	shasum) shasum -a 256 "$1" | awk '{print $1}' ;;
	openssl) openssl dgst -sha256 "$1" | awk '{print $NF}' ;;
	esac
}

# Return nothing only when the exact filename is absent. Duplicate, malformed,
# or hashless entries remain errors rather than becoming optional downloads.
manifest_checksum() {
	awk -v want="$1" '
		{
			sub(/\r$/, "")
			listed = 0
			for (field = 1; field <= NF; field++) {
				if ($field == want || $field == "*" want) listed = 1
			}
			if (listed) {
				count++
				hash = $1
				if (NF != 2 || ($2 != want && $2 != "*" want)) malformed = 1
			}
		}
		END {
			if (count == 0) exit
			if (count > 1) print "duplicate"
			else if (malformed) print "invalid"
			else print hash
		}' "$2"
}

# ------------------------------------------------------------ the transfers

# $1 url, $2 destination, $3 "quiet" or "progress". A hundred megabytes with no
# progress bar looks like a hang, so the binary gets one and the small files
# do not.
require_https_url() {
	case "$1" in
	https://*) ;;
	*) die "Downloads require an HTTPS URL." ;;
	esac
	download_authority="${1#https://}"
	download_authority="${download_authority%%[/?#]*}"
	case "$download_authority" in
	"" | *@* | *\\*) die "Downloads require an HTTPS URL without user information." ;;
	esac
	case "$1" in
	*[![:graph:]]*) die "Download URLs must not contain whitespace or control characters." ;;
	esac
}

# Only the explicitly selected mirror can authorize a local transfer. No
# response header may switch a remote download to a file or network share.
local_mirror_path() {
	case "$1" in file:///*) local_path="${1#file://}" ;; *) return 1 ;; esac
	case "$local_path" in
	//* | *'?'* | *'#'* | *'\\'*) return 1 ;;
	esac
	# Match control bytes, not locale-dependent printable characters. Local
	# filename bytes, including UTF-8 under LC_ALL=C, must survive unchanged.
	[ "$local_path" = "$(printf '%s' "$local_path" | LC_ALL=C tr -d '\001-\037\177')" ] || return 1
	# Decode URI bytes without interpreting escapes as shell source.
	local_encoded="$local_path"
	local_path=""
	while [ -n "$local_encoded" ]; do
		case "$local_encoded" in
		%*)
			local_hex=$(printf '%.2s' "${local_encoded#%}")
			case "$local_hex" in [0-9A-Fa-f][0-9A-Fa-f]) ;; *) return 1 ;; esac
			case "$local_hex" in 0? | 1? | 7[fF] | 5[cC]) return 1 ;; esac
			local_oct=$(printf '%03o' "0x$local_hex")
			local_path="$local_path$(printf "\\$local_oct")"
			local_encoded="${local_encoded#???}"
			;;
		*)
			local_char="${local_encoded%"${local_encoded#?}"}"
			local_path="$local_path$local_char"
			local_encoded="${local_encoded#?}"
			;;
		esac
	done
	case "$local_path" in //*) return 1 ;; esac
}

# GNU Wget's https-only option applies to recursive links. max-redirect=0
# refuses before requesting the next URL, so this loop validates every hop.
# https://raw.githubusercontent.com/mirror/wget/master/doc/wget.texi
# https://raw.githubusercontent.com/mirror/wget/master/src/retr.c
# BusyBox lacks those controls and keeps its native redirects. Remote downloads
# therefore require a verified release signature before their bytes are used.
wget_https() {
	wget_url="$1"
	wget_destination="$2"
	wget_redirects=0
	download_headers=$(mktemp "${TMPDIR:-/tmp}/runinfra-headers.XXXXXX") || return 1
	while :; do
		require_https_url "$wget_url"
		wget_status=0
		if [ "$download_tool" = wget-busybox ]; then
			wget -S -T 60 -O "$wget_destination" "$wget_url" 2>"$download_headers" || wget_status=$?
		else
			wget --no-config --server-response --max-redirect=0 --https-only \
				--timeout=60 --tries=1 --output-document="$wget_destination" "$wget_url" 2>"$download_headers" || wget_status=$?
		fi
		wget_code=$(awk '/^  HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { code=$2 } END { print code }' "$download_headers")
		case "$wget_code" in
		301 | 302 | 303 | 307 | 308)
			[ "$wget_redirects" -lt 5 ] || break
			wget_location=$(awk '/^  HTTP\// { location="" } /^[ \t]+[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:/ { sub(/^[ \t]+[^:]+:[ \t]*/, ""); sub(/\r$/, ""); sub(/ \[following\]$/, ""); location=$0 } END { print location }' "$download_headers")
			[ -n "$wget_location" ] || break
			wget_origin="${wget_url#https://}"
			wget_origin="https://${wget_origin%%[/?#]*}"
			case "$wget_location" in
			https://*) wget_url="$wget_location" ;;
			//*) wget_url="https:$wget_location" ;;
			/*) wget_url="$wget_origin$wget_location" ;;
			\?*) wget_url="${wget_url%%[?#]*}$wget_location" ;;
			\#*) wget_url="${wget_url%%#*}$wget_location" ;;
			*:*) break ;;
			*) wget_url="${wget_url%%[?#]*}"; wget_url="${wget_url%/*}/$wget_location" ;;
			esac
			wget_redirects=$((wget_redirects + 1))
			;;
		200)
			if [ "$wget_status" -eq 0 ]; then
				rm -f "$download_headers"; download_headers=""
				wget_final_url="$wget_url"
				return 0
			fi
			break ;;
		*) break ;;
		esac
	done
	rm -f "$download_headers"; download_headers=""
	if [ "$wget_destination" != /dev/null ]; then rm -f "$wget_destination"; fi
	case "$wget_code" in 404 | 410) return 22 ;; esac
	return 1
}

download() {
	case "$1" in
	file:///*)
		[ -n "$base_url" ] && [ "${1%/*}" = "${base_url%/}" ] && local_mirror_path "$1" || die "Downloads require HTTPS or an explicit local file mirror."
		[ -e "$local_path" ] || return 22
		if cp "$local_path" "$2" 2>/dev/null; then return 0; fi
		rm -f "$2"
		return 1 ;;
	esac
	require_https_url "$1"
	case "$download_tool" in wget | wget-busybox) wget_https "$1" "$2"; return $? ;; esac
	if [ "$3" = progress ]; then download_display=--progress-bar; else download_display=--silent; fi
	# --disable must be first: a user's curlrc must not enable insecure TLS or
	# add output files. Restrict both the initial URL and every redirect.
	if curl --disable --fail --show-error --location \
		--proto '=https' --proto-redir '=https' --max-redirs 5 \
		--connect-timeout 20 --max-time 600 --speed-limit 1024 --speed-time 60 \
		"$download_display" --output "$2" "$1"; then
		return 0
	else
		download_status=$?
		rm -f "$2"
		return "$download_status"
	fi
}

# Curl and GNU wget resolve the newest release without the API. Asking
# github.com for /releases/latest redirects to the tag without a rate limit.
resolve_latest_tag() {
	if [ "$download_tool" = wget-busybox ]; then
		# BusyBox does not report its final URL. Keep the original API lookup.
		latest_url="https://api.github.com/repos/${release_repo}/releases/latest"
		require_https_url "$latest_url"
		latest_json="$(wget -q -T 60 -O - "$latest_url")" || return 1
		printf '%s' "$latest_json" | tr ',' '\n' |
			sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
		return 0
	fi
	if [ "$download_tool" = wget ]; then
		wget_https "https://github.com/${release_repo}/releases/latest" /dev/null || return 1
		printf '%s\n' "${wget_final_url##*/}"
		return 0
	fi
	latest_url="$(curl --disable --fail --silent --show-error --location \
		--proto '=https' --proto-redir '=https' --max-redirs 5 \
		--connect-timeout 20 --max-time 60 \
		--output /dev/null --write-out '%{url_effective}' \
		"https://github.com/${release_repo}/releases/latest")" || return 1
	printf '%s\n' "${latest_url##*/}"
}

# ------------------------------------------------------ the release signature

# The public half of the release signing key, pinned here as a literal.
#
# It is deliberately not downloaded. A key fetched from the same host as the
# artifact proves nothing, because whoever is in a position to replace one is
# in a position to replace the other, and would simply serve a matching pair.
# Pinning it means the only way to change which key this installer trusts is
# to change this installer.
#
# The fingerprint is sha256 over the raw 32 byte public key, which is the last
# 32 bytes of the SPKI DER above. It is published in cli/README.md so the value
# below can be compared against a copy that did not arrive with this file.
RELEASE_KEY_FINGERPRINT="5b2c8f637c0cd00a61ec6f126e5a9493c022ef1ea5be70fdd3ef4adf55801532"

write_release_key() {
	cat >"$1" <<'RUNINFRA_RELEASE_KEY'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAYkEJIc7GfRAHAvUXcY/jrtnwFj53XZNDoXE6cAkOxYk=
-----END PUBLIC KEY-----
RUNINFRA_RELEASE_KEY
}

# Can the openssl at $1 actually do Ed25519? Answered with a self contained
# round trip, not by parsing a version banner: make a throwaway key, sign a few
# bytes, verify them. It touches no network and costs milliseconds.
#
# The probe exists because a non-zero exit from openssl has two opposite
# meanings and no way to tell them apart from the exit code alone. macOS ships
# LibreSSL as /usr/bin/openssl, and LibreSSL's pkeyutl has no -rawin, so the
# real verification would fail there with a usage error rather than a
# cryptographic one. Treating that as an attack would refuse the install on
# every stock Mac, which is a self inflicted outage rather than security. Only
# a failure that happens AFTER this round trip has succeeded is evidence about
# the file we downloaded.
openssl_can_verify_ed25519() {
	probe_openssl="$1"
	probe_dir="${tmp_dir}/sigprobe"
	# Each candidate is judged on what it writes itself, never on a file the
	# previous candidate left behind.
	rm -rf "$probe_dir" >/dev/null 2>&1 || true
	mkdir -p "$probe_dir" || return 1
	printf 'runinfra' >"${probe_dir}/msg" || return 1
	"$probe_openssl" genpkey -algorithm ed25519 -out "${probe_dir}/probe.pem" >/dev/null 2>&1 || return 1
	"$probe_openssl" pkey -in "${probe_dir}/probe.pem" -pubout -out "${probe_dir}/probe.pub" >/dev/null 2>&1 || return 1
	"$probe_openssl" pkeyutl -sign -inkey "${probe_dir}/probe.pem" -rawin \
		-in "${probe_dir}/msg" -out "${probe_dir}/msg.sig" >/dev/null 2>&1 || return 1
	"$probe_openssl" pkeyutl -verify -pubin -inkey "${probe_dir}/probe.pub" -rawin \
		-in "${probe_dir}/msg" -sigfile "${probe_dir}/msg.sig" >/dev/null 2>&1 || return 1
	# The pinned key has to load in this openssl too, or the real verify would
	# fail for a reason that has nothing to do with the signature.
	"$probe_openssl" pkey -pubin -in "$release_key_path" -noout >/dev/null 2>&1 || return 1
	return 0
}

# The openssl that can do the job is not always the one on PATH, and on macOS
# it usually is not: /usr/bin/openssl is LibreSSL, so the probe above fails and
# the signature would go unchecked on a stock Mac. Homebrew's openssl@3 is a
# real OpenSSL and is frequently already installed; it is kept off PATH by
# design so it does not shadow the system one. So look where it actually lives,
# and run the SAME round trip against each candidate rather than assuming a
# path implies a capability. First one that passes wins.
#
# Sets openssl_bin and returns 0, or returns 1 having set openssl_seen to the
# first candidate that existed, for a message that can name what it tried.
resolve_openssl_for_ed25519() {
	openssl_bin=""
	openssl_seen=""

	for candidate in openssl \
		/opt/homebrew/opt/openssl@3/bin/openssl \
		/usr/local/opt/openssl@3/bin/openssl; do
		have "$candidate" || continue
		if [ -z "$openssl_seen" ]; then openssl_seen="$candidate"; fi
		if openssl_can_verify_ed25519 "$candidate"; then
			openssl_bin="$candidate"
			return 0
		fi
	done

	# Asked last, and only when it is needed, because it shells out to brew.
	# The two paths above are where brew puts openssl@3 on Apple silicon and on
	# Intel, so this only earns its keep on a non-default prefix.
	if have brew; then
		brew_prefix="$( (brew --prefix openssl@3) 2>/dev/null || true)"
		if [ -n "$brew_prefix" ] && have "${brew_prefix}/bin/openssl"; then
			if [ -z "$openssl_seen" ]; then openssl_seen="${brew_prefix}/bin/openssl"; fi
			if openssl_can_verify_ed25519 "${brew_prefix}/bin/openssl"; then
				openssl_bin="${brew_prefix}/bin/openssl"
				return 0
			fi
		fi
	fi

	return 1
}

# $1 the signature as downloaded, $2 where to leave exactly 64 raw bytes.
#
# An Ed25519 signature is 64 bytes. Releases publish it either as those raw
# bytes or as their base64 text, and both are accepted here rather than
# hardcoding one: guessing wrong would turn every honest release into a hard
# refusal. Whatever arrives is normalised to raw bytes before it reaches
# openssl, and anything that is neither shape is reported as malformed. If the
# release job ever adopts a third encoding, this function is the one place
# that has to learn about it.
normalize_signature() {
	sig_bytes="$(wc -c <"$1" 2>/dev/null | tr -d '\000-\040')"
	case "$sig_bytes" in
	'' | *[!0-9]*) return 1 ;;
	esac

	if [ "$sig_bytes" -eq 64 ]; then
		cat "$1" >"$2" || return 1
		return 0
	fi

	# base64 of 64 bytes is 88 characters, plus whatever line wrapping and
	# trailing newline the writer chose. Every byte at or below 0x20 goes
	# first, so a wrapped file, a single line file and a CRLF file all decode
	# identically. Raw signature bytes are never fed through this path, so
	# stripping them cannot corrupt a signature that was already raw.
	tr -d '\000-\040' <"$1" >"${2}.b64" 2>/dev/null || return 1
	"$openssl_bin" base64 -d -A -in "${2}.b64" -out "$2" >/dev/null 2>&1 || return 1

	sig_bytes="$(wc -c <"$2" 2>/dev/null | tr -d '\000-\040')"
	[ "$sig_bytes" = 64 ] || return 1
	return 0
}

# $1 the SHA256SUMS file to authenticate. Called BEFORE SHA256SUMS is trusted
# to say anything about the binary, because that is the order the chain runs
# in: the signature authenticates the manifest, the manifest authenticates the
# bytes.
#
# A bad signature is an attack and ends the install. So is an absent one, when
# the artifacts came from a release: see the refusal below for why those are
# the same finding and not two different ones.
#
# Only a downloader that enforces HTTPS at every hop, or an explicit local
# mirror, may skip authentication. A matching binary and checksum can both be
# replaced after an unchecked redirect, so every other transport fails closed.
refuse_unverified_download() {
	case "$source_base" in file:///*) return 0 ;; esac
	case "$download_tool" in curl | wget) return 0 ;; esac
	die "Install curl or openssl to verify this download."
}

verify_release_signature() {
	sums_file="$1"
	sig_file="${tmp_dir}/SHA256SUMS.sig"

	if download "${source_base}/SHA256SUMS.sig" "$sig_file" quiet; then
		:
	else
		signature_download_status=$?
		refuse_unverified_download
		if [ "$signature_download_status" -ne 22 ]; then
			die "The release signature download did not complete."
		fi
		# On a real release this is fatal. An attacker who can serve a swapped
		# binary can also delete the signature that would expose it, so
		# accepting the absence would hand away the whole defence to whoever
		# asks for it: the check this file documents would be worth exactly
		# nothing against the attacker it is aimed at. A missing signature and
		# a wrong one are the same event with a different verb, so they get the
		# same answer.
		#
		# A --base-url mirror is the case this does not apply to, because the
		# person who typed that URL chose the source deliberately and a mirror
		# carrying only the binaries is an ordinary thing.
		if [ "$source_is_release" = yes ] && [ "$allow_unsigned" != 1 ]; then
			die "SHA256SUMS.sig could not be downloaded from ${source_label}. Nothing has been installed." \
				"Every RunInfra release publishes an Ed25519 signature over SHA256SUMS," \
				"so a release without one is a refusal here, not a note." \
				"" \
				"A dropped connection looks the same from here as a deleted file, so try" \
				"again before reading anything into it. If it keeps happening, take it" \
				"seriously: whoever can serve you a swapped binary can also remove the" \
				"signature that would have exposed it. A check that goes away on request" \
				"is not a check, which is why this one does not." \
				"" \
				"If you are mirroring this release yourself, or installing one published" \
				"before the signing key existed, skip it deliberately:" \
				"" \
				"  curl -fsSL <url> | RUNINFRA_ALLOW_UNSIGNED=1 sh" \
				"" \
				"Otherwise do not run these bytes. Report it at https://github.com/${release_repo}/issues"
		fi
		if [ "$source_is_release" = yes ]; then
			say "Note: SHA256SUMS.sig could not be downloaded and RUNINFRA_ALLOW_UNSIGNED=1 is set, so the release signature was NOT checked. The sha256 checksum still runs."
		else
			say "Note: SHA256SUMS.sig could not be downloaded from this source, so the release signature was NOT checked. The sha256 checksum still runs."
		fi
		return 0
	fi

	release_key_path="${tmp_dir}/runinfra-release-key.pem"
	if ! write_release_key "$release_key_path"; then
		refuse_unverified_download
		say "Note: the pinned public key could not be written to a temporary file, so the release signature was NOT checked. The sha256 checksum still runs."
		return 0
	fi

	if ! resolve_openssl_for_ed25519; then
		refuse_unverified_download
		if [ -z "$openssl_seen" ]; then
			say "Note: openssl is not installed, so the release signature was NOT checked. The sha256 checksum still runs."
		else
			say "Note: no openssl here can verify Ed25519 (${openssl_seen} is $("$openssl_seen" version 2>/dev/null || echo unknown)), so the release signature was NOT checked. The sha256 checksum still runs. On macOS, brew install openssl@3 provides one that can."
		fi
		return 0
	fi

	say "Verifying signature"

	sig_raw="${tmp_dir}/SHA256SUMS.sig.raw"
	if ! normalize_signature "$sig_file" "$sig_raw"; then
		refuse_unverified_download
		die "SHA256SUMS.sig is not an Ed25519 signature. Nothing has been installed." \
			"It is neither 64 raw bytes nor the base64 form of them." \
			"A signature file that is not a signature is not a formatting quirk," \
			"it means the published file was replaced. Do not use this download."
	fi

	# openssl exits non-zero here only after the round trip above proved this
	# openssl can perform exactly this operation, so there is one explanation
	# left: these bytes were not signed by the pinned key.
	if ! "$openssl_bin" pkeyutl -verify -pubin -inkey "$release_key_path" \
		-rawin -in "$sums_file" -sigfile "$sig_raw" >/dev/null 2>&1; then
		refuse_unverified_download
		die "SIGNATURE VERIFICATION FAILED on SHA256SUMS. Nothing has been installed." \
			"SHA256SUMS was not signed by the RunInfra release key" \
			"${RELEASE_KEY_FINGERPRINT}" \
			"which is pinned inside this installer." \
			"" \
			"This is not a damaged download. A damaged file fails the checksum," \
			"it does not carry a signature that verifies against the wrong key." \
			"Someone has changed what ${source_label} is serving, or something" \
			"between you and it is rewriting the response." \
			"Do not run these bytes. Report it at https://github.com/${release_repo}/issues"
	fi

	say "Signature verified. SHA256SUMS was signed by release key ${RELEASE_KEY_FINGERPRINT}"
}

# ------------------------------------------------------------- where from ---

if [ -n "$base_url" ]; then
	case "$base_url" in
	file:///*) local_mirror_path "$base_url" && [ -d "$local_path" ] || die "Downloads require HTTPS or an existing local file mirror." ;;
	*) require_https_url "$base_url" ;;
	esac
	source_base="${base_url%/}"
	source_label="$source_base"
	release_tag=""
	# The user named this source themselves. Whatever it does or does not carry
	# is their arrangement, so a missing signature here is a note rather than a
	# refusal. Everything below builds its own URL and is held to the stricter
	# rule.
	source_is_release=no
else
	if [ -n "$version_req" ]; then
		# "0.1.1" becomes the v form, which is how releases are tagged.
		# Anything not starting with a digit is taken to be a tag already, so
		# an unusual scheme can still be pinned without a flag for it.
		case "$version_req" in
		[0-9]*) release_tag="v${version_req}" ;;
		*) release_tag="$version_req" ;;
		esac
	else
		say "Looking up the newest release of ${release_repo}."
		release_tag="$(resolve_latest_tag || true)"
		if [ -z "$release_tag" ]; then
			die "could not work out the newest release of ${release_repo}." \
				"Check the network, or pin one: --version 0.1.1"
		fi
		# This tag came from the release itself, so it only has to look like a
		# version, with or without the v. Demanding one spelling here would
		# break a correct lookup over punctuation.
		case "$release_tag" in
		v[0-9]* | [0-9]*) ;;
		*)
			die "the newest release of ${release_repo} is tagged '$release_tag', which is not a version." \
				"Pin the one you want: --version 0.1.1"
			;;
		esac
	fi
	source_base="https://github.com/${release_repo}/releases/download/${release_tag}"
	source_label="${release_repo} ${release_tag}"
	source_is_release=yes
fi

# ------------------------------------------------------------------ the plan

# Make a relative --install-dir absolute before anything is announced, so the
# plan names the same place the closing line does. This touches nothing on
# disk: the directory does not have to exist yet to be named properly.
case "$install_dir" in
/*) ;;
*) install_dir="$(pwd)/${install_dir#./}" ;;
esac

destination="${install_dir}/${BINARY_NAME}"
action="Installing"
if [ -e "$destination" ]; then
	action="Upgrading"
fi

say ""
say "${action} the runinfra CLI."
printf '  %-14s %s\n' "machine" "$detected_as"
printf '  %-14s %s\n' "build" "$artifact"
printf '  %-14s %s\n' "source" "$source_label"
printf '  %-14s %s\n' "install to" "$destination"
printf '  %-14s %s\n' "checked with" "$sha_tool"
say ""

# ---------------------------------------------------------------- do it -----

mkdir -p "$install_dir" || die "could not create $install_dir" \
	"Pick somewhere you can write: --install-dir \$HOME/bin"

# Resolve to an absolute path so every message names one real place, including
# when --install-dir was relative. Without the guard, a directory that exists
# but cannot be entered would end the script with no explanation at all.
# Resolved into a second name first: a failed command substitution still
# assigns, so writing it back into install_dir would empty the very value the
# error message needs to name.
install_dir_abs="$(cd "$install_dir" && pwd)" ||
	die "created ${install_dir} but cannot enter it." \
		"Check the permissions on it, or pick somewhere else: --install-dir \$HOME/bin"
install_dir="$install_dir_abs"
destination="${install_dir}/${BINARY_NAME}"

tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t runinfra)" ||
	die "could not create a temporary directory."

# The binary is staged inside the install directory, not in the temp
# directory. That keeps the final step a rename on one filesystem, which is
# atomic: nobody ever sees a half-written runinfra, and an upgrade cannot
# leave the old one destroyed and the new one incomplete.
staged_path="${install_dir}/.${BINARY_NAME}.download.$$"

say "Downloading ${artifact}"
download "${source_base}/${artifact}" "$staged_path" progress || die \
	"could not download ${artifact}" \
	"from ${source_base}/${artifact}" \
	"If that file is missing, this release has no build for ${target}."

say "Downloading SHA256SUMS"
download "${source_base}/SHA256SUMS" "${tmp_dir}/SHA256SUMS" quiet || die \
	"could not download SHA256SUMS from ${source_base}/SHA256SUMS" \
	"Without it the binary cannot be verified, so nothing has been installed."

# Authenticate the manifest before reading a single hash out of it. Nothing
# below this line is trustworthy on its own: SHA256SUMS arrives from the same
# place as the binary, so an attacker able to swap the binary can swap its
# recorded hash to match. The signature is what makes the checksum mean
# something, which is why it is checked first.
verify_release_signature "${tmp_dir}/SHA256SUMS"

# GNU writes "<hash>  <name>", and in binary mode "<hash> *<name>". Match both,
# and match only the exact artifact name so that "runinfra-linux-x64" can never
# be satisfied by the line for "runinfra-linux-x64-musl".
expected_sha="$(manifest_checksum "$artifact" "${tmp_dir}/SHA256SUMS")"

if [ "$expected_sha" = duplicate ]; then
	die "SHA256SUMS contains a duplicate entry for ${artifact}." "Nothing has been installed."
fi

if [ -z "$expected_sha" ]; then
	die "SHA256SUMS has no line for ${artifact}." \
		"Nothing has been installed. This release is incomplete for ${target}."
fi
if [ "${#expected_sha}" -ne 64 ]; then
	die "the SHA256SUMS entry for ${artifact} is not a sha256 hash." \
		"Nothing has been installed."
fi
case "$expected_sha" in
*[!0-9a-fA-F]*)
	die "the SHA256SUMS entry for ${artifact} is not a sha256 hash." \
		"Nothing has been installed."
	;;
esac

say "Verifying checksum"
# Both sides are folded to lowercase before they are compared, because some
# tools emit uppercase hex. Only the hex letters are folded: a locale-wide
# A-Z fold is a wider promise than a hash needs.
actual_sha="$(sha256_of "$staged_path" | tr 'ABCDEF' 'abcdef')"
expected_sha="$(printf '%s' "$expected_sha" | tr 'ABCDEF' 'abcdef')"

if [ "$actual_sha" != "$expected_sha" ]; then
	die "checksum mismatch on ${artifact}. Nothing has been installed." \
		"expected  ${expected_sha}" \
		"got       ${actual_sha}" \
		"The download is damaged or it is not the file the release published." \
		"Try again, and if it happens twice do not use the file."
fi

# Older releases did not list notices. Once listed, they must be downloaded
# and verified before the binary is executed or either installed file changes.
notices_expected_sha="$(manifest_checksum "$NOTICES_NAME" "${tmp_dir}/SHA256SUMS")"
if [ "$notices_expected_sha" = duplicate ]; then
	die "SHA256SUMS contains a duplicate entry for ${NOTICES_NAME}." "Nothing has been installed."
fi
if [ -n "$notices_expected_sha" ]; then
	if [ "${#notices_expected_sha}" -ne 64 ]; then
		die "SHA256SUMS must contain exactly one valid sha256 hash for ${NOTICES_NAME}." "Nothing has been installed."
	fi
	case "$notices_expected_sha" in
	*[!0-9a-fA-F]*)
		die "SHA256SUMS must contain exactly one valid sha256 hash for ${NOTICES_NAME}." "Nothing has been installed."
		;;
	esac
	staged_notices_path="${install_dir}/.${NOTICES_NAME}.download.$$"
	say "Downloading ${NOTICES_NAME}"
	download "${source_base}/${NOTICES_NAME}" "$staged_notices_path" quiet || die \
		"could not download ${NOTICES_NAME} listed in SHA256SUMS." \
		"Nothing has been installed. This release is incomplete."
	notices_actual_sha="$(sha256_of "$staged_notices_path" | tr 'ABCDEF' 'abcdef')"
	notices_expected_sha="$(printf '%s' "$notices_expected_sha" | tr 'ABCDEF' 'abcdef')"
	if [ "$notices_actual_sha" != "$notices_expected_sha" ]; then
		die "checksum mismatch on ${NOTICES_NAME}. Nothing has been installed." \
			"expected  ${notices_expected_sha}" \
			"got       ${notices_actual_sha}" \
			"Try again, and if it happens twice do not use the file."
	fi
	chmod 644 "$staged_notices_path" || die "could not make ${NOTICES_NAME} readable."
fi

chmod 755 "$staged_path" || die "could not make ${artifact} executable."

# Run the staged copy before it takes the real name. If it cannot run here it
# will not run once renamed, and an upgrade that swapped a working binary for
# a broken one would be the worst outcome this script could produce.
#
# stdin comes from /dev/null on purpose. Under `curl | sh` the shell is
# reading this script from stdin, so a child that read stdin would eat the
# rest of the installer.
if ! installed_version="$("$staged_path" --version 2>&1 </dev/null)"; then
	case "$installed_version" in
	*GLIBC_*|*GLIBCXX_*|*built\ for\ macOS*|*requires\ macOS*|*Symbol\ not\ found*|*Error\ relocating*)
		boot_hint="This system is too old or lacks required runtime libraries. GNU Linux needs glibc 2.25 or newer; macOS needs 13.0 or newer. On Alpine, install libstdc++."
		;;
	*Permission\ denied*|*Operation\ not\ permitted*)
		boot_hint="If ${install_dir} is mounted noexec, install somewhere else: --install-dir \$HOME/bin"
		;;
	*)
		boot_hint="Check that the selected target matches this machine and its OS and runtime requirements."
		;;
	esac
	die "the downloaded binary passed its checksum but will not run here." \
		"${installed_version}" \
		"Nothing has been replaced. ${boot_hint}"
fi

if [ -n "$staged_notices_path" ]; then
	notices_destination="${install_dir}/${NOTICES_NAME}"
	if [ -e "$notices_destination" ] || [ -L "$notices_destination" ]; then
		[ -f "$notices_destination" ] || die "${notices_destination} is not a file." \
			"Nothing has been replaced. Move it aside and try again."
		notices_backup_path="${install_dir}/.${NOTICES_NAME}.previous.$$"
		cp -p -P "$notices_destination" "$notices_backup_path" || die "could not preserve ${notices_destination}." \
			"Nothing has been replaced."
	fi
	notices_replaced=yes
	mv -f "$staged_notices_path" "$notices_destination" || die "could not put ${NOTICES_NAME} into ${install_dir}." \
		"The previous binary remains installed."
	staged_notices_path=""
fi

mv -f "$staged_path" "$destination" || die \
	"could not move the new binary into ${destination}." \
	"Nothing has been replaced."
staged_path=""
notices_replaced=no

# ------------------------------------------------------------------- report

say ""
say "Installed ${installed_version} to ${destination}"

case ":${PATH:-}:" in
*":${install_dir}:"*)
	say "Paste the setup prompt into your coding agent: https://runinfra.ai/docs/tools-sdks/agent-setup"
	say "To set it up yourself, run runinfra."
	;;
*)
	profile_hint="$HOME/.profile"
	quoted_install_dir="$(printf '%s' "$install_dir" | sed "s/'/'\\\\''/g")"
	quoted_destination="$(printf '%s' "$destination" | sed "s/'/'\\\\''/g")"
	path_line="export PATH='${quoted_install_dir}':\"\$PATH\""
	case "$(basename "${SHELL:-sh}")" in
	zsh) profile_hint="$HOME/.zshrc" ;;
	bash)
		profile_hint="$HOME/.bashrc"
		if [ "${target%%-*}" = darwin ]; then
			profile_hint="$HOME/.bash_profile"
		fi
		;;
	fish)
		profile_hint="$HOME/.config/fish/config.fish"
		# Fish single quotes escape both backslashes and apostrophes.
		quoted_install_dir="$(printf '%s' "$install_dir" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
		quoted_destination="$(printf '%s' "$destination" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
		path_line="fish_add_path '${quoted_install_dir}'"
		;;
	esac
	say ""
	say "${install_dir} is not on your PATH, so the name ${BINARY_NAME} will not"
	say "resolve yet. Add this line to ${profile_hint} and open a new terminal:"
	say ""
	say "  ${path_line}"
	say ""
	say "This installer does not edit your shell files. Until you add that line,"
	say "the full path works: '${quoted_destination}'"
	say "Paste the setup prompt into your coding agent: https://runinfra.ai/docs/tools-sdks/agent-setup"
	say "To set it up yourself, run the full path above, or runinfra once your PATH is set."
	;;
esac

say ""
