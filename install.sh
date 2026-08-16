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

if command -v curl >/dev/null 2>&1; then
  fetch()      { curl -fsSL -o "$2" "$1"; }
  latest_url() { curl -fsSLI -o /dev/null -w '%{url_effective}' "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch()      { wget -q -O "$2" "$1"; }
  latest_url() { wget -q --max-redirect=10 -O /dev/null "$1" 2>&1 \
                   | sed -n 's/^Location: \([^ ]*\).*/\1/p' | tail -1; }
else
  fail "neither curl nor wget is available"
fi

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
got=$(cd "$tmp" && "./$name/wand" e '1 + 1') \
  || fail "the downloaded binary did not run"
[ "$got" = "2 : Int" ] || fail "the downloaded binary answered '$got' to 1 + 1"

# ── Install ───────────────────────────────────────────────────────────────

mkdir -p "$install_dir"
cp "$tmp/$name/wand" "$install_dir/wand"
chmod +x "$install_dir/wand"

say "installed wand $version to $install_dir/wand"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) say "note: $install_dir is not on your PATH; add it with:"
     say "  export PATH=\"$install_dir:\$PATH\"" ;;
esac
