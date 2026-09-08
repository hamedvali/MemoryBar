# MemoryBar MVP

MemoryBar is a private, local work-memory service for macOS. It has no main window: a small brain icon opens a spacious liquid-glass menu-bar panel showing capture status, active time, memory counts, the local MCP URL, permission state, and privacy settings.

The app captures the screen every two seconds, but only performs OCR and stores a record when the visual change score passes a threshold. A ten-second fallback stores periodic context even on mostly static screens. All processing and storage stay on the Mac.

## What is implemented

- Menu-bar-only SwiftUI app with a polished liquid-glass popover and accessible typography
- Custom macOS application icon, with the menu-bar control kept monochrome for native visibility
- Modern ScreenCaptureKit screen capture
- Smart visual change detection plus a 10-second fallback
- macOS Accessibility metadata for the focused app, window, document, role, value, and selection
- Apple Vision OCR with automatic language detection
- Apple Vision on-device image classification as the MVP's small local vision model
- Heuristic temporal episode merging, project/person extraction, and open-action detection
- SQLite in WAL mode with exact OCR text, structured metadata, timestamps, confidence, evidence, optional thumbnails, and FTS5 full-text search
- Apple NaturalLanguage sentence embeddings when available, with a deterministic local hashed-vector fallback
- A loopback-only, read-only Streamable HTTP MCP server at `http://127.0.0.1:7331/mcp`
- Pause/resume, app exclusions, visible status, evidence-thumbnail control, and delete-all-memory
- Seven MCP tools: `search_memory`, `get_recent_activity`, `get_episode`, `get_day_summary`, `get_open_actions`, `get_person_context`, and `get_project_context`

There is no login, analytics SDK, telemetry, cloud model, or cloud backend.

## Architecture

```text
ScreenCaptureKit (2 s poll / 10 s fallback)
          +
Focused-window Accessibility metadata
          │
          ▼
Visual diff ── unchanged? ──► skip expensive processing
          │ changed/fallback
          ▼
Vision OCR + local image classification
          │
          ▼
Episode builder (2-minute same-window merge)
          │
          ├── exact text + FTS5
          ├── timestamps + confidence + evidence
          ├── people / project / actions
          └── local sentence embedding
          │
          ▼
SQLite on this Mac
          │
          ▼
127.0.0.1:7331/mcp ──► Codex / Claude / local MCP clients
```

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (tested with Swift 6.2 / Xcode 26.3)
- Screen Recording permission for useful captures
- Accessibility permission for richer window and focused-control context

## Build and run

From this folder:

```bash
./scripts/build_app.sh
open outputs/MemoryBar.app
```

The build creates a locally signed app at `outputs/MemoryBar.app`. Its explicit designated requirement keeps the app identity stable across local rebuilds so Screen Recording and Accessibility grants are not invalidated whenever the binary changes. On first launch, click the menu-bar brain, allow both permissions, then quit and reopen MemoryBar once.

For development, `swift run` also works, but using the app bundle gives macOS a stable bundle identifier for privacy permissions.

The database is stored at:

```text
~/Library/Application Support/MemoryBar/memory.sqlite3
```

The popover's **Show memory file** button reveals it in Finder. **Delete all…** removes observations, episodes, FTS rows, actions, and thumbnails, then truncates the WAL.

## Connect an MCP client

Keep MemoryBar running. Its server deliberately binds only to `127.0.0.1`, so it is available to clients on the same Mac and cannot be reached from the LAN.

### Codex / ChatGPT desktop app

In a terminal:

```bash
codex mcp add memorybar --url http://127.0.0.1:7331/mcp
codex mcp list
```

Alternatively, in the ChatGPT desktop app open **Settings → MCP servers → Add server**, choose **Streamable HTTP**, and paste the URL shown in MemoryBar. Restart the client after adding it. Codex CLI, the IDE extension, and the desktop app share the MCP configuration, as described in the [official OpenAI MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

ChatGPT on the web does not read local MCP configuration and cannot reach a Mac's `127.0.0.1`. Keeping the product strictly local therefore supports the local ChatGPT/Codex desktop experience, not hosted ChatGPT web. A web connection would require an authenticated remote HTTPS service, which is intentionally outside this MVP's privacy boundary.

### Claude or another stdio-only MCP client

This repository includes a dependency-free bridge. Use an absolute path in the client's MCP configuration:

```json
{
  "mcpServers": {
    "memorybar": {
      "command": "/usr/bin/python3",
      "args": [
        "/ABSOLUTE/PATH/TO/MemoryBar/scripts/mcp_stdio_bridge.py",
        "http://127.0.0.1:7331/mcp"
      ]
    }
  }
}
```

Clients that already support Streamable HTTP can use the URL directly.

## Example agent routines

MemoryBar does not schedule cloud jobs itself. It stays queryable, so a local agent or its scheduler can run prompts such as:

```text
Every hour, call get_recent_activity for the last 60 minutes and get_open_actions.
Only notify me when there is a specific new commitment or something time-sensitive.
Quote the supporting episode ID and confidence. Otherwise say nothing.
```

```text
At 17:30, call get_day_summary for today. Produce a short recap with projects,
people, unfinished actions, and uncertain OCR claims clearly marked.
```

External actions—sending messages, creating calendar events, or changing tasks—are intentionally not exposed by this read-only MCP server. An agent should ask before performing those actions through another integration.

## Test

```bash
swift test
```

The tests cover episode merging, full-text/embedding search, action and person extraction, project context, database behavior, and the MCP tool catalog. Screen capture itself requires interactive macOS permissions and is verified by running the built app.

## MVP tradeoffs and next steps

- **Vision understanding:** `VNClassifyImageRequest` is small and fully local, but generic. A later version can add an optional Core ML UI-understanding model while keeping the same evidence schema.
- **Episode semantics:** merging and entity extraction are deterministic heuristics. This keeps the MVP fast and private, but names and commitments can be wrong; consumers receive confidence and episode evidence.
- **Embedding coverage:** Apple sentence embeddings vary by installed language. The hashed fallback preserves offline semantic-ish retrieval without a model download, but is less accurate.
- **Capture scope:** the MVP captures the first active display, not every monitor, and retains only a reduced JPEG when the thumbnail setting is enabled.
- **Security:** loopback binding prevents network access, but another process running as the same user can query the unauthenticated local port. Production should add a per-install token and database encryption.
- **Storage growth:** there is no retention window yet. Use app exclusions, disable thumbnails, or delete all memory from the popover.
- **Distribution:** the generated app uses an ad-hoc signature with a stable local designated requirement. This is useful for MVP development, but public distribution still needs an Apple Developer ID signature, notarization, and a hardened-runtime review.

## Project layout

```text
Sources/MemoryBar/
  MemoryBarApp.swift          menu-bar popover
  AppModel.swift              lifecycle and settings
  CaptureService.swift        smart capture loop
  AccessibilityReader.swift   focused-app/window metadata
  LocalVisionProcessor.swift  OCR and local classification
  MemoryDatabase.swift        SQLite, FTS5, embeddings, episodes
  MCPProtocolHandler.swift    MCP tools and JSON-RPC
  LocalHTTPServer.swift       loopback HTTP transport
scripts/
  build_app.sh                creates outputs/MemoryBar.app
  mcp_stdio_bridge.py         optional stdio compatibility bridge
Resources/
  AppIcon-1024.png            editable master application icon
  AppIcon.icns                packaged macOS application icon
Tests/MemoryBarTests/         deterministic unit tests
```
