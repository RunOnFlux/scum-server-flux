#!/bin/bash
# Shared helpers for the SCUM image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam, Wine or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's and Wine's, disposable, local to the node) and the
# data (the game's SaveGames folder and ours). The data is the only thing that has to survive.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/scum/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/scum/data}"
# The game keeps its settings and lists in <install>/SCUM/Saved/Config/WindowsServer (a symlink to
# <data>/Config/WindowsServer, made at every start by fluxscum.py apply) and its save in
# <install>/SCUM/Saved/SaveFiles/SCUM.db (an SQLite database, LOCAL: the data volume holds a
# snapshot of it, fluxscum.py snapshot).
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_DATA_DIR}/flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# The game's console output, on the INSTALL volume (local, never synced): Unreal logs a lot, and on
# the synced data volume that would be steady Syncthing traffic. The current one is capped at
# FLUX_GAME_LOG_MAX_BYTES.
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-52428800}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_STATE_DIR}/backups}"
FLUX_GAME_EXE="${FLUX_GAME_EXE:-SCUM/Binaries/Win64/SCUMServer.exe}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-3792580}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# How the running server is found. Under Wine the Windows process's command line is the exe's
# name and its arguments ("SCUMServer.exe -log ..."; measured). `[S]` keeps
# pgrep from matching its own command line.
FLUX_GAME_OWN_LOG="${FLUX_GAME_OWN_LOG:-${FLUX_SERVER_DIR}/SCUM/Saved/Logs/SCUM.log}"
FLUX_GENERATION_MARK="${FLUX_GENERATION_MARK:-/tmp/flux-generation-start}"
FLUX_GAME_PATTERN="${FLUX_GAME_PATTERN:-[S]CUMServer\.exe}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a port as given, $2 = the default when it is empty. Prints the port; returns 1 for a value
# that is not a port from 1024 to 65535.
flux_port() {
  local value="${1:-$2}"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# $1 $2 = the game and query ports. Returns 1 when they are the same (the server binds each).
flux_ports_distinct() {
  [ "$1" != "$2" ]
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A restart the supervisor planned (a game update, the
# daily restart, one the panel asked for) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The daily restart. There is no console to warn players through, so it waits for an empty
# server, up to FLUX_RESTART_WAIT_MINUTES.
# ---------------------------------------------------------------------------------------------

# $1 = SCUM_RESTART_TIME as given. Prints HH:MM (in TZ), or "" when off. Returns 1 for a value
# that is not a time.
flux_restart_time() {
  local value="${1-}" h m
  case "${value,,}" in
    "" | off | none | false | 0) printf ''; return 0 ;;
  esac
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%02d:%02d' "${h}" "${m}"
}

# $1 = now (epoch seconds), $2 = HH:MM in the container's time zone (TZ; UTC when unset). Prints
# the epoch of the next time it is $2: today when that is still ahead, tomorrow otherwise.
flux_next_daily() {
  local now="$1" at
  at="$(date -d "$(date -d "@${now}" +%F) $2" +%s 2>/dev/null)" || return 1
  if [ "${at}" -le "${now}" ]; then
    at="$(date -d "$(date -d "@$((now + 86400))" +%F) $2" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "${at}"
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Steam builds: an outdated server refuses players on the new client, so a new build means a
# restart (onto it). The installed buildid (appmanifest) is compared with the public branch's.
# ---------------------------------------------------------------------------------------------

# $1 = an appmanifest_<app>.acf. Prints its buildid.
flux_installed_build() {
  [ -f "$1" ] || return 0
  awk -F'"' '$2 == "buildid" { print $4; exit }' "$1"
}

# stdin = steamcmd +app_info_print output. Prints the public branch's buildid.
flux_public_build() {
  awk '
    /"branches"/ { inb = 1 }
    inb && /"public"/ { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# The game's console output of the current generation.
flux_game_log() {
  printf '%s' "${FLUX_GAME_LOG:-${FLUX_GAME_LOG_DIR}/current.log}"
}

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PATTERN}" 2>/dev/null | head -1
}

# $1 = a unix path. Prints it as Wine's Z: drive sees it ("/mnt/scum/data" -> "Z:\mnt\scum\data").
flux_wine_path() {
  local p="${1//\//\\}"
  printf 'Z:%s' "${p}"
}

# stdin = one line of the server's console. Returns 0 when it is noise worth dropping from the
# container log (Unreal's per-level streaming, per-tick stats, config echoes, the resource and
# radiation managers' timings). The full output stays in the game log on the install volume.
flux_noise() {
  local line
  IFS= read -r line || return 1
  [[ "${line}" =~ ^[[:space:]]*$ ]] && return 0
  case "${line}" in
    "LogStreaming: "* | "LogShaderLibrary: "* | "LogGameFeatures: "* | "LogAssetRegistry: "* | "LogConfig: "* | "LogFoliageCache: "* | "LogQuadTree: "* | \
      "LogReplenishableResourceManager: "* | "LogRadiationManager: "* | "LogShaderCompilers"* | \
      "LogSCUM: Global Stats:"* | "LogSCUM: Parameter updated"* | "LogSCUM: Loaded from config"* | \
      "LogSCUM: Tick time of"* | "LogSCUM: Display: GEM BP"* | "LogSCUM: Display: Saving settings"* | "LogSCUM: Warning: ABuilding::UpdateDoorNavLinks"* | \
      "LogTextLocalizationResource"* | "LogPackageName: "* | "LogIoDispatcher: "* | "LogPakFile: "*) return 0 ;;
  esac
  return 1
}

# stdin -> stdout: the line with any password argument replaced (the image passes none on the command
# line, but SCUM_EXTRA_ARGS is the owner's).
flux_redact() {
  sed -E 's/(-[A-Za-z]*Password=)("[^"]*"|[^ ]*)/\1***/g'
}

# $1 = the game's own log file (SCUM/Saved/Logs/SCUM.log), $2 = a file touched when this generation
# started. Returns 0 once the world has loaded: the game writes a "LogSCUM: Global Stats" line to its
# log every few seconds from its first tick (measured: the first comes after the map has streamed in,
# about 70 s on 4 cores). The console output (what we capture) carries only warnings and displays, so
# the marker is looked for in the game's file, and only counts when the file is newer than the start
# (the previous generation's file is still there until the game replaces it).
flux_world_loaded() {
  [ -s "$1" ] && [ "$1" -nt "$2" ] && grep -qa "LogSCUM: Global Stats" "$1"
}

# $1 = the restart marker. Prints the earliest epoch the server may be stopped for it, 0 when it
# says nothing.
flux_marker_not_before() {
  local value
  value="$(sed -n 's/^notbefore=//p' "$1" 2>/dev/null | head -1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}
