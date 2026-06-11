# MY-KERNEL — LFS + Rust-Kernel + Mojo-KI + Desktop-Chat-Widget

Maßgeschneidertes Linux-System auf Basis von **Linux From Scratch (LFS)** mit:

1. **Bereich 1** — LFS-Host-Vorbereitung & automatisierte Cross-Toolchain
2. **Bereich 2** — Linux-Kernel mit In-Tree-**Rust**-Support + eigenes Rust-Kernelmodul (`/dev/rust_core`)
3. **Bereich 3** — **Mojo**-KI-Inferenz-Engine als Hintergrunddienst auf einem Unix-Socket
4. **Bereich 4** — Minimaler Window-Manager (Sway/X11) + transparentes, randloses KI-**Chat-Widget**

Die Komponenten sind über den Unix Domain Socket `/run/mojo_ai.sock` (bzw.
`/var/run/mojo_ai.sock`) entkoppelt: Das Desktop-Widget sendet Text, der
Mojo-Daemon rechnet, die Antwort fließt zurück ins Widget.

```
 ┌────────────────────┐   text   ┌────────────────────┐   ioctl   ┌──────────────────┐
 │  Chat-Widget (GTK) │ ───────► │  Mojo-AI-Daemon    │           │  Kernel: Rust    │
 │  Bereich 4         │ ◄─────── │  Bereich 3 (SIMD)  │           │  /dev/rust_core  │
 └────────────────────┘  reply   └────────────────────┘           │  Bereich 2       │
        Desktop                  /run/mojo_ai.sock                 └──────────────────┘
                                  Bereich 1 = LFS-Fundament für alles
```

> **Realitätscheck / Grenzen**
> - Ein vollständiger LFS- und Kernel-Build dauert auf dedizierter Hardware
>   Stunden und kann nicht in einer CI-Umgebung end-to-end ausgeführt werden.
> - Das **Mojo-SDK** (Modular MAX) ist proprietär und in CI nicht frei baubar.
>   Daher liegt zusätzlich ein **bytegleicher Python-Mock-Daemon**
>   (`03-mojo-ai/mock_daemon.py`) bei, mit dem sich das Widget und die gesamte
>   Brücke ohne Mojo testen lassen.
> - Das Rust-Kernelmodul ist gegen die offizielle In-Tree-Rust-API (Kernel 6.13)
>   geschrieben; die exakte API ändert sich zwischen Kernelversionen.

---

## Alles zu einer bootfähigen ISO bauen — `build.sh`

`build.sh` bündelt alle 4 Bereiche zu einer hybriden (BIOS+UEFI) ISO
(`my-kernel.iso`). Die ISO bootet per GRUB einen Kernel + ein Initramfs; das
Initramfs startet den AI-Daemon und öffnet eine TTY-Chat-Konsole — inklusive
automatischem End-to-End-Selbsttest im Boot-Log.

```bash
# Demo-ISO (BusyBox-Rootfs + Host-Kernel + gebündeltes Python + AI-Daemon):
./build.sh

# Mit echtem Rust-Kernel (baut rust_core in den Kernel ein):
./build.sh --kernel-src /pfad/zu/linux-6.13

# Vollständiges LFS-Rootfs einpacken / echten Mojo-Daemon nutzen:
./build.sh --rootfs /mnt/lfs --use-mojo

# In QEMU testen:
qemu-system-x86_64 -m 768 -cdrom my-kernel.iso -nographic -serial mon:stdio
# oder direkt:  ./build.sh --test
```

Pipeline: `check_deps → prepare_rootfs (BusyBox/LFS + Python + Komponenten) →
prepare_kernel (bauen/kopieren) → make_initramfs (cpio+gzip) → make_iso
(grub.cfg + grub-mkrescue)`. Host-Abhängigkeiten: `xorriso`, `grub-mkrescue`
(`grub-pc-bin`/`grub-efi-amd64-bin`), `cpio`, `busybox-static`, optional
`qemu-system-x86`.

Verifiziert: Die Demo-ISO bootet in QEMU, lädt `/init`, startet den AI-Daemon
auf `/run/mojo_ai.sock` und der Selbsttest liefert `AI-Selbsttest: PASS` mit
echter Socket-Antwort.

---

## Verzeichnis- & Dateiübersicht (mit Ziel-Ablagepfaden)

### Bereich 1 — `01-lfs-toolchain/`
| Datei | Zweck | Ziel auf dem System |
|-------|-------|---------------------|
| `00-setup-lfs-env.sh` | `$LFS`/`$LFS_TGT`/PATH setzen, Layout anlegen, Benutzer `lfs` | Host, als root |
| `01-mount-virtual-fs.sh` | `$LFS/{dev,proc,sys,run}` mounten + chroot-Aufruf | Host, als root |
| `03-umount-virtual-fs.sh` | virtuelle FS wieder aushängen | Host, als root |
| `02-build-cross-toolchain.sh` | Binutils/GCC/Glibc/libstdc++ Cross-Toolchain | als `lfs`, baut nach `$LFS/tools` |
| `packages.md` | Paket-/Versionsliste + Downloadbefehle | — |

