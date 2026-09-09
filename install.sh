#!/bin/sh
# Install a released wand binary:
#
#     curl -fsSL https://raw.githubusercontent.com/mjstahl/wand/main/install.sh | sh
#
# Detects the platform, downloads the matching archive from the latest
# release, verifies its sha256 against the checksum published beside it,
# checks the binary answers before it is installed, and puts `wand` in
# ~/.local/bin. No sudo, nothing outside the install directory.
#
#     WAND_VERSION=0.10.0 sh install.sh     # a specific release
#     WAND_INSTALL_DIR=~/bin sh install.sh  # somewhere else on your PATH
#
# The binary carries its own standard library, so the one file is the
# whole installation.

set -eu

repo="mjstahl/wand"
install_dir="${WAND_INSTALL_DIR:-$HOME/.local/bin}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ── Platform ──────────────────────────────────────────────────────────────

os=$(uname -s)
arch=$(uname -m)

case "$os" in
  Darwin) os=macos ;;
  Linux)  os=linux ;;
  *) fail "no release archive for $os; the README covers building from source" ;;
esac

case "$arch" in
  x86_64 | amd64)  arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) fail "no release archive for $os-$arch; the README covers building from source" ;;
esac

# ── Download tooling ──────────────────────────────────────────────────────

# curl, and only curl. There used to be a wget fallback; it could not have
# worked, and nothing here could have told you. Resolving "latest" means
# reading the URL that /releases/latest redirects to, which curl prints
# outright and wget does not -- so the wget path scraped the `Location:`
# header out of wget's diagnostic output, without asking wget to print
# headers at all, with a pattern that could not have matched the indented
# lines if it had. It failed closed, and it failed for everyone who reached
# it.
#
# Two reasons it is gone rather than fixed. Every CI runner has curl, so the
# branch never ran anywhere and a fix would have shipped unexercised. And the
# output it read is diagnostic text, which differs between GNU wget and the
# busybox one on the machines most likely to lack curl -- so a fix aimed at
# either would still be a guess about the other.
#
# The install line at the top of this file is a curl pipeline, so anyone
# following it has curl already.

command -v curl >/dev/null 2>&1 || fail \
  "curl is needed to install wand.
            Install curl, or take the archive for your platform from
            https://github.com/$repo/releases and unpack it yourself --
            it holds a single binary."

fetch()      { curl -fsSL -o "$2" "$1"; }
latest_url() { curl -fsSLI -o /dev/null -w '%{url_effective}' "$1"; }

if command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 -c "$1" >/dev/null; }
elif command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum -c "$1" >/dev/null; }
else
  fail "neither shasum nor sha256sum is available to verify the download"
fi

# ── Version ───────────────────────────────────────────────────────────────

# The /releases/latest page redirects to /releases/tag/vX.Y.Z; the version
# is read off the URL rather than the API, so no token and no JSON.
version="${WAND_VERSION:-}"
if [ -z "$version" ]; then
  tag_url=$(latest_url "https://github.com/$repo/releases/latest")
  version=${tag_url##*/tag/v}
  case "$version" in
    */*|'') fail "could not work out the latest version from $tag_url" ;;
  esac
fi

name="wand-$version-$os-$arch"
base="https://github.com/$repo/releases/download/v$version"

# ── Download, verify, prove it runs ───────────────────────────────────────

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading $name.tar.gz"
fetch "$base/$name.tar.gz" "$tmp/$name.tar.gz" \
  || fail "could not download $base/$name.tar.gz -- is v$version a release with a $os-$arch archive?"
fetch "$base/$name.tar.gz.sha256" "$tmp/$name.tar.gz.sha256" \
  || fail "could not download the checksum beside $name.tar.gz"

(cd "$tmp" && checksum "$name.tar.gz.sha256") \
  || fail "checksum mismatch for $name.tar.gz -- refusing to install it"
say "checksum verified"

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"

# From an empty directory, the way setup-wand does: wand carries its own
# standard library, so answering here is the whole claim the binary makes,
# and a broken download fails now rather than in your first script.
# `wand -e` is the spelling from 0.55.0 on and `wand e` the one before it.
# WAND_VERSION installs whatever it is given, so both are asked and an older
# release is not a failure.
# Both spellings are asked, and stderr is kept. A binary that dies at
# startup prints why and then aborts; discarding that left "did not run" as
# the whole report, and a run-time abort on the linux-x86_64 build has twice
# been diagnosed from nothing else.
err="$tmp/run.err"
got=$(cd "$tmp" && { "./$name/wand" -e '1 + 1' 2>"$err" \
                     || "./$name/wand" e '1 + 1' 2>"$err"; }) || {
  if [ -s "$err" ]; then
    printf 'install.sh: the binary said:\n' >&2
    sed 's/^/  /' "$err" >&2
  fi
  fail "the downloaded binary did not run"
}
[ "$got" = "2 : Int" ] || fail "the downloaded binary answered '$got' to 1 + 1"

# ── Install ───────────────────────────────────────────────────────────────

# Staged next to the destination and renamed over it: the archive's binary
# is read-only (dune's build outputs are 555, and tar keeps that), so an
# in-place cp over a previous install is refused -- and the rename swaps
# the file whole, so a running wand is never overwritten mid-execution.
mkdir -p "$install_dir"
cp "$tmp/$name/wand" "$install_dir/.wand.new.$$"
chmod 755 "$install_dir/.wand.new.$$"
mv -f "$install_dir/.wand.new.$$" "$install_dir/wand"

say "installed wand $version to $install_dir/wand"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) say "note: $install_dir is not on your PATH; add it with:"
     say "  export PATH=\"$install_dir:\$PATH\"" ;;
esac
