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
# Verwendung (DEFAULT = komplettes System mit Kernel-Kompilierung):
#
#   ./build.sh                       # STANDARD: lädt Linux 6.13, richtet die
#                                    # Toolchain ein, kompiliert Kernel +
#                                    # rust_core und baut die ISO
#   ./build.sh --kernel-ver 6.13     # andere Kernel-Version laden + bauen
#   ./build.sh --kernel-src /pfad/zu/linux-6.13   # eigenen Quellbaum bauen
#   ./build.sh --kernel-image /boot/vmlinuz-x.y   # vorhandenes bzImage (Demo)
#   ./build.sh --rootfs /mnt/lfs     # ein fertiges (rohes) Rootfs einpacken
#   ./build.sh --distro /pfad/zur/distro-rootfs   # KOMPLETTE Distro: bootet per
#                                    # Autologin direkt in einen Sway/Wayland-
#                                    # Desktop mit KI-Chat-Widget + Mojo-Daemon.
#                                    # Fehlende Desktop-Pakete (sway, foot, ...)
#                                    # werden per chroot best-effort nachinstalliert.
#   ./build.sh --distro-user name    # Autologin-Benutzer (Default: ai)
#   ./build.sh --use-mojo-binary     # echten Mojo-Daemon statt Python-Mock
#   ./build.sh --out /tmp/my.iso
#   ./build.sh --no-test             # nicht in QEMU testen
#   ./build.sh --demo                # Demo-ISO: BusyBox-Rootfs + Host-Kernel
#
# Abhängigkeiten (Host): xorriso, grub-mkrescue (grub-pc-bin/grub-efi-amd64-bin),
#                        cpio, gzip, find; für BusyBox: busybox(-static).
# Der Kernel-Build braucht clang/llvm + rustc (+ rust-src) + bindgen — diese
# werden im STANDARD-Modus bei vorhandenem apt/rustup automatisch eingerichtet.
# ===========================================================================
set -euo pipefail

# --- Pfade -----------------------------------------------------------------
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$SELF/.build}"
ROOTFS="$WORK/rootfs"
ISODIR="$WORK/iso"
OUT="$SELF/my-kernel.iso"

# --- Standard-Optionen (komplett-System aktiviert) -------------------------
BUILD_KERNEL=1                      # Standard: echten Rust-Kernel selbst bauen
KERNEL_VER="6.13"                   # Linux-Version, die geladen + gebaut wird
KERNEL_SRC=""                       # leer => Quellen werden heruntergeladen
KERNEL_IMAGE=""
EXT_ROOTFS="$SELF/../lfs-root"     # Standard: LFS-Rootfs falls vorhanden
DISTRO_ROOTFS=""                    # --distro: komplette Distro-Rootfs -> Wayland-Desktop
DISTRO_USER="ai"                    # Autologin-Benutzer der Distro-Sitzung
USE_MOJO=0                          # Python-Mock per default
RUN_TEST=1                          # Test per default aktiviert
DEMO_MODE=0                         # kein Demo-Modus per default
BINDGEN_VERSION="0.69.4"           # mit Linux 6.13 verifizierte bindgen-Version

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,50p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-src)       KERNEL_SRC="$2"; BUILD_KERNEL=0; shift 2 ;;
        --kernel-ver)       KERNEL_VER="$2"; shift 2 ;;
        --kernel-image)     KERNEL_IMAGE="$2"; KERNEL_SRC=""; BUILD_KERNEL=0; shift 2 ;;
        --rootfs)           EXT_ROOTFS="$2"; shift 2 ;;
        --distro)           DISTRO_ROOTFS="$2"; shift 2 ;;
        --distro-user)      DISTRO_USER="$2"; shift 2 ;;
        --out)              OUT="$2"; shift 2 ;;
        --use-mojo-binary)  USE_MOJO=1; shift ;;
        --no-test)          RUN_TEST=0; shift ;;
        --demo)             DEMO_MODE=1; BUILD_KERNEL=0; KERNEL_SRC=""; EXT_ROOTFS=""; shift ;;
        -h|--help)          usage ;;
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

    # Hinweis: Die Kernel-/Rust-Toolchain (clang/llvm, rustc, bindgen) wird bei
    # BUILD_KERNEL=1 automatisch von setup_kernel_toolchain eingerichtet und
    # daher hier NICHT als harte Voraussetzung geprüft.

    # BusyBox nur für das Minimal-Rootfs nötig (nicht bei --distro/--rootfs).
    if [[ -z "$DISTRO_ROOTFS" && ! -d "$EXT_ROOTFS" ]]; then
        command -v busybox >/dev/null 2>&1 || missing+=("busybox")
    fi

    # Distro-Modus benötigt chroot (util-linux/coreutils) für die Einrichtung.
    if [[ -n "$DISTRO_ROOTFS" ]]; then
        command -v chroot >/dev/null 2>&1 || missing+=("chroot")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Fehlende Tools: ${missing[*]}
  Ubuntu/Debian:  sudo apt-get install -y xorriso grub-pc-bin grub-efi-amd64-bin mtools cpio busybox-static qemu-system-x86 clang llvm rustc bindgen"
    fi
    ok "Alle benötigten Tools vorhanden."
}

