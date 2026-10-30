#!/bin/bash
# PID 1, and the supervisor of the SCUM server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and a server that ends on its own
# is followed by the next one in place:
#
#   - every start: SteamCMD update (the Windows build, anonymous), the restore the panel asked for,
#     the save guard (fluxscum.py db-guard: which copy of SCUM.db the game starts on), a backup, then
#     ServerSettings.ini and the player lists from the environment and the panel (fluxscum.py apply /
#     args), then the server under Wine (no display: it does not need one)
#   - SIGTERM/SIGINT from Docker: the server CANNOT be told to save (measured: SIGINT ends it at
#     once, exit code 0, with no shutdown code run). Its save is an SQLite database the game commits
#     to all the time, so what a stop loses is the last moments, not a whole autosave period. The
#     stop makes a snapshot of the save for the synced volume (SQLite's online backup, bounded by
#     FLUX_STOP_SNAPSHOT_SECONDS), then ends the game. A stop stays well inside the 10 seconds Flux
#     gives a container
#   - a snapshot of the save to the synced data volume every FLUX_SNAPSHOT_MINUTES
#   - a new build on Steam: an outdated server refuses players on the new client, so it is
#     restarted onto it, as soon as nobody is playing or after FLUX_UPDATE_WAIT_MINUTES
#   - SCUM_RESTART_TIME: a daily restart at that time (in TZ, UTC when unset), on an empty server
#     if one comes within FLUX_RESTART_WAIT_MINUTES
#   - the server ending on its own: a new generation in the same container; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup on start (unless one is under an hour old) and every FLUX_BACKUP_HOURS, kept on the
#     data volume (flux/backups), and a backup restored when the panel asked for one
#   - the panel's restart (flux-scum restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/abioticfactor-server-flux and runonflux/sotf-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so a stop from Docker (SIGTERM to us) gets FLUX_STOP_GRACE (8 s: it kills the game
# before Docker kills us).
# A restart the panel or the daily timer asked for has nobody waiting on a deadline and gets
# FLUX_RESTART_GRACE.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-8}"
FLUX_RESTART_GRACE="${FLUX_RESTART_GRACE:-60}"
# After SIGINT the game ends by itself in about 2.2 s (measured: Wine's ExitProcess, the process
# is gone, no save); this long, then SIGKILL.
FLUX_STOP_AFTER_SIGNAL="${FLUX_STOP_AFTER_SIGNAL:-4}"
# At most this long the stop waits for the snapshot of the save before it signals.
FLUX_STOP_SNAPSHOT_SECONDS="${FLUX_STOP_SNAPSHOT_SECONDS:-3}"
FLUX_SNAPSHOT_MINUTES="${FLUX_SNAPSHOT_MINUTES:-5}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"
# Ready = the world is loaded (flux_world_loaded), polled every second. FLUX_READY_TIMEOUT: how long
# a start may take before it is logged as slow.
FLUX_READY_TIMEOUT="${FLUX_READY_TIMEOUT:-300}"

s="${FLUX_SERVER_DIR}"
scum() { python3 /opt/flux/fluxscum.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "SCUM"

if ! restart_at="$(flux_restart_time "${SCUM_RESTART_TIME:-}")"; then
  flux_log "WARN SCUM_RESTART_TIME='${SCUM_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, wine ${FLUX_WINE_VERSION:-unknown})"

game_pid=""
tail_pid=""
watch_pid=""
backup_pid=""
cap_pid=""
snap_pid=""
terminating=0
generation=0
restart_history=()

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: shutting down, no restart will follow"
  stop_game
}
trap term_handler TERM INT

# Ends the game. It cannot be told to save (see the header), so: a snapshot of the save for the synced
# volume (at most FLUX_STOP_SNAPSHOT_SECONDS), then SIGINT, which Wine turns into an ExitProcess
# (measured about 2.5 s), then SIGKILL after FLUX_STOP_AFTER_SIGNAL.
stop_game() {
  local pid
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] || return 0
  timeout "${FLUX_STOP_SNAPSHOT_SECONDS}" python3 /opt/flux/fluxscum.py snapshot >/dev/null 2>&1
  kill -INT "${pid}" 2>/dev/null
}

