#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxscum.py's file handling. No Docker, no
# Steam, no Wine, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "7777 is a port" "7777" "$(flux_port 7777 1)"
check "empty takes the default" "27015" "$(flux_port '' 27015)"
check "a leading zero is not octal" "9700" "$(flux_port 09700 1)"
check "port 80 is refused" "1" "$(status flux_port 80 1)"
check "a word is not a port" "1" "$(status flux_port abc 1)"
check "distinct ports" "0" "$(status flux_ports_distinct 7777 27015)"
check "a port used twice" "1" "$(status flux_ports_distinct 7777 7777)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the wine path of a folder" 'Z:\mnt\scum\data\Config' "$(flux_wine_path /mnt/scum/data/Config)"
check "the game is found by its exe name" "SCUMServer.exe" "$(printf 'x\nSCUMServer.exe -log -port=7777\n' | grep -o -E "${FLUX_GAME_PATTERN}")"
check "and pgrep's own command line is not" "1" "$(status bash -c "echo 'pgrep -f ${FLUX_GAME_PATTERN}' | grep -q -E '${FLUX_GAME_PATTERN}'")"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
check "marker notbefore" "123" "$(printf 'x\nnotbefore=123\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"
check "marker without notbefore" "0" "$(printf 'x\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"

# --- Log noise and passwords -------------------------------------------------------------------
check "level streaming is noise" "0" "$(status flux_noise <<<"LogStreaming: Display: ULevelStreaming::RequestLevel(/Game/ConZ_Files/Maps/The_Island/Z_0_Vrsar) is flushing async loading")"
check "per-tick stats are noise" "0" "$(status flux_noise <<<"LogSCUM: Global Stats: 199.3ms (  5.0FPS), 199.9ms")"
check "resource timings are noise" "0" "$(status flux_noise <<<"LogReplenishableResourceManager: Warning: DbUpdateReplenishableResourceTimers: 0.5947ms")"
check "config echoes are noise" "0" "$(status flux_noise <<<"LogConfig: Setting CVar [[scum.ServerName:LabTest]]")"
check "shader library mounting is noise" "0" "$(status flux_noise <<<"LogShaderLibrary: Display: ShaderCodeLibraryPakFileMountedCallback: PakFile x")"
check "blank lines are noise" "0" "$(status flux_noise <<<"   ")"
check "the listening line is not noise" "1" "$(status flux_noise <<<"LogNet: GameNetDriver IpNetDriver_2147482441 IpNetDriver listening on port 7777")"
check "an auto-save is not noise" "1" "$(status flux_noise <<<"LogEntitySystem: Auto-save took 0.020ms for 0 objects")"
check "an error is not noise" "1" "$(status flux_noise <<<"LogSCUM: Error: UDedicatedServerResponse: Invalid message type, kicking the client")"
check "passwords are redacted" 'LogInit: Command Line:  -log -ServerPassword=*** -port=7777 -AdminPassword=***' "$(echo 'LogInit: Command Line:  -log -ServerPassword=hunter2 -port=7777 -AdminPassword="a"' | flux_redact)"
touch -d '2026-10-28 10:00:00' "${tmp}/mark"
printf 'LogStreaming: x\nLogSCUM: Global Stats: 199ms\n' >"${tmp}/g.log"
check "the world is loaded at the first Global Stats line of this generation" "0" "$(status flux_world_loaded "${tmp}/g.log" "${tmp}/mark")"
printf 'LogStreaming: x\n' >"${tmp}/g2.log"
check "and not before" "1" "$(status flux_world_loaded "${tmp}/g2.log" "${tmp}/mark")"
check "an empty log is not loaded" "1" "$(: >"${tmp}/g3.log"; status flux_world_loaded "${tmp}/g3.log" "${tmp}/mark")"
touch -d '2026-10-28 09:00:00' "${tmp}/g.log"
check "the previous generation's log (older than the start) is not loaded" "1" "$(status flux_world_loaded "${tmp}/g.log" "${tmp}/mark")"
check "a missing log is not loaded" "1" "$(status flux_world_loaded "${tmp}/nope.log" "${tmp}/mark")"

# --- Steam builds ------------------------------------------------------------------------------
printf '"AppState"\n{\n\t"appid"\t\t"3792580"\n\t"buildid"\t\t"24343458"\n}\n' >"${tmp}/manifest.acf"
check "installed build" "24343458" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "24400000" "$(printf '%s\n' '"3792580"' '{' '"depots"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"24400000"' '}' | flux_public_build)"