# ===========================================================================
# 1a) Toolchain für den Rust-Kernel-Build einrichten (clang/llvm, rustc, bindgen)
# ===========================================================================
setup_kernel_toolchain() {
    log "Richte Toolchain für den Rust-Kernel-Build ein ..."
    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq || warn "apt-get update fehlgeschlagen — fahre fort."
        $SUDO apt-get install -y clang lld llvm libclang-dev flex bison \
            libelf-dev libssl-dev bc kmod cpio >&2 \
            || warn "apt-Installation unvollständig — prüfe Tools manuell."
    else
        warn "Kein apt-get gefunden — clang/llvm/flex/bison/libelf/libssl bitte manuell bereitstellen."
    fi

    # Rust-Toolchain (rustc + rust-src + bindgen)
    if ! command -v rustc >/dev/null 2>&1 && ! command -v rustup >/dev/null 2>&1; then
        die "rustc/rustup nicht gefunden. Bitte Rust installieren: https://rustup.rs"
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    if command -v rustup >/dev/null 2>&1; then
        rustup component add rust-src >&2 2>&1 || warn "rust-src konnte nicht hinzugefügt werden."
    fi
    if ! command -v bindgen >/dev/null 2>&1; then
        log "Installiere bindgen-cli $BINDGEN_VERSION ..."
        cargo install --locked bindgen-cli --version "$BINDGEN_VERSION" >&2 \
            || die "bindgen-Installation fehlgeschlagen."
    fi

    local t
    for t in clang rustc bindgen; do
        command -v "$t" >/dev/null 2>&1 || die "Pflicht-Tool fehlt nach Setup: $t"
    done
    ok "Kernel-Toolchain bereit: clang/llvm + rustc $(rustc --version | awk '{print $2}') + bindgen."
}

# ===========================================================================
# 1b) Linux-Quellcode herunterladen und entpacken (-> Pfad auf stdout)
# ===========================================================================
fetch_kernel_source() {
    local ver="$1"
    local maj="${ver%%.*}"
    local dst="$WORK/linux-$ver"
    if [[ -f "$dst/Makefile" ]]; then
        log "Nutze bereits entpackten Quellbaum $dst" >&2
        echo "$dst"; return 0
    fi
    mkdir -p "$WORK"
    local tarball="$WORK/linux-$ver.tar.xz"
    local url="https://cdn.kernel.org/pub/linux/kernel/v${maj}.x/linux-$ver.tar.xz"
    if [[ ! -f "$tarball" ]]; then
        log "Lade Linux-$ver-Quellcode: $url" >&2
        if command -v curl >/dev/null 2>&1; then
            curl -fSL "$url" -o "$tarball" >&2 || die "Download fehlgeschlagen: $url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$tarball" "$url" >&2 || die "Download fehlgeschlagen: $url"
        else
            die "Weder curl noch wget vorhanden — kann Kernel-Quellen nicht laden."
        fi
    fi
    log "Entpacke $tarball nach $dst ..." >&2
    ( cd "$WORK" && tar xf "$tarball" )
    [[ -f "$dst/Makefile" ]] || die "Quellbaum $dst unvollständig."
    echo "$dst"
}

