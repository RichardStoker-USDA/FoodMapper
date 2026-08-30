#!/bin/bash
set -euo pipefail
umask 077

is_allowed_hidden_path() {
    case "$1" in
        .gitignore|.gitleaks.toml|.github/dependabot.yml|\
        docs/.nojekyll|\
        site/.gitattributes|site/.gitignore|site/public/.nojekyll)
            return 0
            ;;
        .github/workflows/*)
            case "${1##*/}" in
                .*)
                    return 1
                    ;;
                *.yml|*.yaml)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

is_tokenizer_vocabulary() {
    case "$1" in
        FoodMapper/Resources/Models/tokenizer.json|\
        FoodMapper/Resources/Models/vocab.txt)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_allowed_temporary_path_source() {
    case "$1" in
        FoodMapper/Models/FoodMapperStorage.swift|\
        FoodMapperTests/TestStorageGuard.swift|\
        scripts/run-isolated-tests.sh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

development_trace_pattern() {
    printf '%b' '\103\157\144\145\170|\103\154\141\165\144\145[[:space:]]+\103\157\144\145|\117\160\145\156\103\157\144\145|\101\151\144\145\162|\103\165\162\163\157\162|\103\154\151\156\145|\107\151\164\110\165\142[[:space:]]+\103\157\160\151\154\157\164|\101\107\105\116\124\123\134.\155\144|\103\114\101\125\104\105\134.\155\144|\143\154\157\165\144\134.\155\144|\147\154\157\142\141\154\134.\155\144|[Gg]enerated[[:space:]]+with|[Cc]o-[Aa]uthored-[Bb]y'
}

require_tracked_path() {
    local root="$1"
    local path="$2"
    local tracked
    tracked="$(git -C "$root" ls-files -- "$path")"
    if [ -z "$tracked" ]; then
        printf '%s\n' "Required public path is not tracked: $path" >&2
        return 1
    fi
}

verify_public_tree() {
    local root="$1"
    local path trace_pattern failed=0
    local required_paths=(
        README.md
        CHANGELOG.md
        LICENSE
        FoodMapper
        FoodMapper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
        FoodMapperTests
        scripts
        .github
        docs
        site
    )

    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '%s\n' "Public tree check requires a Git worktree." >&2
        return 1
    fi

    for path in "${required_paths[@]}"; do
        require_tracked_path "$root" "$path" || failed=1
    done
    [ "$failed" -eq 0 ] || return 1

    trace_pattern="$(development_trace_pattern)"
    while IFS= read -r -d '' path; do
        case "$path" in
            .*|*/.*)
                if ! is_allowed_hidden_path "$path"; then
                    printf '%s\n' "Unexpected tracked hidden path: $path" >&2
                    failed=1
                fi
                ;;
        esac

        if git -C "$root" grep -I -q -E '/Users/' -- "$path"; then
            printf '%s\n' "Tracked text contains a machine-specific user path: $path" >&2
            failed=1
        fi

        if ! is_allowed_temporary_path_source "$path" &&
           git -C "$root" grep -I -q -E '/private/tmp/' -- "$path"; then
            printf '%s\n' "Tracked text contains an unexpected temporary path: $path" >&2
            failed=1
        fi

        if ! is_tokenizer_vocabulary "$path" &&
           git -C "$root" grep -I -q -i -E "$trace_pattern" -- "$path"; then
            printf '%s\n' "Tracked text contains an internal development trace: $path" >&2
            failed=1
        fi
    done < <(git -C "$root" ls-files -z)

    [ "$failed" -eq 0 ]
}

self_test_root() {
    local identifier
    identifier="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "/private/tmp/foodmapper-public-tree-self-test-${identifier}"
}

remove_self_test_root() {
    local root="${1:-}"
    case "$root" in
        /private/tmp/foodmapper-public-tree-self-test-????????-????-????-????-????????????)
            if [ -e "$root" ] || [ -L "$root" ]; then
                rm -R -- "$root"
            fi
            ;;
    esac
}

make_fixture() {
    local root="$1"
    mkdir -m 700 "$root"
    git -C "$root" init -q
    mkdir -p "$root/FoodMapper/Resources/Models" \
        "$root/FoodMapper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
        "$root/FoodMapperTests" \
        "$root/scripts" \
        "$root/.github/workflows" \
        "$root/docs" \
        "$root/site/public"
    printf '%s\n' 'FoodMapper' > "$root/README.md"
    printf '%s\n' 'Changes' > "$root/CHANGELOG.md"
    printf '%s\n' 'License' > "$root/LICENSE"
    printf '%s\n' 'Anthropic API' > "$root/FoodMapper/allowed.swift"
    printf '%s\n' '{"pins": []}' > "$root/FoodMapper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    printf '%s\n' 'Tests' > "$root/FoodMapperTests/allowed.swift"
    printf '%s\n' '#!/bin/bash' > "$root/scripts/check.sh"
    printf '%s\n' 'name: Check' > "$root/.github/workflows/check.yml"
    : > "$root/docs/.nojekyll"
    : > "$root/site/.gitattributes"
    : > "$root/site/.gitignore"
    : > "$root/site/public/.nojekyll"
    printf '%s' "$(development_trace_pattern)" > "$root/FoodMapper/Resources/Models/vocab.txt"
    git -C "$root" add -A
}

assert_rejected() (
    local root
    root="$(self_test_root)"
    trap 'remove_self_test_root "$root"' EXIT
    make_fixture "$root"
    "$@" "$root"
    git -C "$root" add -A
    if verify_public_tree "$root" >/dev/null 2>&1; then
        return 1
    fi
)

add_root_dotenv() {
    : > "$1/.env"
}

add_nested_hidden_path() {
    mkdir -p "$1/FoodMapper/.local"
    : > "$1/FoodMapper/.local/settings"
}

add_hidden_workflow() {
    : > "$1/.github/workflows/.private.yml"
}

add_user_path() {
    printf '%s\n' '/Users/example/private-file' > "$1/FoodMapper/unsafe.swift"
}

add_unexpected_temporary_path() {
    printf '%s\n' '/private/tmp/private-file' >> "$1/README.md"
}

add_development_trace() {
    printf '%s\n' "$(development_trace_pattern)" > "$1/FoodMapper/unsafe.swift"
}

remove_required_path() {
    rm -R -- "$1/FoodMapperTests"
}

remove_swift_package_lock() {
    rm -- "$1/FoodMapper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
}

run_self_test() (
    local root status=0
    root="$(self_test_root)"
    trap 'remove_self_test_root "$root"' EXIT
    make_fixture "$root"
    verify_public_tree "$root" || status=1
    remove_self_test_root "$root"

    assert_rejected add_root_dotenv || status=1
    assert_rejected add_nested_hidden_path || status=1
    assert_rejected add_hidden_workflow || status=1
    assert_rejected add_user_path || status=1
    assert_rejected add_unexpected_temporary_path || status=1
    assert_rejected add_development_trace || status=1
    assert_rejected remove_required_path || status=1
    assert_rejected remove_swift_package_lock || status=1
    return "$status"
)

usage() {
    printf '%s\n' "Usage: scripts/verify-public-tree.sh [--self-test]"
}

case "${1:-}" in
    "")
        repo_root="$(cd "$(dirname "$0")/.." && pwd)"
        verify_public_tree "$repo_root"
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