# --- fluxscum.py ----------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
mkdir -p "${server}/steamapps"
cp "${tmp}/manifest.acf" "${server}/steamapps/appmanifest_3792580.acf"
scum() { # VAR=value... command args: fluxscum.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" "${vars[@]}" python3 scripts/fluxscum.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))' "$1"; }
ini="${data}/Config/WindowsServer/ServerSettings.ini"
inival() { tr -d '\r' <"${ini}" | sed -n "s/^$1=//p"; }
saved="${server}/SCUM/Saved"

scum apply >"${tmp}/apply.out"
check "apply links the game's Config to the data volume" "${data}/Config/WindowsServer" "$(readlink "${saved}/Config/WindowsServer")"
check "and makes the settings file from the game's own defaults" "SCUM Server" "$(inival scum.ServerName)"
check "with the line endings of the game's file (CRLF)" "449" "$(grep -c $'\r' "${ini}")"
check "and empty player lists" "1" "$(status test -s "${data}/Config/WindowsServer/AdminUsers.ini")"
check "the default launch line" "-log -port=7777 -MaxPlayers=64 -nobattleye" "$(scum args | tr '\n' ' ' | sed 's/ $//')"
check "the state records the port" "7777" "$(jget gamePort <"${data}/flux/state.json")"
check "BattlEye can be asked for" "0" "$(scum SCUM_BATTLEYE=true args | grep -c nobattleye)"

scum SCUM_GAME_PORT=31000 SCUM_SERVER_NAME="Lab One" SCUM_MAX_PLAYERS=12 SCUM_PASSWORD=pw1 apply >/dev/null
check "env sets the name" "Lab One" "$(inival scum.ServerName)"
check "env sets the players" "12" "$(inival scum.MaxPlayers)"
check "env sets the password" "pw1" "$(inival scum.ServerPassword)"
check "env sets the launch line" "-log -port=31000 -MaxPlayers=12 -nobattleye" "$(scum SCUM_GAME_PORT=31000 args | tr '\n' ' ' | sed 's/ $//')"
check "everything else in the file is untouched" "449" "$(grep -c $'\r' "${ini}")"
scum set-settings '{"values": {"scum.ServerName": "Panel Name"}}' >/dev/null
scum SCUM_SERVER_NAME="Lab One" apply >/dev/null
check "the same env value does not undo a panel change" "Panel Name" "$(inival scum.ServerName)"
scum SCUM_SERVER_NAME="Lab Two" apply >/dev/null
check "a changed env value applies" "Lab Two" "$(inival scum.ServerName)"
check "an empty env value leaves the setting" "Lab Two" "$(scum SCUM_SERVER_NAME= apply >/dev/null; inival scum.ServerName)"
check "a port below 1024 is refused" "2" "$(status scum SCUM_GAME_PORT=80 apply)"
check "the refusal names the variable" "1" "$(scum SCUM_GAME_PORT=80 apply | grep -c 'ERROR SCUM_GAME_PORT=80')"
check "port + 2 must still be a port" "2" "$(status scum SCUM_GAME_PORT=65534 apply)"
check "a word is not a port" "2" "$(status scum SCUM_GAME_PORT=abc apply)"
check "args refuses what apply refuses" "2" "$(status scum SCUM_GAME_PORT=80 args)"
check "players above the cap are refused by the env" "64" "$(scum SCUM_MAX_PLAYERS=500 apply >/dev/null; scum SCUM_MAX_PLAYERS=64 apply >/dev/null; inival scum.MaxPlayers)"

# Settings, validated by the type the game's default has.
check "settings lists every key" "437" "$(scum settings | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["settings"]))')"
check "a key has its default and type" "bool False" "$(scum settings | python3 -c 'import json,sys
for s in json.load(sys.stdin)["settings"]:
    if s["key"]=="scum.AllowEvents": print(s["type"], not s["default"]=="True")')"
check "the password is never listed" "" "$(scum SCUM_PASSWORD=pw1 apply >/dev/null; scum settings | python3 -c 'import json,sys
for s in json.load(sys.stdin)["settings"]:
    if s["key"]=="scum.ServerPassword": print(s["value"])')"
check "a bool is written as the game spells it" "False" "$(scum set-settings '{"values": {"scum.AllowEvents": false}}' >/dev/null; inival scum.AllowEvents)"
check "a float keeps six decimals" "2.500000" "$(scum set-settings '{"values": {"scum.FameGainMultiplier": "2.5"}}' >/dev/null; inival scum.FameGainMultiplier)"
check "an int" "7" "$(scum set-settings '{"values": {"scum.MaxAllowedBirds": 7}}' >/dev/null; inival scum.MaxAllowedBirds)"
check "a time" "09:30:00" "$(scum set-settings '{"values": {"scum.StartTimeOfDay": "09:30:00"}}' >/dev/null; inival scum.StartTimeOfDay)"
check "a bad bool is refused" "1" "$(status scum set-settings '{"values": {"scum.AllowEvents": "maybe"}}')"
check "a bad number is refused" "1" "$(status scum set-settings '{"values": {"scum.FameGainMultiplier": "lots"}}')"
check "a bad time is refused" "1" "$(status scum set-settings '{"values": {"scum.StartTimeOfDay": "9am"}}')"
check "an unknown key is refused" "1" "$(status scum set-settings '{"values": {"scum.Nope": 1}}')"
check "players above the game's cap are refused" "1" "$(status scum set-settings '{"values": {"scum.MaxPlayers": 129}}')"
check "and say which" "1" "$(scum set-settings '{"values": {"scum.MaxPlayers": 129}}' | grep -c 'scum.MaxPlayers must be from 1 to 128')"
check "players above the plan figure are not capped" "100" "$(scum set-settings '{"values": {"scum.MaxPlayers": 100}}' >/dev/null; inival scum.MaxPlayers)"
check "a refusal changes nothing" "100" "$(scum set-settings '{"values": {"scum.MaxPlayers": 50, "scum.Nope": 1}}' >/dev/null; inival scum.MaxPlayers)"
check "an empty name is refused" "1" "$(status scum set-settings '{"values": {"scum.ServerName": " "}}')"
check "a key the file lacks is added to its section" "1" "$(sed -i '/scum.MaxAllowedBirds/d' "${ini}"; scum set-settings '{"values": {"scum.MaxAllowedBirds": 9}}' >/dev/null; inival scum.MaxAllowedBirds | grep -c '^9$')"
check "the join password is read back" "pw1" "$(scum join-password | jget joinPassword)"

# Player lists.
check "an admin is added" "1" "$(scum set-list admins '{"ids": ["76561198000000001"]}' >/dev/null; scum list admins | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
check "the file has the game's line endings" "1" "$(grep -c $'\r' "${data}/Config/WindowsServer/AdminUsers.ini")"
printf '76561198000000001[SetGodMode]\r\n' >"${data}/Config/WindowsServer/AdminUsers.ini"
scum set-list admins '{"ids": ["76561198000000001", "https://steamcommunity.com/profiles/76561198000000002"]}' >/dev/null
check "a permission suffix survives a save" "76561198000000001[SetGodMode]" "$(tr -d '\r' <"${data}/Config/WindowsServer/AdminUsers.ini" | head -1)"
check "a profile link becomes the SteamID" "76561198000000002" "$(tr -d '\r' <"${data}/Config/WindowsServer/AdminUsers.ini" | tail -1)"
check "removing the last one empties the file" "0" "$(scum set-list admins '{"ids": []}' >/dev/null; wc -c <"${data}/Config/WindowsServer/AdminUsers.ini" | tr -d ' ')"
check "a bad SteamID is refused" "1" "$(status scum set-list banned '{"ids": ["nope"]}')"
check "an unknown list is refused" "64" "$(status scum list nothing)"
check "banned list" "1" "$(scum set-list banned '{"ids": ["76561198000000003"]}' >/dev/null; scum list banned | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
check "SCUM_ADMINS adds admins" "2" "$(scum SCUM_ADMINS='76561198000000004,76561198000000005' apply >/dev/null; scum list admins | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
check "and never removes one" "3" "$(scum SCUM_ADMINS='76561198000000006' apply >/dev/null; scum list admins | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"
check "and skips what is not a SteamID" "1" "$(scum SCUM_ADMINS='bob' apply | grep -c 'not a SteamID64')"

# JSON rule files.
check "a rule file reads as the game's default before the game makes one" "1" "$(scum file raid | jget text | grep -c raiding-times)"
check "valid JSON is written" "0" "$(status scum set-file raid '{"raiding-times": []}')"
check "and read back" '{"raiding-times": []}' "$(scum file raid | jget text | tr -d '\n')"
check "invalid JSON is refused" "1" "$(status scum set-file raid '{nope')"
check "a JSON array is refused" "1" "$(status scum set-file raid '[1]')"
check "an unknown file is refused" "64" "$(status scum file ini)"

# The save: an SQLite database the game keeps open. Snapshot, guard, backups, restore.
mkdb() { python3 - "$1" "${2:-1}" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL")
c.executescript("CREATE TABLE IF NOT EXISTS user(id TEXT,name TEXT,last_login_time TEXT,is_banned INTEGER); CREATE TABLE IF NOT EXISTS user_profile(id INTEGER); CREATE TABLE IF NOT EXISTS prisoner(id INTEGER);")
c.execute("DELETE FROM user"); c.execute("DELETE FROM prisoner"); c.execute("INSERT INTO user VALUES('76561198000000001','Alice','2026-10-28T10:00:00Z',0)")
c.execute("INSERT INTO user VALUES('76561198000000003','Mallory','2026-10-27T10:00:00Z',1)")
c.execute("INSERT INTO prisoner VALUES(?)",(int(sys.argv[2]),)); c.commit()
PY
}
dbrows() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select max(id) from prisoner").fetchone()[0])' "$1"; }
live="${saved}/SaveFiles/SCUM.db"
snap="${data}/SaveFiles/SCUM.db"
check "no save yet: a snapshot is skipped" "0" "$(status scum snapshot)"
check "and the guard lets the game make a new world" "0" "$(status scum db-guard)"
mkdir -p "${saved}/SaveFiles"
mkdb "${live}" 1
check "a snapshot of the live database (still open in WAL mode)" "0" "$(status scum snapshot)"
check "is a consistent copy" "1" "$(dbrows "${snap}")"
check "and is remembered" "1" "$([ -f "${data}/flux/db-seen.json" ] && echo 1)"
check "the guard keeps the live database" "0" "$(status scum db-guard)"
rm -f "${live}" "${live}-wal" "${live}-shm"
check "a new node starts from the snapshot" "1" "$(scum db-guard >/dev/null; dbrows "${live}")"
# Another node (its own install volume, the same synced data volume) runs the server and snapshots.
server2="${tmp}/server2"
mkdir -p "${server2}/SCUM/Saved/SaveFiles"
scum2() { NODE_DIR="${server2}" scum "$@"; }
scum() { # VAR=value... command args: fluxscum.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${NODE_DIR:-${server}}" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" "${vars[@]}" python3 scripts/fluxscum.py "$@"
}
mkdb "${server2}/SCUM/Saved/SaveFiles/SCUM.db" 2
sleep 2
scum2 snapshot >/dev/null
check "a snapshot written by another node, newer than ours, our save untouched since: failover, it wins" "2" "$(scum db-guard >/dev/null; dbrows "${live}")"
check "and the replaced copy is kept" "1" "$(find "${server}/flux-replaced" -type f | wc -l | tr -d ' ')"
check "and the next start finds it adopted (own)" "own" "$(scum db-guard >/dev/null; jget decision <"${data}/flux/save-guard.json")"
mkdb "${live}" 3
check "a newer live save beats the snapshot" "3" "$(scum db-guard >/dev/null; dbrows "${live}")"
printf 'garbage' >"${live}"
rm -f "${live}-wal" "${live}-shm"
check "a damaged live save is replaced by the snapshot" "2" "$(scum db-guard >/dev/null; dbrows "${live}")"
rm -f "${live}" "${live}-wal" "${live}-shm" "${snap}" "${data}/SaveFiles/snapshot.json"
check "a save this server had, now missing, waits for the sync" "1" "$(status scum db-guard)"
check "and says so" "1" "$(scum db-guard | grep -c 'Waiting for the save')"
check "with no backup, after the grace it does not start a new world" "1" "$(status scum FLUX_DB_SYNC_GRACE_SECONDS=0 db-guard)"
check "and says what to do" "1" "$(scum FLUX_DB_SYNC_GRACE_SECONDS=0 db-guard | grep -c 'Not starting a new world')"
rm -f "${data}/flux/db-seen.json" "${server}/flux-db-missing.json"

mkdb "${live}" 4
check "a backup is made" "0" "$(status scum backup first force)"
check "and listed" "1" "$(scum backups | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["backups"]))')"
check "and holds the save and the config" "SaveFiles/SCUM.db Config/WindowsServer/ServerSettings.ini" "$(tar tzf "${data}"/flux/backups/*.tar.gz | grep -E 'SaveFiles/SCUM.db$|ServerSettings.ini$' | tr '\n' ' ' | sed 's/ $//')"
check "a young backup blocks the next unforced one" "1" "$(scum backup again | grep -c 'skipped')"
mkdb "${live}" 5
name="$(scum backups | jget backups.0.name)"
check "restore is asked for" "0" "$(status scum restore "${name}")"
check "a bad backup name is refused" "1" "$(status scum restore ../x)"
scum do-restore >/dev/null
check "the backup is put back on the next start" "4" "$(dbrows "${live}")"
check "after a backup of what was there" "1" "$(scum backups | python3 -c 'import json,sys; print(sum(1 for b in json.load(sys.stdin)["backups"] if b["why"].startswith("before restoring")))')"
check "and the restore says it worked" "True" "$(jget ok <"${data}/flux/last-restore.json")"
check "the snapshot follows the restore" "4" "$(dbrows "${snap}")"

# An imported save.
mkdir -p "${data}/flux/uploads"
mkdb "${data}/flux/uploads/up.db" 9
check "a SCUM.db from another server is accepted" "0" "$(status scum import-save "${data}/flux/uploads/up.db")"
scum do-restore >/dev/null
check "and restored" "9" "$(dbrows "${live}")"
echo notasave >"${data}/flux/uploads/bad.db"
check "a file that is not SQLite is refused" "1" "$(status scum import-save "${data}/flux/uploads/bad.db")"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table t(a)"); c.commit()' "${data}/flux/uploads/other.db"
check "an SQLite file that is not a SCUM save is refused" "1" "$(status scum import-save "${data}/flux/uploads/other.db")"
check "a path outside the uploads is refused" "1" "$(status scum import-save /etc/passwd)"

# Backups: one JSON document, forced ones kept, temp dirs on the install volume.
check "a backup answers ONE JSON document with its name" "1" "$(scum backup json force | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["ok"] and d["name"].endswith("-scum.tar.gz") and d["size"] > 0 else 0)')"
check "and nothing on stderr" "" "$(scum backup quiet force 2>&1 >/dev/null)"
check "a forced backup is kept" "True" "$(scum backup safety force | jget keep)"
check "and marked kept in the list" "True" "$(scum backups | jget backups.0.keep)"
check "an unforced one under the age rule is skipped, ok false, skipped true" "False True" "$(scum backup again | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["skipped"])')"
check "and exits 1 like fail()" "1" "$(status scum backup again)"
check "the supervisor's backup keeps the plain line" "1" "$(scum FLUX_BACKUP_MIN_AGE_MINUTES=0 backup-plain plainline | grep -c '^# backup .*plainline')"
sleep 1
scum FLUX_BACKUP_MIN_AGE_MINUTES=0 FLUX_BACKUP_KEEP=1 backup-plain rot1 >/dev/null; sleep 1
scum FLUX_BACKUP_MIN_AGE_MINUTES=0 FLUX_BACKUP_KEEP=1 backup-plain rot2 >/dev/null
check "forced backups survive pruning" "1" "$(scum backups | python3 -c 'import json,sys; print(sum(1 for b in json.load(sys.stdin)["backups"] if b["why"]=="safety" and b["keep"]))')"
check "an ordinary one is pruned" "0" "$(scum backups | python3 -c 'import json,sys; print(sum(1 for b in json.load(sys.stdin)["backups"] if b["why"]=="rot1"))')"
check "the label is one short line" "a b" "$(scum backup $'a\nb' force | jget why)"
check "backup and restore make their temp dirs on the install volume, never on the synced one" "ok" "$(FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" python3 - "${server}" "${data}" <<'PY'
import sys, tempfile, contextlib, io
sys.path.insert(0, "scripts")
import fluxscum
made = []
real = tempfile.mkdtemp
def spy(*a, **k):
    d = real(*a, **k); made.append(d); return d
tempfile.mkdtemp = spy
res, _ = fluxscum.make_backup("spy", force=True)
assert res["ok"], res
with contextlib.redirect_stdout(io.StringIO()):
    fluxscum.restore_backup_db({"name": res["name"]})
server, data = sys.argv[1:3]
assert len(made) == 2 and all(d.startswith(server + "/.flux-") for d in made), made
print("ok")
PY
)"

