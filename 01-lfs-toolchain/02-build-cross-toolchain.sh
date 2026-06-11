#!/usr/bin/env bash
#
# 02-build-cross-toolchain.sh
# ---------------------------------------------------------------------------
# BEREICH 1.3 — Cross-Toolchain (Binutils, GCC, Linux-Header, Glibc, libstdc++)
#
# Dieses Skript MUSS als Benutzer 'lfs' in der sauberen Umgebung laufen
# (siehe 00-setup-lfs-env.sh):
#
#     sudo su - lfs
#     bash 02-build-cross-toolchain.sh
#
# Es baut die temporäre Cross-Toolchain nach $LFS/tools. Diese erzeugt einen
# Compiler ($LFS_TGT-gcc), mit dem anschließend Glibc, danach die nativen
# X11/Wayland-Bibliotheken und schließlich das Mojo-SDK sauber gegen die
# LFS-Glibc gelinkt werden können.
#
# Paketversionen siehe packages.md. Tarballs müssen in $LFS/sources liegen.
# Geprüft gegen LFS 12.x.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${LFS:?LFS ist nicht gesetzt — bist du als 'lfs' in der sauberen Umgebung? (sudo su - lfs)}"
: "${LFS_TGT:?LFS_TGT ist nicht gesetzt}"

SRC="$LFS/sources"
cd "$SRC"

# Versionen (an packages.md / heruntergeladene Tarballs anpassen)
BINUTILS_VER="${BINUTILS_VER:-2.42}"
GCC_VER="${GCC_VER:-13.2.0}"
GLIBC_VER="${GLIBC_VER:-2.39}"
LINUX_VER="${LINUX_VER:-6.7.4}"
MPFR_VER="${MPFR_VER:-4.2.1}"
GMP_VER="${GMP_VER:-6.3.0}"
MPC_VER="${MPC_VER:-1.3.1}"

msg() { printf '\n\033[1;32m>>> %s\033[0m\n' "$*"; }

extract() {  # extract <tarball-glob> -> echo verzeichnis
    local tb; tb=$(ls "$SRC"/$1 2>/dev/null | head -n1)
    [[ -n "$tb" ]] || { echo "FEHLER: Tarball $1 fehlt in $SRC" >&2; exit 1; }
    tar -xf "$tb"
    basename "$tb" | sed -E 's/\.tar\.(xz|gz|bz2)$//'
}

# ===========================================================================
# 1) Binutils — Pass 1
# ===========================================================================
msg "Binutils Pass 1 ($BINUTILS_VER)"
d=$(extract "binutils-${BINUTILS_VER}.tar.*")
( cd "$d" && mkdir -v build && cd build &&
  ../configure --prefix="$LFS/tools" \
               --with-sysroot="$LFS" \
               --target="$LFS_TGT"   \
               --disable-nls         \
               --enable-gprofng=no   \
               --disable-werror      \
               --enable-default-hash-style=gnu &&
  make &&
  make install )
rm -rf "$d"

# ===========================================================================
# 2) GCC — Pass 1 (nur C, statisch, kein Header-Bedarf)
# ===========================================================================
msg "GCC Pass 1 ($GCC_VER)"
d=$(extract "gcc-${GCC_VER}.tar.*")
(
  cd "$d"
  # Math-Bibliotheken in den GCC-Baum entpacken (in-tree build)
  tar -xf "$SRC"/mpfr-${MPFR_VER}.tar.* && mv -v mpfr-${MPFR_VER} mpfr
  tar -xf "$SRC"/gmp-${GMP_VER}.tar.*   && mv -v gmp-${GMP_VER}   gmp
  tar -xf "$SRC"/mpc-${MPC_VER}.tar.*   && mv -v mpc-${MPC_VER}   mpc

  # 64-Bit: lib64 statt lib als Default-Verzeichnis
  case "$(uname -m)" in
    x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
  esac

  mkdir -v build && cd build
  ../configure                                   \
      --target="$LFS_TGT"                        \
      --prefix="$LFS/tools"                      \
      --with-glibc-version="$GLIBC_VER"          \
      --with-sysroot="$LFS"                      \
      --with-newlib                              \
      --without-headers                          \
      --enable-default-pie                       \
      --enable-default-ssp                       \
      --disable-nls                              \
      --disable-shared                           \
      --disable-multilib                         \
      --disable-threads                          \
      --disable-libatomic                        \
      --disable-libgomp                          \
      --disable-libquadmath                      \
      --disable-libssp                           \
      --disable-libvtv                           \
      --disable-libstdcxx                        \
      --enable-languages=c,c++
  make
  make install

  # Internen Header limits.h vervollständigen (LFS-Standardschritt)
  cd ..
  cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      "$(dirname "$("$LFS/tools/bin/$LFS_TGT-gcc" -print-libgcc-file-name)")/include/limits.h"
)
rm -rf "$d"

