# BEREICH 1.3 — Paketliste & Download

Alle Tarballs gehören nach `$LFS/sources`. Die Versionen unten entsprechen dem
LFS-12.x-Stand; bei Bedarf in `02-build-cross-toolchain.sh` (Variablen am
Dateianfang) anpassen.

## Toolchain-Kernpakete (zwingend für Bereich 1)

| Paket    | Version | URL |
|----------|---------|-----|
| binutils | 2.42    | https://sourceware.org/pub/binutils/releases/binutils-2.42.tar.xz |
| gcc      | 13.2.0  | https://ftp.gnu.org/gnu/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz |
| glibc    | 2.39    | https://ftp.gnu.org/gnu/glibc/glibc-2.39.tar.xz |
| linux    | 6.7.4   | https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.7.4.tar.xz |
| gmp      | 6.3.0   | https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz |
| mpfr     | 4.2.1   | https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz |
| mpc      | 1.3.1   | https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz |

## Zusätzlich für KERNEL-Rust-Support (Bereich 2)

Rust-In-Tree benötigt eine **exakt** zur Kernel-Version passende Rust- und
bindgen-Version. `make rustavailable` im Kernel-Source nennt die geforderten
Versionen. Für Kernel 6.7.x typischerweise:

| Paket   | Version  | Bezug |
|---------|----------|-------|
| rustc   | 1.74.x   | `rustup toolchain install 1.74.1` |
| rust-src| 1.74.x   | `rustup component add rust-src` |
| bindgen | 0.65.x   | `cargo install --locked bindgen-cli --version 0.65.1` |
| clang/LLVM | >= 11 | als Host-Paket (LFS-BLFS `llvm`) |

## Zusätzlich für Mojo / Desktop (Bereiche 3 & 4)

| Komponente | Bezug |
|------------|-------|
| Mojo SDK (MAX) | `curl -fsSL https://pixi.sh/install.sh \| bash` → `magic` CLI, dann `magic global install max` (proprietäres SDK von Modular, kein freier CI-Build) |
| Wayland / wayland-protocols | BLFS |
| Sway + wlroots | BLFS / Quellbau |
| GTK4 + PyGObject + Cairo | BLFS (für das Python-Chat-Widget) |

## Beispiel: Download per wget-Liste

```bash
sudo su - lfs
cd $LFS/sources
cat > wget-list <<'EOF'
https://sourceware.org/pub/binutils/releases/binutils-2.42.tar.xz
https://ftp.gnu.org/gnu/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz
https://ftp.gnu.org/gnu/glibc/glibc-2.39.tar.xz
https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.7.4.tar.xz
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz
https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz
EOF
wget --input-file=wget-list --continue --directory-prefix=$LFS/sources
```