# Players: the save's table, and the game's login log. THE GAME'S LOGS ARE UTF-16LE (measured, no BOM).
mkdir -p "${saved}/SaveFiles/Logs"
python3 - "${saved}/SaveFiles/Logs/login_20261028100000.log" <<'PY'
import sys
lines = ["\n2026.10.28-10.00.00: Game version: 1.3.5.1.172191+172352",
         "2026.10.28-10.00.00: '1.2.3.4 76561198000000001:Alice(1)' logged in at: X=1 Y=2 Z=3",
         "2026.10.28-10.01.00: '5.6.7.8 76561198000000009:Bob(2)' logged in at: X=1 Y=2 Z=3",
         "2026.10.28-10.05.00: '5.6.7.8 76561198000000009:Bob(2)' logged out at: X=1 Y=2 Z=3", ""]
open(sys.argv[1], "wb").write("\r\n".join(lines).encode("utf-16-le"))
PY
check "the fixture really is UTF-16LE with no BOM, like the game's own logs" "1" "$(head -c 2 "${saved}/SaveFiles/Logs/login_20261028100000.log" | od -An -tx1 | tr -d ' ' | grep -c -E '^(0a00|0d00)')"
scum state running >/dev/null
check "who is online comes from the login log" "Alice" "$(scum status | jget players.0.name)"
check "a player who logged out is gone" "1" "$(scum status | jget playerCount)"
check "the count for the supervisor" "1" "$(scum players-online)"
printf "%s\n" "2026.10.28-10.09.00: '5.6.7.8 76561198000000007:Carol(3)' logged in at: X=1 Y=2 Z=3" >"${saved}/SaveFiles/Logs/login_20261028100900.log"
check "a plain UTF-8 log is read too (the newest login log wins)" "Carol" "$(scum status | jget players.0.name)"
touch -d '2020-01-01' "${saved}/SaveFiles/Logs/login_20261028100900.log"
check "the real header decodes (Game version line)" "1" "$(python3 -c 'import sys; sys.path.insert(0, "scripts"); import fluxscum; print(1 if "Game version: 1.3.5" in fluxscum.read_game_log(sys.argv[1]) else 0)' "${saved}/SaveFiles/Logs/login_20261028100000.log")"
rm -f "${saved}/SaveFiles/Logs/login_20261028100900.log"
check "the players tab knows the save's players" "2" "$(scum players | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["players"]))')"
check "and who is online, banned" "True True" "$(scum players | python3 -c 'import json,sys
p={x["name"]:x for x in json.load(sys.stdin)["players"]}; print(p["Alice"]["online"], p["Mallory"]["banned"])')"

