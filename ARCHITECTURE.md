# BetterDrop — Architecture

## What it is

AirDrop with a queue. When you drop a file onto a device that's offline, BetterDrop holds it and sends automatically when that device comes back online. Works across macOS, iOS, and eventually Windows/Android via a lightweight relay agent.

---

## High-level diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS App (SwiftUI)                                            │
│  ┌──────────────┐   ┌─────────────────┐   ┌─────────────────┐  │
│  │  Menu Bar    │   │  Device Grid    │   │  Queue Sheet    │  │
│  │  Popover     │   │  (drop targets) │   │  (per-device)   │  │
│  └──────┬───────┘   └────────┬────────┘   └────────┬────────┘  │
│         └────────────────────┼─────────────────────┘           │
│                              │                                  │
│                        AppStore (ObservableObject)              │
│                              │                                  │
│              ┌───────────────┼──────────────────┐               │
│              ▼               ▼                  ▼               │
│     TransferQueue       DeviceRegistry    PersistenceStore      │
│     (in-memory +        (Bonjour +        (SQLite via GRDB)     │
│      SQLite-backed)      LAN scan)                              │
│              │               │                                  │
│              └───────────────┼──────────────────┘               │
│                              ▼                                  │
│                     TransferEngine                              │
│          ┌──────────────────┬───────────────────┐               │
│          ▼                  ▼                   ▼               │
│   AWDLTransport      TCPDirectTransport   RelayTransport        │
│   (native AirDrop)   (LAN, same network)  (cloud relay,        │
│                                            cross-network)       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Core layers

### 1. UI Layer (SwiftUI)

**`ContentView`** — device card grid, the main window. Cards are drag targets.

**`MenuBarPopoverView`** — same drop UX in a compact menu bar popover. Accessible without switching apps.

**`QueueSheetView`** — per-device queue inspector. Opened by tapping a device card.

**`AppStore`** — single `@MainActor ObservableObject`. All state flows down from here. No view holds mutable state beyond local UI state (hover, drag).

### 2. Transfer Queue

The queue is the core feature. Each `Transfer` is a document:

```
Transfer
  ├── id: UUID
  ├── targetDeviceID: UUID
  ├── files: [TransferFile]       ← local file refs + metadata
  ├── status: .queued | .sending | .completed | .failed | .cancelled
  ├── progress: Double
  └── retryCount: Int
```

**Queue persistence**: Transfers are written to SQLite immediately on enqueue. The app can quit mid-transfer and resume on relaunch.

**Queue processor**: A background `Actor` (`QueueProcessor`) polls every 30 seconds and on device-online events. It picks the oldest `.queued` transfer for each online device and starts it.

### 3. Device Registry

Discovers peers on the local network using:
- **Bonjour/mDNS** — primary, zero-config, works on LAN
- **Bluetooth LE advertisements** — fallback when no shared WiFi
- **Manual pairing** — QR code or 6-digit code for first-time cross-network setup

Each device persists to SQLite with `lastSeen` updated on every observation. The UI derives online/offline purely from whether a device responded to a ping within the last 15 seconds.

```
Device
  ├── id: UUID                   ← stable, generated on first pair
  ├── name: String
  ├── platform: macOS | iOS | iPadOS | windows | android
  ├── publicKey: Data            ← Curve25519, used for E2E encryption
  ├── lastSeen: Date
  └── isTrusted: Bool
```

### 4. Transport Layer

Three transports, tried in order:

| Transport | When | Speed |
|---|---|---|
| `AWDLTransport` | Both devices nearby (wraps AirDrop protocol) | Fast |
| `TCPDirectTransport` | Same LAN, AWDL unavailable | Medium |
| `RelayTransport` | Cross-network, device is online elsewhere | Slower |

**AWDL transport** uses `NEAppProxyProvider` or the public `Network.framework` AWDL interface. On iOS 17+, `SharePlay` or `DeviceDiscoveryUI` can be used to bootstrap.

**TCP direct transport** opens a TLS 1.3 connection directly to the device's LAN IP, discovered via Bonjour. Files are chunked at 256 KB and sent with a simple length-prefixed binary protocol. The receiver ACKs each chunk; the sender retries on timeout.

**Relay transport** is a lightweight server (Go) that acts as a rendezvous point. Each device maintains a long-poll or WebSocket connection to the relay. Files are end-to-end encrypted with the recipient's public key before leaving the sender — the relay cannot read them.

### 5. Offline Queue Delivery

When a device comes online:

```
1. DeviceRegistry fires a .deviceOnline(id) notification
2. QueueProcessor receives it, queries SQLite for .queued transfers to that device
3. For each transfer (oldest first):
     a. Choose best transport
     b. Mark transfer .sending
     c. Stream file chunks; update progress in real-time
     d. On success: mark .completed, clean up temp files
     e. On failure: mark .failed, increment retryCount, schedule retry
```

**Retry policy**: exponential backoff capped at 1 hour. After 5 failures, the transfer is parked as `.failed` and the user is notified.

### 6. Security model

- All transfers are **E2E encrypted** with Curve25519 ECDH + ChaCha20-Poly1305
- Device pairing requires **out-of-band verification** (QR code or numeric code)
- Relay server sees only: sender ID, recipient ID, encrypted blob, size — nothing else
- Keys are stored in the macOS/iOS **Keychain**, never on disk in plaintext
- Transfer files are staged in a sandboxed temp directory and deleted after ACK

---

## Cross-platform

| Platform | Implementation |
|---|---|
| macOS | SwiftUI app (this repo) |
| iOS | SwiftUI app (shared models + store, platform-specific transport) |
| Windows | Electron + Go sidecar for transport |
| Android | Kotlin + Coroutines, same relay protocol |

The relay protocol is a minimal JSON-over-WebSocket signaling layer with binary frames for file data. Any platform can implement it in ~500 lines.

---

## Key technical risks

**AWDL access on macOS**: Apple restricts direct AWDL access to sandboxed apps. Using AirDrop's native flow (`NSSharingService`) avoids this but loses progress visibility and queue control. The TCP-direct path is the primary workaround for LAN transfers.

**Background execution on iOS**: iOS aggressively suspends apps. The iOS companion needs a `BGAppRefreshTask` + `NEAppPushProvider` (VoIP-push-like wake) to process the queue when the screen is off.

**Relay server cost**: Large files through the relay are expensive. Cap relay transfers at 2 GB and prompt for direct transfer for anything larger (requires both devices online simultaneously).

**File path stability**: Queued files are referenced by URL. If the user moves or deletes the source file before the device comes online, the transfer fails. The fix is to copy files to a dedicated queue staging directory on enqueue.

---

## File layout

```
BetterDrop/
├── BetterDropApp.swift        — app entry, MenuBarExtra
├── Models/
│   ├── Device.swift
│   └── Transfer.swift
├── Store/
│   └── AppStore.swift         — single source of truth
├── Views/
│   ├── ContentView.swift      — device grid main window
│   ├── DeviceCardView.swift   — large drop-target card
│   ├── QueueSheetView.swift   — per-device queue inspector
│   ├── MenuBarPopoverView.swift
│   ├── TransferRowView.swift
│   └── SharedComponents.swift — StatusDot, DeviceAvatar, DropZoneView
├── Engine/ (TODO)
│   ├── QueueProcessor.swift
│   ├── DeviceRegistry.swift
│   └── Transports/
│       ├── AWDLTransport.swift
│       ├── TCPDirectTransport.swift
│       └── RelayTransport.swift
└── Persistence/ (TODO)
    └── Database.swift         — GRDB SQLite wrapper
```
