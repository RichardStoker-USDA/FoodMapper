#!/bin/bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
test_root="/private/tmp/foodmapper-xctest-${test_id}"
derived_data="/private/tmp/foodmapper-derived-data-${test_id}"
preferences_root="/private/tmp/foodmapper-preferences-${test_id}"
test_temporary_root="${derived_data}/Temporary"
test_symroot="${derived_data}/Symroot"
test_objroot="${derived_data}/Objroot"
defaults_suite="app.foodmapper.FoodMapper.tests.${test_id}"
live_support="${HOME:?HOME is required}/Library/Application Support/FoodMapper"
live_preferences="${HOME:?HOME is required}/Library/Preferences/app.foodmapper.FoodMapper.plist"

is_generated_path() {
    case "$1" in
        /private/tmp/foodmapper-xctest-????????-????-????-????-????????????|\
        /private/tmp/foodmapper-derived-data-????????-????-????-????-????????????|\
        /private/tmp/foodmapper-preferences-????????-????-????-????-????????????|\
        /private/tmp/foodmapper-ci-self-test-????????-????-????-????-????????????)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

remove_generated_path() {
    local path="${1:-}"
    if is_generated_path "$path" && [ -e "$path" -o -L "$path" ]; then
        rm -R -- "$path"
    fi
}

require_private_directory() {
    local path="$1"
    [ -d "$path" ] || return 1
    [ "$(stat -f '%u' "$path")" = "$(id -u)" ] || return 1
    [ "$(stat -f '%Lp' "$path")" = "700" ] || return 1
}

snapshot_tree() {
    local scope="$1"
    local path="$2"
    local output="$3"
    local entries_file="${output}.entries"
    local entry relative path_digest metadata status=0

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        printf '%s|missing\n' "$scope" >> "$output" || return 1
        return 0
    fi

    if ! LC_ALL=C find "$path" -xdev -print0 > "$entries_file"; then
        rm -f -- "$entries_file"
        return 1
    fi

    while IFS= read -r -d '' entry; do
        if [ "$entry" = "$path" ]; then
            relative="."
        else
            relative="${entry#"$path"/}"
        fi
        if ! path_digest="$(printf '%s' "$relative" | shasum -a 256 | awk '{ print $1 }')"; then
            status=1
            break
        fi
        if ! metadata="$(stat -f '%HT|%d|%i|%B|%m|%c|%z|%p|%u|%g|%l' "$entry")"; then
            status=1
            break
        fi
        if ! printf '%s|%s|%s\n' "$scope" "$path_digest" "$metadata" >> "$output"; then
            status=1
            break
        fi
    done < "$entries_file"
    rm -f -- "$entries_file" || return 1
    return "$status"
}

capture_live_metadata() {
    local output="$1"
    : > "$output" || return 1
    snapshot_tree "support" "$live_support" "$output" || return 1
    snapshot_tree "preferences" "$live_preferences" "$output" || return 1
    LC_ALL=C sort -o "$output" "$output" || return 1
}