### Bereich 2 — `02-kernel-rust/`
| Datei | Zweck | Ziel auf dem System |
|-------|-------|---------------------|
| `kernel-config-rust.fragment` | `.config`-Flags (`CONFIG_RUST=y`, …) | in Kernel-`.config` mergen |
| `rust_core/rust_core.rs` | Rust-Kernelmodul: Misc-Char-Device | `drivers/rust_core/` im Kernelbaum |
| `rust_core/Kbuild` | In-Tree-Build-Regel | `drivers/rust_core/` |
| `rust_core/Kconfig` | `CONFIG_RUST_CORE` | `drivers/rust_core/` |
| `rust_core/Makefile` | Komfort-Wrapper (`make KDIR=…`) | — |
| `install-into-kernel.sh` | integriert das Modul + patcht `drivers/Kconfig`/`Makefile` | Host |
| `rust_core_test.c` | Userspace-ioctl-Test für `/dev/rust_core` | Host |

### Bereich 3 — `03-mojo-ai/`
| Datei | Zweck | Ziel auf dem System |
|-------|-------|---------------------|
| `mojo_ai_daemon.mojo` | Daemon, Unix-Socket, FFI zu libc | `/usr/local/bin/mojo_ai_daemon` |
| `inference.mojo` | SIMD-Matmul-Inferenz + optional llama.cpp-FFI | mit Daemon gebaut |
| `mojo-ai.service` | systemd-Unit | `/etc/systemd/system/` |
| `mojo-ai.init` | SysVinit-Bootscript (LFS) | `/etc/rc.d/init.d/` |
| `client_test.py` | CLI-Testclient | Host |
| `mock_daemon.py` | bytegleicher Python-Ersatz für Tests | Host |

### Bereich 4 — `04-desktop-widget/`
| Datei | Zweck | Ziel auf dem System |
|-------|-------|---------------------|
| `sway/config` | Wayland-Sitzung + Widget-Autostart | `~/.config/sway/config` |
| `xinitrc` | X11-Sitzung (Openbox + picom) + Widget | `~/.xinitrc` |
| `chat_widget.py` | randloses, transparentes Chat-Widget + Socket-Brücke | `/usr/local/bin/mojo-chat-widget` |

---

## Schnellstart der einzelnen Bereiche

### Bereich 1 — LFS-Umgebung & Toolchain
```bash
sudo bash 01-lfs-toolchain/00-setup-lfs-env.sh /mnt/lfs
sudo su - lfs
echo $LFS $LFS_TGT $PATH                     # Variablen prüfen
# Tarballs nach $LFS/sources legen (siehe packages.md), dann:
bash /pfad/zu/MY-KERNEL/01-lfs-toolchain/02-build-cross-toolchain.sh
# Vor chroot:
sudo bash 01-lfs-toolchain/01-mount-virtual-fs.sh /mnt/lfs
```

### Bereich 2 — Kernel mit Rust + rust_core
```bash
cd linux-6.13
bash /pfad/zu/MY-KERNEL/02-kernel-rust/install-into-kernel.sh "$PWD"
make LLVM=1 defconfig
./scripts/kconfig/merge_config.sh .config \
    /pfad/zu/MY-KERNEL/02-kernel-rust/kernel-config-rust.fragment
make LLVM=1 olddefconfig
make LLVM=1 rustavailable          # muss "Rust is available!" melden
make LLVM=1 -j"$(nproc)"
# Modul laden & testen:
sudo insmod drivers/rust_core/rust_core.ko
cc /pfad/zu/MY-KERNEL/02-kernel-rust/rust_core_test.c -o /tmp/t && sudo /tmp/t
```

### Bereich 3 — Mojo-AI-Daemon
```bash
# Mit Mojo-SDK:
mojo build 03-mojo-ai/mojo_ai_daemon.mojo -o /usr/local/bin/mojo_ai_daemon
sudo cp 03-mojo-ai/mojo-ai.service /etc/systemd/system/
sudo systemctl enable --now mojo-ai.service
python3 03-mojo-ai/client_test.py --sock /run/mojo_ai.sock "Hallo KI"

# Ohne Mojo-SDK (Test mit Python-Mock):
python3 03-mojo-ai/mock_daemon.py --sock /tmp/ai.sock &
python3 03-mojo-ai/client_test.py --sock /tmp/ai.sock "Hallo KI"
```

### Bereich 4 — Desktop-Widget
```bash
sudo install -m 0755 04-desktop-widget/chat_widget.py /usr/local/bin/mojo-chat-widget
# X11:    cp 04-desktop-widget/xinitrc ~/.xinitrc && startx
# Wayland:cp 04-desktop-widget/sway/config ~/.config/sway/config && sway
# Lokaltest gegen den Mock:
python3 03-mojo-ai/mock_daemon.py --sock /tmp/ai.sock &
./04-desktop-widget/chat_widget.py --sock /tmp/ai.sock
```

---

## Socket-Protokoll
Zeilenbasiert über `AF_UNIX`/`SOCK_STREAM`:
- **Request:** UTF-8-Text + `\n`
- **Response:** `[mojo-ai] Intent=<Klasse> | Eingabe-Laenge=<n> | Antwort: …\n`

Identisch in `mojo_ai_daemon.mojo`/`inference.mojo` und `mock_daemon.py`.
