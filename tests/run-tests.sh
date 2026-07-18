#!/usr/bin/env bash
# =============================================================================
# Tests for build.sh
# =============================================================================
# Runs build.sh end-to-end against fixture projects with every external
# command stubbed on PATH (eas, brew, xcodebuild, pod, fastlane, ios-deploy,
# java, adb, npm, pnpm, yarn, bun, uname). Only `node` is real — build.sh
# needs it to parse eas.json. No network, no installs, no real builds.
#
# Usage: bash tests/run-tests.sh
# =============================================================================

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SH="$REPO_DIR/build.sh"

# Resolve the real node binary, not a version-manager shim (mise/asdf/nvm):
# shims break inside the env -i sandbox below where HOME points elsewhere
if ! NODE_BIN="$(node -e 'process.stdout.write(process.execPath)' 2>/dev/null)" || [[ -z "$NODE_BIN" ]]; then
    echo "node is required to run the tests" >&2
    exit 1
fi
NODE_DIR="$(dirname "$NODE_BIN")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

STUB_DIR="$WORK_DIR/stubs"
FAKE_HOME="$WORK_DIR/home"
MARKER_DIR="$WORK_DIR/markers"
mkdir -p "$STUB_DIR" "$FAKE_HOME" "$MARKER_DIR"

RUN_PATH="$STUB_DIR:$NODE_DIR:/usr/bin:/bin"

# -----------------------------------------------------------------------------
# Stubs
# -----------------------------------------------------------------------------

make_stub() {
    local name="$1" body="${2:-}"
    printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$body" >"$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Stub that appends its invocation (args + cwd) to $TEST_MARKER_FILE
make_recording_stub() {
    local name="$1"
    cat >"$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
if [[ -n "\${TEST_MARKER_FILE:-}" ]]; then echo "$name \$* cwd=\$PWD" >> "\$TEST_MARKER_FILE"; fi
exit 0
EOF
    chmod +x "$STUB_DIR/$name"
}

# shellcheck disable=SC2016  # stub bodies must expand at stub runtime, not here
make_stub uname 'echo "${FAKE_UNAME:-Darwin}"'
make_stub brew
# shellcheck disable=SC2016
make_stub xcodebuild 'if [[ "${1:-}" == "-version" ]]; then echo "Xcode 16.0"; fi'
# shellcheck disable=SC2016
make_stub pod 'if [[ "${1:-}" == "--version" ]]; then echo "1.15.2"; fi'
make_stub fastlane 'echo "fastlane 2.220.0"'
make_stub ios-deploy
make_stub java 'echo "openjdk version \"17.0.10\"" >&2'
make_stub adb
make_recording_stub npm
make_recording_stub pnpm
make_recording_stub yarn
make_recording_stub bun
make_recording_stub mise

# Fake eas: `whoami` succeeds, `build` writes a dummy artifact to --output
# (unless FAKE_EAS_BUILD_FAIL is set, simulating a build that produces nothing)
cat >"$STUB_DIR/eas" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${TEST_MARKER_FILE:-}" ]]; then echo "eas $* cwd=$PWD" >> "$TEST_MARKER_FILE"; fi
case "${1:-}" in
    --version) echo "eas-cli/16.3.0" ;;
    whoami) echo "test-user" ;;
    build)
        shift
        out=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--output" ]]; then out="${2:-}"; shift; fi
            shift
        done
        if [[ -n "$out" ]] && [[ -z "${FAKE_EAS_BUILD_FAIL:-}" ]]; then
            mkdir -p "$(dirname "$out")"
            echo "fake-artifact" > "$out"
        fi
        ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/eas"

# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------

# Creates an Expo-like project (eas.json, app.json, package-lock.json) with a
# copy of build.sh in its root, and prints the project path.
make_fixture() {
    local dir="$WORK_DIR/$1"
    mkdir -p "$dir"
    cat >"$dir/eas.json" <<'EOF'
{
  "build": {
    "production": { "distribution": "store" },
    "preview": { "distribution": "internal", "android": { "buildType": "apk" } },
    "simulator": { "distribution": "internal", "ios": { "simulator": true } },
    "device": { "distribution": "internal" },
    "preview-inherited": { "extends": "preview" }
  }
}
EOF
    echo '{ "expo": { "name": "My Cool App!" } }' >"$dir/app.json"
    echo '{ "name": "fixture-app", "private": true }' >"$dir/package.json"
    echo '{}' >"$dir/package-lock.json"
    cp "$BUILD_SH" "$dir/build.sh"
    echo "$dir"
}

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------

