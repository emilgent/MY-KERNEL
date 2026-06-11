#!/usr/bin/env bash
#
# 01-mount-virtual-fs.sh
# ---------------------------------------------------------------------------
# BEREICH 1.2 — Virtuelle Kernel-Dateisysteme in das LFS-Chroot einhängen.
#
# Diese Mounts werden benötigt, bevor man per chroot in $LFS wechselt, damit
# die im Chroot laufenden Programme auf Geräte (/dev), Prozessinfos (/proc),
# Kernel-Sysfs (/sys) und tmpfs (/run) zugreifen können.
#
# Ausführen als root:
#     sudo bash 01-lfs-toolchain/01-mount-virtual-fs.sh /mnt/lfs
#
# Gegenstück: 03-umount-virtual-fs.sh
# ---------------------------------------------------------------------------
set -euo pipefail

export LFS="${1:-/mnt/lfs}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "FEHLER: muss als root laufen." >&2
    exit 1
fi
if [[ ! -d "$LFS" ]]; then
    echo "FEHLER: $LFS existiert nicht." >&2
    exit 1
fi

# Zielverzeichnisse sicherstellen
mkdir -pv "$LFS"/{dev,proc,sys,run}

# --- /dev: bind-mount des Host-/dev ---------------------------------------
# (LFS-Buch nutzt seit udev-Umstellung den bind-mount statt mknod.)
if ! mountpoint -q "$LFS/dev"; then
    mount -v --bind /dev "$LFS/dev"
fi

# --- /dev/pts, /proc, /sys, /run ------------------------------------------
if ! mountpoint -q "$LFS/dev/pts"; then
    mount -v --bind /dev/pts "$LFS/dev/pts"
fi
if ! mountpoint -q "$LFS/proc"; then
    mount -vt proc     proc  "$LFS/proc"
fi
if ! mountpoint -q "$LFS/sys"; then
    mount -vt sysfs    sysfs "$LFS/sys"
fi
if ! mountpoint -q "$LFS/run"; then
    mount -vt tmpfs    tmpfs "$LFS/run"
fi

# Manche Hosts haben /dev/shm als Symlink auf /run/shm
if [ -h "$LFS/dev/shm" ]; then
    install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
    mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

echo
echo ">>> Aktuelle LFS-Mounts:"
mount | grep -E "on ${LFS}(/|\s)" || true

cat <<EOF

============================================================================
 Virtuelle Dateisysteme sind eingehängt.

 Chroot betreten (LFS-Buch, Standard-Aufruf):

   chroot "$LFS" /usr/bin/env -i   \\
       HOME=/root                  \\
       TERM="\$TERM"               \\
       PS1='(lfs chroot) \u:\w\$ ' \\
       PATH=/usr/bin:/usr/sbin     \\
       MAKEFLAGS="-j\$(nproc)"     \\
       /bin/bash --login

 Boot-/Kernel-Parameter Hinweis:
   Für den späteren echten Boot wird in der Bootloader-Konfiguration
   (z. B. /boot/grub/grub.cfg) typischerweise gesetzt:

     linux  /boot/vmlinuz-<ver>-lfs root=/dev/sdXn ro rootfstype=ext4 \\
            init=/sbin/init rust_core.metrics=1

   Die virtuellen FS (/dev /proc /sys /run) werden im laufenden System von
   /etc/fstab bzw. den Bootscripts (mountvirtfs) eingehängt, NICHT als
   Kernel-Cmdline-Parameter.
============================================================================
EOF
