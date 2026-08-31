#!/bin/bash
set -euo pipefail
umask 077

remove_scan_root() {
    local root="${1:-}"
    case "$root" in
        */foodmapper-secret-scan.??????|*/foodmapper-secret-selfcheck.??????)
            if [ -e "$root" ] || [ -L "$root" ]; then
                rm -R -- "$root"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

verify_tracked_commit() (
    local root="$1"
    local git_path gitleaks_path scan_root source_commit candidate

    git_path="$(command -v git)" || return 1
    gitleaks_path="$(command -v gitleaks)" || return 1
    [ -x /usr/bin/tar ] || return 1
    "$git_path" -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    source_commit="$("$git_path" -C "$root" rev-parse --verify HEAD^{commit})" || return 1

    scan_root="$(mktemp -d "${TMPDIR:-/tmp}/foodmapper-secret-scan.XXXXXX")" || return 1
    chmod 700 "$scan_root"
    trap 'remove_scan_root "$scan_root"' EXIT

    "$git_path" -C "$root" archive --format=tar "$source_commit" \
        | /usr/bin/tar -xf - -C "$scan_root"

    while IFS= read -r -d '' candidate; do
        printf '%s\n' "Tracked symlinks are not accepted by the secret scan: ${candidate#"$scan_root"/}" >&2
        return 1
    done < <(/usr/bin/find "$scan_root" -type l -print0)

    [ -f "$scan_root/.gitleaks.toml" ] && [ ! -L "$scan_root/.gitleaks.toml" ] || {
        printf '%s\n' "The tracked commit has no regular .gitleaks.toml file." >&2
        return 1
    }

    cd "$scan_root"
    "$gitleaks_path" detect \
        --source . \
        --no-git \
        --config .gitleaks.toml \
        --redact=100 \
        --no-banner
)

self_test_root() {
    mktemp -d "${TMPDIR:-/tmp}/foodmapper-secret-selfcheck.XXXXXX"
}

initialize_fixture() {
    local root="$1"
    mkdir -m 700 "$root/repository"
    git -C "$root/repository" init -q
    git -C "$root/repository" config user.name "FoodMapper Check"
    git -C "$root/repository" config user.email "foodmapper-check@example.invalid"
    printf '%s\n' \
        'title = "FoodMapper secret scan fixture"' \
        '' \
        '[[rules]]' \
        'id = "fixture-secret"' \
        'description = "Fixture secret"' \
        "regex = '''fixture-secret-[a-z]+'''" \
        > "$root/repository/.gitleaks.toml"
    printf '%s\n' 'ignored.txt' > "$root/repository/.gitignore"
    printf '%s\n' 'safe tracked text' > "$root/repository/tracked.txt"
    printf '%s\n' 'fixture-secret-ignored' > "$root/repository/ignored.txt"
    git -C "$root/repository" add .gitleaks.toml .gitignore tracked.txt
    git -C "$root/repository" commit -q -m "Create fixture"
}

run_self_test() (
    local root link_root

    root="$(self_test_root)"
    trap 'remove_scan_root "$root"' EXIT
    initialize_fixture "$root"
    verify_tracked_commit "$root/repository"

    printf '%s\n' 'fixture-secret-detected' > "$root/repository/tracked.txt"
    git -C "$root/repository" add tracked.txt
    git -C "$root/repository" commit -q -m "Add finding"
    if verify_tracked_commit "$root/repository" >/dev/null 2>&1; then
        return 1
    fi
    remove_scan_root "$root"
    trap - EXIT

    link_root="$(self_test_root)"
    trap 'remove_scan_root "$link_root"' EXIT
    initialize_fixture "$link_root"
    ln -s tracked.txt "$link_root/repository/tracked-link"
    git -C "$link_root/repository" add tracked-link
    git -C "$link_root/repository" commit -q -m "Add symlink"
    if verify_tracked_commit "$link_root/repository" >/dev/null 2>&1; then
        return 1
    fi
)

usage() {
    printf '%s\n' "Usage: scripts/verify-secrets.sh [--self-test]"
}

case "${1:-}" in
    "")
        repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
        verify_tracked_commit "$repository_root"
        ;;
    --self-test)
        run_self_test
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
