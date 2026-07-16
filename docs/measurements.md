# sim6564 Measurement Record

Go/no-go data for the MAC & chains sketch (§6 of docs/6564-mac-and-chains-sketch.md).
Regenerate with `sim6564 measure`; append a dated section per feature landing.

## Baseline — pre-MAC, pre-chains (2026-07-16, commit 9aca29b)


| demo | code bytes | instructions | cycles | ctx switches | verified |
|---|---:|---:|---:|---:|---|
| pingpong (0x6564/1024/8) | 479 | 797 | 11028 | 40 | yes |
| supervise (fixed) | 175 | 1458 | 4104 | 0 | yes |
| pipeline (0x6564/1024/16/2) | 1166 | 8479 | 66871 | 317 | yes |
| scatter (0x6564/1024/6) | 518 | 1883 | 13096 | 44 | yes |
| ring (64x100) | 74 | 205055 | 425018 | 12863 | yes |
| **total** | 2412 | 217672 | 520117 | 13264 | yes |
