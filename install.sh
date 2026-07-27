#!/bin/sh
#
# RunInfra CLI installer for Linux and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.sh | sh
#
# Installs the standalone `runinfra` binary, which needs no Node and no Python
# runtime on the host. The binary is verified against the release's SHA256SUMS
# file before anything is written into place, and the installer never edits a
# shell profile: if the install directory is not on PATH it prints the line to
# add and the file to add it to, and leaves that decision to you.
#
# OPTIONS. Every option is an environment variable and a flag. Use the flags
# when the script is piped, since a pipe has no place to put an assignment:
#
#   curl -fsSL <url> | sh -s -- --version 0.1.1 --install-dir /usr/local/bin
#
#   RUNINFRA_VERSION       --version       Pin a release, "0.1.1" or "v0.1.1".
#                                          Default: the newest release.
#   RUNINFRA_INSTALL_DIR   --install-dir   Default: $HOME/.local/bin
#   RUNINFRA_REPO          --repo          owner/name holding the releases.
#   RUNINFRA_BASE_URL      --base-url      Take the artifacts from this
#                                          directory URL instead of a release.
#                                          https:// and file:// only. Skips the
#                                          version lookup entirely.
#   RUNINFRA_TARGET        --target        Force the build to fetch, for example
#                                          "linux-x64". Default: detected from
#                                          uname. Use it to stage a build for a
#                                          machine you are not standing on.
#
# THE RELEASE LAYOUT THIS EXPECTS. Each release is tagged "v<version>" and
# carries these files as flat assets, with no directory components in the name:
#
#   runinfra-linux-x64           runinfra-darwin-x64
#   runinfra-linux-x64-musl      runinfra-darwin-arm64
#   runinfra-linux-arm64         runinfra-windows-x64.exe
#   runinfra-linux-arm64-musl    SHA256SUMS
#
# SHA256SUMS is coreutils format: one "<64 lowercase hex>  <artifact>" line per
# artifact. If a build is missing from a release, the machine that needs it
# gets a refusal naming the exact file, which is the correct outcome. Installing
# a glibc build on a musl host would produce a loader error nobody can read.

set -eu

# pipefail is not in POSIX sh. dash does not have it, bash, ksh, zsh and
# busybox ash do. Turn it on where it exists rather than demanding a shell.
# An `if` condition is exempt from `set -e`, which a bare `&&` is not.
# shellcheck disable=SC3040
if (set -o pipefail 2>/dev/null); then set -o pipefail; fi

RELEASE_REPO_DEFAULT="RightNow-AI/runinfra-cli"
BINARY_NAME="runinfra"

# Every build the release publishes. A target that is not on this list is
# refused before anything is downloaded.
SUPPORTED_TARGETS="linux-x64 linux-x64-musl linux-arm64 linux-arm64-musl darwin-x64 darwin-arm64"

tmp_dir=""
staged_path=""

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
  --base-url URL        Directory URL to take the artifacts from, https or file.
  --target NAME         Build to fetch, for example linux-x64. Default: detected.
  -h, --help            This text.

The same values are read from RUNINFRA_VERSION, RUNINFRA_INSTALL_DIR,
RUNINFRA_REPO, RUNINFRA_BASE_URL and RUNINFRA_TARGET.
USAGE
}

# ----------------------------------------------------------- the options ---

version_req="${RUNINFRA_VERSION:-}"
install_dir="${RUNINFRA_INSTALL_DIR:-}"
release_repo="${RUNINFRA_REPO:-$RELEASE_REPO_DEFAULT}"
base_url="${RUNINFRA_BASE_URL:-}"
forced_target="${RUNINFRA_TARGET:-}"

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

	target="${target_os}-${target_arch}${target_libc}"
	detected_as="$uname_s $uname_m"
fi

artifact="${BINARY_NAME}-${target}"

# ---------------------------------------------------------------- the tools

# Everything that could refuse is checked before a single byte is transferred.
# Discovering there is no way to verify a checksum after pulling down a hundred
# megabytes would be an insult.
if have curl; then
	downloader=curl
elif have wget; then
	downloader=wget
else
	die "no way to download anything: neither curl nor wget is installed." \
		"Install one of them and run this again."
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

# ------------------------------------------------------------ the transfers

