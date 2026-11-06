#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd -- "$repo_dir"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    printf 'Commit or clean working-tree changes before packaging.\n' >&2
    exit 1
fi

version="$(sed -n 's/^## Version: //p' BetterDungeonLoot.toc)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid version in BetterDungeonLoot.toc: %s\n' "$version" >&2
    exit 1
fi

tag_commit="$(git rev-parse -q --verify "refs/tags/v$version^{}" || true)"
if [[ "$tag_commit" != "$(git rev-parse HEAD)" ]]; then
    printf 'Package only a release commit tagged v%s.\n' "$version" >&2
    exit 1
fi

archive="BetterDungeonLoot-$version.zip"
git archive --format=zip --prefix=BetterDungeonLoot/ --output="$archive" HEAD
printf 'Created %s/%s\n' "$repo_dir" "$archive"