# The Wine prefix, on the install volume (local to the node, made again on a new one). No display:
# the server and wineboot run headless (measured, README "Measured").
ensure_prefix() {
  [ -d "${WINEPREFIX}/drive_c" ] && return 0
  flux_log "creating the Wine prefix (once per node)"
  mkdir -p "${WINEPREFIX}"
  wineboot --init >/dev/null 2>&1
  wineserver -w 2>/dev/null
  [ -d "${WINEPREFIX}/drive_c" ]
}

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  scum state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, Windows build)"
  # No `validate` on the first attempt: it re-hashes the whole 3.4 GB install on every start. An
  # install that is actually broken fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # app_info_update first: a fresh SteamCMD answers "Missing configuration" to the very first
    # app_update of this app (measured 2026-10-24) and stops; the next attempt works. That error is
    # retried at once WITHOUT validate (validate re-hashes the whole 3 GB install).
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${s}" +login anonymous \
      +app_info_update 1 +app_update "${FLUX_STEAM_APP}" ${validate} +quit \
      >/tmp/steamcmd.log 2>&1 &
    wait $!
    # "fully installed" after a download, "already up to date" otherwise.
    if [ -f "${s}/${FLUX_GAME_EXE}" ] && grep -qE "fully installed|already up to date" /tmp/steamcmd.log; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    if ! grep -aq "Missing configuration" /tmp/steamcmd.log; then
      validate="validate"
    fi
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')retrying in 5s${validate:+ with validate}"
    sleep 5 &
    wait $!
  done
  if [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# A backup (fluxscum.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_save() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(scum backup-plain "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_save "every ${FLUX_BACKUP_HOURS}h"
  done
}

# shellcheck disable=SC2329  # run in the background below
# The synced copy of the save: SQLite's online backup of the live database, every FLUX_SNAPSHOT_MINUTES.
snapshotter() {
  local line
  [ "${FLUX_SNAPSHOT_MINUTES}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_SNAPSHOT_MINUTES * 60))
    line="$(scum snapshot 2>&1)"
    case "${line}" in *WARN*) flux_log "${line#\# }" ;; esac
  done
}

request_restart() {
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
}

# shellcheck disable=SC2329  # run in the background below
# The current game log, capped at FLUX_GAME_LOG_MAX_BYTES: its last 5 MB go to a rotated file and
# the live one is emptied in place (the game keeps writing it).
log_capper() {
  local current size
  current="$(flux_game_log)"
  while true; do
    sleep 60
    size="$(stat -c %s "${current}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLUX_GAME_LOG_MAX_BYTES}" ] 2>/dev/null; then
      tail -c 5242880 "${current}" >"${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log" 2>/dev/null
      : >"${current}"
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
      flux_log "the game log reached $((size / 1048576)) MB: rotated"
    fi
  done
}

# Waits for an empty server for up to $1 minutes, checking every minute.
wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60)) n
  while [ "$(date -u +%s)" -lt "${until}" ]; do
    n="$(scum players-online 2>/dev/null)"
    [ "${n}" = "0" ] && return 0
    sleep 60
  done
  return 0
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once its world is loaded (the game's first "Global Stats" line, which it
# prints every few seconds once it ticks), then follows Steam for a newer build and keeps the daily
# restart. SCUM answers no Steam A2S query (measured), so the log is the readiness signal.
watcher() {
  local build public last_check now next_restart="" waited=0
  last_check="$(date -u +%s)"
  until flux_world_loaded "${FLUX_GAME_OWN_LOG}" "${FLUX_GENERATION_MARK}"; do
    sleep 1
    waited=$((waited + 1))
    [ "${waited}" = "${FLUX_READY_TIMEOUT}" ] && flux_log "WARN the world has not finished loading after ${FLUX_READY_TIMEOUT}s"
  done
  scum state running
  flux_log "the server is up, its world loaded after ${waited}s (generation ${generation})"
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    scum note nextRestart "${next_restart}"
  else
    scum note nextRestart
  fi
  scum note updateWaiting
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! scum update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it when the server is empty, at most ${FLUX_UPDATE_WAIT_MINUTES} min from now"
        scum note updateWaiting "${public}"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        scum update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      flux_log "daily restart (${restart_at} ${TZ:-UTC}): waiting up to ${FLUX_RESTART_WAIT_MINUTES} min for an empty server"
      wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})"
      exit 0
    fi
  done
}

# shellcheck disable=SC2329  # run in the background below
# The game's console onto the container's output, without the lines Unreal prints for every actor
# and EOS attribute (the full output stays in the game log), and with the passwords of the
# "Command Line:" echo hidden.
log_follower() {
  local line
  while IFS= read -r line; do
    flux_noise <<<"${line}" || printf '%s\n' "${line}" | flux_redact
  done < <(tail -n 0 -F "$1" 2>/dev/null)
}