# $1 url, $2 destination, $3 "quiet" or "progress". A hundred megabytes with no
# progress bar looks like a hang, so the binary gets one and the small files
# do not.
download() {
	case "$downloader" in
	curl)
		if [ "$3" = progress ]; then
			curl --fail --show-error --location \
				--proto-redir '=https' \
				--connect-timeout 20 --speed-limit 1024 --speed-time 60 \
				--progress-bar --output "$2" "$1"
		else
			curl --fail --silent --show-error --location \
				--proto-redir '=https' \
				--connect-timeout 20 --speed-limit 1024 --speed-time 60 \
				--output "$2" "$1"
		fi
		;;
	wget)
		if [ "$3" = progress ]; then
			wget --output-document "$2" "$1"
		else
			wget --quiet --output-document "$2" "$1"
		fi
		;;
	esac
}

# The newest release, without the API. Asking github.com for /releases/latest
# answers with a redirect to the tag, which costs no rate limit budget. The
# API is only used when curl is absent, because wget will not report where it
# was redirected to.
resolve_latest_tag() {
	case "$downloader" in
	curl)
		latest_url="$(curl --fail --silent --show-error --location \
			--proto-redir '=https' --connect-timeout 20 --max-time 60 \
			--output /dev/null --write-out '%{url_effective}' \
			"https://github.com/${release_repo}/releases/latest")" || return 1
		printf '%s\n' "${latest_url##*/}"
		;;
	wget)
		latest_json="$(wget --quiet --output-document - \
			"https://api.github.com/repos/${release_repo}/releases/latest")" || return 1
		printf '%s' "$latest_json" | tr ',' '\n' |
			sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
		;;
	esac
}

# ------------------------------------------------------------- where from ---

if [ -n "$base_url" ]; then
	case "$base_url" in
	https://* | file://*) ;;
	http://*)
		die "refusing an http:// source: $base_url" \
			"The checksum would arrive over the same unprotected connection as the" \
			"binary, so anything able to change one can change the other. Use https."
		;;
	*)
		die "--base-url must start with https:// or file://, got: $base_url"
		;;
	esac
	source_base="${base_url%/}"
	source_label="$source_base"
	release_tag=""
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

# GNU writes "<hash>  <name>", and in binary mode "<hash> *<name>". Match both,
# and match only the exact artifact name so that "runinfra-linux-x64" can never
# be satisfied by the line for "runinfra-linux-x64-musl".
expected_sha="$(awk -v want="$artifact" '$2 == want || $2 == "*" want { print $1; exit }' \
	"${tmp_dir}/SHA256SUMS")"

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

chmod 755 "$staged_path" || die "could not make ${artifact} executable."

# Run the staged copy before it takes the real name. If it cannot run here it
# will not run once renamed, and an upgrade that swapped a working binary for
# a broken one would be the worst outcome this script could produce.
#
# stdin comes from /dev/null on purpose. Under `curl | sh` the shell is
# reading this script from stdin, so a child that read stdin would eat the
# rest of the installer.
if ! installed_version="$("$staged_path" --version 2>&1 </dev/null)"; then
	die "the downloaded binary passed its checksum but will not run here." \
		"${installed_version}" \
		"Nothing has been replaced. If ${install_dir} is mounted noexec, install" \
		"somewhere else: --install-dir \$HOME/bin"
fi

mv -f "$staged_path" "$destination" || die \
	"could not move the new binary into ${destination}." \
	"Nothing has been replaced."
staged_path=""

# ------------------------------------------------------------------- report

say ""
say "Installed ${installed_version} to ${destination}"

case ":${PATH:-}:" in
*":${install_dir}:"*)
	say "Run: ${BINARY_NAME} login"
	;;
*)
	profile_hint="$HOME/.profile"
	path_line="export PATH=\"${install_dir}:\$PATH\""
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
		path_line="fish_add_path ${install_dir}"
		;;
	esac
	say ""
	say "${install_dir} is not on your PATH, so the name ${BINARY_NAME} will not"
	say "resolve yet. Add this line to ${profile_hint} and open a new terminal:"
	say ""
	say "  ${path_line}"
	say ""
	say "This installer does not edit your shell files. Until you add that line,"
	say "the full path works: ${destination} login"
	;;
esac

say ""