# ===========================================================================
# 1c) Kompatibilitäts-Patches für neuere Rust-Toolchains
# ===========================================================================
# Neuere Versionen von clippy (Rust ≥ 1.78) behandeln `useless_transmute` in
# den von bindgen generierten Dateien als harten Fehler. Diese Transmutes sind
# korrekt (bindgen nutzt sie für bitfield-Zugriffe auf u8), aber clippy hält
# sie für unnötig, weil Quell- und Zieltyp identisch sind. Wir erlauben den
# Lint auf Crate-Ebene in den betroffenen Dateien, ohne den restlichen
# Kernel-Code zu beeinflussen.
patch_kernel_rust_compat() {
    local ksrc="$1"
    log "Patche Rust-Bindings für Kompatibilität mit neuerer Toolchain ..."
    local patched=0
    for f in "$ksrc/rust/bindings/lib.rs" "$ksrc/rust/uapi/lib.rs"; do
        if [[ -f "$f" ]] && ! grep -q 'clippy::useless_transmute' "$f"; then
            sed -i '1i #![allow(clippy::useless_transmute)]' "$f"
            patched=$((patched + 1))
        fi
    done
    if [[ $patched -gt 0 ]]; then
        ok "Rust-Kompatibilitäts-Patch: $patched Datei(en) angepasst."
    else
        log "Rust-Kompatibilitäts-Patch: bereits vorhanden oder nicht nötig."
    fi
}

# ===========================================================================
# 1) Kernel beschaffen (bauen / kopieren)
# ===========================================================================
prepare_kernel() {
    mkdir -p "$ISODIR/boot"
    # STANDARD: echten Rust-Kernel selbst bauen — Toolchain einrichten und
    # Linux-Quellen herunterladen, falls kein Quellbaum vorgegeben wurde.
    if [[ "$BUILD_KERNEL" -eq 1 && -z "$KERNEL_SRC" ]]; then
        setup_kernel_toolchain
        KERNEL_SRC="$(fetch_kernel_source "$KERNEL_VER")"
    fi
    if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC/Makefile" ]]; then
        log "Baue Kernel inkl. rust_core aus $KERNEL_SRC ..."
        bash "$SELF/02-kernel-rust/install-into-kernel.sh" "$KERNEL_SRC"
        patch_kernel_rust_compat "$KERNEL_SRC"
        ( cd "$KERNEL_SRC"
          export PATH="$HOME/.cargo/bin:$PATH"
          [[ -f .config ]] || make LLVM=1 defconfig
          ./scripts/kconfig/merge_config.sh .config \
              "$SELF/02-kernel-rust/kernel-config-rust.fragment"
          make LLVM=1 olddefconfig
          make LLVM=1 rustavailable
          make LLVM=1 -j"$(nproc)" bzImage modules )
        cp -v "$KERNEL_SRC/arch/x86/boot/bzImage" "$ISODIR/boot/vmlinuz"
        # rust_core.ko ins Rootfs übernehmen (falls als Modul gebaut)
        find "$KERNEL_SRC/drivers/rust_core" -name 'rust_core.ko' \
            -exec cp -v {} "$ROOTFS/rust_core.ko" \; 2>/dev/null || true
    elif [[ -n "$KERNEL_SRC" ]]; then
        die "$KERNEL_SRC ist kein Kernel-Source-Tree (keine Makefile gefunden)."
    elif [[ -n "$KERNEL_IMAGE" ]]; then
        log "Nutze vorhandenes Kernel-Image $KERNEL_IMAGE"
        [[ -f "$KERNEL_IMAGE" ]] || die "Kernel-Image $KERNEL_IMAGE nicht gefunden."
        cp -v "$KERNEL_IMAGE" "$ISODIR/boot/vmlinuz"
    else
        log "Kein Kernel angegeben — nutze Host-Kernel (Demo-Modus)."
        local hk; hk="$(find_host_kernel)"
        if [[ -z "$hk" ]]; then
            warn "Kein Host-Kernel in /boot gefunden — beschaffe automatisch einen generischen Kernel ..."
            hk="$(acquire_demo_kernel)" || true
        fi
        [[ -n "$hk" && -f "$hk" ]] || die "Kein bootfähiger Kernel verfügbar.
  Installiere ein Kernel-Paket (z. B. 'sudo apt-get install -y linux-image-generic')
  oder nutze --kernel-src /pfad/zu/linux-6.13 bzw. --kernel-image /pfad/zu/bzImage."
        cp -v "$hk" "$ISODIR/boot/vmlinuz"
        warn "Demo nutzt Host-Kernel ohne rust_core. Für rust_core: --kernel-src verwenden."
    fi
    ok "Kernel bereit: $ISODIR/boot/vmlinuz"
}

