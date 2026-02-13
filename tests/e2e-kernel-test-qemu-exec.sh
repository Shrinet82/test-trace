#!/bin/bash
#
# Run E2E Kernel Tests inside QEMU (Direct Execution)
# This script is meant to be run INSIDE the QEMU VM by virtme-ng.
# It invokes the standard test suites (Compatibility, Instrumentation, Network, Kernel).
#

set -u

SCRIPT_TMP_DIR=/tmp
TRACEE_TMP_DIR=/tmp/tracee
ARTIFACTS_DIR="./qemu-artifacts"

# Setup directories
mkdir -p "$TRACEE_TMP_DIR"
mkdir -p "$SCRIPT_TMP_DIR"
mkdir -p "$ARTIFACTS_DIR"

info() {
    echo "INFO: $*"
}

error() {
    echo "ERROR: $*"
}

# Ensure we have the right paths (synced from host)
export HOME="/tmp/root"
export GOPATH="/tmp/go"
export GOCACHE="/tmp/go-cache"
# Add Go bin to PATH so 'go' command works
export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin

# We expect to be in the root of the repo (mounted by virtme-ng)
if [[ ! -x ./dist/tracee ]]; then
    error "Tracee binary not found at ./dist/tracee. Did you build it on the host?"
    exit 1
fi

EXIT_CODE=0

# 1. Compatibility Test
info ">>> Running Compatibility Test..."
# 'make test-compatibility' compiles and runs a test. We need to ensure it uses the right go env.
if make test-compatibility; then
    info "Compatibility Test: PASSED"
else
    error "Compatibility Test: FAILED"
    EXIT_CODE=1
fi

# 2. Instrumentation Test
info ">>> Running Instrumentation Test..."
# Run standard instrumentation tests
if ./tests/e2e-inst-test.sh --keep-artifacts 2>&1 | tee "$ARTIFACTS_DIR/e2e-inst-test.log"; then
    info "Instrumentation Test: PASSED"
else
    error "Instrumentation Test: FAILED"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        EXIT_CODE=1
    fi
fi

# 3. Network Test
info ">>> Running Network Test..."
if ./tests/e2e-net-test.sh 2>&1 | tee "$ARTIFACTS_DIR/e2e-net-test.log"; then
    info "Network Test: PASSED"
else
    error "Network Test: FAILED"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        EXIT_CODE=1
    fi
fi

# 4. Kernel Test (Requires Docker)
# Note: In a virtme-ng environment (using host rootfs), we typically don't have access to the host's Docker daemon
# unless the socket is explicitly mounted and namespaces allow it. 
# We'll check for docker before running.
info ">>> Running Kernel Test..."
if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    if ./tests/e2e-kernel-test.sh 2>&1 | tee "$ARTIFACTS_DIR/e2e-kernel-test.log"; then
        info "Kernel Test: PASSED"
    else
        error "Kernel Test: FAILED"
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            EXIT_CODE=1
        fi
    fi
else
    info "SKIPPING Kernel Test: Docker daemon not available in this environment."
    # We do NOT fail the job for this, as it's an expected limitation of the VM environment currently.
fi

info "All tests completed."
if [[ $EXIT_CODE -eq 0 ]]; then
    info "Result: SUCCESS"
else
    error "Result: FAILURE (One or more test suites failed)"
fi

exit $EXIT_CODE
