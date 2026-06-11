#!/usr/bin/env bash
#
# 03-umount-virtual-fs.sh
# ---------------------------------------------------------------------------
# Hängt die virtuellen Kernel-Dateisysteme wieder aus $LFS aus.
# Immer ausführen, bevor das LFS-Dateisystem selbst ausgehängt wird.
#
#     sudo bash 01-lfs-toolchain/03-umount-virtual-fs.sh /mnt/lfs
# ---------------------------------------------------------------------------
set -uo pipefail

export LFS="${1:-/mnt/lfs}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "FEHLER: muss als root laufen." >&2
    exit 1
fi

# In umgekehrter Reihenfolge aushängen; lazy umount für hartnäckige Mounts.
for mp in "$LFS/dev/shm" "$LFS/dev/pts" "$LFS/dev" "$LFS/run" "$LFS/sys" "$LFS/proc"; do
    if mountpoint -q "$mp"; then
        umount -v "$mp" 2>/dev/null || umount -lv "$mp"
    fi
done

echo ">>> Verbleibende LFS-Mounts (sollte leer sein):"
mount | grep -E "on ${LFS}(/|\s)" || echo "  (keine)"
