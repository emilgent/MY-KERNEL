#!/usr/bin/env python3
"""BEREICH 3 — Referenz-/Mock-Daemon in reinem Python.

Implementiert exakt dasselbe Socket-Protokoll und dieselbe Inferenz-Logik wie
``mojo_ai_daemon.mojo`` + ``inference.mojo``. Damit lassen sich das Chat-Widget
(Bereich 4) und die gesamte Bruecke testen, ohne dass das proprietaere Mojo-SDK
installiert ist.

    python3 mock_daemon.py                       # /run/mojo_ai.sock (root noetig)
    python3 mock_daemon.py --sock /tmp/ai.sock   # beliebiger Pfad

Antworten sind byte-fuer-byte identisch zur Mojo-Implementierung.
"""
import argparse
import os
import socket
import sys

FEAT = 16
NUM_LABELS = 4


def weight(label: int, feat: int) -> float:
    return (float((label * 31 + feat * 7) % 17) - 8.0) / 8.0


def featurize(text: str) -> list[float]:
    hist = [0.0] * FEAT
    for ch in text:
        hist[ord(ch) % FEAT] += 1.0
    total = sum(hist)
    if total > 0:
        hist = [h / total for h in hist]
    return hist


def classify(text: str) -> int:
    x = featurize(text)
    best_label, best_score = 0, float("-inf")
    for label in range(NUM_LABELS):
        score = sum(weight(label, f) * x[f] for f in range(FEAT))
        if score > best_score:
            best_score, best_label = score, label
    return best_label


def generate_reply(prompt: str) -> str:
    label = classify(prompt)
    intent = {0: "Begruessung", 1: "Frage", 2: "Befehl"}.get(label, "Sonstiges")
    return (
        f"[mojo-ai] Intent={intent} | Eingabe-Laenge={len(prompt)} | "
        f"Antwort: Verstanden, ich verarbeite '{prompt}'."
    )


def serve(sock_path: str) -> None:
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o666)
    srv.listen(16)
    print(f"[mock-ai] Bereit auf {sock_path}", flush=True)
    try:
        while True:
            conn, _ = srv.accept()
            with conn:
                data = conn.recv(4096)
                if not data:
                    continue
                req = data.decode("utf-8", errors="replace").split("\n", 1)[0]
                print(f"[mock-ai] <- {req}", flush=True)
                reply = generate_reply(req) + "\n"
                conn.sendall(reply.encode("utf-8"))
    finally:
        srv.close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", default="/run/mojo_ai.sock")
    args = ap.parse_args()
    try:
        serve(args.sock)
    except PermissionError:
        print(
            f"Kein Schreibrecht fuer {args.sock} — als root starten oder "
            f"--sock /tmp/ai.sock verwenden.",
            file=sys.stderr,
        )
        return 1
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
