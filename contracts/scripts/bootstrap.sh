#!/usr/bin/env bash
set -euo pipefail

contract_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$contract_root/lib" "$contract_root/deployments"

while read -r name repository ref revision; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    dependency_path="$contract_root/lib/$name"
    if [[ ! -e "$dependency_path" ]]; then
        git clone --quiet --filter=blob:none --no-checkout -- "$repository" "$dependency_path"
        git -C "$dependency_path" fetch --quiet --depth 1 origin "$revision"
        git -C "$dependency_path" checkout --quiet --detach "$revision"
    fi
    actual_revision="$(git -C "$dependency_path" rev-parse HEAD)"
    if [[ "$actual_revision" != "$revision" || -n "$(git -C "$dependency_path" status --porcelain)" ]]; then
        printf 'Dependency %s must be clean at %s (%s).\n' "$name" "$revision" "$ref" >&2
        exit 1
    fi
    printf '%s %s\n' "$name" "$revision"
done < "$contract_root/dependencies.lock"
