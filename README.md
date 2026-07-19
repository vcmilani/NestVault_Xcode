# NestVault — macOS Client  `v4.0.0`

Native macOS SwiftUI client for the [NestVault](https://github.com/vcmilani/NestVault) self-hosted backup server.

---

## Requirements

| Item | Minimum |
|------|---------|
| macOS | 14.0 (Sonoma) |
| Xcode | 15.0 |
| Swift | 5.9 |
| Server | backup_files v2.6+ (mínimo funcional — batch check) · v7.8+ recomendado (habilita `/register/batch`) |

---

## Project Structure

```
NestVault_Xcode/
├── NestVaultClient.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/NestVaultClient.xcscheme
└── NestVaultClient/
    │
    ├── # Entry & Core
    ├── BackupVaultApp.swift       # App entry · MenuBarExtra · Settings scene
    ├── ContentView.swift          # Main window · fixed sidebar · NavigationSplitView
    ├── Models.swift               # All data models — check/register batch, absorb, BackupSchedule
    ├── APIService.swift           # Network layer · backoff-aware checkHealth · batch check/register · Keychain-backed API key
    ├── ConfigStore.swift          # Local profile persistence (UserDefaults)
    │
    ├── # Views
    ├── DashboardView.swift        # Global stats · system explanation
    ├── BackupsView.swift          # 3-panel browser: backups → versions → files
    ├── BackupConfigsView.swift    # Profile CRUD · ExcludesEditor · ScheduleEditor
    ├── CleanupView.swift          # Old version cleanup with preview
    ├── SettingsView.swift         # Server URL · API Key · startup · system status
    ├── MenuBarView.swift          # Compact menu bar panel
    ├── PlaceholderView.swift      # ContentUnavailableView substitute (macOS 13/14)
    │
    ├── # Backup Execution
    ├── BackupRunner.swift         # Pipelined backup engine (hash→check→register/upload overlapped) · byte-weighted progress · dock progress
    ├── BackupRunnerView.swift     # Execution sheet with live log and cancel
    ├── BackupQueue.swift          # Sequential queue engine
    ├── BackupQueueView.swift      # Queue sheet with selection UI and per-item progress
    │
    ├── # Scheduling & System
    ├── ScheduleManager.swift      # Timer-based scheduler · respects power/network
    ├── ScheduleEditor.swift       # Schedule editor (Hourly/Daily/Weekly/Custom)
    ├── LoginItemManager.swift     # SMAppService wrapper for auto-start
    ├── PowerMonitor.swift         # Battery + network interface monitoring
    ├── DockProgress.swift         # Dock tile progress bar during backups
    │
    ├── # Utilities
    ├── L10n.swift                 # L("key") helper for non-view contexts
    ├── LegacyMigration.swift      # One-time migration from com.vcm.backupvault.app
    │
    ├── # Localization
    ├── en.lproj/Localizable.strings
    ├── pt-BR.lproj/Localizable.strings
    │
    └── # Resources
        ├── Info.plist             # ATS · NSLocalNetworkUsageDescription
        └── Assets.xcassets/AppIcon.appiconset/
```

---

## Setup

1. Open `NestVaultClient.xcodeproj` in Xcode
2. In **Signing & Capabilities**, select your Team
3. In **Assets.xcassets → AppIcon**, enable *Single Size* and drag a 1024×1024 PNG
4. ⌘R to run

**Bundle ID:** `com.vcm.nestvaultclient.app`

---

## Features

### Dashboard
- Cards: total backups, versions, files, and storage
- List of active backups with size and last version date
- Explanation panel: SHA-256 deduplication, versioning, label isolation, snapshots
- Alert banner when the server is unreachable

### Backups (Server Browser)
- 3-panel `HStack` layout: backups → versions → files
- Filter by backup label and file name
- File table with SHA-256, status, size
- Delete individual version via context menu

### My Backups (Local Profiles)
- Create and manage local backup profiles
- Each profile: name, label, source folder, server override, workers, prefix, excludes, schedule
- Native folder picker (`NSOpenPanel` via `panel.begin`)
- 4-tab editor: General / Server / Schedule / Exclusions
- Run individual backup (sheet with live log)
- Run queue with selection UI and per-item progress
- Duplicate-run guard: reopening the runner sheet for a profile already backing up (manual, scheduled, or as the current queue item) re-attaches to the active runner instead of starting a second one; the label stays disabled elsewhere until it finishes
- Delete backup from server (context menu)
- Python equivalent command preview

### Smart Skip (v3.0)
- Optional per-profile toggle: **Skip if no changes**
- Before running the classify/hash/upload pipeline, compares the local file tree against the hash cache (`mtime` + `size`)
- If 0 files changed: skips classify, execute, and sync phases entirely; creates a new version by calling `POST /absorb` from the previous version — no upload
- If any file changed (or was added/deleted): falls back to a full backup automatically
- **1-week safety override:** if more than 7 days have elapsed since the last full backup, a full run is forced regardless of change detection, to keep the server verified
- `lastFullBackupDate` is persisted per profile and updated only after a real full backup completes
- Recommended for backups maintained by a single client machine (no concurrent writers)

### Accumulate Mode
- Optional per-profile toggle: **Accumulate** (`profile.accumulate`) — for archives that are never fully present on the client at once (e.g. a photo library spread across external drives)
- On finalize, the client calls `POST /absorb` with the previous done version as source: the server copies every `VersionFile` absent from the current version (by `original_path`) into it, so deleted-from-client files are preserved instead of dropped
- **Client-side optimization:** unchanged files whose exact content (same server path + sha256) already exists in the previous done version are withheld from the register pipeline entirely and inherited by that same absorb call — zero register round-trips for them, instead of one request each
- **Safety guard:** once files are withheld this way, absorb becomes structural rather than best-effort — if it fails, or inherits fewer paths than were withheld, the version is marked `failed` rather than silently missing files
- Profiles without a previous done version, or where the previous version's file cache is unavailable, fall back to registering every file individually (no withholding)

### Scheduling
- 5 modes: **Disabled / Hourly / Daily / Weekly / Custom (minutes)**
- Daily and Weekly respect a configured time-of-day
- Weekly also respects day of week
- Custom supports 5–10080 minutes
- `ScheduleManager` checks every 30s with a `Timer`
- Respects network reachability, battery state, and active backup lock
- Shows next run date in editor and last run time in detail view
- A schedule that has never run anchors to the moment it was enabled (not to the distant past), so a freshly configured daily/weekly schedule fires at its configured time instead of immediately
- Local notifications (`UserNotifications`) report completion or failure for scheduled individual backups and scheduled queue runs — the only reliable signal while the app runs as a menu-bar accessory, since the Dock bounce is invisible without a Dock icon

### Cleanup
- Mode: all backups or specific label
- Keep N most recent versions (default: 5)
- Per-label preview table before executing
- Mandatory confirmation alert
- Detailed results: versions removed + storage files freed

### Menu Bar (`MenuBarExtra`)
- Connection indicator icon
- Compact panel: status, 3 mini-stats, 5 recent backups
- Quick actions: Open NestVault · Settings · Quit

### Settings
- **General tab:** Login Item (start with macOS via `SMAppService`), network status, power source, backoff info
- **Server tab:** Server URL and API Key, test connection, tips
- **About tab:** version, links to Swagger UI and GitHub

---

## API Contract (v2.6 baseline · v7.8+ recommended)

### Endpoints

| Method | Endpoint | Usage |
|--------|----------|-------|
| `GET` | `/health` | Check connection (backoff-aware) |
| `GET` | `/backups` | List backups with `version_count`, `file_count`, `total_size_bytes` |
| `GET` | `/backups/{label}/versions` | List versions |
| `GET` | `/files?backup_label=&version_key=` | List files |
| `POST` | `/backups` | Create backup (`label`, `client_name`) |
| `POST` | `/backups/{label}/versions` | Create version (`version_key`) |
| `POST` | `/check` | Check single file: returns `needs_upload`, `content_exists` |
| `POST` | `/check/batch` | Check up to 100 files in one request (v2.6+) |
| `POST` | `/register/batch` | Register up to 500 files whose content already exists in one request — one server commit per batch instead of one per file (v7.8+; client batches at 200) |
| `POST` | `/upload` | Upload file (binary) or register (header only) |
| `POST` | `/sync` | Mark absent files as deleted (`existing_paths`) |
| `PATCH` | `/backups/{label}/versions/{key}` | Finalize version (`status: done/failed`) |
| `POST` | `/backups/{label}/cleanup` | Remove old versions (`keep`) |
| `DELETE` | `/backups/{label}/versions/{key}` | Delete version |
| `DELETE` | `/backups/{label}` | Delete entire backup |

### Upload Protocol

**New content** (`content_exists = false`):
```
POST /upload
Content-Type: application/octet-stream
X-Backup-Label:   <label>
X-Version-Key:    <version_key>
X-Original-Path:  <path base64>
X-Mtime:          <epoch float>

<raw file bytes>
```

**Already in storage** (`content_exists = true`):
```
POST /upload
X-Backup-Label:    <label>
X-Version-Key:     <version_key>
X-Original-Path:   <path base64>
X-Content-Sha256:  <sha256>
X-Mtime:           <epoch float>
(no body)
```

---

## Backup Engine

The `BackupRunner` walks the source tree once (BFS over `contentsOfDirectory` with `includingPropertiesForKeys` — `mtime`, `size`, `isDirectory` — in a single kernel pass), splits files into cache hits (matching mtime+size against the previous version or the local hash cache) and files needing a hash, then runs the rest as a **pipeline** instead of strict sequential phases:

- A **producer** hashes changed files in parallel (SHA-256, streamed in 4 MB chunks) and, as each batch of hashes completes, classifies it against the server (`POST /check/batch`) — CPU (hashing) and network (classification) overlap instead of waiting on each other.
- Cache hits and classified "register" items are coalesced into `/register/batch` requests (batches of 200) when the server supports it (v7.8+); otherwise they fall back to individual `POST /upload` register calls. A batch item whose content turns out missing server-side escalates to a full upload; a batch that fails after retries falls back to per-file registers.
- Files needing new content upload via `POST /upload` with a binary body, streamed directly from disk with configurable concurrency (`workers`) and exponential retry (3 attempts).
- **Progress** is a single pool of byte-equivalent units spanning hashing + classification + transfer (a server round-trip costs a fixed unit; upload cost is the file's actual size). It only moves forward, and is throttled to ~10 updates/sec to stay smooth with tens of thousands of files. Upload progress itself streams in real time via a per-task `URLSessionTaskDelegate` reporting bytes sent, so a single large file no longer stalls the bar.
- In accumulate mode, files withheld for absorb-inheritance (see **Accumulate Mode** above) skip this pipeline entirely — no hash, no check, no register.

---

## Local Persistence

**UserDefaults:**

| Key | Content |
|-----|---------|
| `server_url` | Server URL |
| `backupProfiles_v1` | JSON array of `BackupProfile` (includes `BackupSchedule`, `lastRun`, `smartSkip`, `accumulate`, `lastFullBackupDate`) |
| `schedule.pauseOnBattery` | Bool — pause when on battery |
| `schedule.minBatteryPercent` | Int — minimum battery level to run |

**Keychain** (service `com.vcm.nestvault`):

| Item | Content |
|------|---------|
| `api_key` | API Key — no longer stored in UserDefaults. A one-time migration on first launch of this version moves any existing plaintext key from UserDefaults into the Keychain and clears the old value. |

---

## macOS Permissions

Declared in `Info.plist`:
- `NSLocalNetworkUsageDescription` — required on macOS 15+ for local network access
- `NSAppTransportSecurity` with `NSAllowsLocalNetworking` — allows HTTP on local IPs

On first connection, macOS will prompt for local network permission — click **Allow**.

---

## Localization

The app automatically uses the system language. Supported: **English** (default) and **Brazilian Portuguese**.

Files: `en.lproj/Localizable.strings` and `pt-BR.lproj/Localizable.strings`.

---

## Server Quick Start

```bash
cd backup_files/server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export BACKUP_API_KEY="your-key"
export STORAGE_DIR="/mnt/external/backups"
export DB_PATH="/mnt/external/backup.db"

uvicorn main:app --host 0.0.0.0 --port 8000
```

Web dashboard: `http://<pi-ip>:8000/`  
Swagger UI: `http://<pi-ip>:8000/docs`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Error `-1009` | Local network permission denied | System Settings → Privacy → Local Network → enable NestVault |
| `BadRequest` on upload | Server older than v2.1 | Update server to v2.6+ |
| Keys shown raw (e.g. `menubar.open`) | Localizable.strings not in bundle | Verify `Localizable.strings` is in target Resources build phase |
| Schedule not running | Battery mode or network | Check Settings → General → System Status |
| `requiresApproval` on Login Item | macOS needs user consent | Click "Open Settings" in Settings → General |
| Connection refused | Server offline | `systemctl status backup-server` on the Pi |

---

## Changelog

### 4.0.0

| Componente | Mudança |
|---|---|
| **`BackupRunner.swift` — progress model** | Substituído o modelo de pesos fixos (40/60 entre fases) por um pool único de unidades byte-equivalentes; fases visíveis (`preparing/scanning/checking/processing/finalizing`) com contagens ao vivo; UI throttled a ~10 updates/s |
| **`BackupRunner.swift` — pipeline** | Hash → check → register/upload deixaram de ser fases sequenciais estritas: um produtor faz hash em paralelo e classifica em lotes assim que completa, sobrepondo CPU e rede; um executor consome via `AsyncStream` respeitando o limite de `workers` |
| **`BackupRunner.swift` — upload progress** | Progresso intra-upload via `URLSessionTaskDelegate` por task (deltas de bytes enviados), eliminando o congelamento da barra durante um único arquivo grande |
| **`ScheduleManager.swift` — duplicate-run guard** | Reabrir o sheet de um perfil já em backup (manual, agendado, ou item corrente da fila) reanexa ao runner ativo em vez de iniciar um segundo; o label fica bloqueado em outros pontos de entrada até terminar |
| **`ScheduleManager.swift` — schedule anchors** | Um agendamento nunca executado ancora no momento em que foi habilitado, não no passado distante — agendamentos diário/semanal recém-criados disparam no horário configurado, não imediatamente |
| **`ScheduleManager.swift` / `BackupNotifier`** | Notificações locais (`UserNotifications`) para conclusão/falha de backups agendados e de fila — sinal confiável já que o bounce do Dock é invisível sem ícone no Dock (app como acessório de menu bar) |
| **`APIService.swift` — Keychain** | API key migrada de `UserDefaults` (plaintext) para o Keychain (`com.vcm.nestvault`), com migração automática de uma vez na primeira execução |
| **Limpeza de código morto** | Removidos `BackoffPolicy.swift`, `UploadResponse`, `BackupDeletedResponse`, `stats.total`/`stats.skipped` não utilizados, `PowerMonitor` duplicado em `SettingsView` |
| **Performance** | Classificação fast/slow e detecção de smart-skip reduzidas de ~2 saltos de actor por arquivo para 1 salto para a lista inteira; `cleanupAll` coleta erros por label em vez de abortar no primeiro; `ForEach` com identidade estável em vez de índice posicional |
| **Localização e polimento** | Strings PT hardcoded movidas para `Localizable.strings` (pt-BR/en); `onChange(of:perform:)` migrado para a API de dois parâmetros do macOS 14 |
| **`BackupRunner.swift` — Accumulate Mode** | Modo acumulativo passa a herdar arquivos inalterados via `/absorb` em vez de registrá-los um a um — ver seção **Accumulate Mode** acima |
| **`APIService.swift`, `BackupRunner.swift` — `/register/batch`** | Cliente adota o endpoint de registro em lote do servidor (v7.8+) — ver **API Contract** e **Backup Engine** acima |
