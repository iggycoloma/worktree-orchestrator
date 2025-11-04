#!/usr/bin/env bash
# Lightweight Bash Testing Framework
# Provides assertion functions and test utilities for unit testing

# Test counters
TEST_PASSED=0
TEST_FAILED=0
TEST_CURRENT_SUITE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test environment
TEST_TEMP_DIR=""

#
# Logging Functions
#

test_suite() {
    TEST_CURRENT_SUITE="$1"
    echo -e "\n${CYAN}==== Test Suite: $1 ====${NC}\n"
}

test_pass() {
    echo -e "${GREEN}  ✓${NC} $1"
    ((TEST_PASSED++)) || true
}

test_fail() {
    echo -e "${RED}  ✗${NC} $1"
    ((TEST_FAILED++)) || true
}

test_info() {
    echo -e "${BLUE}  ==>${NC} $1"
}

#
# Assertion Functions
#

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (expected: '$expected', got: '$actual')"
        return 1
    fi
}

assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [[ "$expected" != "$actual" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (both values: '$expected')"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    if [[ -e "$file" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist: $file}"

    if [[ ! -e "$file" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory should exist: $dir}"

    if [[ -d "$dir" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message"
        return 1
    fi
}

assert_symlink() {
    local link="$1"
    local expected_target="$2"
    local message="${3:-Symlink should point to target}"

    if [[ ! -L "$link" ]]; then
        test_fail "$message (not a symlink: $link)"
        return 1
    fi

    local actual_target=$(readlink "$link")
    if [[ "$actual_target" == "$expected_target" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (expected: '$expected_target', got: '$actual_target')"
        return 1
    fi
}

assert_is_symlink() {
    local link="$1"
    local message="${2:-Should be a symlink: $link}"

    if [[ -L "$link" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message"
        return 1
    fi
}

assert_not_symlink() {
    local path="$1"
    local message="${2:-Should not be a symlink: $path}"

    if [[ ! -L "$path" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message"
        return 1
    fi
}

assert_command_succeeds() {
    local message="$1"
    shift
    local cmd=("$@")

    if "${cmd[@]}" &>/dev/null; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (command failed: ${cmd[*]})"
        return 1
    fi
}

assert_command_fails() {
    local message="$1"
    shift
    local cmd=("$@")

    if ! "${cmd[@]}" &>/dev/null; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (command succeeded but should have failed: ${cmd[*]})"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (haystack: '$haystack', needle: '$needle')"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (found '$needle' in '$haystack')"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should contain pattern}"

    if [[ ! -f "$file" ]]; then
        test_fail "$message (file not found: $file)"
        return 1
    fi

    if grep -qF "$pattern" "$file"; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (pattern: '$pattern' not found in $file)"
        return 1
    fi
}

assert_return_code() {
    local expected_code="$1"
    local actual_code="$2"
    local message="${3:-Return code should match}"

    if [[ "$expected_code" -eq "$actual_code" ]]; then
        test_pass "$message"
        return 0
    else
        test_fail "$message (expected: $expected_code, got: $actual_code)"
        return 1
    fi
}

#
# Test Environment Setup
#

setup_test_env() {
    # Create temporary directory for tests
    TEST_TEMP_DIR=$(mktemp -d)

    # Create mock dotfiles structure
    mkdir -p "$TEST_TEMP_DIR/dotfiles"
    mkdir -p "$TEST_TEMP_DIR/home"

    # Export for functions that use it
    export DOTFILES_DIR="$TEST_TEMP_DIR/dotfiles"
    export HOME="$TEST_TEMP_DIR/home"

    return 0
}

teardown_test_env() {
    # Clean up temporary directory
    if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi

    # Restore original HOME if needed
    TEST_TEMP_DIR=""

    return 0
}

run_in_temp_dir() {
    local test_function="$1"

    setup_test_env

    # Run the test function
    $test_function
    local result=$?

    teardown_test_env

    return $result
}

#
# Mock Functions
#

mock_file() {
    local file="$1"
    local content="${2:-}"

    mkdir -p "$(dirname "$file")"
    echo "$content" > "$file"
}

mock_dir() {
    local dir="$1"
    mkdir -p "$dir"
}

mock_symlink() {
    local link="$1"
    local target="$2"

    mkdir -p "$(dirname "$link")"
    ln -sf "$target" "$link"
}

#
# Test Summary
#

print_test_summary() {
    local total=$((TEST_PASSED + TEST_FAILED))

    echo -e "\n${CYAN}==== Test Summary ====${NC}\n"
    echo "Total tests: $total"
    echo -e "${GREEN}Passed: $TEST_PASSED${NC}"
    echo -e "${RED}Failed: $TEST_FAILED${NC}"

    if [[ $TEST_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All tests passed!${NC}\n"
        return 0
    else
        echo -e "\n${RED}✗ Some tests failed!${NC}\n"
        return 1
    fi
}

#
# Utility Functions
#

capture_output() {
    local cmd=("$@")
    "${cmd[@]}" 2>&1
}

silence_output() {
    local cmd=("$@")
    "${cmd[@]}" &>/dev/null
}