# ===========================================================================
# 3) Linux API Headers
# ===========================================================================
msg "Linux API Headers ($LINUX_VER)"
d=$(extract "linux-${LINUX_VER}.tar.*")
( cd "$d" &&
  make mrproper &&
  make headers &&
  find usr/include -type f ! -name '*.h' -delete &&
  cp -rv usr/include "$LFS/usr" )
rm -rf "$d"

# ===========================================================================
# 4) Glibc (gegen die Cross-Toolchain)
# ===========================================================================
msg "Glibc ($GLIBC_VER)"
d=$(extract "glibc-${GLIBC_VER}.tar.*")
(
  cd "$d"
  # Kompatibilitäts-Symlinks für den Loader (LFS-Standard)
  case "$(uname -m)" in
    i?86)   ln -sfv ld-linux.so.2 "$LFS/lib/ld-lsb.so.3" ;;
    x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3" ;;
  esac

  mkdir -v build && cd build
  echo "rootsbindir=/usr/sbin" > configparms
  ../configure                              \
      --prefix=/usr                         \
      --host="$LFS_TGT"                      \
      --build="$(../scripts/config.guess)"  \
      --enable-kernel=4.19                  \
      --with-headers="$LFS/usr/include"     \
      --disable-nscd                        \
      libc_cv_slibdir=/usr/lib
  make
  make DESTDIR="$LFS" install

  # Loader-Pfad in ldd-Skript korrigieren (LFS-Standard)
  sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"
)
rm -rf "$d"

# Sanity-Check: ein triviales Programm muss mit der neuen Toolchain linken
msg "Sanity-Check der Cross-Toolchain"
echo 'int main(void){return 0;}' > /tmp/lfs-dummy.c
"$LFS/tools/bin/$LFS_TGT-gcc" /tmp/lfs-dummy.c -o /tmp/lfs-dummy
readelf -l /tmp/lfs-dummy | grep -q 'ld-linux' \
    && echo "OK: Programm nutzt den LFS-Loader." \
    || { echo "FEHLER: Loader-Pfad falsch."; exit 1; }
rm -f /tmp/lfs-dummy.c /tmp/lfs-dummy

# ===========================================================================
# 5) libstdc++ aus GCC (Pass 1) — wird für C++-Tools (u. a. LLVM/Mojo) gebraucht
# ===========================================================================
msg "libstdc++ ($GCC_VER)"
d=$(extract "gcc-${GCC_VER}.tar.*")
(
  cd "$d"
  mkdir -v build && cd build
  ../libstdc++-v3/configure            \
      --host="$LFS_TGT"                \
      --build="$(../config.guess)"     \
      --prefix=/usr                    \
      --disable-multilib               \
      --disable-nls                    \
      --disable-libstdcxx-pch          \
      --with-gxx-include-dir="/tools/$LFS_TGT/include/c++/$GCC_VER"
  make
  make DESTDIR="$LFS" install
  # Nicht benötigte libtool-Archive entfernen
  rm -v "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la
)
rm -rf "$d"

cat <<EOF

============================================================================
 Cross-Toolchain fertig in \$LFS/tools.

 Damit später Mojo (LLVM-basiert) und die X11/Wayland-Stacks nativ gegen die
 LFS-Glibc bauen, folgen im LFS-Buch als Nächstes die "temporären Tools"
 (m4, ncurses, bash, coreutils, make, ... ) und danach das eigentliche
 native System im chroot.

 Compiler-Aufruf zum Test:
   \$LFS_TGT-gcc --version
   \$LFS_TGT-g++ --version
============================================================================
EOF
