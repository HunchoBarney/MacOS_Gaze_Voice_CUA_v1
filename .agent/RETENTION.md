# Local candidate retention — 2026-11-17

All seven apps under `~/jarvis-local/c1-candidates/jev-c1-final-*/Jev Voice.app`
report 0.1.5 (6). Each passed strict deep signature verification on this Mac
on the inventory date. The SHA-256 below is of **Contents/MacOS/JevVoice**,
not of the app tree. Each matched the main executable in its
`.agent/results/P12/c1-final-<revision>-stage.json` receipt. Roles describe
historical evidence, not new live checks.

| Revision | Executable SHA-256 | Why keep it |
|---|---|---|
| r5 | `7e813283b9d3c596d8049858d52873e80dbd7d9e983a74a80b6570b8f2ebf721` | Scroll refusal comparator; [resource-sharing helper](results/P4/c1-r8-share-resources.py) names its path. Keep unpacked while that dependency exists. |
| r6 | `db36d3a487c6f8cffc984c2ede8fd5ac9af92944446e3c16e2c4a8b29091fdb8` | Viewport moved but completion failed; compare with R7/R8. |
| r7 | `6b035fac125308d0c6079cf6e1e4387c5139a14f77e5336870b1fdf1fe85b6a1` | Native bridge with [no measured viewport movement](results/P4/c1-scroll-r7-native/comparison.json). |
| r8 | `60a17df6d1380953cde91700e1ba88fafceb63937a564f88b37af8e39b85c7a3` | [Successful native scroll comparator](results/P4/c1-scroll-r8-native3/comparison.json); not a hands-free pass. |
| r9 | `dc79dbf4b805456e139e016b59fa427a15b265e12d53ded7a1d450a4614f1f25` | [First duplex preflight](results/P4/c1-r9-duplex-attempt-1.json) hung; negative comparator. |
| r9-2 | `79e8859b32d849e2777c741cefec099123cae9e18a6d081de8bab440cabb276b` | Keep unpacked: [R10 packaging base and fallback](results/P4/c1-r10-packaging-base-amendment.md), not the daily install. |
| r10 | `2261f60b64e0c8cb26a5996c62ee3154e1c2afc86481847e2e479cb9ab30d5f0` | Keep unpacked: [current physical qualification candidate](results/P4/c1-r10-physical-check.md). Source and signature checks don't close C1. |

Don't remove a comparator until its owner releases the role and a complete
archive has been restored and verified against its receipt. Keep historical
receipts, regression tests and archives. Logical bundle sizes don't measure
reclaimable space on APFS.

* **Recovery copies:** the Documents checkout's ignored
  `.context/c1-local/Jev-Voice-C1-R10-signed.zip` hashes to
  `b4a194b7b5753715de676a44290fc810e266b20082f36c8ac4907d308cfd1535`.
  Its entries matched the current R10 payload; no restore was performed.
  R2–R4 archives and tree manifests in `~/jarvis-local/c1-archives/`
  matched their P12 archive receipts. The [interrupted c292 receipt](results/P12/c1-review-c292-c292e12024dc-archive.json)
  is historical: only its tree manifest was present, not a full ZIP.
  The three [tracked retired ZIPs](results/P12/c1-staging-retirement.json)
  preserve selected files, not complete app bundles.
* **Unknown binary:** `~/jarvis-local/test-bin` hashes to
  `5ccc104d6b63df45d92d7bc4df4f59819b8d183d603bc429fe8d1e9c695267a9`.
  It matches none of the candidates. Keep until provenance and owner are
  established; don't use it as a fallback.
* **Launch paths:** the daily app was absent. The app-support
  `JevVoice/EyeTracking` symlink pointed to the Documents checkout's
  `EyeTracking/`. Keep both; repoint and verify the replacement before any move.
  Leave the empty review directory alone.
