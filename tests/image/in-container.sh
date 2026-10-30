#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 wine wineboot wineserver pgrep pkill tail tar; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "wine is the pinned build" "0" "$(status bash -c 'wine --version | grep -q "wine-10.0"')"
check "and it has fsync" "0" "$(status bash -c 'wine --version | grep -q "Fsync"')"
check "flux-scum is on the PATH" "0" "$(status command -v flux-scum)"
check "flux-scum starts (usage)" "64" "$(status flux-scum)"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" the exe (the first call fails with "Missing configuration" like a fresh
# SteamCMD does); wine runs a stand-in that behaves like the server where it matters: it prints the
# "Global Stats" line once its world is loaded, keeps SCUM.db open in WAL mode and commits to it,
# writes a login log, listens on port + 2 (TCP), and ends AT ONCE on SIGINT.
mkdir -p /usr/local/bin /opt/standin
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
for a in "$@"; do [ "${prev:-}" = "+force_install_dir" ] && dir="$a"; prev="$a"; done
echo "$*" >>/tmp/steamcmd-calls
[ -n "${dir}" ] || exit 0
if [ ! -f /tmp/.first-failed ]; then touch /tmp/.first-failed; echo "ERROR! Failed to install app '3792580' (Missing configuration)"; exit 8; fi
mkdir -p "${dir}/steamapps" "${dir}/SCUM/Binaries/Win64"
: >"${dir}/SCUM/Binaries/Win64/SCUMServer.exe"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_3792580.acf"
if [ -f /tmp/.installed ]; then echo "Success! App '3792580' already up to date."; else touch /tmp/.installed; echo "Success! App '3792580' fully installed."; fi
STUB
cat >/opt/standin/SCUMServer.exe <<'GAME'
#!/usr/bin/env python3
# Named like the server so the supervisor finds it by its exe name.
import os, signal, socket, sqlite3, sys, threading, time
cmd = " ".join(sys.argv[1:])
def arg(name, default=""):
    for a in sys.argv[1:]:
        if a.lower().startswith("-%s=" % name.lower()):
            return a.split("=", 1)[1]
    return default
port, maxp = int(arg("port", "7777")), int(arg("MaxPlayers", "64"))
saved = "/mnt/scum/server/SCUM/Saved"
ini = os.path.join(saved, "Config", "WindowsServer", "ServerSettings.ini")
name = ""
for line in open(ini, encoding="utf-8-sig"):
    if line.startswith("scum.ServerName="):
        name = line.strip().split("=", 1)[1]
print("LogInit: Command Line:  " + cmd, flush=True)
print("LogConfig: Setting CVar [[scum.ServerName:%s]]" % name, flush=True)
print("LogStreaming: Display: ULevelStreaming::RequestLevel(/Game/x) is flushing async loading", flush=True)
print("env DISPLAY=%s" % os.environ.get("DISPLAY", "unset"), flush=True)
print("name=%s maxp=%d port=%d" % (name, maxp, port), flush=True)
signal.signal(signal.SIGINT, lambda *_: os._exit(0))   # Wine: an immediate ExitProcess, no shutdown code
os.makedirs(os.path.join(saved, "SaveFiles", "Logs"), exist_ok=True)
os.makedirs(os.path.join(saved, "Logs"), exist_ok=True)
open(os.path.join(saved, "Logs", "SCUM.log"), "w").write("LogInit: started\n")
db = os.path.join(saved, "SaveFiles", "SCUM.db")
c = sqlite3.connect(db, check_same_thread=False)
c.execute("PRAGMA journal_mode=WAL")
c.executescript("CREATE TABLE IF NOT EXISTS user(id TEXT,name TEXT,last_login_time TEXT,is_banned INTEGER);"
                "CREATE TABLE IF NOT EXISTS user_profile(id INTEGER);CREATE TABLE IF NOT EXISTS prisoner(id INTEGER);"
                "CREATE TABLE IF NOT EXISTS tick(n INTEGER);")
c.commit()
def commits():
    n = 0
    while True:
        n += 1
        c.execute("INSERT INTO tick VALUES (?)", (n,)); c.commit()
        time.sleep(0.2)
