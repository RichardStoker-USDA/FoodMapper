#!/bin/bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner_temp="${RUNNER_TEMP:-}"
if [ -n "$runner_temp" ]; then
    temporary_root="${runner_temp%/}"
    case "$temporary_root" in
        /*) ;;
        *)
            printf '%s\n' "RUNNER_TEMP must be an absolute path." >&2
            exit 1
            ;;
    esac
    [ "$temporary_root" != "/" ] || {
        printf '%s\n' "RUNNER_TEMP cannot be the filesystem root." >&2
        exit 1
    }
else
    temporary_root="/private/tmp"
fi
test_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
test_root="${temporary_root}/foodmapper-xctest-${test_id}"
derived_data="${temporary_root}/foodmapper-derived-data-${test_id}"
preferences_root="${temporary_root}/foodmapper-preferences-${test_id}"
test_temporary_root="${derived_data}/Temporary"
test_symroot="${derived_data}/Symroot"
test_objroot="${derived_data}/Objroot"
defaults_suite="app.foodmapper.FoodMapper.tests.${test_id}"
live_support="${HOME:?HOME is required}/Library/Application Support/FoodMapper"
live_preferences="${HOME:?HOME is required}/Library/Preferences/app.foodmapper.FoodMapper.plist"
if [ -n "$runner_temp" ]; then
    swiftpm_source_packages="${temporary_root}/foodmapper-source-packages"
    swiftpm_package_cache="${temporary_root}/foodmapper-package-cache"
    swiftpm_home="${temporary_root}/foodmapper-swiftpm-home"
else
    swiftpm_source_packages="${FOODMAPPER_SWIFTPM_ROOT:-${temporary_root}/foodmapper-source-packages}"
    swiftpm_package_cache="${FOODMAPPER_SWIFTPM_CACHE:-${temporary_root}/foodmapper-package-cache}"
    swiftpm_home="${FOODMAPPER_SWIFTPM_HOME:-${temporary_root}/foodmapper-swiftpm-home}"
fi

require_runner_temp_path() {
    local path="$1"
    if [ -n "$runner_temp" ]; then
        case "$path" in
            "${temporary_root}"/*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

require_swiftpm_paths() {
    local path
    for path in "$swiftpm_source_packages" "$swiftpm_package_cache" "$swiftpm_home"; do
        if ! require_runner_temp_path "$path"; then
            printf '%s\n' "Swift package paths must remain under RUNNER_TEMP." >&2
            return 1
        fi
    done
}

is_generated_path() {
    case "$1" in
        "${temporary_root}"/foodmapper-xctest-????????-????-????-????-????????????|\
        "${temporary_root}"/foodmapper-derived-data-????????-????-????-????-????????????|\
        "${temporary_root}"/foodmapper-preferences-????????-????-????-????-????????????|\
        "${temporary_root}"/foodmapper-ci-self-test-????????-????-????-????-????????????)
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

prepare_swiftpm_paths() {
    local path
    require_swiftpm_paths || return 1
    for path in "$swiftpm_source_packages" "$swiftpm_package_cache" "$swiftpm_home"; do
        [ ! -L "$path" ] || return 1
        mkdir -p -m 700 "$path" || return 1
        chmod 700 "$path" || return 1
        [ ! -L "$path" ] || return 1
        require_private_directory "$path" || return 1
    done
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
    local first_token
    first_token="${executable%%[[:space:]]*}"
    if [ "$first_token" != "$executable" ] && [ -x "$first_token" ]; then
        return 1
    fi
    case "$executable" in
        */FoodMapper.app/Contents/MacOS/FoodMapper)
            case "$executable" in
                *" /"*) return 1 ;;
            esac
            return 0
            ;;
        FoodMapper|*/FoodMapper)
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
    local line pid executable
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        line="${line#"${line%%[![:space:]]*}"}"
        pid="${line%%[!0-9]*}"
        if [ -z "$pid" ]; then
            printf '%s\n' "Unable to parse a process identifier." >&2
            return 1
        fi
        executable="${line#"$pid"}"
        executable="${executable#"${executable%%[![:space:]]*}"}"
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

assert_test_environment_value() {
    local plist="$1"
    local name="$2"
    local expected="$3"
    local dictionary key_path actual

    for dictionary in EnvironmentVariables TestingEnvironmentVariables; do
        key_path="TestConfigurations.0.TestTargets.0.${dictionary}.${name}"
        if ! actual="$(plutil -extract "$key_path" raw "$plist" 2>/dev/null)"; then
            return 1
        fi
        [ "$actual" = "$expected" ] || return 1
    done
}

