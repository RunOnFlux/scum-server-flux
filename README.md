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
- Backups (start, every 6 h, before a restore), restore, import of a `SCUM.db` from another server, players
  (the save's table plus who is online), a JSON status for the hub.
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
`players`, `file|set-file <raid|economy|notifications>`, `backups`, `backup`, `restore <name>`, `import-save <db>`,
`restart`, `join-password`. Every command answers one JSON document. Settings are validated by the type of the
game's default (bool, int, float, time `HH:MM:SS`, text) and refused as a whole if one is wrong. Run `flux-scum` for the list.

## The save

`SaveFiles/SCUM.db` is SQLite in WAL mode (header `SQLite format 3`, 359 tables, 4.7 MB empty). The game
commits to it all the time and makes its own copy at every start (`SCUM_<time>.db-backup`). A live WAL
database must not be synchronised file by file, so:

- the live copy is on the install volume (local);
- `flux-scum snapshot` (SQLite `backup()` of the open database, then `quick_check`) writes the synced copy
  on the data volume every 5 minutes and at a stop; Python's backup against the game's open database was
  tested and the game did not notice (0.04 s for an empty save);
- **`db-guard` before every start**: no live save and a snapshot (a new node) -> the snapshot is used; a
  snapshot much newer than the live save (another node ran meanwhile) -> the snapshot is used and the local
  copy kept in `flux-replaced`; a live save failing `quick_check` -> the snapshot, else the newest backup;
  a save this server had and none anywhere (a half-synced volume) -> the start waits 5 minutes, then puts
  back the newest backup, else waits with the reason in the state. It never starts a new world over a real one;
- backups are `.tar.gz` of a consistent copy of the database plus the config folder.

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
