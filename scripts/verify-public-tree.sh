#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

unexpected_hidden_paths=0
while IFS= read -r path; do
    case "$path" in
        .github/*|.gitignore|.gitleaks.toml)
            ;;
        .*/*)
            printf '%s\n' "Unexpected tracked hidden path: $path" >&2
            unexpected_hidden_paths=1
            ;;
    esac
done < <(git ls-files)

if [ "$unexpected_hidden_paths" -ne 0 ]; then
    exit 1
fi

if git grep -I -n -E '/Users/|/private/tmp/' -- README.md CHANGELOG.md docs site; then
    printf '%s\n' "Public documentation contains a machine-specific path." >&2
    exit 1
fi