# The game's own database copies and logs are pruned.
for ts in 20261001000001 20261001000002 20261001000003 20261001000004 20261001000005; do : >"${saved}/SaveFiles/SCUM_${ts}.db-backup"; done
for ts in 20200101000001 20200101000002 20200101000003 20200101000004 20200101000005; do : >"${saved}/SaveFiles/Logs/chat_${ts}.log"; touch -d '2020-01-01' "${saved}/SaveFiles/Logs/chat_${ts}.log"; done
scum apply >/dev/null
check "only the newest 3 of the game's own database copies are kept" "3" "$(find "${saved}/SaveFiles" -maxdepth 1 -name 'SCUM_*.db-backup' | wc -l | tr -d ' ')"
check "and they are the newest" "20261001000005" "$(find "${saved}/SaveFiles" -maxdepth 1 -name 'SCUM_*.db-backup' | sort | tail -1 | grep -o '[0-9]\{14\}')"
check "old logs are removed, keeping the newest three of a kind" "3" "$(find "${saved}/SaveFiles/Logs" -name 'chat_*.log' | wc -l | tr -d ' ')"
check "a log newer than the cutoff is kept" "1" "$(find "${saved}/SaveFiles/Logs" -name 'login_20261028100000.log' | wc -l | tr -d ' ')"

