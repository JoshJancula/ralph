# Antigravity runtime contract

Pinned by `bundle/.ralph/plugin-inputs/contracts/antigravity.json`.

## Model value policy

`modelValuePolicy` is `opaque-byte-preserved`.

Ralph must pass Antigravity `--model` values exactly as returned by `agy models`
(and as supplied by the operator). Do not normalize, remap, sort, or rewrite the
model display string.
