#!/usr/bin/env bash
set -euo pipefail

project_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
koreader_directory=${1:-$(flatpak info --show-location rocks.koreader.KOReader)/files/lib/koreader}
export TMPDIR="$HOME/tmp"
mkdir -p -- "$TMPDIR"
scratch_directory=$(mktemp -d -p "$TMPDIR" koreader-localsend-cli.XXXXXX)
cleanup_test_files() {
    case "$scratch_directory" in
        "$HOME"/tmp/koreader-localsend-cli.*)
            printf 'Removing test directory %s\n' "$scratch_directory"
            rm -rf -- "$scratch_directory"
            ;;
    esac
}
trap cleanup_test_files EXIT
curl -fL --max-time 35 -sS -o "$scratch_directory/localsend.tar.gz" \
  https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-CLI-1.18.2-linux-x86-64.tar.gz
printf '%s  %s\n' f5a986e0b4701b9aafeb9747225a2f3e314e97aba61b3dd7c9d076226f512b08 "$scratch_directory/localsend.tar.gz" | sha256sum -c -
tar -xzf "$scratch_directory/localsend.tar.gz" -C "$scratch_directory" localsend-cli
cd -- "$koreader_directory"
export LUA_PATH="$project_directory/localsend-lite.koplugin/?.lua;;"
export LD_LIBRARY_PATH="$PWD/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
python3 "$project_directory/tests/official-cli.py" "$scratch_directory/localsend-cli" "$project_directory/tests/official-peer.lua" "$scratch_directory"