# Lists: one id at a time, under a lock.
adm="${data}/Config/WindowsServer/AdminUsers.ini"
printf '76561198000000001[SetGodMode]\r\n' >"${adm}"
check "list-add adds one id" "True 2" "$(scum list-add admins 76561198000000020 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["changed"], d["count"])')"
check "and keeps another id's permission suffix" "76561198000000001[SetGodMode]" "$(tr -d '\r' <"${adm}" | head -1)"
check "and the game's line endings" "2" "$(grep -c $'\r' "${adm}")"
sum="$(md5sum <"${adm}")"
check "adding an id that is there is ok, unchanged, file untouched" "False $sum" "$(scum list-add admins 76561198000000020 | jget changed) $(md5sum <"${adm}")"
check "a profile link is accepted" "True" "$(scum list-add admins https://steamcommunity.com/profiles/76561198000000021 | jget changed)"
check "a bad id is refused" "1" "$(status scum list-add admins nope)"
check "an unknown list is refused" "64" "$(status scum list-add nothing 76561198000000020)"
check "list-remove removes one" "True" "$(scum list-remove admins 76561198000000021 | jget changed)"
check "and keeps the others' suffix" "76561198000000001[SetGodMode]" "$(tr -d '\r' <"${adm}" | head -1)"
check "removing an absent id is ok, unchanged" "False" "$(scum list-remove admins 76561198000000099 | jget changed)"
: >"${data}/Config/WindowsServer/WhitelistedUsers.ini"
for i in 1 2 3 4 5 6 7 8; do scum list-add whitelist "$(printf '7656119%010d' "${i}")" >/dev/null & done
wait
check "eight concurrent list-add calls lose nothing" "8" "$(scum list whitelist | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))')"