is_foodmapper_executable() {
    local executable="$1"
    case "$executable" in
        FoodMapper|*/FoodMapper|\
        */FoodMapper.app/Contents/MacOS/*|\
        */FoodMapper\ *.app/Contents/MacOS/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_no_running_foodmapper() {
    local matches
    if ! matches="$(ps -axo pid=,comm= | matching_foodmapper_processes)"; then
        printf '%s\n' "Unable to inspect running processes before isolated tests." >&2
        return 1
    fi
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" >&2
        printf '%s\n' "Close FoodMapper before running the isolated test suite." >&2
        return 1
    fi
}

matching_foodmapper_processes() {
    local pid executable
    while read -r pid executable; do
        if is_foodmapper_executable "$executable"; then
            printf '%s %s\n' "$pid" "$executable"
        fi
    done
}

set_test_environment_value() {
    local plist="$1"
    local name="$2"
    local value="$3"
    local dictionary key_path

    for dictionary in EnvironmentVariables TestingEnvironmentVariables; do
        key_path="TestConfigurations.0.TestTargets.0.${dictionary}"
        if [ "$(plutil -type "$key_path" "$plist" 2>/dev/null || true)" != "dictionary" ]; then
            printf '%s\n' "Generated test configuration does not contain ${dictionary}." >&2
            return 1
        fi
        key_path="${key_path}.${name}"
        if ! plutil -replace "$key_path" -string "$value" "$plist" >/dev/null 2>&1; then
            plutil -insert "$key_path" -string "$value" "$plist" >/dev/null
        fi
    done
}

require_xcode_16_4() {
    local version
    : "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the Xcode 16.4 developer directory.}"
    [ "$DEVELOPER_DIR" = "/Applications/Xcode_16.4.app/Contents/Developer" ] || {
        printf '%s\n' "The isolated test suite requires /Applications/Xcode_16.4.app." >&2
        return 1
    }
    [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] || {
        printf '%s\n' "Xcode 16.4 is not available at DEVELOPER_DIR." >&2
        return 1
    }
    version="$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | head -n 1)"
    [ "$version" = "Xcode 16.4" ] || {
        printf '%s\n' "Expected Xcode 16.4, found ${version}." >&2
        return 1
    }
}

cleanup() {
    set +e
    if [ -n "${preferences_root:-}" ] && [ -n "${defaults_suite:-}" ]; then
        CFFIXED_USER_HOME="$preferences_root" defaults delete "$defaults_suite" >/dev/null 2>&1 || true
    fi
    remove_generated_path "${test_root:-}"
    remove_generated_path "${derived_data:-}"
    remove_generated_path "${preferences_root:-}"
}

run_self_test() (
    local self_id self_root fixture first second status=0
    self_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    self_root="/private/tmp/foodmapper-ci-self-test-${self_id}"
    fixture="${self_root}/fixture.xctestrun"
    first="${self_root}/first.metadata"
    second="${self_root}/second.metadata"
    trap 'remove_generated_path "$self_root"' EXIT

    mkdir -m 700 "$self_root"
    mkdir -m 700 "${self_root}/watched"
    plutil -create xml1 "$fixture"
    plutil -insert TestConfigurations -array "$fixture"
    plutil -insert TestConfigurations.0 -dictionary "$fixture"
    plutil -insert TestConfigurations.0.TestTargets -array "$fixture"
    plutil -insert TestConfigurations.0.TestTargets.0 -dictionary "$fixture"
    plutil -insert TestConfigurations.0.TestTargets.0.EnvironmentVariables -dictionary "$fixture"
    plutil -insert TestConfigurations.0.TestTargets.0.TestingEnvironmentVariables -dictionary "$fixture"

    set_test_environment_value "$fixture" "FOODMAPPER_TEST_STORAGE_ROOT" "$self_root" || status=1
    [ "$(plutil -extract TestConfigurations.0.TestTargets.0.EnvironmentVariables.FOODMAPPER_TEST_STORAGE_ROOT raw "$fixture")" = "$self_root" ] || status=1
    [ "$(plutil -extract TestConfigurations.0.TestTargets.0.TestingEnvironmentVariables.FOODMAPPER_TEST_STORAGE_ROOT raw "$fixture")" = "$self_root" ] || status=1

    snapshot_tree "fixture" "${self_root}/watched" "$first"
    : > "${self_root}/watched/marker"
    snapshot_tree "fixture" "${self_root}/watched" "$second"
    cmp -s "$first" "$second" && status=1
    require_private_directory "$self_root" || status=1
    is_foodmapper_executable "/tmp/FoodMapper Dev.app/Contents/MacOS/FoodMapper" || status=1
    is_foodmapper_executable "/tmp/space path/FoodMapper" || status=1
    is_foodmapper_executable "/tmp/FoodMapper Preview.app/Contents/MacOS/RenamedExecutable" || status=1
    ! is_foodmapper_executable "/tmp/FoodMapperTools.app/Contents/MacOS/Tool" || status=1
    ! is_foodmapper_executable "/tmp/space path/FoodMapperHelper" || status=1
    ! is_foodmapper_executable "/usr/bin/echo" || status=1
    printf '%s\n' '123 /tmp/FoodMapper Dev.app/Contents/MacOS/FoodMapper' | matching_foodmapper_processes | grep -q '^123 ' || status=1
    printf '%s\n' '124 /tmp/FoodMapper Preview.app/Contents/MacOS/RenamedExecutable' | matching_foodmapper_processes | grep -q '^124 ' || status=1
    ! printf '%s\n' '125 /usr/bin/echo /tmp/FoodMapper Dev.app/Contents/MacOS/FoodMapper' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '126 /tmp/FoodMapperTools.app/Contents/MacOS/Tool' | matching_foodmapper_processes | grep -q . || status=1

    remove_generated_path "$self_root"
    return "$status"
)

usage() {
    printf '%s\n' "Usage: scripts/run-isolated-tests.sh [--self-test]"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
    "")
        ;;
    --self-test)
        run_self_test
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

