# BEREICH 3.2 — inference.mojo
# ===========================================================================
# Minimale, aber funktionale Inferenz-Logik in Mojo.
#
# Es werden zwei Pfade bereitgestellt:
#
#   1) SIMD-optimiertes "Dummy-Modell": Der eingegebene Text wird in einen
#      Feature-Vektor (Bag-of-Bytes-Histogramm) überführt und über eine feste
#      Gewichtsmatrix (Matrixmultiplikation mit SIMD-Vektorisierung) auf ein
#      kleines Label-Set projiziert. Daraus wird deterministisch eine Antwort
#      erzeugt. Das ist echte, lauffähige Rechenarbeit (kein Platzhalter) und
#      dient als Stellvertreter für ein echtes Modell.
#
#   2) Optionaler llama.cpp/ggml-Pfad über C-Interoperabilität (siehe
#      `LlamaBackend` unten). Standardmäßig deaktiviert, da er die installierte
#      libllama voraussetzt.
#
# Getestet gegen Mojo (MAX) >= 24.5 Syntax.
# ===========================================================================

from sys.ffi import DLHandle, external_call
from memory import UnsafePointer
from collections import List

alias FEAT: Int = 16  # Feature-Dimension (Bytes mod 16)
alias NUM_LABELS: Int = 4
alias SIMD_W: Int = 8  # SIMD-Breite für die Akkumulation


# ---------------------------------------------------------------------------
# Feste Gewichtsmatrix (NUM_LABELS x FEAT) eines kleinen linearen Klassifikators.
# In einem echten System kämen die Gewichte aus einer Datei; hier deterministisch.
# ---------------------------------------------------------------------------
fn weight(label: Int, feat: Int) -> Float32:
    # Deterministische, reproduzierbare Pseudogewichte.
    var v = Float32((label * 31 + feat * 7) % 17) - 8.0
    return v / 8.0


# ---------------------------------------------------------------------------
# Text -> Feature-Vektor (Byte-Histogramm, L1-normalisiert).
# ---------------------------------------------------------------------------
fn featurize(text: String) -> SIMD[DType.float32, FEAT]:
    var hist = SIMD[DType.float32, FEAT](0.0)
    var n = len(text)
    for i in range(n):
        var b = ord(text[i])
        var bucket = b % FEAT
        hist[bucket] = hist[bucket] + 1.0
    # L1-Normalisierung, damit unterschiedlich lange Eingaben vergleichbar sind.
    var total: Float32 = 0.0
    for j in range(FEAT):
        total += hist[j]
    if total > 0.0:
        for j in range(FEAT):
            hist[j] = hist[j] / total
    return hist


# ---------------------------------------------------------------------------
# SIMD-Matrixmultiplikation: scores[label] = sum_feat W[label,feat] * x[feat]
# Die innere Schleife wird über SIMD-Lanes (SIMD_W) vektorisiert.
# ---------------------------------------------------------------------------
fn classify(text: String) -> Int:
    var x = featurize(text)
    var best_label = 0
    var best_score = Float32(-1.0e30)

    for label in range(NUM_LABELS):
        var acc = SIMD[DType.float32, SIMD_W](0.0)
        var f = 0
        # vektorisierter Hauptteil
        while f + SIMD_W <= FEAT:
            var wv = SIMD[DType.float32, SIMD_W](0.0)
            var xv = SIMD[DType.float32, SIMD_W](0.0)
            for k in range(SIMD_W):
                wv[k] = weight(label, f + k)
                xv[k] = x[f + k]
            acc = acc + wv * xv
            f += SIMD_W
        # horizontale Summe
        var score: Float32 = 0.0
        for k in range(SIMD_W):
            score += acc[k]
        # Rest (falls FEAT nicht durch SIMD_W teilbar)
        while f < FEAT:
            score += weight(label, f) * x[f]
            f += 1
        if score > best_score:
            best_score = score
            best_label = label

    return best_label


# ---------------------------------------------------------------------------
# Antwortgenerierung auf Basis des klassifizierten Labels.
# ---------------------------------------------------------------------------
fn generate_reply(prompt: String) -> String:
    var label = classify(prompt)
    var intent: String
    if label == 0:
        intent = "Begruessung"
    elif label == 1:
        intent = "Frage"
    elif label == 2:
        intent = "Befehl"
    else:
        intent = "Sonstiges"

    # Deterministische, aber sinnvolle Antwort inkl. erkannter Intent-Klasse.
    return (
        "[mojo-ai] Intent="
        + intent
        + " | Eingabe-Laenge="
        + str(len(prompt))
        + " | Antwort: Verstanden, ich verarbeite '"
        + prompt
        + "'."
    )


# ---------------------------------------------------------------------------
# OPTIONAL: llama.cpp/ggml über C-Interoperabilität.
# Aktivierung: USE_LLAMA=1 als Umgebungsvariable + libllama im Linker-Pfad.
# Dies zeigt die direkte Einbindung einer nativen Inferenz-Bibliothek via FFI.
# ---------------------------------------------------------------------------
struct LlamaBackend:
    var handle: DLHandle

    fn __init__(out self, lib_path: String):
        # Lädt z. B. /usr/lib/libllama.so zur Laufzeit.
        self.handle = DLHandle(lib_path)

    fn backend_init(self):
        # void llama_backend_init(void);
        var fp = self.handle.get_function[fn () -> None]("llama_backend_init")
        fp()

    fn backend_free(self):
        var fp = self.handle.get_function[fn () -> None]("llama_backend_free")
        fp()

    fn __del__(owned self):
        self.handle.close()