# The game's own logs: kinds, tail, UTF-16LE, caps.
python3 - "${saved}/SaveFiles/Logs" <<'PY'
import sys, os
d = sys.argv[1]
def w(name, lines, enc="utf-16-le"):
    open(os.path.join(d, name), "wb").write(("\r\n".join(lines) + "\r\n").encode(enc))
w("admin_20261028100000.log", [f"2026.10.28-10.00.0{i}: cmd {i}" for i in range(5)])
w("admin_20261028110000.log", ["2026.10.28-11.00.00: new file line a", "2026.10.28-11.00.01: new file line b éü"])
w("violations_20261028100000.log", ["2026.10.28-10.00.00: violation one"])
w("chat_20261028100000.log", ["2026.10.28-10.00.00: chat one"], "utf-8")
w("famepoints_20261028100000.log", ["2026.10.28-10.00.00: fame one"])
with open(os.path.join(d, "big_20261028100000.log"), "wb") as f:
    f.write("\r\n".join(f"line {i:05d} ééééé" for i in range(5000)).encode("utf-16-le"))
PY
check "gamelog returns the last lines across files, oldest first" "cmd 4|new file line a|new file line b éü" "$(scum gamelog admin 3 | python3 -c 'import json,sys; d=json.load(sys.stdin); print("|".join(l.split(": ",1)[1] for l in d["lines"]))')"
check "with the files it read, oldest first" "admin_20261028100000.log admin_20261028110000.log" "$(scum gamelog admin 7 | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["files"]))')"
check "UTF-16LE is decoded (no NULs)" "0" "$(scum gamelog admin | grep -c '\\u0000')"
check "an alias: violation is violations" "violations" "$(scum gamelog violation | jget kind)"
check "a UTF-8 log is read too" "1" "$(scum gamelog chat | jget count)"
check "a kind that only exists on disk works" "1" "$(scum gamelog famepoints | jget count)"
check "a known kind with no file is empty, not an error" "0" "$(scum gamelog kill | jget count)"
check "an unknown kind lists the kinds" "False 1 1" "$(scum gamelog nothing | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], int("chat" in d["kinds"]), int("famepoints" in d["kinds"]))')"
check "and exits 1" "1" "$(status scum gamelog nothing)"
check "a kind cannot be a path" "1" "$(status scum gamelog ../../etc/passwd)"
check "the lines are capped at 2000" "2000" "$(scum gamelog big 999999 | jget count)"
check "and the bytes are capped, dropping the oldest" "True" "$(scum gamelog big 2000 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(l.encode()) + 1 for l in d["lines"]) <= 512*1024 and d["lines"][-1].startswith("line 04999"))')"
check "a byte cap with an odd tail still decodes whole lines" "ok" "$(python3 - "${saved}/SaveFiles/Logs/big_20261028100000.log" <<'PY'
import re, sys
sys.path.insert(0, "scripts")
import fluxscum
for cap in (1001, 1002, 4097, 777):
    text = fluxscum.read_game_log(sys.argv[1], max_bytes=cap)
    lines = [l for l in text.split("\n") if l.strip()]
    assert lines and all(re.fullmatch(r"line \d{5} é{5}\r?", l) for l in lines), (cap, lines[:2])
    assert len(text.encode("utf-16-le")) <= cap + 2, cap