is_xcode_26_6_version() {
    case "$1" in
        "Xcode 26.6") ;;
        *)
            return 1
            ;;
    esac
}

require_xcode_26_6() {
    local version
    : "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the Xcode 26.6 developer directory.}"
    [ "$DEVELOPER_DIR" = "/Applications/Xcode_26.6.app/Contents/Developer" ] || {
        printf '%s\n' "The isolated test suite requires /Applications/Xcode_26.6.app." >&2
        return 1
    }
    [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] || {
        printf '%s\n' "Xcode 26.6 is not available at DEVELOPER_DIR." >&2
        return 1
    }
    version="$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | head -n 1)"
    if ! is_xcode_26_6_version "$version"; then
        printf '%s\n' "Expected Xcode 26.6, found ${version}." >&2
        return 1
    fi
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

validate_ad_hoc_bundle() {
    local bundle="$1"
    local details

    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        printf '%s\n' "Ad hoc signature validation failed: $bundle" >&2
        return 1
    fi
    if ! details="$(codesign -dv --verbose=4 "$bundle" 2>&1)"; then
        printf '%s\n' "Unable to inspect the ad hoc signature: $bundle" >&2
        return 1
    fi
    case "$details" in
        *flags=*adhoc*) ;;
        *)
            printf '%s\n' "Expected an ad hoc signature: $bundle" >&2
            return 1
            ;;
    esac
    case "$details" in
        *"TeamIdentifier=not set"*) return 0 ;;
        *)
            printf '%s\n' "The test product has a signing team identifier: $bundle" >&2
            return 1
            ;;
    esac
}

validate_ad_hoc_products() {
    local products_file="${derived_data}/signed-products.paths"
    local path app_bundle="" test_bundle=""

    if ! find "$test_symroot" -type d \( -name 'FoodMapper.app' -o -name 'FoodMapperTests.xctest' \) -print > "$products_file"; then
        printf '%s\n' "Unable to enumerate the generated test products." >&2
        return 1
    fi
    while IFS= read -r path; do
        case "$path" in
            *.app)
                [ -z "$app_bundle" ] || {
                    printf '%s\n' "More than one FoodMapper app was generated." >&2
                    return 1
                }
                app_bundle="$path"
                ;;
            *.xctest)
                [ -z "$test_bundle" ] || {
                    printf '%s\n' "More than one FoodMapper test bundle was generated." >&2
                    return 1
                }
                test_bundle="$path"
                ;;
        esac
    done < "$products_file"
    [ -n "$app_bundle" ] || {
        printf '%s\n' "The generated FoodMapper app was not found." >&2
        return 1
    }
    [ -n "$test_bundle" ] || {
        printf '%s\n' "The generated FoodMapper test bundle was not found." >&2
        return 1
    }
    validate_ad_hoc_bundle "$app_bundle" || return 1
    validate_ad_hoc_bundle "$test_bundle"
}

