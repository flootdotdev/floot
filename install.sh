#!/bin/sh
# Installs the floot CLI for macos or linux. This is piped straight into
# `sh` (curl -fsSL https://floot.dev/install.sh | sh), so it has to stay
# strict POSIX sh: no arrays, no [[ ]], no "local", no "function" keyword.
set -eu

repo="flootdotdev/floot"
api_url="https://api.github.com/repos/${repo}/releases/latest"
download_base="https://github.com/${repo}/releases/download"

err() {
  echo "error: $1" >&2
  exit 1
}

# --- detect platform ---
uname_s=$(uname -s)
case "$uname_s" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  *) err "unsupported operating system: $uname_s" ;;
esac

uname_m=$(uname -m)
case "$uname_m" in
  x86_64 | amd64) arch="x64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *) err "unsupported architecture: $uname_m" ;;
esac

asset="floot-${os}-${arch}.tar.gz"

# curl or wget, whichever is on the box; no other dependency is assumed
if command -v curl >/dev/null 2>&1; then
  downloader="curl"
elif command -v wget >/dev/null 2>&1; then
  downloader="wget"
else
  err "neither curl nor wget is installed, one of them is required"
fi

# $1 = url, $2 = output file path. No authorization header: a release
# download redirects to an object store that signs the redirect itself and
# answers 400 when a second credential rides along, and wget forwards headers
# across hosts.
fetch() {
  if [ "$downloader" = "curl" ]; then
    curl -fsSL "$1" -o "$2"
  else
    wget -q "$1" -O "$2"
  fi
}

# $1 = url, body goes to stdout. This one is the API call, the only request a
# token helps, and it never redirects off api.github.com.
fetch_api() {
  if [ "$downloader" = "curl" ]; then
    if [ -n "${auth_header:-}" ]; then
      curl -fsSL -H "$auth_header" "$1"
    else
      curl -fsSL "$1"
    fi
  else
    if [ -n "${auth_header:-}" ]; then
      wget -q --header="$auth_header" -O - "$1"
    else
      wget -q -O - "$1"
    fi
  fi
}

# optional token, only to dodge the unauthenticated rate limit, never required
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
auth_header=""
if [ -n "$token" ]; then
  auth_header="Authorization: Bearer $token"
fi

# the API is used instead of following the /releases/latest redirect
# because it is the thing that skips pre-releases; the tag is pulled out
# with grep/sed/cut on purpose so the script does not need jq installed
api_response=$(fetch_api "$api_url") || err "failed to reach $api_url"
tag=$(printf '%s\n' "$api_response" | grep '"tag_name"' | head -n 1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
[ -n "$tag" ] || err "could not determine the latest release tag"
version=$(printf '%s\n' "$tag" | sed 's/^cli-v//')

echo "installing floot $version for ${os}-${arch}"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT INT TERM

fetch "${download_base}/${tag}/${asset}" "${work_dir}/${asset}" || err "failed to download ${asset}"
fetch "${download_base}/${tag}/checksums.txt" "${work_dir}/checksums.txt" || err "failed to download checksums.txt"

if command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "${work_dir}/${asset}" | cut -d ' ' -f 1)
elif command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "${work_dir}/${asset}" | cut -d ' ' -f 1)
else
  err "neither shasum nor sha256sum is installed, one of them is required"
fi

expected=$(awk -v want="$asset" '$2 == want || $2 == "*" want { print $1; exit }' "${work_dir}/checksums.txt")
[ -n "$expected" ] || err "no checksum entry found for ${asset} in checksums.txt"
if [ "$actual" != "$expected" ]; then
  err "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
fi

mkdir -p "${work_dir}/extracted"
tar -xzf "${work_dir}/${asset}" -C "${work_dir}/extracted"
binary=$(find "${work_dir}/extracted" -type f -name "floot" | head -n 1)
[ -n "$binary" ] || err "could not find the floot binary inside ${asset}"

# the install directory has to stay user writable because "floot update"
# replaces this binary in place later and must never need sudo to do it
install_dir="${FLOOT_INSTALL_DIR:-$HOME/.floot/bin}"
mkdir -p "$install_dir"
chmod 755 "$binary"
mv -f "$binary" "${install_dir}/floot"

# The version is taken from the tag rather than from the binary: running it
# here would also fire its post-run check against pub.dev, on a channel that
# does not install from there.
echo "installed floot ${version} to ${install_dir}/floot"

case ":${PATH}:" in
  *":${install_dir}:"*) ;;
  *)
    case "${SHELL:-}" in
      */zsh) profile="~/.zshrc" ;;
      */bash) profile="~/.bashrc" ;;
      *) profile="~/.profile" ;;
    esac
    # The line is printed rather than appended: this script is usually read
    # off a pipe into sh, and editing a shell profile nobody asked us to
    # touch is not something to do sight unseen.
    echo "${install_dir} is not on your PATH yet, add this line to ${profile}:"
    echo "  export PATH=\"${install_dir}:\$PATH\""
    ;;
esac

echo "next: run floot login"