require_no_running_foodmapper
require_xcode_16_4

mkdir -m 700 "$test_root" "$derived_data" "$preferences_root"
mkdir -m 700 "$test_temporary_root" "$test_symroot" "$test_objroot"
require_private_directory "$test_root"
require_private_directory "$derived_data"
require_private_directory "$preferences_root"
require_private_directory "$test_temporary_root"

before_metadata="${derived_data}/live-before.metadata"
after_metadata="${derived_data}/live-after.metadata"
capture_live_metadata "$before_metadata"

run_test_workflow() {
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    TMPDIR="$test_temporary_root" \
    CFFIXED_USER_HOME="$preferences_root" \
    arch -arm64 "$DEVELOPER_DIR/usr/bin/xcodebuild" build-for-testing \
        -project "$repo_root/FoodMapper.xcodeproj" \
        -scheme FoodMapper \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        SYMROOT="$test_symroot" \
        OBJROOT="$test_objroot" \
        CODE_SIGNING_ALLOWED=NO || return 1

    local xctestrun_files=()
    local xctestrun_file
    while IFS= read -r xctestrun_file; do
        xctestrun_files+=("$xctestrun_file")
    done < <(find "$test_symroot" -type f -name '*.xctestrun' -print)

    if [ "${#xctestrun_files[@]}" -ne 1 ]; then
        printf '%s\n' "Expected one generated xctestrun file." >&2
        return 1
    fi

    xctestrun_file="${xctestrun_files[0]}"
    set_test_environment_value "$xctestrun_file" "FOODMAPPER_TEST_STORAGE_ROOT" "$test_root" || return 1
    set_test_environment_value "$xctestrun_file" "FOODMAPPER_TEST_DEFAULTS_SUITE" "$defaults_suite" || return 1
    set_test_environment_value "$xctestrun_file" "TMPDIR" "$test_temporary_root" || return 1
    set_test_environment_value "$xctestrun_file" "CFFIXED_USER_HOME" "$preferences_root" || return 1

    DEVELOPER_DIR="$DEVELOPER_DIR" \
    TMPDIR="$test_temporary_root" \
    CFFIXED_USER_HOME="$preferences_root" \
    arch -arm64 "$DEVELOPER_DIR/usr/bin/xcodebuild" test-without-building \
        -xctestrun "$xctestrun_file" \
        -destination 'platform=macOS,arch=arm64'
}

set +e
run_test_workflow
test_status=$?
set -e

if ! capture_live_metadata "$after_metadata"; then
    printf '%s\n' "Unable to capture live storage metadata after the isolated test suite." >&2
    exit 1
fi
if ! cmp -s "$before_metadata" "$after_metadata"; then
    printf '%s\n' "Live storage metadata changed during the isolated test suite." >&2
    diff -u "$before_metadata" "$after_metadata" || true
    exit 1
fi

exit "$test_status"