run_self_test() (
    local self_id self_root fixture first second self_defaults_suite status=0
    self_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    self_root="${temporary_root}/foodmapper-ci-self-test-${self_id}"
    self_defaults_suite="app.foodmapper.FoodMapper.tests.${self_id}"
    fixture="${self_root}/fixture.xctestrun"
    first="${self_root}/first.metadata"
    second="${self_root}/second.metadata"
    trap 'remove_generated_path "$self_root"' EXIT

    require_swiftpm_paths || status=1
    if [ -n "$runner_temp" ]; then
        [ "$swiftpm_source_packages" = "${temporary_root}/foodmapper-source-packages" ] || status=1
        [ "$swiftpm_package_cache" = "${temporary_root}/foodmapper-package-cache" ] || status=1
        [ "$swiftpm_home" = "${temporary_root}/foodmapper-swiftpm-home" ] || status=1
    fi
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
    assert_test_environment_value "$fixture" "FOODMAPPER_TEST_STORAGE_ROOT" "$self_root" || status=1
    set_test_environment_value "$fixture" "FOODMAPPER_TEST_DEFAULTS_SUITE" "$self_defaults_suite" || status=1
    assert_test_environment_value "$fixture" "FOODMAPPER_TEST_DEFAULTS_SUITE" "$self_defaults_suite" || status=1
    set_test_environment_value "$fixture" "TMPDIR" "${self_root}/tmp" || status=1
    assert_test_environment_value "$fixture" "TMPDIR" "${self_root}/tmp" || status=1
    set_test_environment_value "$fixture" "CFFIXED_USER_HOME" "${self_root}/preferences" || status=1
    assert_test_environment_value "$fixture" "CFFIXED_USER_HOME" "${self_root}/preferences" || status=1

    snapshot_tree "fixture" "${self_root}/watched" "$first"
    : > "${self_root}/watched/marker"
    snapshot_tree "fixture" "${self_root}/watched" "$second"
    cmp -s "$first" "$second" && status=1
    require_private_directory "$self_root" || status=1
    ! is_generated_path "$temporary_root" || status=1
    ! is_generated_path "${self_root}/nested" || status=1
    is_foodmapper_executable "/tmp/FoodMapper.app/Contents/MacOS/FoodMapper" || status=1
    is_foodmapper_executable "/tmp/space path/FoodMapper" || status=1
    ! is_foodmapper_executable "/tmp/FoodMapper Preview.app/Contents/MacOS/RenamedExecutable" || status=1
    ! is_foodmapper_executable "/tmp/FoodMapper.app/Contents/MacOS/FoodMapperHelper" || status=1
    ! is_foodmapper_executable "/tmp/FoodMapperTools.app/Contents/MacOS/Tool" || status=1
    ! is_foodmapper_executable "/tmp/space path/FoodMapperHelper" || status=1
    ! is_foodmapper_executable "/usr/bin/echo" || status=1
    is_xcode_26_6_version "Xcode 26.6" || status=1
    ! is_xcode_26_6_version "Xcode 26.6 beta" || status=1
    ! is_xcode_26_6_version "Xcode 26.6.1" || status=1
    ! is_xcode_26_6_version "Xcode 26.5" || status=1
    ! is_xcode_26_6_version "Xcode 27 beta" || status=1
    printf '%s\n' '  123 /tmp/FoodMapper.app/Contents/MacOS/FoodMapper' | matching_foodmapper_processes | grep -q '^123 ' || status=1
    ! printf '%s\n' '124 /tmp/FoodMapper Preview.app/Contents/MacOS/RenamedExecutable' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '125 /bin/echo /tmp/FoodMapper.app/Contents/MacOS/FoodMapper' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '126 /tmp/FoodMapper.app/Contents/MacOS/FoodMapperHelper' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '127 /tmp/FoodMapperTools.app/Contents/MacOS/Tool' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '128 /tmp/FoodMapper.app/Contents/MacOS/FoodMapper --test' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' '129 /bin/echo /tmp/FoodMapper' | matching_foodmapper_processes | grep -q . || status=1
    ! printf '%s\n' 'not-a-pid /tmp/FoodMapper.app/Contents/MacOS/FoodMapper' | matching_foodmapper_processes >/dev/null 2>&1 || status=1

    remove_generated_path "$self_root"
    return "$status"
)

usage() {
    printf '%s\n' "Usage: scripts/run-isolated-tests.sh [--self-test]"
    printf '%s\n' "Debug test products are signed ad hoc; no Apple signing credentials are used."
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
require_xcode_26_6
prepare_swiftpm_paths

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
    HOME="$swiftpm_home" \
    CFFIXED_USER_HOME="$preferences_root" \
    arch -arm64 "$DEVELOPER_DIR/usr/bin/xcodebuild" build-for-testing \
        -project "$repo_root/FoodMapper.xcodeproj" \
        -scheme FoodMapper \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$swiftpm_source_packages" \
        -packageCachePath "$swiftpm_package_cache" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        -skipPackageUpdates \
        SYMROOT="$test_symroot" \
        OBJROOT="$test_objroot" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="" \
        FOODMAPPER_APP_BUNDLE_IDENTIFIER="app.foodmapper.FoodMapper.tests.host.${test_id}" \
        PROVISIONING_PROFILE_SPECIFIER="" || return 1

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
    validate_ad_hoc_products || return 1
    set_test_environment_value "$xctestrun_file" "FOODMAPPER_TEST_STORAGE_ROOT" "$test_root" || return 1
    set_test_environment_value "$xctestrun_file" "FOODMAPPER_TEST_DEFAULTS_SUITE" "$defaults_suite" || return 1
    set_test_environment_value "$xctestrun_file" "TMPDIR" "$test_temporary_root" || return 1
    set_test_environment_value "$xctestrun_file" "CFFIXED_USER_HOME" "$preferences_root" || return 1

    DEVELOPER_DIR="$DEVELOPER_DIR" \
    TMPDIR="$test_temporary_root" \
    HOME="$swiftpm_home" \
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