PASS=0
FAIL=0
CURRENT_TEST=""
TEST_OK=1

# Per-invocation knobs, reset before every test by run_test
FAKE_UNAME="Darwin"
APP_NAME_ENV=""
PRE_BUILD_CMD_ENV=""
FAKE_EAS_FAIL=""
TEST_MARKER_FILE=""

# run_build <cwd> <script> <args...>  — sets OUTPUT and STATUS
run_build() {
    local dir="$1" script="$2"
    shift 2
    OUTPUT="$(cd "$dir" && env -i \
        HOME="$FAKE_HOME" \
        PATH="$RUN_PATH" \
        FAKE_UNAME="$FAKE_UNAME" \
        FAKE_EAS_BUILD_FAIL="$FAKE_EAS_FAIL" \
        TEST_MARKER_FILE="$TEST_MARKER_FILE" \
        APP_NAME="$APP_NAME_ENV" \
        PRE_BUILD_COMMAND="$PRE_BUILD_CMD_ENV" \
        bash "$script" "$@" 2>&1)"
    STATUS=$?
}

t_fail() {
    TEST_OK=0
    echo "    FAIL: $1"
}

assert_status() {
    [[ "$STATUS" -eq "$1" ]] || t_fail "expected exit $1, got $STATUS"
}

assert_output_contains() {
    [[ "$OUTPUT" == *"$1"* ]] || t_fail "output missing: '$1'"
}

assert_glob() {
    compgen -G "$1" >/dev/null || t_fail "no file matching: $1"
}

assert_no_glob() {
    if compgen -G "$1" >/dev/null; then t_fail "unexpected file matching: $1"; fi
}

run_test() {
    CURRENT_TEST="$1"
    TEST_OK=1
    FAKE_UNAME="Darwin"
    APP_NAME_ENV=""
    PRE_BUILD_CMD_ENV=""
    FAKE_EAS_FAIL=""
    TEST_MARKER_FILE="$MARKER_DIR/$1.log"
    "$1"
    if [[ "$TEST_OK" -eq 1 ]]; then
        echo "  ok $CURRENT_TEST"
        PASS=$((PASS + 1))
    else
        echo "  NOT ok $CURRENT_TEST"
        FAIL=$((FAIL + 1))
    fi
}

# -----------------------------------------------------------------------------
# Tests: argument and environment validation
# -----------------------------------------------------------------------------

test_missing_args_shows_usage() {
    local dir; dir="$(make_fixture missing-args)"
    run_build "$dir" "$dir/build.sh"
    assert_status 1
    assert_output_contains "Usage: ./build.sh"
}

test_invalid_platform_rejected() {
    local dir; dir="$(make_fixture invalid-platform)"
    run_build "$dir" "$dir/build.sh" windows preview
    assert_status 1
    assert_output_contains "Invalid platform: windows"
}

test_unknown_profile_lists_available() {
    local dir; dir="$(make_fixture unknown-profile)"
    run_build "$dir" "$dir/build.sh" android nope
    assert_status 1
    assert_output_contains "Profile 'nope' not found"
    assert_output_contains "production"
}

test_malicious_profile_name_handled_safely() {
    # Regression test: profile names must never reach node as JS source
    local dir; dir="$(make_fixture evil-profile)"
    run_build "$dir" "$dir/build.sh" android "x']; require('child_process').execSync('touch pwned'); //"
    assert_status 1
    assert_output_contains "not found"
    [[ ! -f "$dir/pwned" ]] || t_fail "profile name was evaluated as code"
}

test_missing_eas_json_errors() {
    mkdir -p "$WORK_DIR/no-eas/bin" "$WORK_DIR/no-eas-cwd"
    cp "$BUILD_SH" "$WORK_DIR/no-eas/bin/build.sh"
    run_build "$WORK_DIR/no-eas-cwd" "$WORK_DIR/no-eas/bin/build.sh" android preview
    assert_status 1
    assert_output_contains "Could not find eas.json"
}

test_ios_requires_macos() {
    local dir; dir="$(make_fixture ios-linux)"
    FAKE_UNAME="Linux"
    run_build "$dir" "$dir/build.sh" ios device
    assert_status 1
    assert_output_contains "iOS builds require macOS"
}

# -----------------------------------------------------------------------------
# Tests: artifact naming and extensions
# -----------------------------------------------------------------------------

test_android_apk_profile_builds_apk() {
    local dir; dir="$(make_fixture android-apk)"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    assert_output_contains "Build Complete!"
    assert_glob "$dir/build-output/my-cool-app-preview-*.apk"
}

