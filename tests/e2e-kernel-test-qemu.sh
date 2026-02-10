#!/bin/bash
#
# Run E2E Kernel Tests inside QEMU (using virtme)
# Usage: ./e2e-kernel-test-qemu.sh [kernel-version] [arch]
# Example: ./e2e-kernel-test-qemu.sh v6.12 x86_64
#

set -euo pipefail

# Inputs
KERNEL_VERSION=${1:-$(uname -r)}
ARCH=${2:-$(uname -m)}

# Map input architecture to QEMU architecture
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    QEMU_ARCH="aarch64"
    ARCH="arm64"
else
    QEMU_ARCH="x86_64"
    ARCH="amd64"
fi

echo "Configuration: Kernel=$KERNEL_VERSION, Arch=$ARCH, QEMU_ARCH=$QEMU_ARCH"

# Install virtme from upstream git and patch QEMU compatibility issues
install_virtme() {
    if command -v virtme-run >/dev/null 2>&1; then
        echo "virtme-run already available"
    else
        echo "Installing virtme from upstream git..."
        pip3 install git+https://github.com/amluto/virtme.git
    fi

    # Patch: QEMU 9.x (Ubuntu 24.04) removed the legacy '-watchdog' CLI option.
    # virtme still emits '-watchdog i6300esb'. We must remove ALL occurrences.
    VIRTME_PKG_DIR=$(python3 -c "import virtme; import os; print(os.path.dirname(virtme.__file__))" 2>/dev/null || true)
    if [[ -n "$VIRTME_PKG_DIR" && -d "$VIRTME_PKG_DIR" ]]; then
        echo "Virtme package dir: $VIRTME_PKG_DIR"
        echo "Searching for ALL -watchdog references..."
        # Find every file that mentions watchdog
        WATCHDOG_FILES=$(grep -rl "watchdog" "$VIRTME_PKG_DIR" 2>/dev/null || true)
        if [[ -n "$WATCHDOG_FILES" ]]; then
            echo "Found watchdog references in:"
            echo "$WATCHDOG_FILES"
            for f in $WATCHDOG_FILES; do
                echo "  Patching: $f"
                # Remove any line containing 'watchdog' (covers all variants)
                sed -i '/watchdog/d' "$f"
            done
            echo "All watchdog references patched."
        else
            echo "No watchdog references found (already clean)."
        fi
    else
        echo "WARNING: Could not locate virtme package directory"
    fi

    # Verify the patch by showing what QEMU command would be generated
    echo "Verifying patch with --show-command..."
}

install_virtme

# Locate kernel image
if [[ "$KERNEL_VERSION" == v* ]]; then
    VERSION_NUM=${KERNEL_VERSION#v}
    KERNEL_RELEASE=$(ls /boot/vmlinuz* 2>/dev/null | grep "$VERSION_NUM" | sort -V | tail -n1 | sed 's/.*vmlinuz-//')
else
    KERNEL_RELEASE=$KERNEL_VERSION
fi

if [ -z "${KERNEL_RELEASE:-}" ]; then
    echo "Error: Could not find installed kernel for version $KERNEL_VERSION"
    ls -l /boot/vmlinuz* 2>/dev/null || echo "No vmlinuz files in /boot"
    exit 1
fi

echo "Selected Kernel Release: $KERNEL_RELEASE"

KERNEL_IMG="/boot/vmlinuz-$KERNEL_RELEASE"

if [[ ! -f "$KERNEL_IMG" ]]; then
    echo "Error: Kernel image not found at $KERNEL_IMG"
    exit 1
fi

# Prepare test command
CMD="$(pwd)/tests/e2e-kernel-test-qemu-exec.sh"
chmod +x "$CMD"

# First, show the QEMU command for debugging (dry run)
echo "=== DRY RUN (showing QEMU command) ==="
virtme-run \
    --kimg "$KERNEL_IMG" \
    --memory 4G \
    --cpus 2 \
    --show-command || echo "(show-command returned non-zero, continuing anyway)"

echo "=== END DRY RUN ==="

echo "Launching virtme-run with kernel: $KERNEL_IMG"

# Build virtme-run command
VIRTME_ARGS=(
    virtme-run
    --kimg "$KERNEL_IMG"
    --memory 4G
    --cpus 2
    --rw
    --pwd
    --script-exec "$CMD"
)

# For cross-architecture, use --arch
if [[ "$QEMU_ARCH" != "$(uname -m)" ]]; then
    echo "Cross-architecture emulation: $QEMU_ARCH on $(uname -m)"
    VIRTME_ARGS+=(--arch "$QEMU_ARCH")
fi

echo "Running: ${VIRTME_ARGS[*]}"
"${VIRTME_ARGS[@]}"
