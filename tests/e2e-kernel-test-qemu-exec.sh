#!/bin/bash
#
# DEBUG: E2E Kernel Tests inside QEMU
#

set -u
# Do NOT use set -e, we want to catch errors and print logs

SCRIPT_TMP_DIR=/tmp
TRACEE_TMP_DIR=/tmp/tracee
ARTIFACTS_DIR="./qemu-artifacts"

mkdir -p "$TRACEE_TMP_DIR"
mkdir -p "$SCRIPT_TMP_DIR"
mkdir -p "$ARTIFACTS_DIR"

info() { echo "INFO: $*"; }
error() { echo "ERROR: $*"; }

# Setup Env
export HOME="/tmp/root"
export GOPATH="/tmp/go"
export GOCACHE="/tmp/go-cache"
export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin

info "=== DEBUG INFO ==="
info "User: $(whoami)"
info "Kernel: $(uname -r)"
info "Arch: $(uname -m)"
info "Go: $(go version 2>&1 || echo 'missing')"
info "Make: $(make --version 2>&1 | head -n1 || echo 'missing')"
info "GCC: $(gcc --version 2>&1 | head -n1 || echo 'missing')"
info "Clang: $(clang --version 2>&1 | head -n1 || echo 'missing')"
info "Kernel Headers: $(ls -d /lib/modules/$(uname -r)/build 2>/dev/null || echo 'missing')"
info "Dist: $(ls -l ./dist/tracee 2>/dev/null || echo 'missing')"

EXIT_CODE=0

# 1. Compatibility Test
info ">>> Running Compatibility Test..."
if make test-compatibility > "$ARTIFACTS_DIR/test-compatibility.log" 2>&1; then
    info "Compatibility Test: PASSED"
else
    error "Compatibility Test: FAILED"
    info "--- LOGS: test-compatibility ---"
    cat "$ARTIFACTS_DIR/test-compatibility.log" | tail -n 50
    info "-------------------------------"
    EXIT_CODE=1
fi

# 2. Instrumentation Test
info ">>> Running Instrumentation Test..."
# FORCE KEEP ARTIFACTS
if ./tests/e2e-inst-test.sh --keep-artifacts > "$ARTIFACTS_DIR/e2e-inst-test.log" 2>&1; then
    info "Instrumentation Test: PASSED"
else
    error "Instrumentation Test: FAILED"
    info "--- LOGS: e2e-inst-test ---"
    cat "$ARTIFACTS_DIR/e2e-inst-test.log" | tail -n 100
    info "---------------------------"
    
    # Check for specific suite logs if they exist
    for suite_log in /tmp/test_*_*.log; do
        if [[ -f "$suite_log" ]]; then
            info "--- SUITE LOG: $(basename $suite_log) ---"
            cat "$suite_log" | tail -n 20
            info "---------------------------------------"
        fi
    done
    
    EXIT_CODE=1
fi

# 3. Network Test
info ">>> Running Network Test..."
if ./tests/e2e-net-test.sh > "$ARTIFACTS_DIR/e2e-net-test.log" 2>&1; then
    info "Network Test: PASSED"
else
    error "Network Test: FAILED"
    info "--- LOGS: e2e-net-test ---"
    cat "$ARTIFACTS_DIR/e2e-net-test.log" | tail -n 50
    info "------------------------"
    EXIT_CODE=1
fi

info "DEBUG SCRIPT COMPLETE. Exit Code: $EXIT_CODE"
exit $EXIT_CODE