print("ok")
PY
)"

# Status and restart.
check "status names the image version and what it can do" "True" "$(scum FLUX_IMAGE_VERSION=1.0.1 status | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["imageVersion"]=="1.0.1" and all(c in d["capabilities"] for c in ("list-add","list-remove","gamelog","backup-json","restore-marker")) and "gamelog" in d["verbs"])')"
check "status carries the build" "24343458" "$(scum status | jget build)"
check "and the state" "running" "$(scum status | jget state)"
check "a restart is a marker" "0" "$(status scum restart)"
check "and not a second one" "0" "$(status test -f "${tmp}/restart-marker")"
rm -f "${tmp}/restart-marker"
scum state stopped >/dev/null
check "a restart of a stopped server is refused" "1" "$(status scum restart)"

# Game updates that did not install.
scum update-target 99 >/dev/null
check "an update that did not install is noted" "1" "$(scum update-check | grep -c 'did not install')"
check "and skipped for a while" "0" "$(status scum update-skip 99)"
check "another build is not skipped" "1" "$(status scum update-skip 100)"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

# --- db-guard decision table: the node is "server", another node is "server2", the data volume is shared.
data="${tmp}/dg-data"
server="${tmp}/dg-s1"
server2="${tmp}/dg-s2"
saved="${server}/SCUM/Saved"
live="${saved}/SaveFiles/SCUM.db"
snap="${data}/SaveFiles/SCUM.db"
dgnew() { # this node ran and snapshotted (live 10); R = the time of its last snapshot
  rm -rf "${data}" "${server}" "${server2}"
  mkdir -p "${server}/SCUM/Saved/SaveFiles" "${server2}/SCUM/Saved/SaveFiles"
  mkdb "${live}" 10
  scum snapshot >/dev/null
  R="$(jget time <"${server}/flux-snapshot-local.json")"
}
mksnap() { mkdb "${snap}" "$1"; }
setmeta() { # node(OWN|OTHER|NONE) delta [size]: snapshot.json as that writer would have left it
  python3 - "${data}/SaveFiles" "${R}" "$1" "$2" "${3:-}" "${server}/flux-node-id" <<'PY'
import json, os, sys
d, base, who, delta, size, idfile = sys.argv[1:7]
meta = {"time": int(base) + int(delta), "size": int(size) if size else os.path.getsize(os.path.join(d, "SCUM.db")), "image": "t"}
if who != "NONE":
    meta["node"] = open(idfile).read().strip() if who == "OWN" else "othernode0123"
    meta["write"] = "w" + delta.replace("-", "m")
json.dump(meta, open(os.path.join(d, "snapshot.json"), "w"))
PY
}
nrep() { find "${server}/flux-replaced" -type f 2>/dev/null | wc -l | tr -d ' '; }
anyrep() { dbrows "$(find "${server}/flux-replaced" -type f | head -1)"; }
decision() { jget decision <"${data}/flux/save-guard.json"; }

