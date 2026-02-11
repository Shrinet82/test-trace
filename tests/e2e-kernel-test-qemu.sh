#!/bin/bash
#
# Run E2E Kernel Tests inside QEMU (using virtme-ng)
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

# Ensure ~/.local/bin is on PATH (pip user installs go there)
export PATH="$HOME/.local/bin:$PATH"

# Install virtme-ng (vng) — the modern, maintained fork
install_virtme_ng() {
    if command -v vng >/dev/null 2>&1; then
        echo "vng (virtme-ng) already available: $(vng --version 2>&1 || true)"
        return
    fi

    echo "Installing virtme-ng..."
    pip3 install virtme-ng

    if ! command -v vng >/dev/null 2>&1; then
        echo "Error: vng not found on PATH after installation"
        echo "PATH=$PATH"
        exit 1
    fi
    echo "virtme-ng installed: $(vng --version 2>&1 || true)"
}

install_virtme_ng

# Locate kernel image and release
if [[ "$KERNEL_VERSION" == v* ]]; then
    VERSION_NUM=${KERNEL_VERSION#v}
    KERNEL_RELEASE=$(ls /boot/vmlinuz* 2>/dev/null | grep "$VERSION_NUM" | sort -V | tail -n1 | sed 's/.*vmlinuz-//' || true)
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

# /boot is root-owned — CI runner user cannot read vmlinuz directly.
# Copy the kernel to the workspace so QEMU can access it.
LOCAL_KERNEL="./vmlinuz-$KERNEL_RELEASE"
echo "Copying kernel to workspace for QEMU access..."
sudo cp "$KERNEL_IMG" "$LOCAL_KERNEL"
sudo chmod +r "$LOCAL_KERNEL"

echo "Kernel image ready at: $LOCAL_KERNEL"

# Make /boot/vmlinuz readable so vng can find it by release name
sudo chmod +r "$KERNEL_IMG" 2>/dev/null || true

# Prepare test command
CMD="$(pwd)/tests/e2e-kernel-test-qemu-exec.sh"
chmod +x "$CMD"

# Build vng command
VNG_ARGS=(
    vng
    -r "$KERNEL_RELEASE"
    --verbose
    --memory 4G
    --cpus 2
)

# For cross-architecture emulation
if [[ "$QEMU_ARCH" != "$(uname -m)" ]]; then
    echo "Cross-architecture emulation: $QEMU_ARCH on $(uname -m)"
    VNG_ARGS+=(--arch "$QEMU_ARCH")

    # For cross-arch, virtme-ng cannot use the host rootfs.
    # We must provide an architecture-compatible rootfs.
    # We'll use Ubuntu Base 24.04 (Noble) for arm64.

    ROOTFS_DIR="$(pwd)/rootfs-aarch64"
    if [[ ! -d "$ROOTFS_DIR" ]]; then
        echo "Downloading Ubuntu Base aarch64 rootfs..."
        # URL for Ubuntu Base 24.04 arm64
        ROOTFS_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04-base-arm64.tar.gz"
        mkdir -p "$ROOTFS_DIR"
        wget -q -O rootfs.tar.gz "$ROOTFS_URL"
        echo "Extracting rootfs..."
        tar -xzf rootfs.tar.gz -C "$ROOTFS_DIR"
        rm rootfs.tar.gz
        
        # Enable DNS in the chroot
        echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"
    fi

    # Inject kernel modules into the rootfs
    # virtme-ng usually handles modules, but cross-arch with --root might need help if host path != guest path.
    # Host: /lib/modules/$KERNEL_RELEASE (installed by setup script)
    # Guest: /lib/modules/$KERNEL_RELEASE
    echo "Injecting kernel modules into rootfs..."
    mkdir -p "$ROOTFS_DIR/lib/modules"
    sudo cp -rn "/lib/modules/$KERNEL_RELEASE" "$ROOTFS_DIR/lib/modules/" || echo "Warning: module copy failed or exists"

    # We need to ensure the workspace (where Tracee is) is mounted in the guest.
    # vng --pwd mounts the current directory to the same path in the guest.
    # BUT since we are providing a custom rootfs, the mount points must exist.
    # We are in $(pwd).
    # Create the mount point in the rootfs.
    mkdir -p "$ROOTFS_DIR/$(pwd)"

    echo "Using custom rootfs: $ROOTFS_DIR"
    VNG_ARGS+=(--root "$ROOTFS_DIR")
    
    # Ensure /tmp exists and has correct permissions in rootfs
    mkdir -p "$ROOTFS_DIR/tmp"
    chmod 1777 "$ROOTFS_DIR/tmp"
    
    # We need to manually specify the exec command because --root changes things?
    # No, --exec should still work, but requires --rw or similar.
    # --pwd mounts CWD.
    VNG_ARGS+=(--pwd)
    VNG_ARGS+=(--rw)

    # The command needs to run inside the guest. The path to CMD is fully qualified.
    # Since we mount CWD, the path should be valid.
    VNG_ARGS+=(--exec "$CMD")

else
    # Native architecture - use host rootfs
    # NOTE: Do NOT use --rw for native, it causes permission issues with /tmp overlay
    VNG_ARGS+=(--exec "$CMD")
fi

echo "Launching virtme-ng..."
echo "Running: ${VNG_ARGS[*]}"
"${VNG_ARGS[@]}"
