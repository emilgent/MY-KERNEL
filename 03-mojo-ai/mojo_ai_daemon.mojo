# BEREICH 3.1 — mojo_ai_daemon.mojo
# ===========================================================================
# Hintergrunddienst (Daemon) in Mojo.
#
# Lauscht auf einem Unix Domain Socket (Standard: /var/run/mojo_ai.sock) auf
# Text-Eingaben. Für jede Verbindung:
#   1) liest die Zeile vom Client,
#   2) berechnet über inference.generate_reply() eine Antwort
#      (SIMD-Matrixmultiplikation, siehe inference.mojo),
#   3) schreibt die Antwort zurück und schliesst die Verbindung.
#
# Die Socket-Operationen nutzen die Linux-libc über Mojos FFI (external_call),
# da die Mojo-Stdlib (noch) keine eigene Unix-Socket-API mitbringt.
#
# Start (Vordergrund, zum Testen):
#   mojo run mojo_ai_daemon.mojo
#   mojo run mojo_ai_daemon.mojo /var/run/mojo_ai.sock
#
# Kompilieren zu einer Binary (für den systemd/SysVinit-Dienst):
#   mojo build mojo_ai_daemon.mojo -o /usr/local/bin/mojo_ai_daemon
#
# Getestet gegen Mojo (MAX) >= 24.5 Syntax.
# ===========================================================================

from sys import argv
from sys.ffi import external_call
from memory import UnsafePointer, memset_zero
from inference import generate_reply

# --- Linux-Konstanten ------------------------------------------------------
alias AF_UNIX: Int32 = 1
alias SOCK_STREAM: Int32 = 1
alias SUN_PATH_OFF: Int = 2     # Offset von sun_path in struct sockaddr_un
alias SOCKADDR_UN_LEN: Int = 110  # sizeof(struct sockaddr_un) auf Linux
alias BACKLOG: Int32 = 16
alias BUF_SIZE: Int = 4096
alias DEFAULT_SOCK: String = "/var/run/mojo_ai.sock"


fn die(msg: String):
    print("[mojo-ai] FEHLER:", msg)


# --- libc-Wrapper über external_call --------------------------------------
fn c_socket(domain: Int32, typ: Int32, proto: Int32) -> Int32:
    return external_call["socket", Int32](domain, typ, proto)

fn c_bind(fd: Int32, addr: UnsafePointer[UInt8], len: Int32) -> Int32:
    return external_call["bind", Int32](fd, addr, len)

fn c_listen(fd: Int32, backlog: Int32) -> Int32:
    return external_call["listen", Int32](fd, backlog)

fn c_accept(fd: Int32) -> Int32:
    return external_call["accept", Int32](
        fd, UnsafePointer[UInt8](), UnsafePointer[Int32]()
    )

fn c_read(fd: Int32, buf: UnsafePointer[UInt8], n: Int) -> Int:
    return external_call["read", Int](fd, buf, n)

fn c_write(fd: Int32, buf: UnsafePointer[UInt8], n: Int) -> Int:
    return external_call["write", Int](fd, buf, n)

fn c_close(fd: Int32) -> Int32:
    return external_call["close", Int32](fd)

fn c_unlink(path: UnsafePointer[UInt8]) -> Int32:
    return external_call["unlink", Int32](path)


# --- Hilfsfunktion: String -> nullterminierter UInt8-Puffer ----------------
fn cstr(s: String) -> UnsafePointer[UInt8]:
    var n = len(s)
    var p = UnsafePointer[UInt8].alloc(n + 1)
    for i in range(n):
        p[i] = ord(s[i])
    p[n] = 0
    return p


# --- sockaddr_un aufbauen: family=AF_UNIX, sun_path=pfad -------------------
fn make_sockaddr_un(path: String) -> UnsafePointer[UInt8]:
    var addr = UnsafePointer[UInt8].alloc(SOCKADDR_UN_LEN)
    memset_zero(addr, SOCKADDR_UN_LEN)
    # sun_family (UInt16, little-endian) = AF_UNIX (1)
    addr[0] = 1
    addr[1] = 0
    # sun_path
    var n = len(path)
    for i in range(n):
        addr[SUN_PATH_OFF + i] = ord(path[i])
    return addr


fn handle_client(client_fd: Int32):
    var buf = UnsafePointer[UInt8].alloc(BUF_SIZE)
    var nread = c_read(client_fd, buf, BUF_SIZE - 1)
    if nread <= 0:
        buf.free()
        _ = c_close(client_fd)
        return

    # Eingabe in einen Mojo-String überführen.
    var req = String("")
    for i in range(nread):
        var c = buf[i]
        if c == ord("\n"):
            break
        req += chr(Int(c))

    print("[mojo-ai] <-", req)
    var reply = generate_reply(req) + "\n"
    print("[mojo-ai] ->", reply)

    var out = cstr(reply)
    _ = c_write(client_fd, out, len(reply))

    out.free()
    buf.free()
    _ = c_close(client_fd)


fn main() raises:
    # Socketpfad aus argv oder Default.
    var sock_path = DEFAULT_SOCK
    var args = argv()
    if len(args) > 1:
        sock_path = String(args[1])

    print("[mojo-ai] Starte Daemon auf", sock_path)

    # Evtl. vorhandenen Socket entfernen (sonst EADDRINUSE).
    var pcstr = cstr(sock_path)
    _ = c_unlink(pcstr)

    var fd = c_socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0:
        die("socket() fehlgeschlagen")
        return

    var addr = make_sockaddr_un(sock_path)
    if c_bind(fd, addr, Int32(SOCKADDR_UN_LEN)) < 0:
        die("bind() fehlgeschlagen (Rechte auf /var/run? root noetig)")
        _ = c_close(fd)
        return

    if c_listen(fd, BACKLOG) < 0:
        die("listen() fehlgeschlagen")
        _ = c_close(fd)
        return

    print("[mojo-ai] Bereit. Warte auf Verbindungen ...")

    # Akzeptanz-Schleife (Daemon läuft, bis er per Signal beendet wird).
    while True:
        var client = c_accept(fd)
        if client < 0:
            continue
        handle_client(client)

    # (nicht erreicht — der Dienst wird per SIGTERM beendet)
    _ = c_close(fd)
    addr.free()
    pcstr.free()