dgnew
check "own snapshot: live kept" "10 own 0" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision) $(nrep)")"
dgnew; mksnap 20; setmeta OTHER 1000
check "newer foreign (failover): the snapshot is used" "20 failover" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
check "and the replaced copy (live 10) is kept" "1 10" "$(nrep) $(anyrep)"
check "and the panel can see it" "True" "$(jget notice <"${data}/flux/save-guard.json")"
check "status shows the decision" "failover" "$(scum status | jget saveGuard.decision)"
dgnew; mksnap 30; setmeta OTHER -1000
check "older foreign (restore or stale sync) without a marker: live kept" "10 older-snapshot" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
check "the older snapshot is kept in flux-replaced" "1 30" "$(nrep) $(anyrep)"
check "the stop snapshot that follows does not lose it nor duplicate it" "1 30 10" "$(scum snapshot >/dev/null; echo "$(nrep) $(anyrep) $(dbrows "${snap}")")"
dgnew; mksnap 30; setmeta OWN -1000
check "an older snapshot with this node's own id (a restored backup of this node) is not own either" "10 older-snapshot" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
dgnew; mksnap 30; setmeta OTHER -1000; scum restore-mark "hub restore" >/dev/null
check "restore marker: the stop snapshot does not overwrite the restored files" "30" "$(scum snapshot >/dev/null; dbrows "${snap}")"
check "and the next start uses them" "30 restore-marker" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
check "the marker is consumed" "1" "$(status test -e "${data}/flux/restore-marker.json")"
check "this node's copy is kept" "1 10" "$(nrep) $(anyrep)"
check "the restore is reported" "True" "$(jget ok <"${data}/flux/last-restore.json")"
check "and the next start has nothing to decide" "own" "$(scum db-guard >/dev/null; decision)"
dgnew; mksnap 30; setmeta OTHER -1000; rm -f "${data}/SaveFiles/snapshot.json"; scum restore-mark >/dev/null
check "a marker whose files have not all arrived waits" "1" "$(status scum db-guard)"
check "and says so" "1" "$(scum db-guard | grep -c 'Waiting for the restored save')"
check "after the grace it gives up, keeps live, reports a failed restore" "0 10 False" "$(scum FLUX_DB_SYNC_GRACE_SECONDS=0 db-guard >/dev/null; echo "$? $(dbrows "${live}") $(jget ok <"${data}/flux/last-restore.json")")"
check "and removes the marker" "1" "$(status test -e "${data}/flux/restore-marker.json")"
dgnew; mksnap 40; setmeta OTHER 500; touch -d "@$((R + 1000))" "${live}"
check "split-brain, live changed later than the snapshot: live is used" "10 split-brain" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
check "and the other copy is kept" "1 40" "$(nrep) $(anyrep)"
dgnew; mksnap 40; setmeta OTHER 2000; touch -d "@$((R + 1000))" "${live}"
check "split-brain, snapshot later than live: the snapshot is used" "40 split-brain" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision)")"
check "and this node's copy is kept" "1 10" "$(nrep) $(anyrep)"
dgnew; mksnap 20; setmeta OTHER 1000 123
check "meta/DB size mismatch: the snapshot is not trusted, live kept" "10 snapshot-untrusted 0" "$(scum db-guard >/dev/null; echo "$(dbrows "${live}") $(decision) $(nrep)")"
rm -f "${live}" "${live}-wal" "${live}-shm"
check "and with no live save it waits instead of starting a new world" "1" "$(status scum db-guard)"
check "naming the wait" "1" "$(scum db-guard | grep -c 'Waiting for the save')"
check "a snapshot with no snapshot.json yet is not trusted either" "1" "$(rm -f "${data}/SaveFiles/snapshot.json"; status scum db-guard)"
dgnew; rm -f "${server}/flux-snapshot-local.json"; mksnap 20; setmeta NONE 1000
check "upgrade from 1.0.0 (nothing recorded, meta without node): the old rule, much newer snapshot wins" "20" "$(scum db-guard >/dev/null; dbrows "${live}")"
dgnew; rm -f "${server}/flux-snapshot-local.json"; mksnap 20; setmeta NONE -1000
check "upgrade from 1.0.0 with an older snapshot: live kept" "10" "$(scum db-guard >/dev/null; dbrows "${live}")"
check "and the snapshot is remembered, so a later restore is seen as foreign" "1" "$([ -s "${server}/flux-snapshot-local.json" ] && echo 1)"
dgnew; mksnap 30; setmeta OTHER -1000
check "a foreign snapshot is kept before the snapshot verb overwrites it (without a guard in between)" "1" "$(scum snapshot | grep -c 'was not written by this node')"
check "and then the volume holds this node's snapshot" "10" "$(dbrows "${snap}")"
check "and the foreign copy is in flux-replaced" "1 30" "$(nrep) $(anyrep)"

# Temp dirs: leftovers of older versions are cleaned at the start, a fresh one (a backup running) is not.
dgnew
mkdir -p "${data}/.flux-backup-old" "${data}/.flux-restore-fresh" "${server}/.flux-restore-old" "${data}/flux/backups"
: >"${data}/.flux-backup-old/SCUM.db"; : >"${data}/flux/backups/x-scum.tar.gz.part"; : >"${data}/SaveFiles/SCUM.db.part"
touch -d '2020-01-01' "${data}/.flux-backup-old" "${data}/.flux-backup-old/SCUM.db" "${server}/.flux-restore-old" "${data}/flux/backups/x-scum.tar.gz.part" "${data}/SaveFiles/SCUM.db.part"
scum db-guard >/dev/null
check "old temp dirs on the synced volume are removed at start" "1" "$(status test -e "${data}/.flux-backup-old")"
check "so are old ones on the install volume" "1" "$(status test -e "${server}/.flux-restore-old")"
check "and half-written backup / snapshot files" "1 1" "$(status test -e "${data}/flux/backups/x-scum.tar.gz.part") $(status test -e "${data}/SaveFiles/SCUM.db.part")"
check "but one touched a moment ago is left alone" "0" "$(status test -d "${data}/.flux-restore-fresh")"
dgnew
check "nothing saved yet: a backup is skipped, ok false, skipped true" "False True" "$(rm -rf "${live}" "${data}/SaveFiles"; scum backup x | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["skipped"])')"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