# Sucht einen vorhandenen vmlinuz auf dem Host; gibt den Pfad auf stdout aus.
find_host_kernel() {
    local hk
    hk="/boot/vmlinuz-$(uname -r)"
    [[ -f "$hk" ]] && { echo "$hk"; return 0; }
    hk="$(ls -1 /boot/vmlinuz-* /boot/vmlinuz 2>/dev/null | head -n1 || true)"
    [[ -n "$hk" && -f "$hk" ]] && echo "$hk"
    return 0
}

# Beschafft im Demo-Modus automatisch einen Kernel: erst per apt (linux-image-*),
# sonst als direkter Download des Debian-Netboot-Kernels. Pfad -> stdout.
# Alle Status-/Tool-Ausgaben gehen nach stderr, damit stdout nur den Pfad enthält.
acquire_demo_kernel() {
    local sudo=""
    [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo="sudo"

    if command -v apt-get >/dev/null 2>&1; then
        log "Installiere generischen Kernel via apt ..." >&2
        $sudo apt-get update -qq >&2 || true
        local pkg found
        for pkg in linux-image-generic linux-image-amd64 linux-image-cloud-amd64 linux-image-virtual; do
            if $sudo apt-get install -y --no-install-recommends "$pkg" >&2; then
                ok "Kernel-Paket $pkg installiert." >&2
                found="$(find_host_kernel)"
                [[ -n "$found" ]] && { echo "$found"; return 0; }
            fi
        done
        warn "apt konnte kein Kernel-Paket installieren — versuche Direkt-Download ..." >&2
    fi

    # Fallback: Debian-Netboot-Kernel (stabiler Pfad) direkt herunterladen.
    local url="https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux"
    local dst="$WORK/netboot-vmlinuz"
    if command -v curl >/dev/null 2>&1; then
        log "Lade Debian-Netboot-Kernel herunter ..." >&2
        curl -fsSL "$url" -o "$dst" >&2 && [[ -s "$dst" ]] && { echo "$dst"; return 0; }
    elif command -v wget >/dev/null 2>&1; then
        log "Lade Debian-Netboot-Kernel herunter ..." >&2
        wget -qO "$dst" "$url" >&2 && [[ -s "$dst" ]] && { echo "$dst"; return 0; }
    fi
    return 1
}

# ===========================================================================
# 2) Rootfs zusammenstellen
# ===========================================================================
prepare_rootfs() {
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,usr/bin,usr/local/bin,var/log}

    # --- KOMPLETTE Distro-Rootfs (-> Sway/Wayland-Desktop, systemd als PID1) ---
    if [[ -n "$DISTRO_ROOTFS" ]]; then
        [[ -d "$DISTRO_ROOTFS" ]] || die "Distro-Rootfs $DISTRO_ROOTFS nicht gefunden."
        [[ -x "$DISTRO_ROOTFS/sbin/init" || -L "$DISTRO_ROOTFS/sbin/init" || -e "$DISTRO_ROOTFS/lib/systemd/systemd" ]] \
            || warn "In $DISTRO_ROOTFS ist kein /sbin/init bzw. systemd erkennbar — Boot könnte fehlschlagen."
        log "Kopiere komplette Distro-Rootfs aus $DISTRO_ROOTFS (das kann dauern) ..."
        # Leeres Zielverzeichnis: moderne Distros nutzen usrmerge (/bin -> /usr/bin
        # als Symlink), das sich nicht über vorab angelegte Verzeichnisse kopieren
        # lässt.
        rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
        cp -a "$DISTRO_ROOTFS"/. "$ROOTFS"/
        install_components
        configure_distro_desktop
        ok "Distro-Rootfs (Wayland-Desktop) bereit unter $ROOTFS"
        return 0
    fi

    if [[ -d "$EXT_ROOTFS" ]]; then
        log "Kopiere externes Rootfs aus $EXT_ROOTFS ..."
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
        # Im Distro-Modus bringt die Distro ihren eigenen python3 mit.
        if [[ -z "$DISTRO_ROOTFS" && ( -z "$EXT_ROOTFS" || ! -d "$EXT_ROOTFS" ) ]]; then
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

# ===========================================================================
# 2b) KOMPLETTE Distro -> Sway/Wayland-Desktop mit KI-Chat einrichten
# ---------------------------------------------------------------------------
# Erwartet ein bereits nach $ROOTFS kopiertes, vollständiges Distro-Rootfs
# (systemd-basiert). Richtet ein: Autologin-Benutzer, Sway-Session auf TTY1,
# Autostart des Chat-Widgets, Aktivierung von mojo-ai.service + rust_core.ko.
# Fehlende Desktop-Pakete werden – falls ein Paketmanager vorhanden ist – per
# chroot best-effort nachinstalliert.
# ===========================================================================

# Führt ein Kommando im $ROOTFS-chroot aus (mit gemounteten virtuellen FS).
run_in_distro_chroot() {
    local cmd="$1"
    mount --bind /proc    "$ROOTFS/proc"    2>/dev/null || true
    mount --bind /sys     "$ROOTFS/sys"     2>/dev/null || true
    mount --bind /dev     "$ROOTFS/dev"     2>/dev/null || true
    mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
    local rc=0
    chroot "$ROOTFS" /bin/sh -c "$cmd" || rc=$?
    umount "$ROOTFS/dev/pts" 2>/dev/null || true
    umount "$ROOTFS/dev"     2>/dev/null || true
    umount "$ROOTFS/sys"     2>/dev/null || true
    umount "$ROOTFS/proc"    2>/dev/null || true
    return $rc
}

# Installiert die Desktop-Pakete best-effort (überspringt fehlende einzeln).
install_distro_desktop_packages() {
    if [[ -x "$ROOTFS/usr/bin/apt-get" ]]; then
        if chroot "$ROOTFS" /bin/sh -c 'command -v sway >/dev/null 2>&1'; then
            ok "Sway bereits in der Distro vorhanden — überspringe Paketinstallation."
            return 0
        fi
        log "Installiere Wayland-Desktop-Pakete in die Distro-Rootfs (apt) ..."
        cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
        run_in_distro_chroot 'DEBIAN_FRONTEND=noninteractive apt-get update -qq' || \
            warn "apt-get update fehlgeschlagen — Paketinstallation evtl. unvollständig."
        local pkgs="sway foot grim wofi fonts-dejavu-core dbus dbus-user-session \
            libgl1-mesa-dri seatd kmod python3 python3-gi gir1.2-gtk-3.0 \
            gir1.2-gtklayershell-0.1"
        local p
        for p in $pkgs; do
            run_in_distro_chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $p" \
                || warn "Paket '$p' konnte nicht installiert werden (übersprungen)."
        done
    else
        warn "Kein apt-get in der Distro-Rootfs gefunden — überspringe automatische Paketinstallation."
        warn "Stelle sicher, dass sway, foot, python3-gi, gir1.2-gtk-3.0 vorab installiert sind."
    fi
}

configure_distro_desktop() {
    [[ "$(id -u)" -eq 0 ]] || die "--distro benötigt root-Rechte (nutze: sudo ./build.sh --distro ...)."
    log "Richte Sway/Wayland-Desktop + KI-Autostart in der Distro ein ..."

    install_distro_desktop_packages

    # --- Autologin-Benutzer anlegen (idempotent) ---------------------------
    if ! chroot "$ROOTFS" id "$DISTRO_USER" >/dev/null 2>&1; then
        log "Lege Benutzer '$DISTRO_USER' an ..."
        run_in_distro_chroot "useradd -m -s /bin/bash -G video,render,input,audio,tty \"$DISTRO_USER\" || adduser --disabled-password --gecos '' \"$DISTRO_USER\"" \
            || warn "Benutzeranlage via chroot fehlgeschlagen."
        # Passwort leeren (Autologin braucht keins).
        run_in_distro_chroot "passwd -d \"$DISTRO_USER\"" 2>/dev/null || true
    fi
    local home="/home/$DISTRO_USER"
    install -d "$ROOTFS$home/.config/sway"

    # --- Sway-Konfiguration (Bereich 4) als Standard-Session ---------------
    cp -v "$SELF/04-desktop-widget/sway/config" "$ROOTFS$home/.config/sway/config"
    install -d "$ROOTFS/etc/sway"
    cp -f "$SELF/04-desktop-widget/sway/config" "$ROOTFS/etc/sway/config"

    # --- Autostart der Wayland-Sitzung auf TTY1 (~/.bash_profile) ----------
    cat > "$ROOTFS$home/.bash_profile" <<'PROFILEEOF'
# MY-KERNEL: startet beim Autologin auf TTY1 direkt die Sway/Wayland-Sitzung.
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    [ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"; }
    export XDG_SESSION_TYPE=wayland
    export WLR_RENDERER=pixman          # reines Software-Rendering (kein GPU nötig)
    export WLR_NO_HARDWARE_CURSORS=1
    # Log in ein benutzerschreibbares Verzeichnis (NICHT /var/log — root-only).
    mkdir -p "$HOME/.local/state"
    exec sway >"$HOME/.local/state/sway.log" 2>&1
fi
PROFILEEOF
    cp -f "$ROOTFS$home/.bash_profile" "$ROOTFS$home/.profile"

    # Eigentümer der Home-Dateien korrekt setzen.
    local uid gid
    uid="$(chroot "$ROOTFS" id -u "$DISTRO_USER" 2>/dev/null || echo 1000)"
    gid="$(chroot "$ROOTFS" id -g "$DISTRO_USER" 2>/dev/null || echo 1000)"
    chown -R "$uid:$gid" "$ROOTFS$home" 2>/dev/null || true

    # --- getty@tty1 Autologin (systemd-Drop-in) ----------------------------
    install -d "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
    cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $DISTRO_USER --noclear %I \$TERM
EOF

    # --- mojo-ai.service (Bereich 3) installieren + aktivieren -------------
    local exec_line
    if [[ "$USE_MOJO" -eq 1 ]]; then
        exec_line="/usr/local/bin/mojo_ai_daemon /run/mojo_ai.sock"
    else
        exec_line="/usr/bin/python3 /usr/local/bin/mojo_ai_daemon.py --sock /run/mojo_ai.sock"
    fi
    cat > "$ROOTFS/etc/systemd/system/mojo-ai.service" <<EOF
[Unit]
Description=Mojo AI Inference Daemon (Unix socket /run/mojo_ai.sock)
After=network.target

[Service]
Type=simple
ExecStart=$exec_line
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 25); do [ -S /run/mojo_ai.sock ] && break; sleep 0.2; done; chmod 0666 /run/mojo_ai.sock || true'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    # --- rust_core.ko beim Boot laden (Bereich 2) --------------------------
    cat > "$ROOTFS/etc/systemd/system/rust_core.service" <<'EOF'
[Unit]
Description=Lade das rust_core-Kernelmodul (/dev/rust_core)
After=systemd-modules-load.service
ConditionPathExists=/rust_core.ko

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/insmod /rust_core.ko

[Install]
WantedBy=multi-user.target
EOF

    # --- Dienste aktivieren (Symlinks, da systemctl im chroot oft fehlt) ---
    install -d "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sf ../mojo-ai.service   "$ROOTFS/etc/systemd/system/multi-user.target.wants/mojo-ai.service"
    ln -sf ../rust_core.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/rust_core.service"

    # Auf Multi-User booten (Autologin auf TTY1 startet Sway); kein Display-Manager.
    ln -sf /lib/systemd/system/multi-user.target "$ROOTFS/etc/systemd/system/default.target"

    # systemd als reales Root behandeln (kein Initrd-Modus im tmpfs-Root).
    rm -f "$ROOTFS/etc/initrd-release" 2>/dev/null || true

    ok "Distro-Desktop konfiguriert: Autologin '$DISTRO_USER' -> Sway, Widget + mojo-ai.service aktiv."
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

# Auf den Socket warten (statt fixem sleep) — vermeidet Race beim Selbsttest.
i=0
while [ ! -S /run/mojo_ai.sock ] && [ "$i" -lt 50 ]; do
    sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
done

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
    # Sicherheitshalber evtl. zurückgebliebene chroot-Bind-Mounts lösen, damit
    # cpio nicht in Host-/proc//sys/ hineinläuft.
    for m in dev/pts dev sys proc; do
        mountpoint -q "$ROOTFS/$m" 2>/dev/null && umount -l "$ROOTFS/$m" 2>/dev/null || true
    done
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

    # Im Distro-Modus ist die Distro-Rootfs selbst das Initramfs (tmpfs-Root):
    # systemd wird via rdinit=/sbin/init als PID 1 gestartet und bootet den
    # Wayland-Desktop. Im Standard-/BusyBox-Modus läuft unser /init-Skript.
    local kcmdline="console=tty0 console=ttyS0,115200 rust_core.metrics=1"
    if [[ -n "$DISTRO_ROOTFS" ]]; then
        kcmdline="$kcmdline rdinit=/sbin/init rw"
    fi

    cat > "$ISODIR/boot/grub/grub.cfg" <<GRUBEOF
serial --unit=0 --speed=115200
terminal_input  serial console
terminal_output serial console
set default=0
set timeout=3

menuentry "MY-KERNEL (LFS + rust_core + Mojo-AI)" {
    echo "Lade Kernel ..."
    linux  /boot/vmlinuz $kcmdline
    echo "Lade Initramfs ..."
    initrd /boot/initramfs.img
}
menuentry "MY-KERNEL (verbose / debug)" {
    linux  /boot/vmlinuz $kcmdline debug
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

    # --- Distro-Modus: grafischer Boot, Screenshot des Wayland-Desktops -----
    if [[ -n "$DISTRO_ROOTFS" ]]; then
        local shot="$WORK/desktop.ppm" png="$SELF/desktop.png"
        log "Boote Distro-ISO in QEMU (virtio-gpu, ~70s) und erstelle Screenshot ..."
        ( sleep 60; printf 'screendump %s\n' "$shot"; sleep 3; printf 'quit\n' ) \
            | timeout 90 qemu-system-x86_64 -m 3072 -cdrom "$OUT" \
                -device virtio-gpu-pci -display none -vga none \
                -serial file:"$WORK/distro-serial.log" -monitor stdio -no-reboot \
                >/dev/null 2>&1 || true
        if [[ -f "$shot" ]] && command -v convert >/dev/null 2>&1; then
            convert "$shot" "$png" 2>/dev/null && ok "Desktop-Screenshot: $png"
        elif [[ -f "$shot" ]]; then
            ok "Desktop-Screenshot (PPM): $shot"
        else
            warn "Konnte keinen Screenshot erzeugen — siehe $WORK/distro-serial.log"
        fi
        grep -aE 'sway|mojo-ai|rust_core|Reached target|systemd' "$WORK/distro-serial.log" 2>/dev/null | tail -15 || true
        return 0
    fi

    log "Boote ISO in QEMU (seriell, bis zu 90s) ..."
    timeout 90 qemu-system-x86_64 -m 768 -cdrom "$OUT" \
        -nographic -serial mon:stdio -no-reboot 2>&1 \
        | grep -aE 'MY-KERNEL|rust_core|/dev/rust_core|\[init\]|mock-ai|Intent=|Selbsttest|KI-Konsole' \
        || true
}

# ===========================================================================
main() {
    log "MY-KERNEL ISO-Build startet (WORK=$WORK)"
    if [[ -n "$DISTRO_ROOTFS" ]]; then
        log "Modus: DISTRO (komplette Distro-Rootfs -> Sway/Wayland-Desktop mit KI-Chat)"
    else
        log "Modus: $([ "$DEMO_MODE" -eq 1 ] && echo 'DEMO' || echo 'STANDARD (komplettes System mit Kernel-Kompilierung)')"
    fi
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

 Hinweise zum Customizen:
   * Standard baut den echten Rust-Kernel (Linux $KERNEL_VER + rust_core).
   * Eigener Quellbaum: ./build.sh --kernel-src /pfad/zu/linux-6.13
   * Andere Version: ./build.sh --kernel-ver 6.13
   * Schneller Demo-Modus (ohne rust_core): ./build.sh --demo
   * Benutzer-Rootfs: ./build.sh --rootfs /mnt/lfs
   * Komplette Distro -> Wayland-Desktop: sudo ./build.sh --distro /pfad/zur/distro-rootfs
   * Echten Mojo-Daemon: ./build.sh --use-mojo-binary
   * Test deaktivieren: ./build.sh --no-test
============================================================================
EOF
}

main "$@"
