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

# --- put floot on PATH ---
# One block in the profile of the user's shell, between two marker lines. A
# rerun updates the block where it stands: lines already in it stay (the CLI
# adds its own later, such as the FVM folder), and only the ones missing are
# added before the closing marker. Printing the line instead left most people
# at "command not found" on their very first floot command.
block_start="# >>> added by floot >>>"
block_end="# <<< added by floot <<<"

case "${SHELL:-}" in
  */zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
  */bash)
    # Terminal.app opens a login shell, which reads .bash_profile and never
    # .bashrc; most Linux terminals open the other kind.
    if [ "$os" = "macos" ]; then profile="$HOME/.bash_profile"; else profile="$HOME/.bashrc"; fi
    ;;
  */fish) profile="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/floot.fish" ;;
  *) profile="$HOME/.profile" ;;
esac

case "${SHELL:-}" in
  */fish) path_line="contains -- \"${install_dir}\" \$PATH; or set -gx PATH \"${install_dir}\" \$PATH" ;;
  *) path_line="export PATH=\"${install_dir}:\$PATH\"" ;;
esac

# The CLI's tab completion for zsh registers through `compdef`, which only
# exists once zsh's completion system is loaded, and a new Mac's zsh does not
# load it. Loaded here, only when nothing else did, ahead of the completion
# entry the CLI appends below this block on its first run.
compinit_line=""
case "${SHELL:-}" in
  */zsh) compinit_line='if ! type compdef >/dev/null 2>&1; then autoload -Uz compinit && compinit -i; fi' ;;
esac

on_path="no"
case ":${PATH}:" in
  *":${install_dir}:"*) on_path="yes" ;;
esac

has_block="no"
if [ -f "$profile" ] && grep -qxF "$block_start" "$profile"; then
  has_block="yes"
fi

# Writes the new profile to $kept: the block's missing lines added before its
# closing marker, or a whole block appended when there is none.
build_profile() {
  kept="${work_dir}/profile"
  if [ "$has_block" = "yes" ]; then
    awk -v start="$block_start" -v end="$block_end" -v one="$path_line" -v two="$compinit_line" '
      $0 == start { inside = 1; has_one = 0; has_two = (two == "") }
      inside && $0 == one { has_one = 1 }
      inside && $0 == two { has_two = 1 }
      inside && $0 == end {
        if (!has_one) print one
        if (!has_two) print two
        inside = 0
      }
      { print }
    ' "$profile" >"$kept" || return 1
    return 0
  fi
  if [ -f "$profile" ]; then cat "$profile" >"$kept" || return 1; else : >"$kept"; fi
  # A blank line before the block, unless the file is empty or ends in one.
  if [ -s "$kept" ] && [ -n "$(tail -n 1 "$kept")" ]; then
    echo >>"$kept"
  fi
  {
    echo "$block_start"
    echo "$path_line"
    if [ -n "$compinit_line" ]; then echo "$compinit_line"; fi
    echo "$block_end"
  } >>"$kept"
}

# The profile written in place (cat, not mv), so a symlinked dotfile stays a
# link. Prints nothing and fails when the profile cannot be written.
write_profile() {
  mkdir -p "$(dirname "$profile")" 2>/dev/null || return 1
  cat "$kept" >"$profile" 2>/dev/null
}

by_hand() {
  echo "could not write to ${profile}, add these lines to it yourself:"
  echo "  ${path_line}"
  if [ -n "$compinit_line" ]; then echo "  ${compinit_line}"; fi
  echo "then open a new terminal and run floot login"
}

next_step() {
  if [ "$on_path" = "yes" ]; then
    echo "next: run floot login"
  else
    # A script read off a pipe cannot change the shell that started it.
    echo "open a new terminal, then run floot login"
  fi
}

if [ "$has_block" = "no" ] && [ "$on_path" = "yes" ]; then
  # The user put the folder on PATH themselves; their setup is left alone.
  next_step
elif ! build_profile; then
  by_hand
elif [ -f "$profile" ] && cmp -s "$kept" "$profile"; then
  # The block already carries every line.
  next_step
elif write_profile; then
  if [ "$has_block" = "yes" ]; then
    echo "updated the floot block in ${profile}"
  else
    echo "added ${install_dir} to your PATH in ${profile}"
  fi
  next_step
else
  by_hand
fi
