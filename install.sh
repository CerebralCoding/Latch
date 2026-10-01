#!/bin/sh
set -eu
umask 077

fail() { printf 'latch installer: %s\n' "$*" >&2; exit 1; }

[ "$(/usr/bin/id -u)" != 0 ] || fail 'run as your macOS login user, not root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'macOS is required'
[ "$(/usr/bin/uname -m)" = arm64 ] || fail 'Apple Silicon is required'
os_version=$(/usr/bin/sw_vers -productVersion)
[ "${os_version%%.*}" -ge 26 ] || fail 'macOS 26 or newer is required'
[ "${HOME#/}" != "$HOME" ] || fail 'HOME must be an absolute path'

# Releases package this script with an immutable version; source copies require one.
version='@LATCH_VERSION@'
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --version ] || fail 'usage: install.sh [--version X.Y.Z]'
    version=$2
fi
case "$version" in ''|*[!0-9.]*|.*|*..*|*.) fail 'specify a release with --version X.Y.Z' ;; esac
old_ifs=$IFS
IFS=.
set -- $version
IFS=$old_ifs
[ "$#" -eq 3 ] || fail 'version must have three numeric components'

target="$HOME/.local/bin/latch"
plist="$HOME/Library/LaunchAgents/com.cerebralcoding.latch.plist"
mode=install
if [ -L "$target" ]; then
    fail "refusing to replace symlink: $target"
elif [ -e "$target" ]; then
    [ -f "$target" ] && [ -x "$target" ] && [ -f "$plist" ] && [ ! -L "$plist" ] || fail 'conflicting or incomplete installation'
    mode=update
elif [ -e "$plist" ] || [ -L "$plist" ]; then
    fail 'service configuration exists without its executable'
fi

cache="$HOME/.cache/latch"
[ ! -L "$cache" ] || fail "cache must not be a symlink: $cache"
/bin/mkdir -p "$cache"
[ "$(/usr/bin/stat -f %u "$cache")" = "$(/usr/bin/id -u)" ] || fail 'cache must be owned by this user'
/bin/chmod 700 "$cache"
work=$(/usr/bin/mktemp -d "$cache/install.XXXXXXXX")
trap '/bin/rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

asset="latch-$version-macos-arm64"
base="https://github.com/CerebralCoding/Latch/releases/download/v$version"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 --output "$work/latch" "$base/$asset"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 --retry 2 --output "$work/checksum" "$base/$asset.sha256"
read -r expected < "$work/checksum" || fail 'missing checksum'
case "$expected" in ''|*[!0-9a-f]*) fail 'invalid SHA-256 checksum' ;; esac
[ "${#expected}" -eq 64 ] || fail 'invalid SHA-256 checksum'
actual=$(/usr/bin/shasum -a 256 "$work/latch")
[ "${actual%% *}" = "$expected" ] || fail 'download checksum mismatch'

requirement='anchor apple generic and identifier "com.cerebralcoding.latch" and certificate leaf[subject.OU] = "YKF838CLKT" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
/usr/bin/codesign --verify --strict --verbose=2 --test-requirement "$requirement" "$work/latch"
/bin/chmod 755 "$work/latch"
[ "$("$work/latch" --version)" = "$version" ] || fail 'release version does not match download'

if [ "$mode" = update ]; then
    "$work/latch" update --timeout 600
else
    "$work/latch" service install
fi
