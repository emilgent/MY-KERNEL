// SPDX-License-Identifier: GPL-2.0
//
// BEREICH 2.2 — rust_core
// ===========================================================================
// Ein echtes, ladbares Linux-Kernel-Modul in Rust, das ein Misc-Charakter-
// Gerät unter /dev/rust_core registriert. Es nutzt ausschließlich die
// offiziellen In-Tree-Rust-Abstraktionen (`kernel::prelude`,
// `kernel::miscdevice`, `kernel::uaccess`, `kernel::sync::Mutex`).
//
// Funktionsumfang:
//   * /dev/rust_core wird beim Laden des Moduls automatisch angelegt.
//   * Pro `open()` wird ein globaler Öffnungszähler (Kernel-Metrik) erhöht.
//   * Über ioctl() kann der Userspace:
//       - RUST_CORE_SET_VALUE : einen i32-Wert im Gerät speichern,
//       - RUST_CORE_GET_VALUE : diesen Wert zurücklesen,
//       - RUST_CORE_GET_OPENS : die Metrik "Anzahl der open()-Aufrufe" lesen,
//       - RUST_CORE_HELLO     : eine Log-Nachricht ins Kernel-Log schreiben.
//
// Ziel-Kernel: 6.13 (In-Tree-Rust, `MiscDevice`-Abstraktion).
// Build: siehe Kbuild / Makefile in diesem Verzeichnis.
// ===========================================================================

use core::sync::atomic::{AtomicU64, Ordering};

use kernel::{
    c_str,
    device::Device,
    fs::File,
    ioctl::{_IO, _IOC_SIZE, _IOR, _IOW},
    miscdevice::{MiscDevice, MiscDeviceOptions, MiscDeviceRegistration},
    new_mutex,
    prelude::*,
    sync::Mutex,
    types::ARef,
    uaccess::{UserSlice, UserSliceReader, UserSliceWriter},
};

// --- ioctl-Kommandonummern (müssen mit dem Userspace-Header übereinstimmen) -
const RUST_CORE_IOCTL_MAGIC: u32 = b'R' as u32;

const RUST_CORE_GET_VALUE: u32 = _IOR::<i32>(RUST_CORE_IOCTL_MAGIC, 0x80);
const RUST_CORE_SET_VALUE: u32 = _IOW::<i32>(RUST_CORE_IOCTL_MAGIC, 0x81);
const RUST_CORE_GET_OPENS: u32 = _IOR::<u64>(RUST_CORE_IOCTL_MAGIC, 0x82);
const RUST_CORE_HELLO: u32 = _IO(RUST_CORE_IOCTL_MAGIC, 0x83);

// Globale Metrik: wie oft wurde das Gerät seit dem Laden des Moduls geöffnet?
static OPEN_COUNT: AtomicU64 = AtomicU64::new(0);

module! {
    type: RustCoreModule,
    name: "rust_core",
    author: "MY-KERNEL Project",
    description: "Rust char misc device exposing a value and open-count metric at /dev/rust_core",
    license: "GPL",
}

/// Modul-Wurzelstruktur: hält die Registrierung des Misc-Geräts am Leben.
/// Solange diese Struktur existiert, existiert /dev/rust_core.
struct RustCoreModule {
    _miscdev: MiscDeviceRegistration<RustCoreDevice>,
}

impl kernel::InPlaceModule for RustCoreModule {
    fn init(_module: &'static ThisModule) -> impl PinInit<Self, Error> {
        pr_info!("rust_core: Initialisiere Modul, registriere /dev/rust_core\n");

        let options = MiscDeviceOptions {
            name: c_str!("rust_core"),
        };

        try_pin_init!(Self {
            _miscdev <- MiscDeviceRegistration::register(options),
        })
    }
}

/// Pro geöffnetem File-Handle existiert eine Instanz dieser Struktur.
#[pin_data]
struct RustCoreDevice {
    #[pin]
    inner: Mutex<Inner>,
    dev: ARef<Device>,
}

/// Durch den Mutex geschützter, veränderlicher Zustand.
struct Inner {
    value: i32,
}

#[vtable]
impl MiscDevice for RustCoreDevice {
    type Ptr = Pin<KBox<Self>>;

    fn open(_file: &File, misc: &MiscDeviceRegistration<Self>) -> Result<Pin<KBox<Self>>> {
        let dev = ARef::from(misc.device());
        let opens = OPEN_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        dev_info!(dev, "rust_core: open() #{}\n", opens);

        KBox::try_pin_init(
            try_pin_init! {
                RustCoreDevice {
                    inner <- new_mutex!(Inner { value: 0_i32 }),
                    dev: dev,
                }
            },
            GFP_KERNEL,
        )
    }

    fn ioctl(me: Pin<&RustCoreDevice>, _file: &File, cmd: u32, arg: usize) -> Result<isize> {
        let size = _IOC_SIZE(cmd);
        match cmd {
            RUST_CORE_GET_VALUE => me.get_value(UserSlice::new(arg, size).writer())?,
            RUST_CORE_SET_VALUE => me.set_value(UserSlice::new(arg, size).reader())?,
            RUST_CORE_GET_OPENS => me.get_opens(UserSlice::new(arg, size).writer())?,
            RUST_CORE_HELLO => me.hello()?,
            _ => {
                dev_err!(me.dev, "rust_core: unbekanntes ioctl: 0x{:x}\n", cmd);
                return Err(ENOTTY);
            }
        };
        Ok(0)
    }
}

impl RustCoreDevice {
    fn get_value(&self, mut writer: UserSliceWriter) -> Result {
        let value = self.inner.lock().value;
        dev_info!(self.dev, "rust_core: GET_VALUE -> {}\n", value);
        writer.write::<i32>(&value)?;
        Ok(())
    }

    fn set_value(&self, mut reader: UserSliceReader) -> Result {
        let new_value = reader.read::<i32>()?;
        let mut guard = self.inner.lock();
        dev_info!(
            self.dev,
            "rust_core: SET_VALUE {} -> {}\n",
            guard.value,
            new_value
        );
        guard.value = new_value;
        Ok(())
    }

    fn get_opens(&self, mut writer: UserSliceWriter) -> Result {
        let opens = OPEN_COUNT.load(Ordering::Relaxed);
        dev_info!(self.dev, "rust_core: GET_OPENS -> {}\n", opens);
        writer.write::<u64>(&opens)?;
        Ok(())
    }

    fn hello(&self) -> Result {
        dev_info!(self.dev, "rust_core: Hallo aus dem Kernel-Rust-Modul!\n");
        Ok(())
    }
}
