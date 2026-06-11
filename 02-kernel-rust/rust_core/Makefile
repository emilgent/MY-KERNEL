# SPDX-License-Identifier: GPL-2.0
# BEREICH 2.3 — Komfort-Makefile zum Bauen von rust_core über den Kernelbaum
#
# Rust-Kernelmodule werden über das Kernel-Build-System gebaut (LLVM=1). Dieses
# Makefile ist ein dünner Wrapper, der das Modul aus dem integrierten Pfad
# heraus baut. Es setzt voraus, dass install-into-kernel.sh das Verzeichnis
# bereits nach $(KDIR)/drivers/rust_core kopiert und Kconfig/Makefile des
# Kernels gepatcht hat (CONFIG_RUST_CORE=m).
#
# Verwendung:
#   make KDIR=/pfad/zum/linux-<ver>           # baut rust_core.ko
#   make KDIR=/pfad/zum/linux-<ver> modules_install
#   make KDIR=/pfad/zum/linux-<ver> clean
#
# Hinweis: CONFIG_RUST + passende rustc/bindgen-Versionen müssen vorhanden sein
# ("make LLVM=1 rustavailable" im Kernelbaum muss erfolgreich sein).

KDIR ?= /lib/modules/$(shell uname -r)/build
LLVM ?= 1

.PHONY: all modules modules_install clean help

all: modules

modules:
	$(MAKE) -C $(KDIR) LLVM=$(LLVM) M=drivers/rust_core modules

modules_install:
	$(MAKE) -C $(KDIR) LLVM=$(LLVM) M=drivers/rust_core modules_install
	depmod -a

clean:
	$(MAKE) -C $(KDIR) LLVM=$(LLVM) M=drivers/rust_core clean

help:
	@echo "Targets: all|modules (Standard), modules_install, clean"
	@echo "Variablen: KDIR=<kernel-source>, LLVM=1"
