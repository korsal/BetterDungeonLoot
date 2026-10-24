#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
wow_dir="$(dirname -- "$repo_dir")"
addons_dir="$wow_dir/_anniversary_/Interface/AddOns"
target="$addons_dir/BetterDungeonLoot"

if [[ ! -d "$addons_dir" ]]; then
    printf 'Anniversary AddOns directory not found: %s\n' "$addons_dir" >&2
    exit 1
fi
if [[ -L "$target" ]]; then
    printf 'Refusing to replace symlink: %s\n' "$target" >&2
    exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
cp -- "$repo_dir/BetterDungeonLoot.toc" "$repo_dir/BetterDungeonLoot.lua" "$stage/"
mkdir -p -- "$target"
rsync -a --delete -- "$stage/" "$target/"
printf 'Installed BetterDungeonLoot into %s\n' "$target"
