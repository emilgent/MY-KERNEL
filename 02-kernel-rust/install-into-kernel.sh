#!/usr/bin/env bash
#
# install-into-kernel.sh
# ---------------------------------------------------------------------------
# BEREICH 2.3 — Integriert das rust_core-Modul in einen Kernel-Source-Tree.
#
# Kopiert rust_core/ nach $KDIR/drivers/rust_core und hängt es idempotent in
# drivers/Kconfig und drivers/Makefile ein.
#
#   bash install-into-kernel.sh /pfad/zum/linux-6.13
#
# Danach im Kernelbaum:
#   ./scripts/kconfig/merge_config.sh .config \
#       /pfad/zu/MY-KERNEL/02-kernel-rust/kernel-config-rust.fragment
#   make LLVM=1 olddefconfig
#   make LLVM=1 rustavailable
#   make LLVM=1 -j"$(nproc)"            # Kernel + Module
# ---------------------------------------------------------------------------
set -euo pipefail

KDIR="${1:?Usage: install-into-kernel.sh /pfad/zum/linux-<ver>}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF_DIR/rust_core"

[[ -f "$KDIR/Makefile" && -d "$KDIR/drivers" ]] || {
    echo "FEHLER: $KDIR sieht nicht wie ein Kernel-Source-Tree aus." >&2
    exit 1
}

echo ">>> Kopiere rust_core nach $KDIR/drivers/rust_core"
install -d "$KDIR/drivers/rust_core"
install -m 0644 "$SRC/rust_core.rs" "$KDIR/drivers/rust_core/rust_core.rs"
install -m 0644 "$SRC/Kbuild"       "$KDIR/drivers/rust_core/Kbuild"
install -m 0644 "$SRC/Kconfig"      "$KDIR/drivers/rust_core/Kconfig"

# --- drivers/Kconfig: source-Zeile idempotent einfügen ---------------------
KCONFIG="$KDIR/drivers/Kconfig"
if ! grep -q 'drivers/rust_core/Kconfig' "$KCONFIG"; then
    echo ">>> Patche $KCONFIG"
    # Vor das abschließende 'endmenu' einfügen
    sed -i 's@^endmenu@source "drivers/rust_core/Kconfig"\n\nendmenu@' "$KCONFIG"
else
    echo ">>> $KCONFIG bereits gepatcht"
fi

# --- drivers/Makefile: obj-Zeile idempotent anhängen -----------------------
DMAKE="$KDIR/drivers/Makefile"
if ! grep -q 'obj-\$(CONFIG_RUST_CORE)' "$DMAKE"; then
    echo ">>> Patche $DMAKE"
    printf '\nobj-$(CONFIG_RUST_CORE) += rust_core/\n' >> "$DMAKE"
else
    echo ">>> $DMAKE bereits gepatcht"
fi

cat <<EOF

============================================================================
 rust_core in den Kernelbaum integriert.

 Nächste Schritte (im Kernelverzeichnis $KDIR):

   make LLVM=1 defconfig
   ./scripts/kconfig/merge_config.sh .config \\
       $SELF_DIR/kernel-config-rust.fragment
   make LLVM=1 olddefconfig
   make LLVM=1 rustavailable        # muss "Rust is available!" zeigen
   make LLVM=1 -j\$(nproc)

 Modul laden & testen:
   sudo insmod drivers/rust_core/rust_core.ko    # bzw. modprobe nach install
   ls -l /dev/rust_core
   sudo dmesg | tail
   cc $SELF_DIR/rust_core_test.c -o /tmp/rust_core_test && sudo /tmp/rust_core_test
============================================================================
EOF
