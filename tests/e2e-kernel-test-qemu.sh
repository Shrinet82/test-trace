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

    # Ensure virtme-ng cache directory exists (fixes QEMU mount error)
    mkdir -p "$HOME/.cache/virtme-ng"
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
    # Ensure virtme-ng cache directory exists (fixes QEMU mount error)
    mkdir -p "$HOME/.cache/virtme-ng"

    # Download static busybox for aarch64 (initramfs needs it)
    BUSYBOX_DIR="$(pwd)/busybox-aarch64"
    BUSYBOX_BIN="$BUSYBOX_DIR/busybox"
    if [[ ! -f "$BUSYBOX_BIN" ]]; then
        echo "Downloading static busybox for aarch64..."
        mkdir -p "$BUSYBOX_DIR"
        # URL for busybox-static arm64 deb from Debian Sid (valid as of 2026-02-11)
        BUSYBOX_URL="http://ftp.de.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-10_arm64.deb"
        if ! wget -q -O busybox.deb "$BUSYBOX_URL"; then
             # Fallback to older version if Sid moves
             wget -q -O busybox.deb "http://ftp.de.debian.org/debian/pool/main/b/busybox/busybox-static_1.35.0-4+b7_arm64.deb"
        fi
        
        # Extract
        dpkg-deb -x busybox.deb "$BUSYBOX_DIR/extracted"
        
        # Find the binary (could be in /bin, /usr/bin, etc.)
        FOUND_BIN=$(find "$BUSYBOX_DIR/extracted" -name busybox -type f | head -n 1)
        if [[ -z "$FOUND_BIN" ]]; then
            echo "Error: busybox binary not found in extracted deb"
            find "$BUSYBOX_DIR/extracted"
            exit 1
        fi
        
        cp "$FOUND_BIN" "$BUSYBOX_BIN"
        chmod +x "$BUSYBOX_BIN"
    fi
    
    VNG_ARGS+=(--busybox "$BUSYBOX_BIN")

    # We'll use Ubuntu Base 24.04 (Noble) for arm64.

    ROOTFS_DIR="$(pwd)/rootfs-aarch64"
    if [[ ! -d "$ROOTFS_DIR" ]]; then
        echo "Downloading Ubuntu Base aarch64 rootfs..."
        # Use Ubuntu Base 22.04 (Jammy) - stable and reliable URL
        ROOTFS_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz"
        mkdir -p "$ROOTFS_DIR"
        
        if ! wget -q -O rootfs.tar.gz "$ROOTFS_URL"; then
            echo "Error: Failed to download rootfs from $ROOTFS_URL"
            exit 1
        fi
        
        echo "Extracting rootfs..."
        tar -xzf rootfs.tar.gz -C "$ROOTFS_DIR"
        rm rootfs.tar.gz
        
    # Enable DNS in the chroot
    echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"

    # Create /tmp in rootfs before doing anything else (apt needs it)
    mkdir -p "$ROOTFS_DIR/tmp"
    chmod 1777 "$ROOTFS_DIR/tmp"

    # Install curl inside rootfs (needed for Tracee healthcheck)
    # This requires qemu-user-static on the host to run aarch64 binaries.
    if [[ -f /usr/bin/qemu-aarch64-static ]]; then
        echo "Installing curl in aarch64 rootfs using qemu-user-static..."
        sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
        
        # Mount /dev, /proc, /sys for apt
        sudo mount --bind /dev "$ROOTFS_DIR/dev"
        sudo mount --bind /proc "$ROOTFS_DIR/proc"
        sudo mount --bind /sys "$ROOTFS_DIR/sys"
        
        # Run apt-get update && install curl
        # We ignore errors to avoid breaking if transient network issues occur,
        # but we really need curl.
        sudo chroot "$ROOTFS_DIR" /bin/bash -c "apt-get update && apt-get install -y --no-install-recommends curl ca-certificates" || echo "Warning: apt-get failed in chroot"
        
        # Cleanup
        sudo umount "$ROOTFS_DIR/sys"
        sudo umount "$ROOTFS_DIR/proc"
        sudo umount "$ROOTFS_DIR/dev"
    else
        echo "Warning: qemu-aarch64-static not found. Skipping curl installation. Health check might fail."
    fi
fi

# Inject kernel modules into the rootfs
echo "Injecting kernel modules into rootfs..."
mkdir -p "$ROOTFS_DIR/lib/modules"
sudo cp -rn "/lib/modules/$KERNEL_RELEASE" "$ROOTFS_DIR/lib/modules/" || echo "Warning: module copy failed or exists"

# We need to ensure the workspace (where Tracee is) is mounted in the guest.
mkdir -p "$ROOTFS_DIR/$(pwd)"

echo "Using custom rootfs: $ROOTFS_DIR"
VNG_ARGS+=(--root "$ROOTFS_DIR")

# Add entropy to guest to prevent boot hangs
VNG_ARGS+=(--qemu-opts "-device virtio-rng-pci")

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
