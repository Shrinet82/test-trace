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

# Check for virtme-ng
if ! command -v vng >/dev/null; then
    echo "Using system virtme-ng or installing..."
    # If running in CI, it should be installed via pip.
    # If not, let's try to install it?
    # Better to assume environment is prepared by workflow.
    if ! pip3 show virtme-ng >/dev/null; then
         echo "virtme-ng not found. Installing..."
         pip3 install virtme-ng
    fi
fi

# Locate kernel image
# This assumes setup-mainline-kernel.sh ran and installed kernels into /boot
# or we are running on a machine with that kernel.
# For CI, setup-mainline-kernel.sh creates /boot/vmlinuz-* files.

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
INITRD_IMG="/boot/initrd.img-$KERNEL_RELEASE"

if [[ ! -f "$KERNEL_IMG" ]]; then
    echo "Error: Kernel image not found at $KERNEL_IMG"
    exit 1
fi

# Determine QEMU arguments
# virtme-ng handles most, but for cross-arch we might need specific flags?
# vng usually detects architecture from the kernel image if possible, but let's be explicit if needed.
# vng --arch ... is not a standard flag, it uses qemu-system-ARCH.

# Command to run inside VM:
# We use the new Dockerless script
CMD="./tests/e2e-kernel-test-qemu-exec.sh"
chmod +x "$CMD"

echo "Launching virtme-ng..."

# --verbose for debugging
# --rw to allow writing to the mounted directory (for build artifacts)
# --pwd to start in current directory
# --cpus 2 --memory 4G

# Construct vng command
VNG_CMD="vng --verbose --rw --pwd --cpus 2 --memory 4G"

# If we need to specify a custom QEMU binary (e.g. for cross-arch emulation)
# vng documentation says it tries to find the right qemu.
# If we are on x86 running aarch64 kernel, we typically need:
# --qemu-bin qemu-system-aarch64

if [[ "$QEMU_ARCH" != "$(uname -m)" ]]; then
    echo "Cross-architecture emulation detected ($QEMU_ARCH on $(uname -m))"
    # We might need --qemu-bin if vng doesn't auto-detect
    # or just rely on kernel being aarch64.
    # NOTE: virtme-ng might need explicit qemu binary path?
    # Let's try appending --qemu-opts if needed or just hope vng is smart.
    # vng has --qemu-bin flag.
fi

# Run vng
# We append -- kernel_path -- initrd_path -- script
# Actually vng syntax: vng --kernel <K> --initrd <I> -- <COMMAND>

# Note: virtme-ng might trigger interactive mode if command fails, so we need to ensure it exits.
# Passing a command usually makes it exit after command.

$VNG_CMD \
    --kernel "$KERNEL_IMG" \
    --initrd "$INITRD_IMG" \
    -- \
    "$CMD"
