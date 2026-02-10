#!/bin/bash
#
# Run E2E Kernel Tests inside QEMU (using virtme-ng)
# Usage: ./e2e-kernel-test-qemu.sh [kernel-version] [arch]
# Example: ./e2e-kernel-test-qemu.sh v6.12.0 x86_64
# Example: ./e2e-kernel-test-qemu.sh v6.12.0 aarch64
#

set -euo pipefail

# Inputs
KERNEL_VERSION=${1:-$(uname -r)}
ARCH=${2:-$(uname -m)}

# Map input architecture to QEMU architecture and binary
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    QEMU_ARCH="aarch64"
    QEMU_BIN="qemu-system-aarch64"
    ARCH="arm64" # Normalize for kernel paths
else
    QEMU_ARCH="x86_64"
    QEMU_BIN="qemu-system-x86_64"
    ARCH="amd64" # Normalize for kernel paths (dpkg style)
fi

echo "Configuration: Kernel=$KERNEL_VERSION, Arch=$ARCH, QEMU=$QEMU_BIN"

# Check for virtme
if ! command -v virtme-run >/dev/null; then
    echo "Using system virtme or installing..."
    if ! pip3 show virtme >/dev/null; then
         echo "virtme not found. Installing from upstream..."
         # PyPI virtme is ancient (0.0.1). Install from git for modern features.
         pip3 install git+https://github.com/amluto/virtme.git
    fi
fi

# Locate kernel image
# ... (unchanged)

if [[ "$KERNEL_VERSION" == v* ]]; then
    # e.g., v6.12 -> find 6.12.0-061200...
    VERSION_NUM=${KERNEL_VERSION#v}
    KERNEL_RELEASE=$(ls /boot/vmlinuz* | grep "$VERSION_NUM" | sort -V | tail -n1 | sed 's/.*vmlinuz-//')
else
    KERNEL_RELEASE=$KERNEL_VERSION
fi

if [ -z "$KERNEL_RELEASE" ]; then
    echo "Error: Could not find installed kernel for version $KERNEL_VERSION"
    ls -l /boot/vmlinuz*
    exit 1
fi

echo "Selected Kernel Release: $KERNEL_RELEASE"

# Boot Kernel path
KERNEL_IMG="/boot/vmlinuz-$KERNEL_RELEASE"

if [[ ! -f "$KERNEL_IMG" ]]; then
    echo "Error: Kernel image not found at $KERNEL_IMG"
    exit 1
fi

# Command to run inside VM:
CMD="./tests/e2e-kernel-test-qemu-exec.sh"
chmod +x "$CMD"

echo "Launching virtme-run..."

# virtme-run arguments:
# --kimg: Kernel image
# --rw: Enable read/write overlay
# --pwd: Mount current directory
# --qemu-opts: Pass flags to QEMU (memory, cpus)
# --script-exec: Run command immediately

# Construct virtme command
VIRTME_CMD="virtme-run --rw --pwd --qemu-opts -m 4G -smp 2"

# Handle Architecture
if [[ "$QEMU_ARCH" != "$(uname -m)" ]]; then
    echo "Cross-architecture emulation detected ($QEMU_ARCH on $(uname -m))"
    # virtme-run defaults to host arch.
    # We rely on qemu-system-$QEMU_ARCH being used or detected.
    # virtme allows specifying qemu binary via --qemu-bin
    VIRTME_CMD="$VIRTME_CMD --qemu-bin $QEMU_BIN"
fi

$VIRTME_CMD \
    --kimg "$KERNEL_IMG" \
    --script-exec "$CMD"
