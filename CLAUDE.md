# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

A **Docker image repo**, not an application: the SCUM dedicated server for Flux,
`runonflux/scum-server-flux`. The server is **Windows-only** (Steam app 3792580, anonymous), so it runs
under Wine 10.0 staging-tkg with fsync (pinned by checksum), **without a display**, like
`~/work/abioticfactor-server-flux` (the shape this repo copies), `~/work/sotf-server-flux`,
`~/work/enshrouded-server-flux` and `~/work/vrising-server-flux`. Written from scratch: third-party SCUM
images are reference only and are never shipped.

**PID 1 is `flux-entrypoint.sh`, never the game.** The game is a child, so a stop reaches us first.

## Commands

```bash
./tests/test-flux.sh                                   # unit tests (flux-lib.sh, fluxscum.py)
docker build --build-arg FLUX_IMAGE_VERSION=1.0.1 -t scum-server-flux:local .
./tests/test-image.sh scum-server-flux:local           # the scripts INSIDE the image, stand-in steamcmd + server
docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

A change to what the image does bumps `VERSION` and adds a line under "Versions" in the README.
A real-game test needs the install volume (15.5 GB): see README "Measured" for the lab used.

## The files

- `scripts/flux-entrypoint.sh`: per generation SteamCMD (Windows build), restore, save guard, backup,
  `flux-scum apply`, Wine prefix, server; watcher (world loaded, Steam build follow, daily restart),
  backupper, snapshotter, log capper.
- `scripts/fluxscum.py`: every rule about the server's files and the hub's commands.
- `scripts/flux-lib.sh`: helpers; sourcing it must stay side-effect free.
- `scripts/data/`: the game's own default `ServerSettings.ini` (the panel's types and defaults come from
  it) and the three JSON rule files as the game writes them. Refresh them when a game update changes them.
- `tests/image/in-container.sh`: stand-in server (a Python script named like the exe).

## Things that will bite you (all measured on build 26280049, game 1.3.5)

- **The save is one SQLite database** (`SCUM/Saved/SaveFiles/SCUM.db`, WAL mode) the game commits to
  continuously. The LIVE copy stays on the install volume (`ml:`, local); the synced copy on the data
  volume is a snapshot made with SQLite's online backup (`flux-scum snapshot`, every 5 minutes and at a
  stop). A live WAL database must never go through a file synchroniser. Python's `sqlite3` backup against
  the game's open database was tested and the game did not notice.
- **`db-guard` decides by node id and meta, not by file times** (see README "The save" for the table):
  `snapshot.json` carries `node`/`write`, each node keeps `flux-snapshot-local.json` on `ml:`. The stop
  snapshot runs BEFORE the next guard, so `cmd_snapshot` itself must not overwrite a foreign snapshot or a pending
  restore marker (it keeps the foreign one in `flux-replaced` first). Temp dirs go under `SERVER_DIR`
  (`ml:`), never `DATA_DIR`; a rename never crosses the two volumes. Read-modify-write commands use `locked()`.
  Tests that simulate a second node use a second `FLUX_SERVER_DIR` on the same `FLUX_DATA_DIR`.
- **The server cannot be told to save** and ends at once on SIGINT (exit code 0, no shutdown code run:
  the log just stops). The WAL makes that safe for the database; the stop takes a snapshot first.
- **No Steam A2S query**: nothing answers on the game port or any other UDP port (checked with the
  server loaded, the Steam query port is not exposed). The only extra socket is **TCP game port + 2**
  (the game's own `UDedicatedServerResponse`; a stray connection logs an error and is kicked, harmless).
  Readiness is therefore the log: the first `LogSCUM: Global Stats` line.
- **Ports**: UDP game port (`-port=`), TCP game port + 2. Flux needs the block of three consecutive
  ports; the hub rolls the block (`randomExternalPortsConsecutive`) and the image reads
  `SCUM_GAME_PORT`.
- **`ServerSettings.ini` is CRLF** and the game rewrites it at every start (adding keys). The image edits
  lines in place and keeps CRLF. `-MaxPlayers=` on the command line wins over the file's `scum.MaxPlayers`;
  the image passes the file's value so they never disagree.
- **Memory is large and flat**: 10.6 GB resident at world loaded with no player, constant over 9 hours.
  Do not size a plan below 12 GB.
- **The game's own logs under `SaveFiles/Logs` are UTF-16LE with no BOM** (a NUL after every character).
  Read them with `read_game_log`, never as UTF-8: the first version of the player count read them as UTF-8 and
  could never have matched a player. The tests write the fixtures in UTF-16LE on purpose.
- **The game backs up its own database at every start** (`SaveFiles/SCUM_<time>.db-backup`) and makes 19 log
  files per start, and it deletes none of them (measured: 8 starts, 8 copies, 152 logs). `apply` keeps the
  newest 3 database copies and prunes logs older than 14 days (newest 3 of each kind kept).
- **The Wine must have fsync or esync** (see the abioticfactor repo notes: without either an idle Windows
  UE server costs far more CPU). TKG 10.16+ and WineHQ 11 are ntsync-only (`/dev/ntsync` is not
  available on Flux).
- **`-nobattleye`** is on by default (see README for what was measured with BattlEye).
- **Empty env = unset.** Flux stops a container with Docker's default 10 seconds.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced
  data volume. `flux_banner` prints the FluxCloud banner at container start and every generation.
- **Passwords are in `ServerSettings.ini`** (the game reads them there), not on the command line.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`).
