# GRDB.swift

Jarvis's on-device memory (`Sources/Jarvis/Memory/`) is one SQLite database
read and written through GRDB.swift, with SQLite's FTS5 full-text index for
picking the memories that matter to a request.

- Library: [GRDB.swift](https://github.com/groue/GRDB.swift) 7.12.0 by
  Gwendal Roué, MIT (`LICENSE`).
- Pinned in `Package.swift` with `exact: "7.12.0"`; `Package.resolved` pins
  the tag to revision `92a554cd0d5e8d67cb18993c6054e73fe42c066c`.
- It links the SQLite that ships with macOS. GRDB's package defines
  `SQLITE_ENABLE_FTS5`, and the store turns on FTS5 `secure-delete`
  (SQLite 3.42 or later; macOS 26 ships 3.51).
- `make release` compiles it into the app binary and copies this licence to
  `Contents/Resources/ThirdParty/GRDB/`.

To upgrade, change the version in `Package.swift`, run
`swift package resolve`, update the revision above, and rerun
`swift test --filter MemoryStoreTests`.
