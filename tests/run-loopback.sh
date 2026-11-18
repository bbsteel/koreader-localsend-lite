#!/usr/bin/env bash
set -euo pipefail

project_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
koreader_directory=${1:-$(flatpak info --show-location rocks.koreader.KOReader)/files/lib/koreader}
export TMPDIR="$HOME/tmp"
mkdir -p -- "$TMPDIR"
scratch_directory=$(mktemp -d -p "$TMPDIR" koreader-localsend.XXXXXX)
trap 'rm -rf -- "$scratch_directory"' EXIT
cd -- "$koreader_directory"
export LUA_PATH="$project_directory/localsend-lite.koplugin/?.lua;;"
export LD_LIBRARY_PATH="$PWD/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
./luajit "$project_directory/tests/loopback.lua" "$scratch_directory"