threading.Thread(target=commits, daemon=True).start()
log = os.path.join(saved, "SaveFiles", "Logs", "login_%s.log" % time.strftime("%Y%m%d%H%M%S"))
if os.environ.get("STANDIN_LOGIN"):
    # The real game's logs are UTF-16LE with no byte-order mark (measured).
    open(log, "wb").write("\r\n2026.10.28-10.00.00: '1.2.3.4 76561198000000001:Alice(1)' logged in at: X=1 Y=2 Z=3\r\n".encode("utf-16-le"))
time.sleep(float(os.environ.get("STANDIN_BOOT", "1.5")))   # the real one needs ~70 s
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port + 2)); srv.listen(5)
print("LogNet: GameNetDriver IpNetDriver_1 IpNetDriver listening on port %d" % port, flush=True)
def stats():
    # The real console shows no "Global Stats"; the game's own log file does.
    while True:
        with open(os.path.join(saved, "Logs", "SCUM.log"), "a") as f:
            f.write("LogSCUM: Global Stats: 199.3ms (  5.0FPS)\n")
        time.sleep(1)
threading.Thread(target=stats, daemon=True).start()
while True:
    conn, _ = srv.accept(); conn.close()
GAME
chmod +x /usr/local/bin/steamcmd /opt/standin/SCUMServer.exe
cat >/usr/local/bin/wine <<'STUB'
#!/bin/bash
exec /opt/standin/"$1" "${@:2}"
STUB
chmod +x /usr/local/bin/wine
cat >/usr/local/bin/wineboot <<'STUB'
#!/bin/bash
mkdir -p "${WINEPREFIX}/drive_c"
STUB
chmod +x /usr/local/bin/wineboot
export PATH="/usr/local/bin:${PATH}"

data=/mnt/scum/data
srv=/mnt/scum/server
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 SCUM_SERVER_NAME="Image Test" SCUM_MAX_PLAYERS=4 \
  SCUM_GAME_PORT=31000 SCUM_PASSWORD=hunter2 FLUX_SNAPSHOT_MINUTES=0 STANDIN_LOGIN=1
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up (its world is loaded)" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 40)"
check "a fresh SteamCMD's first failure is retried without validate" "0" "$(grep -c validate /tmp/steamcmd-calls)"
check "and it took two calls" "2" "$(wc -l </tmp/steamcmd-calls)"
check "the Wine prefix is made on the install volume" "0" "$(status test -d "${srv}/flux-wine/drive_c")"
check "no virtual display is started" "1" "$(status pgrep -x Xvfb)"
check "and the server gets none" "1" "$(grep -c 'env DISPLAY=unset' /tmp/entry.log)"
check "the settings file is on the data volume" "0" "$(status test -f "${data}/Config/WindowsServer/ServerSettings.ini")"
check "through the link" "${data}/Config/WindowsServer" "$(readlink "${srv}/SCUM/Saved/Config/WindowsServer")"
check "the name reached the server" "1" "$(grep -c 'name=Image Test maxp=4 port=31000' /tmp/entry.log)"
check "and the status" "Image Test" "$(flux-scum status | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverName"])')"
check "the port is the environment's" "31000" "$(flux-scum status | python3 -c 'import json,sys;print(json.load(sys.stdin)["ports"]["game"])')"
check "players come from the login log" "Alice" "$(flux-scum status | python3 -c 'import json,sys;print(json.load(sys.stdin)["players"][0]["name"])')"
check "the container log has no level streaming or config echoes" "0" "$(grep -c -E '^(LogStreaming|LogConfig)' /tmp/entry.log)"
check "but the game's lines reach it" "1" "$(grep -c 'listening on port 31000' /tmp/entry.log)"
check "the password is not on the command line" "0" "$(grep -c hunter2 /tmp/entry.log)"
check "the password is in the settings file" "1" "$(tr -d '\r' <"${data}/Config/WindowsServer/ServerSettings.ini" | grep -c '^scum.ServerPassword=hunter2$')"
check "the game log is on the install volume" "0" "$(status test -s "${srv}/flux-logs/current.log")"
check "the ready check passes (port + 2 accepts)" "0" "$(status flux-scum ready)"
check "a snapshot of the live save works with the game writing to it" "0" "$(status flux-scum snapshot)"
check "and is a database that opens" "ok" "$(python3 -c 'import sqlite3;print(sqlite3.connect("'"${data}"'/SaveFiles/SCUM.db").execute("pragma quick_check").fetchone()[0])')"

