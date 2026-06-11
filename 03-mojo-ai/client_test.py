#!/usr/bin/env python3
"""BEREICH 3 — Test-Client für den Mojo-AI-Daemon.

Sendet eine Textzeile an den Unix-Socket und gibt die Antwort aus.

    python3 client_test.py "Hallo KI"
    python3 client_test.py --sock /run/mojo_ai.sock "Wie spaet ist es?"
"""
import argparse
import socket
import sys


def query(sock_path: str, text: str, timeout: float = 5.0) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(sock_path)
        s.sendall((text.rstrip("\n") + "\n").encode("utf-8"))
        chunks = []
        while True:
            data = s.recv(4096)
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks).decode("utf-8", errors="replace").rstrip("\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="+", help="An den Daemon zu sendender Text")
    ap.add_argument("--sock", default="/run/mojo_ai.sock", help="Socket-Pfad")
    args = ap.parse_args()
    try:
        print(query(args.sock, " ".join(args.text)))
    except OSError as e:
        print(f"Verbindung zu {args.sock} fehlgeschlagen: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