# Before every start, the save guard (fluxscum.py db-guard): never start the game on an empty save when
# this server has had one, which on a half-synced volume would make a new world and sync it over
# the real one. A missing save is waited for, then put back from a backup; with none the start
# waits (state updating, the reason in the message), checking every 30 s. Returns 1 when stopping.
guard_save() {
  local line out rc said=""
  while true; do
    out="$(scum db-guard 2>&1)"
    rc=$?
    while IFS= read -r line; do
      [ -n "${line}" ] && [[ "${line}" == "# "* ]] && flux_log "save: ${line#\# }"
    done <<<"${out}"
    [ "${rc}" = "0" ] && return 0
    line="$(grep -v '^# ' <<<"${out}" | tail -1)"
    if [ "${said}" != "${line}" ]; then
      flux_log "WARN ${line}"
      said="${line}"
    fi
    scum state updating "${line}"
    sleep 30 &
    wait $!
    [ "${terminating}" = "1" ] && return 1
  done
}

start_generation() {
  local line current
  local -a args=()
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"
  # A state left by the container that was here before (a kill, a node reboot) is stale from now on.
  scum state updating "Preparing the server"

  update_server || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(scum update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  # A restore the panel asked for, before anything reads the server's files.
  while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(scum do-restore 2>&1)
  guard_save || return 2
  backup_save "start"

  local applied
  if applied="$(scum apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
  else
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
    printf '%s\n' "${applied}" >/tmp/flux-apply.out
    flux_log "ERROR the settings could not be applied: $(grep -h ERROR <<<"${applied}" | tr '\n' ' ')$(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    return 3
  fi

  if ! ensure_prefix; then
    flux_log "ERROR the Wine prefix could not be created"
    return 1
  fi

  current="$(flux_game_log)"
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  : >"${current}"
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  # The launch line, one argument per line (fluxscum.py args).
  mapfile -t args < <(scum args)
  scum state starting "Loading the world"
  flux_banner "SCUM"
  flux_log "starting the server (generation ${generation}): $(printf '%s' "${args[*]}" | flux_redact)"

  touch "${FLUX_GENERATION_MARK}"
  log_follower "${current}" &
  tail_pid=$!

  (
    cd "${s}/$(dirname "${FLUX_GAME_EXE}")" || exit 1
    # stdin closed: the server takes no console input. No DISPLAY: it runs headless.
    exec wine "$(basename "${FLUX_GAME_EXE}")" "${args[@]}" </dev/null >>"${current}" 2>&1
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  snap_pid=""
  snapshotter &
  snap_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${backup_pid}" "${cap_pid}" "${snap_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" backup_pid="" cap_pid="" snap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
  # Whatever Wine left behind for this generation (services.exe, explorer.exe, the crash handler).
  wineserver -k 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A stop or restart asked for goes through stop_game; the game gets
# FLUX_STOP_AFTER_SIGNAL seconds after the signal, and FLUX_STOP_GRACE (a stop) or FLUX_RESTART_GRACE
# (a restart) in all.
wait_for_generation() {
  local asked_at=0 now signalled=0 grace
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 0.5 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      stop_game
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      grace="${FLUX_RESTART_GRACE}"
      [ "${terminating}" = "1" ] && grace="${FLUX_STOP_GRACE}"
      if [ $((now - asked_at)) -ge "${grace}" ] || [ $((now - asked_at)) -ge "${FLUX_STOP_AFTER_SIGNAL}" ]; then
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
        break
      fi
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

# The environment holds a port the server cannot use: restarting cannot fix it and exiting would
# only make the platform restart the same container, so the state says what to change and the
# container waits (no restart budget used) for a stop or the panel's restart.
wait_for_fix() {
  local why
  why="$(grep -ah 'ERROR' /tmp/flux-apply.out 2>/dev/null | head -1 | sed 's/^# ERROR //')"
  scum state needs-fix "${why:-The settings in the environment cannot be used}. Change it in the app's deployment settings; the server starts after a redeploy."
  flux_log "not restarting: ${why}. Waiting for a redeploy."
  while [ "${terminating}" = "0" ] && [ ! -f "${FLUX_RESTART_MARKER}" ]; do
    sleep 2 &
    wait $!
  done
  rm -f "${FLUX_RESTART_MARKER}"
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    scum state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "3" ]; then
    wait_for_fix
    continue
  fi
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    scum state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    scum state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    scum state stopped
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      scum state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  scum state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
