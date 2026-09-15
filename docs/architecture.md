# Native search architecture

## Current implementation

The local agent API, authorization boundary, native approval controls, and scope limitations are documented in [agent-access.md](agent-access.md).

Velocity keeps app navigation discovery local. Adapters enumerate navigation controls, not document bodies or message transcripts.

- `WindowEntry.swift`: search result identity, searchable aliases, display metadata, and recency keys. An adapter destination may own an AX window without being a window result.
- `Windows.swift`: catalog scans, native tab discovery, browser metadata, and audio attribution.
- `Accessibility.swift`: shared read-only AX primitives with type checks. Traversal scope and budgets belong to each adapter.
- `WindowActivation.swift`: app/window handoff and selecting native or scripted browser tabs. Keep activation separate from scanning.
- `Conversations.swift`, `ChatProjects.swift`, `ConductorWorkspaces.swift`: app-specific navigation discovery and fresh target resolution. Stable IDs take precedence over labels; ambiguous destinations fail closed.
- `ResultDeduplication.swift`: one reduction pass after query filtering. Prefer specific destinations over their owning window only when identity or active-destination metadata establishes the relationship. Preserve separate windows and window-only search matches.
- `Palette.swift`: search state and SwiftUI presentation. Publish selected identity and results together; do not activate a captured row index after refresh.
- `App.swift`: lifecycle, shortcuts, scanning queues, and action orchestration. Activate the target app before hiding the palette; hide the palette before hit-testing a native conversation row.

## Verification

Run `swift test` and `swift test -Xswiftc -DVELOCITY_EXPERIMENTAL`. Build the public app with `bash scripts/build.sh` and the private app with `VELOCITY_EXPERIMENTAL=1 bash scripts/build.sh`. Build sequentially; both configurations share SwiftPM output paths.

Tests cover selection identity, duplicate reduction, tab cleanup protections, update validation, and feature gates. Native app Accessibility behavior still requires a live check; a successful AX action does not necessarily mean the app navigated.

## Icon source

The app icon is drawn by `scripts/generate-icons.swift`; the monochrome menu mark is in `Branding.swift`. Regenerate the committed assets with:

```sh
swift scripts/generate-icons.swift
iconutil -c icns resources/AppIcon.iconset -o resources/AppIcon.icns
```

Keep the silhouette legible at 16 pixels and preserve alpha outside the macOS icon tile.
