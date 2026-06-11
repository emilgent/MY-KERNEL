#!/usr/bin/env bash
#
# build.sh — Baut alle 4 Bereiche zu einer bootfähigen ISO zusammen.
# ===========================================================================
# Erzeugt eine hybride (BIOS+UEFI) ISO `my-kernel.iso`, die das maßgeschneiderte
# System aus diesem Repo bündelt:
#
#   * Bereich 2: Linux-Kernel inkl. In-Tree-Rust-Modul `rust_core`
#   * Bereich 3: Mojo-AI-Daemon (bzw. der bytegleiche Python-Mock) auf
#                /run/mojo_ai.sock, automatisch beim Boot gestartet
#   * Bereich 4: Desktop/Chat-Komponenten in das Rootfs installiert
#   * Bereich 1: nutzt optional ein fertig gebautes LFS-Rootfs
#
# Die ISO bootet per GRUB einen Kernel + ein Initramfs. Das Initramfs startet
# den AI-Daemon und einen TTY-Chat-Client, sodass man direkt an der Konsole
# (z. B. in QEMU) mit der KI chatten kann — ein lauffähiger End-to-End-Beweis.
#
# ---------------------------------------------------------------------------
# Verwendung:
#
#   ./build.sh                       # Demo-ISO: BusyBox-Rootfs + Host-Kernel
#   ./build.sh --kernel-src /pfad/zu/linux-6.13   # baut Kernel + rust_core mit
#   ./build.sh --kernel-image /boot/vmlinuz-x.y   # vorhandenes bzImage nutzen
#   ./build.sh --rootfs /mnt/lfs     # ein fertiges LFS-Rootfs einpacken
#   ./build.sh --use-mojo            # echten Mojo-Daemon statt Python-Mock
#   ./build.sh --out /tmp/my.iso
#   ./build.sh --test                # nach dem Bau in QEMU booten (falls vorhanden)
#
# Abhängigkeiten (Host): xorriso, grub-mkrescue (grub-pc-bin/grub-efi-amd64-bin),
#                        cpio, gzip, find; für --busybox: busybox(-static);
#                        für --kernel-src: clang/llvm + rustc + bindgen.
# ===========================================================================
set -euo pipefail

# --- Pfade -----------------------------------------------------------------
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$SELF/.build}"
ROOTFS="$WORK/rootfs"
ISODIR="$WORK/iso"
OUT="$SELF/my-kernel.iso"

# --- Optionen --------------------------------------------------------------
KERNEL_SRC=""
KERNEL_IMAGE=""
EXT_ROOTFS=""
USE_MOJO=0
RUN_TEST=0

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-src)   KERNEL_SRC="$2"; shift 2 ;;
        --kernel-image) KERNEL_IMAGE="$2"; shift 2 ;;
        --rootfs)       EXT_ROOTFS="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        --use-mojo)     USE_MOJO=1; shift ;;
        --test)         RUN_TEST=1; shift ;;
        -h|--help)      usage ;;
        *) die "Unbekannte Option: $1 (siehe --help)" ;;
    esac
done

# ===========================================================================
# 0) Abhängigkeiten prüfen
# ===========================================================================
check_deps() {
    log "Prüfe Host-Abhängigkeiten ..."
    local missing=()
    for t in xorriso cpio gzip find; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    command -v grub-mkrescue >/dev/null 2>&1 || missing+=("grub-mkrescue")
    if [[ -z "$EXT_ROOTFS" ]]; then
        command -v busybox >/dev/null 2>&1 || missing+=("busybox")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Fehlende Tools: ${missing[*]}
  Ubuntu/Debian:  sudo apt-get install -y xorriso grub-pc-bin grub-efi-amd64-bin mtools cpio busybox-static qemu-system-x86"
    fi
    ok "Alle benötigten Tools vorhanden."
}

