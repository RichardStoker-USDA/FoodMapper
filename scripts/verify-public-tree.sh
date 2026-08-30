#!/bin/bash
set -euo pipefail
umask 077

is_allowed_hidden_path() {
    local path="$1"
    local workflow_path

    case "$path" in
        .gitignore|.gitleaks.toml|.github/dependabot.yml|\
        docs/.nojekyll|\
        site/.gitattributes|site/.gitignore|site/public/.nojekyll)
            return 0
            ;;
        .github/workflows/*)
            workflow_path="${path#.github/workflows/}"
            case "$workflow_path" in
                */*|.*)
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

is_allowed_fixture_user_path() {
    local root="$1"
    local path="$2"
    local pattern="$3"
    local user_root expected_line matches

    [ "$path" = "FoodMapper/PreviewHelpers.swift" ] || return 1
    user_root="/$(printf '%s' 'Users')"
    expected_line="            csvPath: \"${user_root}/mock/lab_foods.csv\","
    if ! matches="$(git -C "$root" grep -I -h -E "$pattern" -- "$path")"; then
        return 1
    fi
    [ "$matches" = "$expected_line" ]
}

development_trace_pattern() {
    local tool_pattern trace_context private_file_pattern
    local name_a name_b name_c name_d

    name_a='[Cc][Oo][Dd][Ee][Xx]'
    name_b='[Cc][Ll][Aa][Uu][Dd][Ee][[:space:]]+[Cc][Oo][Dd][Ee]'
    name_c='[Oo][Pp][Ee][Nn][Cc][Oo][Dd][Ee]'
    name_d='[Aa][Ii][Dd][Ee][Rr]'
    tool_pattern="(^|[^[:alnum:]_])(${name_a}|${name_b}|${name_c}|${name_d})([^[:alnum:]_]|$)"
    trace_context='[Bb]uild[[:space:]]+notes?|[Dd]evelopment[[:space:]]+(notes?|trace)|[Aa]gent[[:space:]]+instructions?|[Cc]ommit[[:space:]]+(by|from)'
    private_file_pattern='(^|[^[:alnum:]_.-])([Aa][Gg][Ee][Nn][Tt][Ss][.]md|[Cc][Ll][Aa][Uu][Dd][Ee][.]md|[Cc][Ll][Oo][Uu][Dd][.]md|[Gg][Ll][Oo][Bb][Aa][Ll]([.][Cc][Ll][Oo][Uu][Dd])?[.]md)([^[:alnum:]_.-]|$)'

    printf '%s' "[Gg]enerated[[:space:]]+with|[Cc]o-[Aa]uthored-[Bb]y|(${tool_pattern}.*(${trace_context})|(${trace_context}).*${tool_pattern})|${private_file_pattern}"
}

require_tracked_path() {
    local root="$1"
    local path="$2"
    local tracked
    if ! tracked="$(git -C "$root" ls-files -- "$path")"; then
        printf '%s\n' "Unable to enumerate tracked paths while checking: $path" >&2
        return 1
    fi
    if [ -z "$tracked" ]; then
        printf '%s\n' "Required public path is not tracked: $path" >&2
        return 1
    fi
}

user_path_pattern() {
    printf '/%s/' 'Users'
}

temporary_path_pattern() {
    printf '/%s/%s/' 'private' 'tmp'
}

git_grep_matches() {
    local root="$1"
    local pattern="$2"
    local path="$3"
    git -C "$root" grep -I -q -E "$pattern" -- "$path" >/dev/null 2>&1
}

remove_scan_root() {
    local root="${1:-}"
    case "$root" in
        */foodmapper-public-tree-scan.??????)
            if [ -e "$root" ] || [ -L "$root" ]; then
                rm -R -- "$root"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

verify_public_tree() {
    local root="$1"
    local path trace_pattern user_path temporary_path failed=0
    local scan_root tracked_paths scan_status
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
    user_path="$(user_path_pattern)"
    temporary_path="$(temporary_path_pattern)"

    if ! scan_root="$(mktemp -d "${TMPDIR:-/tmp}/foodmapper-public-tree-scan.XXXXXX")"; then
        printf '%s\n' "Unable to create the public tree scan directory." >&2
        return 1
    fi
    tracked_paths="${scan_root}/tracked"
    if ! git -C "$root" ls-files -z > "$tracked_paths"; then
        printf '%s\n' "Unable to enumerate tracked paths for the public tree check." >&2
        remove_scan_root "$scan_root" || true
        return 1
    fi

    while IFS= read -r -d '' path; do
        case "$path" in
            .*|*/.*)
                if ! is_allowed_hidden_path "$path"; then
                    printf '%s\n' "Unexpected tracked hidden path: $path" >&2
                    failed=1
                fi
                ;;
        esac

        if git_grep_matches "$root" "$user_path" "$path"; then
            if ! is_allowed_fixture_user_path "$root" "$path" "$user_path"; then
                printf '%s\n' "Tracked text contains a machine-specific user path: $path" >&2
                failed=1
            fi
        else
            scan_status=$?
            if [ "$scan_status" -ne 1 ]; then
                printf '%s\n' "Unable to scan tracked text for machine-specific paths: $path" >&2
                failed=1
            fi
        fi

        if ! is_allowed_temporary_path_source "$path" &&
           git_grep_matches "$root" "$temporary_path" "$path"; then
            printf '%s\n' "Tracked text contains an unexpected temporary path: $path" >&2
            failed=1
        else
            scan_status=$?
            if [ "$scan_status" -ne 1 ]; then
                printf '%s\n' "Unable to scan tracked text for temporary paths: $path" >&2
                failed=1
            fi
        fi

        if ! is_tokenizer_vocabulary "$path" &&
           git_grep_matches "$root" "$trace_pattern" "$path"; then
            printf '%s\n' "Tracked text contains an internal development trace: $path" >&2
            failed=1
        else
            scan_status=$?
            if [ "$scan_status" -ne 1 ]; then
                printf '%s\n' "Unable to scan tracked text for development traces: $path" >&2
                failed=1
            fi
        fi
    done < "$tracked_paths"

    if ! remove_scan_root "$scan_root"; then
        printf '%s\n' "Unable to remove the public tree scan directory." >&2
        failed=1
    fi

    [ "$failed" -eq 0 ]
}

