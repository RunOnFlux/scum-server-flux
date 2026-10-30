# scum-server-flux

SCUM dedicated server for Flux: `runonflux/scum-server-flux`.

Gamepires ships the dedicated server for Windows only (Steam app 3792580, anonymous download), so the image
runs it under Wine 10.0 staging-tkg with fsync (the Wine of our V Rising, Enshrouded, Sons of the Forest and
Abiotic Factor images), **with no virtual display**: the server does not need one. Base
`steamcmd/steamcmd:ubuntu-24`. PID 1 is a bash supervisor (`flux-entrypoint.sh`); `flux-scum`
(`fluxscum.py`) holds every decision about the game's files and is the hub's CLI. Written from scratch;
third-party SCUM images were only read for reference.

- SteamCMD update of the Windows build on every start (anonymous), retried when a fresh SteamCMD says "Missing configuration".
- `ServerSettings.ini` (all 437 keys, typed from the game's own defaults), the player lists (admins, bans,
  whitelist, exclusive, silenced, settings admins) and the three JSON rule files (raid times, economy,
  notifications) written from the environment and the hub's panel.
- **The save is an SQLite database** the game keeps open: the live copy stays local, a consistent snapshot
  (SQLite's online backup) goes to the synced volume every 5 minutes and at a stop (see "The save").
- **The server cannot be told to save** and ends at once on a stop (see "The stop"); the stop takes a snapshot first and ends the game in about 3 s.
- Crash restart in place (5 in an hour, then exit 42), game-update following, optional daily restart.
- Backups (start, every 6 h, before a restore, and on demand with `force`), restore, import of a `SCUM.db` from another server, players
  (the save's table plus who is online), the game's own logs, a JSON status for the hub.
- **Settings the environment cannot fix are not a crash**: state `needs-fix`, nothing restarts.

## Volumes

| Path | What | Flux mount |
|---|---|---|
| `/mnt/scum/server` | game install (15.5 GB), Wine prefix (`flux-wine`), the LIVE save (`SCUM/Saved/SaveFiles/SCUM.db`) and the game's logs, `flux-logs/flux.log` (our supervisor log, 5 MB then one `.1`) | `ml:` (local, never synced) |
| `/mnt/scum/data` | `Config/WindowsServer/` (settings, lists, rule files), `SaveFiles/` (the snapshot of the save), `flux/` (state, backups, uploads) | `g:` primary |

At every start `<install>/SCUM/Saved/Config/WindowsServer` is made a symlink to `/mnt/scum/data/Config/WindowsServer`.

## Ports

Game **UDP** `SCUM_GAME_PORT` (default 7777; `-port=`), and **TCP** game port + 2 (the game's own info
responder, measured: `ss` on the loaded server shows UDP 7777 and TCP 7779 and nothing else). Flux needs the
block of three consecutive ports (7777, 7778, 7779); the hub rolls the block and the image reads the first.
The server answers **no Steam A2S query** on any port (checked loaded, anonymous Steam login), so the hub
takes status from the container and the image's own commands.

## Environment

Empty = unset. A value is written to `ServerSettings.ini` when the file is new or the value changed since the
last start, so the hub's panel edits survive restarts.

| Variable | Sets | Default |
|---|---|---|
| `SCUM_GAME_PORT` | `-port=` (1024-65533) | `7777` |
| `SCUM_SERVER_NAME` | `scum.ServerName` | `SCUM Server` |
| `SCUM_PASSWORD` | `scum.ServerPassword` | none |
| `SCUM_MAX_PLAYERS` | `scum.MaxPlayers` and `-MaxPlayers=` (1-128; never capped by the plan) | `64` (the game's file default) |
| `SCUM_ADMINS` | `AdminUsers.ini`: SteamID64s, comma separated, added on every start, never removed | none |
| `SCUM_BATTLEYE` | `true` drops `-nobattleye` (see "BattlEye") | off |
| `SCUM_EXTRA_ARGS` | more launch arguments (`-port=` and `-MaxPlayers=` are dropped) | none |
| `SCUM_RESTART_TIME` | daily restart `HH:MM` (TZ, UTC if unset) | none |
| `SKIP_UPDATE` | do not run SteamCMD (an install must exist) | off |
| `FLUX_STOP_GRACE` / `FLUX_RESTART_GRACE` | seconds a stop / a planned restart may take | 8 / 60 |
| `FLUX_SNAPSHOT_MINUTES`, `FLUX_STOP_SNAPSHOT_SECONDS` | snapshot cadence, and how long a stop may spend on one | 5, 3 |
| `FLUX_BACKUP_HOURS`, `FLUX_BACKUP_KEEP` | backup cadence and count | 6, 8 |
| `FLUX_RESTART_MAX_ATTEMPTS`, `FLUX_RESTART_WINDOW` | crash budget | 5 per 3600 s |

The password is written to `ServerSettings.ini` (that is where the game reads it), never put on the command line.

## `flux-scum` (the hub's CLI)

`status`, `settings`, `set-settings '{"values": {...}}'`, `list|set-list <admins|banned|exclusive|whitelist|silenced|settings-admins>`,
`list-add|list-remove <list> <steamid64>`, `players`, `file|set-file <raid|economy|notifications>`,
`gamelog <kind> [lines]`, `backups`, `backup <label> [force]`, `restore <name>`, `restore-mark [label]`,
`import-save <db>`, `restart`, `join-password`. Every command answers one JSON document (a refusal is
`{"ok": false, "error": ...}` with exit 1). Settings are validated by the type of the game's default (bool, int,
float, time `HH:MM:SS`, text) and refused as a whole if one is wrong. Run `flux-scum` for the list.

- **`status` tells an old image from a new one**: `imageVersion` (the `FLUX_IMAGE_VERSION`, `dev` on a local
  build), `verbs` (what the hub may call) and `capabilities` (`list-add`, `list-remove`, `gamelog`, `backup-json`,
  `backup-force-keep`, `restore-marker`, `save-guard`). A hub that does not find a name there must not call it.
  `status.saveGuard` is what the last start decided about the save (below).
- **`list-add` / `list-remove`** read, change and write one list under a lock, so a panel with stale state cannot
  overwrite a list: `{"ok": true, "name", "id", "changed", "count"}`; adding what is there or removing what is not is
  `ok` with `changed: false` and does not touch the file. Other ids' permission suffixes and CRLF are kept.
- **`gamelog <kind> [lines]`** is the tail of the game's own log (`SaveFiles/Logs/<kind>_<time>.log`, UTF-16LE):
  `{"ok": true, "kind", "files", "lines", "count", "truncated", "kinds"}`, oldest line first, default 200 lines, at
  most 2000 and 512 KB. Kinds: `admin chat kill economy violations login` and any other kind found on disk
  (`violation` is accepted). An unknown kind answers `{"ok": false, "error", "kinds": [...]}` with exit 1.
- **`backup <label> [force]`** answers ONE JSON document and nothing else. Made: `{"ok": true, "name", "size", "why",
  "keep"}`. Not made on purpose (nothing saved yet, or the newest is under 60 minutes old and it is not forced):
  `{"ok": false, "skipped": true, "error"}`. Failed: `{"ok": false, "error"}`. Not ok exits 1. `force` skips the age rule
  and the backup is kept (never pruned), like the ones made before a restore: use it for a safety backup before a
  wipe. (The supervisor's own backups use the internal `backup-plain`, which prints the `# ` log lines.)
- **`restore-mark [label]`** (or the file `flux/restore-marker.json`, `{"time": epoch, "label": text}`): see "A restore from outside".

## The save

`SaveFiles/SCUM.db` is SQLite in WAL mode (header `SQLite format 3`, 359 tables, 4.7 MB empty). The game
commits to it all the time and makes its own copy at every start (`SCUM_<time>.db-backup`). A live WAL
database must not be synchronised file by file, so:

- the live copy is on the install volume (local);
- `flux-scum snapshot` (SQLite `backup()` of the open database, then `quick_check`) writes the synced copy
  on the data volume every 5 minutes and at a stop; Python's backup against the game's open database was
  tested and the game did not notice (0.04 s for an empty save);
- **`db-guard` before every start** decides with an explicit signal, not with file times alone. `snapshot.json`
  carries `time`, `size`, `node` (a random id kept on the install volume, never synced) and `write` (an id per
  snapshot); each node keeps `flux-snapshot-local.json` (install volume) with the last meta it wrote or adopted.
  The snapshot is trusted only when `snapshot.json.size == size of SCUM.db` (they sync as separate files).

  | Situation | Decision |
  |---|---|
  | no live save, trusted snapshot (new node) | snapshot used |
  | no live save, snapshot not trusted / nothing arrived | wait 5 min, then newest backup, else wait (never a new world over a real one) |
  | live save fails `quick_check` | snapshot, else newest backup |
  | restore marker present, snapshot trusted | **restore honoured**: snapshot used, this node's copy to `flux-replaced`, marker consumed |
  | restore marker present, files not all there | wait up to 5 min, then give up (`lastRestore` not ok), marker removed |
  | live + snapshot not trusted | live kept |
  | snapshot is this node's (or already adopted) | live kept (`own`) |
  | foreign, newer than this node's last, live untouched since | **failover**: snapshot used, live to `flux-replaced` |
  | foreign, newer, and live also changed since | **split-brain**: the later of the two is used, the other is kept in `flux-replaced`, notice |
  | foreign, not newer than this node's last, no marker (a restore, or a stale sync) | live kept, the snapshot kept in `flux-replaced`, notice (`older-snapshot`) |
  | nothing recorded on this node (upgrade from 1.0.0) | the old rule: a snapshot much newer than the live save wins |

  `flux-replaced` (install volume) keeps the newest 8 copies. The decision is in `flux/save-guard.json` and in
  `flux-scum status` as `saveGuard` `{decision, message, notice, time}`. Stops and the 5-minute snapshot also check:
  a snapshot on the volume that this node did not write is copied to `flux-replaced` before it is overwritten, and
  nothing is overwritten while a restore marker waits. **Unit-tested only**: no two real nodes or hub restore ran;
- backups are `.tar.gz` of a consistent copy of the database plus the config folder; the temporary copy is made
  on the install volume (`.flux-backup-*` / `.flux-restore-*` under `/mnt/scum/server`), never on the synced one, and
  leftovers (also those 1.0.0 left on the data volume) older than 10 minutes are removed at every start.

### A restore from outside (the hub's automatic backups)

A restore that puts an OLDER `SCUM.db` and `snapshot.json` straight on the synced volume looks, to the image, like
a stale sync, so by default it is **not** honoured (both copies are kept and the panel is told). To make the image
honour it, after the hub wrote BOTH files (SCUM.db first, `snapshot.json` last), call `flux-scum restore-mark "<label>"`
(or write `flux/restore-marker.json`), then restart the app. A marker whose files never become usable is dropped after 5 minutes.

## The stop

**The server cannot be told to save.** SIGINT ends it at once (Wine's ExitProcess, exit 0, the log just stops, no
shutdown code runs). There is no console and no RCON. The WAL makes that safe for the database (a `kill -9`
mid-run was followed by a clean `quick_check` and a normal start); what a stop loses is the last moments the
game had not committed. The supervisor takes a snapshot first (bounded to 3 s), then SIGINT: `docker stop` on a
loaded server returned in 3.3 s (limit 10 s). Do not promise "saved on stop" in copy.

## BattlEye

The default launch line has `-nobattleye`. With BattlEye on, the server under Wine initialises it
(`LogBattlEye: Initialized BattlEye Server`, `MasterPort 8037`) and loads the world. **Not verified with a real
client** (none was available), so the image does not default to it: `SCUM_BATTLEYE=true` turns it on.

## Versions

- 1.0.1: `db-guard` honours a restore (marker) and tells a failover, a split-brain and a stale/older snapshot apart; backup/restore temp dirs on the install volume; `backup` answers one JSON document and `force` keeps the backup; new verbs `list-add`, `list-remove`, `gamelog`, `restore-mark`; `status` carries `imageVersion`, `verbs`, `capabilities`, `saveGuard`.
- 1.0.0 (2026-10-29): first release. The game's own database copies and logs are pruned at every start (it deletes none); its logs are read as UTF-16LE.

## Measured

Lab: WSL2 host, Linux 6.6.87, 20 cores, 15 GB RAM, Docker 28.3.2; container `--cpus=4 --memory=14g` (and 12g
for the first runs). Game 1.3.5 (Steam build 26280049). **No player ever connected: no game client was available.**

| What | Value |
|---|---|
| Install | 15.5 GB (Steam reports 15,499,756,916 bytes); Wine prefix about 0.5 GB |
| Download, first install | about 36 min on the lab line (the SteamCMD run alone) |
| Idle, world loaded, no player (RssAnon) | **10.6 GB** (10.2 GB at load, 10.57-10.88 GB over 9 h 15 min, flat: no growth) |
| CPU idle | 0.3 of a core (7-17 % of 4 cores, mostly the first minutes) |
| Threads | 89 |
| Tick | 5 FPS (199 ms) idle, `MinServerTickRate=5`, `MaxServerTickRate=30` |
| World load (start to "Global Stats") | 79-94 s on 4 cores, warm |
| Panel restart to running again | about 2 min (stop 3 s + SteamCMD check 8 s + backup + 10 s back-off + load 80-95 s) |
| `docker stop` on a loaded server | 3.3 s, exit 0 |
| Crash (`kill -9`) | restarted in place in 10 s + load, save intact |
| Ports | UDP game port, TCP game port + 2 |
| A2S | none |

Things not measured and not claimed: memory and CPU with players, the login log's LINE format with a real player
(the file's encoding IS measured: UTF-16LE with no BOM, decoded by `read_game_log`; `flux-scum status` then looks for a
SteamID64 and `logged in` / `logged out` on a line, which is the game's known format, covered by the tests), how a console or the Steam list sees the
server, the 128-player ceiling (the file's own default is 64; official servers run 128), a cold first start
end to end in the image (the download and the update-check path were each run for real).

The lab scripts and fixtures (`ServerSettings.ini`, the rule files as the game wrote them, the memory samples)
are in `~/work/game-drafts/scum/lab/` (not part of the image).