# ===========================================================================
# 1) Kernel beschaffen (bauen / kopieren)
# ===========================================================================
prepare_kernel() {
    mkdir -p "$ISODIR/boot"
    if [[ -n "$KERNEL_SRC" ]]; then
        log "Baue Kernel inkl. rust_core aus $KERNEL_SRC ..."
        [[ -f "$KERNEL_SRC/Makefile" ]] || die "$KERNEL_SRC ist kein Kernel-Source-Tree."
        bash "$SELF/02-kernel-rust/install-into-kernel.sh" "$KERNEL_SRC"
        ( cd "$KERNEL_SRC"
          [[ -f .config ]] || make LLVM=1 defconfig
          ./scripts/kconfig/merge_config.sh .config \
              "$SELF/02-kernel-rust/kernel-config-rust.fragment"
          make LLVM=1 olddefconfig
          make LLVM=1 rustavailable
          make LLVM=1 -j"$(nproc)" )
        cp -v "$KERNEL_SRC/arch/x86/boot/bzImage" "$ISODIR/boot/vmlinuz"
        # rust_core.ko ins Rootfs übernehmen (falls als Modul gebaut)
        find "$KERNEL_SRC/drivers/rust_core" -name 'rust_core.ko' \
            -exec cp -v {} "$ROOTFS/rust_core.ko" \; 2>/dev/null || true
    elif [[ -n "$KERNEL_IMAGE" ]]; then
        log "Nutze vorhandenes Kernel-Image $KERNEL_IMAGE"
        [[ -f "$KERNEL_IMAGE" ]] || die "Kernel-Image $KERNEL_IMAGE nicht gefunden."
        cp -v "$KERNEL_IMAGE" "$ISODIR/boot/vmlinuz"
    else
        log "Kein Kernel angegeben — nutze Host-Kernel (Demo-Modus)."
        local hk
        hk="/boot/vmlinuz-$(uname -r)"
        [[ -f "$hk" ]] || hk="$(ls -1 /boot/vmlinuz-* 2>/dev/null | head -n1 || true)"
        [[ -n "$hk" && -f "$hk" ]] || die "Kein Host-Kernel in /boot gefunden. Nutze --kernel-src oder --kernel-image."
        cp -v "$hk" "$ISODIR/boot/vmlinuz"
        warn "Demo nutzt Host-Kernel ohne rust_core. Für rust_core: --kernel-src verwenden."
    fi
    ok "Kernel bereit: $ISODIR/boot/vmlinuz"
}

# ===========================================================================
# 2) Rootfs zusammenstellen
# ===========================================================================
prepare_rootfs() {
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,usr/bin,usr/local/bin,var/log}

    if [[ -n "$EXT_ROOTFS" ]]; then
        log "Kopiere externes Rootfs aus $EXT_ROOTFS ..."
        [[ -d "$EXT_ROOTFS" ]] || die "Rootfs-Verzeichnis $EXT_ROOTFS existiert nicht."
        cp -a "$EXT_ROOTFS"/. "$ROOTFS"/
    else
        log "Erzeuge minimales BusyBox-Rootfs ..."
        local bb; bb="$(command -v busybox)"
        cp "$bb" "$ROOTFS/bin/busybox"
        ( cd "$ROOTFS/bin" && for app in sh ash env ls cat mount umount mkdir ln echo \
            sleep cp mv rm ps kill chmod insmod rmmod lsmod dmesg getty login \
            printf grep sed head tail which; do
              ln -sf busybox "$app"; done )
        # env auch unter /usr/bin/env bereitstellen (Shebangs nutzen /usr/bin/env).
        ln -sf /bin/env "$ROOTFS/usr/bin/env"
    fi

    install_components
    write_init
    ok "Rootfs bereit unter $ROOTFS"
}

# --- Bereich 3 + 4 in das Rootfs installieren ------------------------------
install_components() {
    log "Installiere Mojo-AI + Desktop-Komponenten ins Rootfs ..."
    install -d "$ROOTFS/usr/local/bin" "$ROOTFS/etc/rc.d/init.d"

    if [[ "$USE_MOJO" -eq 1 ]]; then
        local mojobin="/usr/local/bin/mojo_ai_daemon"
        if [[ -x "$mojobin" ]]; then
            cp -v "$mojobin" "$ROOTFS/usr/local/bin/mojo_ai_daemon"
        else
            warn "Mojo-Binary $mojobin fehlt — baue es mit: mojo build 03-mojo-ai/mojo_ai_daemon.mojo -o $mojobin"
            warn "Falle auf den Python-Mock zurück."
            USE_MOJO=0
        fi
    fi

    if [[ "$USE_MOJO" -eq 0 ]]; then
        # Python-Mock + Interpreter müssen im Rootfs vorhanden sein.
        cp -v "$SELF/03-mojo-ai/mock_daemon.py" "$ROOTFS/usr/local/bin/mojo_ai_daemon.py"
        if [[ -z "$EXT_ROOTFS" ]]; then
            bundle_python
        fi
    fi

    # TTY-Chat-Client (Konsolen-Brücke) + Desktop-Widget für ein volles Rootfs.
    write_tty_client
    cp -v "$SELF/04-desktop-widget/chat_widget.py" "$ROOTFS/usr/local/bin/mojo-chat-widget"
    cp -v "$SELF/03-mojo-ai/client_test.py" "$ROOTFS/usr/local/bin/ai-client"
    cp -v "$SELF/03-mojo-ai/mojo-ai.init"  "$ROOTFS/etc/rc.d/init.d/mojo-ai"
    chmod +x "$ROOTFS/usr/local/bin/"* "$ROOTFS/etc/rc.d/init.d/mojo-ai" 2>/dev/null || true
}