test_android_default_builds_aab() {
    local dir; dir="$(make_fixture android-aab)"
    run_build "$dir" "$dir/build.sh" android production --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/my-cool-app-production-*.aab"
}

test_extends_profile_inherits_build_type() {
    # 'preview-inherited' extends 'preview' (android.buildType: apk)
    local dir; dir="$(make_fixture extends-profile)"
    run_build "$dir" "$dir/build.sh" android preview-inherited --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/my-cool-app-preview-inherited-*.apk"
    assert_no_glob "$dir/build-output/*.aab"
}

test_ios_simulator_builds_targz() {
    local dir; dir="$(make_fixture ios-sim)"
    run_build "$dir" "$dir/build.sh" ios simulator --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/my-cool-app-simulator-*.tar.gz"
}

test_ios_device_builds_ipa() {
    local dir; dir="$(make_fixture ios-device)"
    run_build "$dir" "$dir/build.sh" ios device --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/my-cool-app-device-*.ipa"
}

test_all_builds_both_platforms() {
    local dir; dir="$(make_fixture all-platforms)"
    run_build "$dir" "$dir/build.sh" all device --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/my-cool-app-device-*.ipa"
    assert_glob "$dir/build-output/my-cool-app-device-*.aab"
}

test_app_name_env_override_is_sanitized() {
    local dir; dir="$(make_fixture app-name-env)"
    APP_NAME_ENV="Custom Name"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    assert_glob "$dir/build-output/custom-name-preview-*.apk"
}

test_build_without_artifact_exits_nonzero() {
    local dir; dir="$(make_fixture build-fail)"
    FAKE_EAS_FAIL=1
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 1
    assert_output_contains "did not produce an artifact"
}

test_mise_toolchain_installed_when_pinned() {
    local dir; dir="$(make_fixture mise-config)"
    printf '[tools]\nnode = "22"\n' >"$dir/.mise.toml"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    grep -q "mise install" "$TEST_MARKER_FILE" || t_fail "expected 'mise install' to run"
    assert_glob "$dir/build-output/my-cool-app-preview-*.apk"
}

test_mise_skipped_without_config() {
    local dir; dir="$(make_fixture mise-absent)"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    if grep -q "^mise" "$TEST_MARKER_FILE" 2>/dev/null; then
        t_fail "mise should not run without a mise config"
    fi
}

# -----------------------------------------------------------------------------
# Tests: install step and hooks
# -----------------------------------------------------------------------------

test_npm_ci_used_with_package_lock() {
    local dir; dir="$(make_fixture npm-lock)"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    grep -q "npm ci" "$TEST_MARKER_FILE" || t_fail "expected 'npm ci' to run"
}

test_pre_build_command_runs() {
    local dir; dir="$(make_fixture pre-build)"
    PRE_BUILD_CMD_ENV="touch prebuild-ran.txt"
    run_build "$dir" "$dir/build.sh" android preview --non-interactive
    assert_status 0
    [[ -f "$dir/prebuild-ran.txt" ]] || t_fail "pre-build command did not run"
}

test_monorepo_installs_at_workspace_root() {
    local root="$WORK_DIR/monorepo"
    local app; app="$(make_fixture monorepo/apps/mobile)"
    rm "$app/package-lock.json"
    echo '{ "name": "workspace-root", "private": true }' >"$root/package.json"
    touch "$root/pnpm-lock.yaml"
    run_build "$app" "$app/build.sh" android preview --non-interactive
    assert_status 0
    grep -q "pnpm install --frozen-lockfile cwd=$root" "$TEST_MARKER_FILE" ||
        t_fail "expected pnpm install at workspace root $root"
    assert_glob "$app/build-output/my-cool-app-preview-*.apk"
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

echo "build.sh test suite"
echo ""

run_test test_missing_args_shows_usage
run_test test_invalid_platform_rejected
run_test test_unknown_profile_lists_available
run_test test_malicious_profile_name_handled_safely
run_test test_missing_eas_json_errors
run_test test_ios_requires_macos
run_test test_android_apk_profile_builds_apk
run_test test_android_default_builds_aab
run_test test_extends_profile_inherits_build_type
run_test test_ios_simulator_builds_targz
run_test test_ios_device_builds_ipa
run_test test_all_builds_both_platforms
run_test test_app_name_env_override_is_sanitized
run_test test_build_without_artifact_exits_nonzero
run_test test_mise_toolchain_installed_when_pinned
run_test test_mise_skipped_without_config
run_test test_npm_ci_used_with_package_lock
run_test test_pre_build_command_runs
run_test test_monorepo_installs_at_workspace_root

echo ""
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
