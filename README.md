# BetterDrop

**AirDrop-style transfers with a queue.** Drop files onto a device in BetterDrop and they are **persisted and sent automatically** when that device comes online—even if it was offline when you queued the transfer.

The macOS app discovers peers on the LAN (and peer-to-peer links such as AWDL) via Bonjour, maintains per-device queues in SQLite, and drains them with retries and backoff. See [ARCHITECTURE.md](ARCHITECTURE.md) for a deeper design walkthrough.

---

## What gets built from this repo

| Piece | How |
|--------|-----|
| **Engine library** (`BetterDropEngine`) | Swift Package Manager — models, persistence, discovery, queue, transports |
| **Unit tests** | `swift test` — queue state machine and related behavior |
| **macOS app** (menu bar + window) | **Xcode** — SwiftUI targets are not exposed as an SPM executable; create or open an Xcode project that includes `BetterDrop/` |
| **Relay server** (optional, cross-network path) | Go — `go run .` in `relay/` |

---

## Requirements

- **macOS 13+** / **iOS 16+** (platforms declared in `Package.swift`)
- **Swift 5.10+**
- **Xcode** (latest stable recommended) for the full SwiftUI app
- **Go 1.21+** (only if you run the relay)

---

## Run the Swift package and tests

From the repository root:

```bash
swift build
swift test
```

`Package.swift` builds **only** the engine target (it excludes `BetterDropApp.swift`, `Views/`, and `Resources/` so the library stays free of the app shell). That is enough to validate core queue and persistence logic in CI or from the command line.

---

## Run the macOS app

This repository includes a checked-in `BetterDrop.xcodeproj`.

### Option A: Run from terminal (no Xcode UI)

From the repository root:

```bash
xcodebuild -project BetterDrop.xcodeproj \
  -scheme BetterDrop \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData build

open .derivedData/Build/Products/Debug/BetterDrop.app
```

Note: this is a macOS app, so there is no iOS-style emulator/simulator involved; it runs directly on your Mac.

### Option B: Run in Xcode

Open `BetterDrop.xcodeproj`, select the `BetterDrop` scheme, and run.

On launch, `BetterDropApp` calls `store.startEngine()` so SQLite state loads, Bonjour runs, and the queue processor starts after the shared `AppStore` singleton is published.

---

## Run the relay (optional)

The relay provides a **WebSocket + HTTPS chunk** path when sender and recipient are not on the same LAN. The server stores **ciphertext only** (payloads are encrypted before upload).

```bash
cd relay
go run .
```

- Default listen port: **8080** (override with `PORT`).
- If `cert.pem` and `key.pem` are present, the server prefers **HTTPS/WSS**; otherwise it falls back to plain HTTP for local development.

---

## Repository layout (high level)

```
BetterDrop/
  Models/          # Transfer, device documents
  Store/           # App-facing state; engine startup
  Engine/          # QueueProcessor, DeviceRegistry, transports
  Persistence/     # SQLite (WAL), devices + transfers
  Views/           # SwiftUI (app target only)
  Resources/       # App assets
relay/             # Go signaling + chunk relay
Tests/             # BetterDropEngineTests
Package.swift      # Library + tests
```

---

## License

Specify your license in a `LICENSE` file at the repo root if you distribute this project.