# --- Eigenständigen Python-Interpreter ins Rootfs bündeln ------------------
# Kopiert den echten python3-Binary, seine via ldd ermittelten Shared Libraries
# (pfadtreu) sowie die Standardbibliothek, damit der Mock-Daemon im Initramfs
# ohne Host-Python läuft. Bei fehlendem Python wird nur gewarnt.
bundle_python() {
    # Bevorzugt den System-Python unter /usr/bin (echtes ELF, Stdlib in /usr/lib),
    # da pyenv-Shims keine eigenständig kopierbaren Binaries sind.
    local py=""
    for cand in /usr/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
        cand="$(readlink -f "$cand" 2>/dev/null || true)"
        if [[ -n "$cand" && -x "$cand" ]] && file "$cand" 2>/dev/null | grep -q ELF; then
            py="$cand"; break
        fi
    done
    if [[ -z "$py" ]]; then
        warn "Kein eigenständiger python3-ELF-Binary gefunden — AI-Daemon im Initramfs deaktiviert."
        return 0
    fi

    local ver; ver="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    log "Bündle Python $ver aus $py ins Rootfs ..."
    install -D "$py" "$ROOTFS/usr/bin/python3"

    # Shared Libraries pfadtreu kopieren (inkl. ld-linux Loader).
    ldd "$py" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u | while read -r lib; do
        [[ -f "$lib" ]] && install -D "$lib" "$ROOTFS$lib"
    done

    # Standardbibliothek + dynamische Module (ohne Tests/pyc zur Platzersparnis).
    local stdlib="/usr/lib/python$ver"
    if [[ -d "$stdlib" ]]; then
        mkdir -p "$ROOTFS$stdlib"
        ( cd "$stdlib" && find . -path ./test -prune -o -name '__pycache__' -prune \
            -o -type f -print0 | cpio -0 -pdm --quiet "$ROOTFS$stdlib" )
    fi
    # lib-dynload separat sicherstellen (für socket/_socket etc.)
    for d in "/usr/lib/python$ver/lib-dynload" "$stdlib/lib-dynload"; do
        [[ -d "$d" ]] && { mkdir -p "$ROOTFS$d"; cp -a "$d"/. "$ROOTFS$d"/ 2>/dev/null || true; }
    done
    ok "Python $ver gebündelt."
}

# --- TTY-Chat-Client (reines Python, ohne GUI) -----------------------------
write_tty_client() {
    cat > "$ROOTFS/usr/local/bin/ai-chat" <<'PYEOF'
#!/usr/bin/env python3
"""Konsolen-Chat gegen den AI-Daemon (Brücke ohne GUI, fürs Initramfs)."""
import socket, sys
SOCK = sys.argv[1] if len(sys.argv) > 1 else "/run/mojo_ai.sock"
print("== MY-KERNEL KI-Konsole ==  (Strg-C zum Beenden)")
while True:
    try:
        text = input("du> ").strip()
    except (EOFError, KeyboardInterrupt):
        print(); break
    if not text:
        continue
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5.0); s.connect(SOCK)
            s.sendall((text + "\n").encode())
            data = b""
            while True:
                b = s.recv(4096)
                if not b: break
                data += b
        print("ai>", data.decode("utf-8", "replace").strip())
    except OSError as e:
        print(f"[Fehler] {SOCK}: {e}")
PYEOF
    chmod +x "$ROOTFS/usr/local/bin/ai-chat"
}

# --- /init des Initramfs ---------------------------------------------------
write_init() {
    log "Schreibe /init (Initramfs-Startskript) ..."
    cat > "$ROOTFS/init" <<'INITEOF'
#!/bin/sh
# Initramfs-Init: virtuelle FS mounten, AI-Daemon starten, Chat-Konsole öffnen.
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin
mount -t proc     proc  /proc  2>/dev/null
mount -t sysfs    sysfs /sys   2>/dev/null
mount -t devtmpfs dev   /dev   2>/dev/null || mount -t tmpfs tmpfs /dev
mount -t tmpfs    tmpfs /run   2>/dev/null

echo ""
echo "================ MY-KERNEL ================"
uname -a 2>/dev/null

# rust_core laden, falls als Modul vorhanden (Bereich 2)
if [ -f /rust_core.ko ]; then
    echo "[init] lade rust_core.ko ..."
    insmod /rust_core.ko 2>/dev/null && echo "[init] /dev/rust_core bereit" || echo "[init] rust_core konnte nicht geladen werden"
fi

# AI-Daemon im Hintergrund starten (Bereich 3)
if [ -x /usr/local/bin/mojo_ai_daemon ]; then
    echo "[init] starte Mojo-AI-Daemon ..."
    /usr/local/bin/mojo_ai_daemon /run/mojo_ai.sock &
elif [ -f /usr/local/bin/mojo_ai_daemon.py ] && command -v python3 >/dev/null 2>&1; then
    echo "[init] starte Python-AI-Daemon (Mock) ..."
    python3 /usr/local/bin/mojo_ai_daemon.py --sock /run/mojo_ai.sock &
else
    echo "[init] WARN: kein AI-Daemon im Rootfs (python3 fehlt?)."
fi
sleep 1

# Automatischer End-to-End-Selbsttest (Beweis im Boot-Log)
if command -v python3 >/dev/null 2>&1 && [ -x /usr/local/bin/ai-client ]; then
    echo "[init] --- AI Selbsttest ---"
    if python3 /usr/local/bin/ai-client --sock /run/mojo_ai.sock "Hallo aus dem Initramfs"; then
        echo "[init] AI-Selbsttest: PASS"
    else
        echo "[init] AI-Selbsttest: FAIL"
    fi
    echo "[init] -----------------------"
fi

# Interaktive Chat-Konsole (Brücke), Bereich 4 — nur bei vorhandenem TTY.
if command -v python3 >/dev/null 2>&1 && [ -t 0 ]; then
    /usr/local/bin/ai-chat /run/mojo_ai.sock
fi

echo "[init] Starte Shell. 'ai-chat' erneut aufrufbar."
exec /bin/sh
INITEOF
    chmod +x "$ROOTFS/init"
}