self_test_root() {
    local identifier temporary_root
    identifier="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    temporary_root="/$(printf '%s' 'private')/$(printf '%s' 'tmp')"
    printf '%s\n' "${temporary_root}/foodmapper-public-tree-self-test-${identifier}"
}

remove_self_test_root() {
    local root="${1:-}"
    local temporary_root="/$(printf '%s' 'private')/$(printf '%s' 'tmp')"
    case "$root" in
        "${temporary_root}"/foodmapper-public-tree-self-test-????????-????-????-????-????????????)
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
    local name_a='Cod' name_b='ex'
    local name_c='Clau' name_d='de Code'
    local name_e='Open' name_f='Code'
    local name_g='Aid' name_h='er'
    printf '%s\n' 'Anthropic API' > "$root/FoodMapper/allowed.swift"
    printf '%s model API\n' "${name_a}${name_b}" >> "$root/FoodMapper/allowed.swift"
    printf '%s provider API\n' "${name_c}${name_d}" >> "$root/FoodMapper/allowed.swift"
    printf '%s model reference\n' "${name_e}${name_f}" >> "$root/FoodMapper/allowed.swift"
    printf '%s model reference\n' "${name_g}${name_h}" >> "$root/FoodMapper/allowed.swift"
    printf '%s tracking pointer\n' 'cursor' >> "$root/FoodMapper/allowed.swift"
    printf '%s\n' '{"pins": []}' > "$root/FoodMapper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    printf '%s\n' 'Tests' > "$root/FoodMapperTests/allowed.swift"
    printf '%s\n' '#!/bin/bash' > "$root/scripts/check.sh"
    printf '%s\n' 'name: Check' > "$root/.github/workflows/check.yml"
    : > "$root/docs/.nojekyll"
    : > "$root/site/.gitattributes"
    : > "$root/site/.gitignore"
    : > "$root/site/public/.nojekyll"
    printf '%s' "$(development_trace_pattern)" > "$root/FoodMapper/Resources/Models/vocab.txt"
    git -C "$root" add -f -A -- .
}

assert_rejected() (
    local root
    root="$(self_test_root)"
    trap 'remove_self_test_root "$root"' EXIT
    make_fixture "$root"
    "$@" "$root"
    git -C "$root" add -f -A -- .
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
    mkdir -p "$1/.github/workflows/.private"
    : > "$1/.github/workflows/.private/check.yml"
}

add_user_path() {
    local user_root="/$(printf '%s' 'Users')"
    printf '%s\n' "${user_root}/example/private-file" > "$1/FoodMapper/unsafe.swift"
}

add_unexpected_temporary_path() {
    local temporary_root="/$(printf '%s' 'private')/$(printf '%s' 'tmp')"
    printf '%s\n' "${temporary_root}/private-file" >> "$1/README.md"
}

add_development_trace() {
    local generated='Generated'
    local with='with'
    local co='Co'
    local authored='Authored'
    local by='By'
    printf '%s %s local build notes\n' "$generated" "$with" > "$1/FoodMapper/unsafe.swift"
    printf '%s-%s-%s: example\n' "$co" "$authored" "$by" >> "$1/FoodMapper/unsafe.swift"
}

add_named_tool_trace() {
    local name_a='Cod' name_b='ex'
    local name_c='Clau' name_d='de Code'
    local name_e='Open' name_f='Code'
    local name_g='Aid' name_h='er'
    printf '%s development note\n' "${name_a}${name_b}" > "$1/FoodMapper/unsafe.swift"
    printf '%s build notes\n' "${name_c}${name_d}" >> "$1/FoodMapper/unsafe.swift"
    printf '%s agent instructions\n' "${name_e}${name_f}" >> "$1/FoodMapper/unsafe.swift"
    printf '%s commit by maintainer\n' "${name_g}${name_h}" >> "$1/FoodMapper/unsafe.swift"
}

add_private_instruction_references() {
    local name_a='AG' name_b='ENTS'
    local name_c='CLAU' name_d='DE'
    local name_e='cl' name_f='oud'
    local name_g='glob' name_h='al'
    printf 'See %s.md\n' "${name_a}${name_b}" > "$1/FoodMapper/unsafe.swift"
    printf 'See %s.md\n' "${name_c}${name_d}" >> "$1/FoodMapper/unsafe.swift"
    printf 'See %s.md\n' "${name_e}${name_f}" >> "$1/FoodMapper/unsafe.swift"
    printf 'See %s.md and %s.%s.md\n' "${name_g}${name_h}" "${name_g}${name_h}" "${name_e}${name_f}" >> "$1/FoodMapper/unsafe.swift"
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
    assert_rejected add_named_tool_trace || status=1
    assert_rejected add_private_instruction_references || status=1
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
