#!/usr/bin/env bash
#
# 00-setup-lfs-env.sh
# ---------------------------------------------------------------------------
# BEREICH 1.1 — LFS Host-Vorbereitung
#
# Setzt die LFS-Umgebungsvariablen, legt die Verzeichnisstruktur an, erzeugt
# den Benutzer 'lfs' mit korrekten Rechten und schreibt eine saubere
# Login-Umgebung (.bash_profile / .bashrc) für den lfs-Benutzer.
#
# Ausführen als root:
#     sudo bash 01-lfs-toolchain/00-setup-lfs-env.sh /mnt/lfs
#
# Danach:
#     sudo su - lfs        # Wechsel in die saubere lfs-Umgebung
#
# Getestet gegen LFS 12.x (SysVinit-Variante).
# ---------------------------------------------------------------------------
set -euo pipefail

# --- 1) Konfiguration ------------------------------------------------------
export LFS="${1:-/mnt/lfs}"          # Mountpoint des LFS-Dateisystems
LFS_FS_DEV="${LFS_FS_DEV:-}"         # optional: Blockgerät, das nach $LFS gemountet wird
LFS_GROUP="lfs"
LFS_USER="lfs"

echo ">>> LFS Root          : $LFS"
echo ">>> Optionales Device : ${LFS_FS_DEV:-<keins, nutze bestehendes Mount>}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "FEHLER: Dieses Skript muss als root laufen." >&2
    exit 1
fi

# --- 2) Verzeichnisstruktur ------------------------------------------------
mkdir -pv "$LFS"

# Optional ein dediziertes Dateisystem nach $LFS mounten
if [[ -n "$LFS_FS_DEV" ]]; then
    if ! mountpoint -q "$LFS"; then
        echo ">>> Mounte $LFS_FS_DEV nach $LFS"
        mount -v -t ext4 "$LFS_FS_DEV" "$LFS"
    fi
fi

# Standard-LFS-Layout
mkdir -pv "$LFS"/{etc,var,usr,tools,sources}
mkdir -pv "$LFS"/usr/{bin,lib,sbin}

for d in bin lib sbin; do
    case "$d" in
        lib) ln -sfv usr/lib "$LFS/lib" ;;
        *)   ln -sfv "usr/$d" "$LFS/$d" ;;
    esac
done

# 64-Bit Hosts: separates lib64
case "$(uname -m)" in
    x86_64) mkdir -pv "$LFS/lib64" ;;
esac

# Quellverzeichnis mit Sticky-Bit (jeder darf eigene Dateien anlegen)
mkdir -pv "$LFS/sources"
chmod -v a+wt "$LFS/sources"

# --- 3) Benutzer 'lfs' anlegen --------------------------------------------
if ! getent group "$LFS_GROUP" >/dev/null; then
    groupadd "$LFS_GROUP"
fi

if ! id "$LFS_USER" >/dev/null 2>&1; then
    useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
    echo ">>> Setze Passwort für '$LFS_USER' (interaktiv):"
    passwd "$LFS_USER" || echo "WARN: Passwort konnte nicht gesetzt werden (non-interaktiv?)."
fi

# lfs-Benutzer bekommt die Eigentümerschaft über das Toolchain-Layout
chown -v "$LFS_USER" "$LFS"/{usr{,/*},lib,var,etc,bin,sbin,tools,sources}
case "$(uname -m)" in
    x86_64) chown -v "$LFS_USER" "$LFS/lib64" ;;
esac

# --- 4) Saubere Login-Umgebung für 'lfs' ----------------------------------
cat > "/home/$LFS_USER/.bash_profile" <<'EOF'
# Startet eine neue, von Host-Variablen befreite Login-Shell.
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat > "/home/$LFS_USER/.bashrc" <<EOF
set +h                       # Pfad-Hashing deaktivieren (frisch installierte Tools sofort finden)
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=\$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE

# Parallelisierung: an die Anzahl der CPU-Kerne anpassen
export MAKEFLAGS="-j\$(nproc)"
EOF

chown "$LFS_USER:$LFS_GROUP" "/home/$LFS_USER/.bash_profile" "/home/$LFS_USER/.bashrc"

# --- 5) Zusammenfassung ----------------------------------------------------
cat <<EOF

============================================================================
 LFS-Umgebung vorbereitet.

   LFS root  : $LFS
   Benutzer  : $LFS_USER  (Gruppe $LFS_GROUP)
   LFS_TGT   : $(uname -m)-lfs-linux-gnu

 Nächste Schritte:
   1) Quellpakete nach \$LFS/sources legen (siehe packages.md).
   2) In die lfs-Umgebung wechseln:   sudo su - lfs
   3)    echo \$LFS \$LFS_TGT \$PATH    # Variablen prüfen
   4) Cross-Toolchain bauen:          bash 02-build-cross-toolchain.sh
============================================================================
EOF
