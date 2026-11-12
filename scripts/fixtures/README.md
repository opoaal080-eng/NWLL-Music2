# Search and transfer regressions

`transfer-recall.json` covers metadata spelling, Cyrillic/Latin names, featured
artists, uploader titles, duplicate uploads, ISRC, previews, competing recordings
and incompatible versions. `test-transfer-search.swift` simulates pending sources,
partial response snapshots, errors, query expansion, caching and cancellation.
`test-search-recall.swift` checks an exact title after 320 earlier hits and makes
sure ownership never hides a better match.

`transfer-model-v2.json` contains exported weights, Python/Swift inference parity
vectors, the deterministic seed and feature-source hash. Reproduce with Python,
numpy, scikit-learn and Swift installed:

```
OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=2 python3 scripts/train-transfer-model.py
```

The bundled model is a 16 → 32 → 16 → 1 MLP trained on synthetic metadata
augmentations. Primary-artist identities are split between training and held-out
validation. Reported precision/recall measures only synthetic pair classification,
not the share of real playlists that can be transferred. No user playlists are
used for training. Runtime rules reject incompatible versions, ISRCs, durations
and ambiguous competing recordings regardless of model confidence.

Inference is offline on the phone. Search still depends on what the server and
providers return. No audio fingerprinting or external language-model API is used.
