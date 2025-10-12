# BoltAI macOS UI (SwiftUI)

This is a minimal native macOS SwiftUI app that acts as a front-end to the `boltai` CLI. It provides:

- A chat-style interface to submit queries to the local index.
- A drag-and-drop area to drop files or folders to index.
- Uses the `boltai` binary (expected on the same PATH or next to the app bundle) via Process.

Build & run (Xcode)
1) Open the folder in Xcode: File -> Open and pick `Package.swift`.
2) Build & Run the `BoltAI` target.

Build & run (SwiftPM)
```
cd mac-ui
swift build
swift run BoltAI
```

Notes
- The UI calls `./boltai` by default when run from the project directory. If you bundle the app, copy the `boltai` binary into the app bundle's Contents/MacOS folder or ensure it's on PATH.
- This is a prototype: for production, sign the app and handle long-running indexing with background tasks and progress reporting.
