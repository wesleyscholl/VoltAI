# VoltAI macOS UI (SwiftUI)

This is a minimal native macOS SwiftUI app that acts as a front-end to the `voltai` CLI. It provides:

- A chat-style interface to submit queries to the local index.
- A drag-and-drop area to drop files or folders to index.
- Uses the `voltai` binary (expected on the same PATH or next to the app bundle) via Process.

Build & run (Xcode)
1) Open the folder in Xcode: File -> Open and pick `Package.swift`.
2) Build & Run the `VoltAI` target.

Build & run (SwiftPM)
```
cd mac-ui
swift build
swift run VoltAI
```

Notes
- The UI calls `./voltai` by default when run from the project directory. If you bundle the app, copy the `voltai` binary into the app bundle's Contents/MacOS folder or ensure it's on PATH.
- This is a prototype: for production, sign the app and handle long-running indexing with background tasks and progress reporting.
