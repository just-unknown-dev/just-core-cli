#!/bin/sh
# Installs `just` and `ju` (just_core_cli) from the newest GitHub release, on macOS
# or Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/just-unknown-dev/just-core-cli/main/tool/install.sh | sh
#
# Or, with Dart: dart pub global activate just_core_cli
#
# Put the folder at the END of your PATH, so a `just` you already have (the
# `just` command runner, say) keeps working: then use `ju`.
set -eu

repo="just-unknown-dev/just-core-cli"
dir="${JUST_CORE_CLI_HOME:-$HOME/.just_core_cli}/bin"

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) echo "just_core_cli: no build for $(uname -s); use: dart pub global activate just_core_cli" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) echo "just_core_cli: no build for $(uname -m); use: dart pub global activate just_core_cli" >&2; exit 1 ;;
esac

tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
  sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$tag" ] || { echo "just_core_cli: could not find the newest release" >&2; exit 1; }
name="just_core_cli-$tag-$os-$arch.tar.gz"
base="https://github.com/$repo/releases/download/$tag"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$base/$name" -o "$tmp/$name"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
expected=$(grep -E "^[0-9a-f]{64} [ *]$name\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)
fi
[ "$expected" = "$actual" ] || { echo "just_core_cli: the download does not match its SHA-256; not installed" >&2; exit 1; }

tar xzf "$tmp/$name" -C "$tmp"
mkdir -p "$dir"
cp "$tmp/just_core_cli/just" "$tmp/just_core_cli/ju" "$dir/"
chmod +x "$dir/just" "$dir/ju"
echo "Installed just_core_cli $tag in $dir."

case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add it to the end of your PATH, in your shell's profile:"
     echo "  export PATH=\"\$PATH:$dir\"" ;;
esac
other=$(command -v just 2>/dev/null || true)
if [ -n "$other" ] && [ "$other" != "$dir/just" ]; then
  echo "Another \`just\` is on your PATH ($other), so use \`ju\`: the same tool."
else
  echo "Run: just doctor"
fi