# ===========================================================================
# 3) Initramfs packen
# ===========================================================================
make_initramfs() {
    log "Packe Initramfs (cpio + gzip) ..."
    ( cd "$ROOTFS" && find . -print0 \
        | cpio --null --create --format=newc 2>/dev/null \
        | gzip -9 ) > "$ISODIR/boot/initramfs.img"
    ok "Initramfs: $ISODIR/boot/initramfs.img ($(du -h "$ISODIR/boot/initramfs.img" | cut -f1))"
}

# ===========================================================================
# 4) GRUB-Konfiguration + ISO erzeugen
# ===========================================================================
make_iso() {
    log "Erzeuge GRUB-Konfiguration ..."
    mkdir -p "$ISODIR/boot/grub"
    cat > "$ISODIR/boot/grub/grub.cfg" <<'GRUBEOF'
serial --unit=0 --speed=115200
terminal_input  serial console
terminal_output serial console
set default=0
set timeout=3

menuentry "MY-KERNEL (LFS + rust_core + Mojo-AI)" {
    echo "Lade Kernel ..."
    linux  /boot/vmlinuz console=tty0 console=ttyS0,115200 rust_core.metrics=1
    echo "Lade Initramfs ..."
    initrd /boot/initramfs.img
}
menuentry "MY-KERNEL (verbose / debug)" {
    linux  /boot/vmlinuz console=tty0 console=ttyS0,115200 debug
    initrd /boot/initramfs.img
}
GRUBEOF

    log "Baue ISO mit grub-mkrescue -> $OUT ..."
    grub-mkrescue -o "$OUT" "$ISODIR" 2>&1 | grep -vE '^xorriso|libisofs|GNU GRUB|Drive|Media|Volume|Added|Writing|ISO image' || true
    [[ -f "$OUT" ]] || die "ISO wurde nicht erzeugt."
    ok "Fertige ISO: $OUT ($(du -h "$OUT" | cut -f1))"
}

# ===========================================================================
# 5) Optionaler QEMU-Boottest
# ===========================================================================
run_test() {
    [[ "$RUN_TEST" -eq 1 ]] || return 0
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        warn "qemu-system-x86_64 nicht installiert — überspringe Boottest."
        return 0
    fi
    log "Boote ISO in QEMU (seriell, 20s) ..."
    timeout 20 qemu-system-x86_64 -m 512 -cdrom "$OUT" \
        -nographic -serial mon:stdio -no-reboot 2>&1 | head -40 || true
}

# ===========================================================================
main() {
    log "MY-KERNEL ISO-Build startet (WORK=$WORK)"
    rm -rf "$ISODIR"
    mkdir -p "$ISODIR/boot"
    check_deps
    prepare_rootfs
    prepare_kernel
    make_initramfs
    make_iso
    run_test
    cat <<EOF

============================================================================
 ISO erstellt: $OUT

 In QEMU testen:
   qemu-system-x86_64 -m 512 -cdrom "$OUT" -nographic -serial mon:stdio

 Auf USB-Stick schreiben (VORSICHT, /dev/sdX ersetzen):
   sudo dd if="$OUT" of=/dev/sdX bs=4M status=progress oflag=sync

 Hinweise:
   * Für den echten Rust-Kernel: ./build.sh --kernel-src /pfad/zu/linux-6.13
   * Für ein vollständiges grafisches System: ./build.sh --rootfs /mnt/lfs
   * Für den echten Mojo-Daemon: ./build.sh --use-mojo (Binary vorher bauen)
============================================================================
EOF
}

main "$@"