# A restart through the panel: the stop takes a snapshot first, and the new name is in the settings file.
start="$(date +%s.%N)"
flux-scum set-settings '{"values": {"scum.ServerName": "Second Name"}}' >/dev/null
rm -f "${data}/SaveFiles/SCUM.db" "${data}/SaveFiles/snapshot.json"
flux-scum restart >/dev/null
check "a panel restart starts again with the new setting" "0" "$(status wait_for '[ "$(flux-scum status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"],d[\"serverName\"])")" = "running 2 Second Name" ]' 40)"
check "the stop made a snapshot" "0" "$(status test -f "${data}/SaveFiles/SCUM.db")"
check "the restart was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "an up-to-date install is not retried" "0" "$(grep -c 'steamcmd failed' /tmp/entry.log | awk '{print ($1 > 1) ? 1 : 0}')"

# A restore through the panel's command.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
check "the panel's backup answers one JSON document, kept when forced" "True True" "$(flux-scum backup "test" force | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["ok"], d["keep"])')"
check "the supervisor's own start backup is logged" "1" "$(grep -c -E 'backup [0-9]{8}-[0-9]{6}-scum.tar.gz \(start' /tmp/entry.log | awk '{print ($1 > 0) ? 1 : 0}')"
check "status tells the hub what this image can do" "True" "$(flux-scum status | python3 -c 'import json,sys;d=json.load(sys.stdin);print("gamelog" in d["capabilities"] and bool(d["imageVersion"]))')"
check "gamelog and list-add work inside the image" "True True" "$(flux-scum gamelog admin | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])') $(flux-scum list-add admins 76561198000000042 | python3 -c 'import json,sys;print(json.load(sys.stdin)["changed"])')"
backup="$(flux-scum backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
check "restore restarts the running server" "True" "$(flux-scum restore "${backup}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restarting"])')"
check "and the third start restored it" "0" "$(status wait_for '[ "$(flux-scum status | python3 -c "import json,sys;print(json.load(sys.stdin)[\"generation\"])")" = 3 ]' 40)"
check "and says so" "True" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/last-restore.json"))["ok"])')"

# A crash: restarted in place.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
pkill -KILL -f '[S]CUMServer\.exe'
check "a crashed server is started again" "0" "$(status wait_for '[ "$(flux-scum status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"])")" = "running 4" ]' 40)"
check "and its save survived the kill (WAL recovered)" "ok" "$(python3 -c 'import sqlite3;print(sqlite3.connect("'"${srv}"'/SCUM/Saved/SaveFiles/SCUM.db").execute("pragma quick_check").fetchone()[0])')"

# A stop from Docker.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
start="$(date +%s)"
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "inside Docker's 10 seconds" "0" "$(status test $(($(date +%s) - start)) -le 6)"
check "and says stopped" "stopped" "$(python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["state"])')"
check "nothing of the server is left" "1" "$(status pgrep -f '[S]CUMServer\.exe')"

# A port the server cannot use is not a crash: the state says what to change and nothing restarts.
SCUM_GAME_PORT=80 /opt/flux/flux-entrypoint.sh >/tmp/entry2.log 2>&1 &
entry2=$!
check "a bad port gives the needs-fix state" "0" "$(status wait_for 'grep -q "needs-fix" ${data}/flux/state.json 2>/dev/null' 20)"
check "that names the variable" "1" "$(grep -c 'SCUM_GAME_PORT=80' ${data}/flux/state.json)"
check "and keeps the supervisor alive" "0" "$(status kill -0 ${entry2})"
kill -TERM "${entry2}"
check "a stop ends it" "0" "$(status wait_for '! kill -0 ${entry2} 2>/dev/null' 10)"

# --- flux.log is local; the banner ----------------------------------------------------------------
check "flux.log is on the install volume" "0" "$(status test -s "${srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'SCUM server image by FluxCloud - https://runonflux.com' /tmp/entry.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
