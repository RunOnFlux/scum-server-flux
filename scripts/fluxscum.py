#!/usr/bin/env python3
"""Every decision about the SCUM server's files and launch line, and the hub's commands.

    fluxscum.py apply               link the config folder to the data volume, settle ServerSettings.ini
                                    (environment + panel), the player lists; "# " notes on stdout (the
                                    entrypoint logs them); exit 2 when the environment holds something the
                                    server cannot use (needs-fix)
    fluxscum.py args                the server's arguments, one per line (the entrypoint reads them)
    fluxscum.py state <state> [msg] record what the supervisor is doing (flux/state.json)

    flux-scum status                state, players (from the game's login log), build (one JSON document)
    flux-scum settings              every ServerSettings.ini key with its type, the game's default and its value
    flux-scum set-settings '<json>' {"values": {"scum.ServerName": "My server", "scum.PVE...": ...}}
    flux-scum list <name>           admins | banned | exclusive | whitelist | silenced | settings-admins
    flux-scum list-add <name> <id>  add one SteamID64 (idempotent, atomic read-modify-write)
    flux-scum list-remove <name> <id>  remove one SteamID64 (idempotent, atomic)
    flux-scum set-list <name> '<json>'   {"ids": ["7656...", ...]}   (names of players: the Players tab)
    flux-scum players               every player the save knows (name, SteamID, last login, banned)
    flux-scum file <name>           raid | economy | notifications: the JSON file's text
    flux-scum set-file <name> '<json text>'   validated as JSON, written for the next start
    flux-scum restart               stop and start the server again (applies the above)
    flux-scum backups               the backups in flux/backups (name, size, date, why)
    flux-scum gamelog <kind> [lines]  the tail of the game's own log (admin, chat, kill, ...): {ok, kind, files, lines}
    flux-scum backup <why> [force]  a backup now: ONE JSON document {ok, name, size, ...} (force skips the age rule and keeps it)
    flux-scum restore-mark [label]  tell the next start that the synced SCUM.db + snapshot.json were put there on purpose
    flux-scum restore <backup>      restore one on the next start (the server is restarted now)
    flux-scum import-save <db>      a SCUM.db brought from another server, restored on the next start

    fluxscum.py snapshot            the synced copy of the save (the supervisor, every few minutes)
    fluxscum.py db-guard            before every start: which copy of the save the game starts on
    fluxscum.py backup-plain <why> [force]  a backup, "# " lines on stdout (the supervisor)
    fluxscum.py do-restore          apply a pending restore (the supervisor, before a start)
    fluxscum.py note <key> [value]  a field of flux/state.json (nextRestart, updateWaiting)
    fluxscum.py update-target <b> / update-check / update-skip <b>   game-update bookkeeping
    fluxscum.py players-online      the number of players logged in, or nothing when not known

THE SAVE IS ONE SQLite DATABASE (SaveFiles/SCUM.db, WAL mode) that the game commits to all the time.
The live copy is on the INSTALL volume (local to the node): a live WAL database must not go through
a file synchroniser. The synchronised copy on the data volume is a snapshot made with SQLite's own
online backup (consistent whatever the game is doing), every FLUX_SNAPSHOT_MINUTES and when the
server stops. A new node starts from the snapshot; the same node keeps its live copy.

The ServerSettings.ini is the game's own file and the single source of truth: the panel and the
environment edit its lines in place (nothing else in the file moves, and CRLF line endings stay).

ENVIRONMENT APPLIES WHEN IT CHANGES, as in our other images: a deploy's SCUM_* value is written on the
first start and again whenever it is DIFFERENT from the value last applied (flux/env-applied.json), so
a redeploy with a new name renames the server while a name changed in the panel is not undone by the
same old env on every start. The port is the exception: read on every start.
"""

import contextlib
import fcntl
import json
import os
import re
import shutil
import socket
import sqlite3
import sys
import tarfile
import tempfile
import time
import uuid

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/scum/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/scum/data")
GAME_SAVED = os.environ.get("FLUX_GAME_SAVED", os.path.join(SERVER_DIR, "SCUM", "Saved"))
# The game's config folder is a symlink to this one on the data volume (synced).
CONFIG_DATA = os.path.join(DATA_DIR, "Config", "WindowsServer")
CONFIG_LINK = os.path.join(GAME_SAVED, "Config", "WindowsServer")
SAVEFILES = os.path.join(GAME_SAVED, "SaveFiles")
LIVE_DB = os.path.join(SAVEFILES, "SCUM.db")
LOGIN_LOG_DIR = os.path.join(SAVEFILES, "Logs")
SNAP_DIR = os.path.join(DATA_DIR, "SaveFiles")
SNAP_DB = os.path.join(SNAP_DIR, "SCUM.db")
SNAP_META = os.path.join(SNAP_DIR, "snapshot.json")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
ENV_APPLIED_FILE = os.path.join(STATE_DIR, "env-applied.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
UPLOAD_DIR = os.path.join(STATE_DIR, "uploads")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
LAST_RESTORE_FILE = os.path.join(STATE_DIR, "last-restore.json")
DB_SEEN = os.path.join(STATE_DIR, "db-seen.json")
# The hub (or the middleware) drops this after it has put an older SCUM.db + snapshot.json on the synced
# volume on purpose (a restore from an automatic backup): the next start honours them.
RESTORE_MARKER = os.path.join(STATE_DIR, "restore-marker.json")
# What the last db-guard decided, for the panel (status.saveGuard).
SAVE_GUARD_FILE = os.path.join(STATE_DIR, "save-guard.json")
# LOCAL (install volume, never synced): who this node is, and the last snapshot meta it wrote or adopted.
NODE_ID_FILE = os.path.join(SERVER_DIR, "flux-node-id")
LOCAL_SNAP_FILE = os.path.join(SERVER_DIR, "flux-snapshot-local.json")
LOCK_FILE = os.path.join(SERVER_DIR, "flux-scum.lock")
REPLACED_DIR = os.path.join(SERVER_DIR, "flux-replaced")
REPLACED_KEEP = 8
TEMP_STALE_SECONDS = int(os.environ.get("FLUX_TEMP_STALE_SECONDS", "600"))
# On the install volume (local, never synced): a counter on the synced one would count for both nodes.
DB_MISSING = os.path.join(SERVER_DIR, "flux-db-missing.json")
DB_SYNC_GRACE = int(os.environ.get("FLUX_DB_SYNC_GRACE_SECONDS", "300"))
# A snapshot this much newer than the live database means another node ran the server since.
SNAP_NEWER_BY = int(os.environ.get("FLUX_SNAP_NEWER_SECONDS", "180"))
# A live save changed this long after the last snapshot this node wrote means it kept running on its
# own since (a hard-killed node can be a whole snapshot period ahead of its last snapshot).
def _snapshot_minutes():
    try:
        return max(int(os.environ.get("FLUX_SNAPSHOT_MINUTES", "5")), 1)
    except ValueError:
        return 5


DIVERGE_SECONDS = int(os.environ.get("FLUX_DIVERGE_SECONDS", str(_snapshot_minutes() * 60 + 120)))
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
STEAM_APP = os.environ.get("FLUX_STEAM_APP", "3792580")
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-scum\.tar\.gz$")
IMPORT_MAX_BYTES = int(os.environ.get("FLUX_IMPORT_MAX_BYTES", str(4 * 1024 * 1024 * 1024)))
SETTLE_SECONDS = 5
DEFAULTS_INI = os.environ.get("FLUX_DEFAULT_INI", os.path.join(os.path.dirname(os.path.realpath(__file__)), "data", "ServerSettings.default.ini"))
DATA_FILES_DIR = os.path.dirname(DEFAULTS_INI)

DEFAULT_GAME_PORT = 7777
MAX_PLAYERS_CAP = 128
STEAM_ID_RE = re.compile(r"^7656119\d{10}$")

INI = "ServerSettings.ini"
# name -> file in the config folder
LISTS = {
    "admins": "AdminUsers.ini",
    "banned": "BannedUsers.ini",
    "exclusive": "ExclusiveUsers.ini",
    "whitelist": "WhitelistedUsers.ini",
    "silenced": "SilencedUsers.ini",
    "settings-admins": "ServerSettingsAdminUsers.ini",
}
JSON_FILES = {
    "raid": "RaidTimes.json",
    "economy": "EconomyOverride.json",
    "notifications": "Notifications.json",
}
# env variable -> ServerSettings.ini key
ENV_KEYS = {
    "SCUM_SERVER_NAME": "scum.ServerName",
    "SCUM_PASSWORD": "scum.ServerPassword",
    "SCUM_MAX_PLAYERS": "scum.MaxPlayers",
}
ENV_ADMINS = "SCUM_ADMINS"
SECRET_KEYS = {"scum.ServerPassword"}


# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=2):
    """Written beside and renamed, so a cut-off write never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def read_text(path):
    try:
        with open(path, encoding="utf-8-sig", newline="") as f:
            return f.read()
    except OSError:
        return None


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


@contextlib.contextmanager
def locked():
    """One writer at a time for the read-modify-write commands (lists, the backup index). The lock file is
    on the install volume (local): a lock on the synced volume would be a file the synchroniser moves
    around. Not re-entrant: never nest."""
    os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
    fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o666)
    try:
        try:
            os.fchmod(fd, 0o666)
        except OSError:
            pass
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def env_set(name):
    """A variable counts only with a value: the marketplace writes every declared parameter, the
    ones left blank as NAME=, and a blank one must not wipe what the panel set."""
    return str(os.environ.get(name, "")).strip() != ""


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def steam_id(value):
    """A SteamID64 from what was typed or pasted (a profile link too), or None."""
    value = str(value).strip()
    m = re.search(r"(?:^|/profiles/)(7656119\d{10})/?$", value)
    return m.group(1) if m else None


# ------------------------------------------------------------------------------------------------
# ServerSettings.ini: read and edited in place
# ------------------------------------------------------------------------------------------------

def parse_ini(text):
    """[(section, key, value, line_index)] and the lines (CRLF kept as the file has it)."""
    lines = text.splitlines(keepends=True)
    rows, section = [], ""
    for i, raw in enumerate(lines):
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif "=" in line and not line.startswith(("#", ";")):
            key, value = line.split("=", 1)
            rows.append((section, key.strip(), value.strip(), i))
    return rows, lines


def infer_type(default):
    if default in ("True", "False"):
        return "bool"
    if re.fullmatch(r"-?\d+", default):
        return "int"
    if re.fullmatch(r"-?\d+\.\d+", default):
        return "float"
    if re.fullmatch(r"\d{2}:\d{2}:\d{2}", default):
        return "time"
    return "text"


def defaults_table():
    """{key: (section, default, type)} from the game's own default file (build 1.3.5 shipped with the image)."""
    text = read_text(DEFAULTS_INI) or ""
    rows, _ = parse_ini(text)
    return {k: (s, v, infer_type(v)) for s, k, v, _ in rows}


def ini_path():
    return os.path.join(CONFIG_DATA, INI)


def load_ini():
    """(rows, lines, newline) of the live file, made from the default one when the game has not
    written its own yet."""
    path = ini_path()
    text = read_text(path)
    if text is None or not text.strip():
        text = read_text(DEFAULTS_INI) or ""
        os.makedirs(CONFIG_DATA, exist_ok=True)
        write_text(path, text)
    rows, lines = parse_ini(text)
    newline = "\r\n" if "\r\n" in text else "\n"
    return rows, lines, newline


def coerce(kind, value):
    """(text as the file holds it, None) or (None, why)."""
    if isinstance(value, bool):
        value = "True" if value else "False"
    value = str(value).strip()
    if kind == "bool":
        v = value.lower()
        if v in ("true", "1", "yes", "on"):
            return "True", None
        if v in ("false", "0", "no", "off"):
            return "False", None
        return None, "must be true or false"
    if kind == "int":
        if not re.fullmatch(r"-?\d+", value):
            return None, "must be a whole number"
        return str(int(value)), None
    if kind == "float":
        try:
            n = float(value)
        except ValueError:
            return None, "must be a number"
        return f"{n:.6f}", None
    if kind == "time":
        if not re.fullmatch(r"\d{1,4}:\d{2}:\d{2}", value):
            return None, "must be a time as HH:MM:SS"
        return value, None
    if re.search(r"[\x00-\x1f\x7f]", value):
        return None, "cannot contain control characters"
    if len(value) > 400:
        return None, "is longer than 400 characters"
    return value, None


def check_key(key, kind, value, why=None):
    """Extra limits beyond the type: the player count."""
    if key == "scum.MaxPlayers":
        if not 1 <= int(value) <= MAX_PLAYERS_CAP:
            return f"must be from 1 to {MAX_PLAYERS_CAP}"
    if key == "scum.ServerName" and not value.strip():
        return "needs a name"
    return why


def set_ini_values(changes):
    """changes: {key: value as given}. Returns (applied {key: text}, errors {key: why}). Unknown keys
    are refused (a typo must not become a line the game ignores)."""
    rows, lines, newline = load_ini()
    defaults = defaults_table()
    present = {k: (s, v, i) for s, k, v, i in rows}
    applied, errors = {}, {}
    for key, value in changes.items():
        if key in present:
            kind = defaults.get(key, (None, present[key][1], infer_type(present[key][1])))[2]
        elif key in defaults:
            kind = defaults[key][2]
        else:
            errors[key] = "is not a setting of this server"
            continue
        text, why = coerce(kind, value)
        why = check_key(key, kind, text, why) if text is not None else why
        if why:
            errors[key] = why
            continue
        applied[key] = text
    if errors:
        return {}, errors
    for key, text in applied.items():
        if key in present:
            i = present[key][2]
            lines[i] = f"{key}={text}{newline}"
        else:
            section = defaults[key][0]
            at = next((n for n, raw in enumerate(lines) if raw.strip() == f"[{section}]"), None)
            if at is None:
                lines.append(f"[{section}]{newline}")
                at = len(lines) - 1
            lines.insert(at + 1, f"{key}={text}{newline}")
            rows2, lines2 = parse_ini("".join(lines))
            present = {k: (s, v, i) for s, k, v, i in rows2}
            lines = lines2
    if applied:
        write_text(ini_path(), "".join(lines))
    return applied, errors


def ini_value(key, default=None):
    rows, _, _ = load_ini()
    for _s, k, v, _i in rows:
        if k == key:
            return v
    return default


# ------------------------------------------------------------------------------------------------
# Player lists
# ------------------------------------------------------------------------------------------------

def list_path(name):
    return os.path.join(CONFIG_DATA, LISTS[name])


def read_list(name):
    """[{id, raw}] for every SteamID64 in the file. The rest of a line (SCUM admins can carry a
    permission suffix such as [SetGodMode]) is kept as 'raw' and written back unchanged."""
    text = read_text(list_path(name)) or ""
    rows = []
    for line in text.splitlines():
        m = re.match(r"^\s*(7656119\d{10})\b(.*)$", line)
        if m:
            rows.append({"id": m.group(1), "raw": line.strip(), "extra": m.group(2).strip()})
    return rows


def write_list(name, ids):
    """Writes exactly `ids` (in order), keeping the suffix of ids that were already there."""
    keep = {r["id"]: r["raw"] for r in read_list(name)}
    seen, lines = set(), []
    for i in ids:
        if i in seen:
            continue
        seen.add(i)
        lines.append(keep.get(i, i))
    write_text(list_path(name), "".join(f"{line}\r\n" for line in lines))


def parse_ids(values):
    ids, bad = [], []
    for v in values:
        sid = steam_id(v)
        (ids if sid else bad).append(sid or str(v))
    return ids, bad


def cmd_list(args):
    if not args or args[0] not in LISTS:
        fail(f"usage: list {{{'|'.join(LISTS)}}}", 64)
    out({"name": args[0], "entries": [{"id": r["id"], "extra": r["extra"]} for r in read_list(args[0])]})


def cmd_set_list(args):
    if len(args) < 2 or args[0] not in LISTS:
        fail(f"usage: set-list {{{'|'.join(LISTS)}}} '<json>'", 64)
    try:
        data = json.loads(args[1])
        ids_in = data["ids"]
        assert isinstance(ids_in, list)
    except (ValueError, KeyError, AssertionError):
        fail('Expected {"ids": ["7656119..."]}.')
    ids, bad = parse_ids(ids_in)
    if bad:
        fail(f"Not a SteamID64: {', '.join(bad[:5])}. A SteamID64 is 17 digits starting 7656119.")
    if len(ids) > 5000:
        fail("Too many entries.")
    with locked():
        write_list(args[0], ids)
    out({"ok": True, "name": args[0], "count": len(set(ids))})


def one_id(args, verb):
    if len(args) < 2 or args[0] not in LISTS:
        fail(f"usage: {verb} {{{'|'.join(LISTS)}}} <steamid64>", 64)
    sid = steam_id(args[1])
    if not sid:
        fail(f"Not a SteamID64: {str(args[1])[:40]}. A SteamID64 is 17 digits starting 7656119.")
    return args[0], sid


def cmd_list_add(args):
    """One id added to a list, read and written under the lock so two panels (or a stale browser tab) can
    never overwrite each other. Already there: ok, changed false, the file is not touched."""
    name, sid = one_id(args, "list-add")
    with locked():
        have = [r["id"] for r in read_list(name)]
        if sid in have:
            out({"ok": True, "name": name, "id": sid, "changed": False, "count": len(set(have))})
            return
        if len(have) >= 5000:
            fail("Too many entries.")
        write_list(name, have + [sid])
    out({"ok": True, "name": name, "id": sid, "changed": True, "count": len(set(have)) + 1})


def cmd_list_remove(args):
    name, sid = one_id(args, "list-remove")
    with locked():
        have = [r["id"] for r in read_list(name)]
        if sid not in have:
            out({"ok": True, "name": name, "id": sid, "changed": False, "count": len(set(have))})
            return
        left = [i for i in have if i != sid]
        write_list(name, left)
    out({"ok": True, "name": name, "id": sid, "changed": True, "count": len(set(left))})


def apply_admins_env(notes):
    """SCUM_ADMINS adds admins on every start and never removes one."""
    if not env_set(ENV_ADMINS):
        return
    ids, bad = parse_ids(re.split(r"[\s,;]+", os.environ[ENV_ADMINS].strip()))
    ids = [i for i in ids if i]
    for b in bad:
        if b:
            notes.append(f"WARN {ENV_ADMINS}: {b!r} is not a SteamID64; skipped")
    with locked():
        have = [r["id"] for r in read_list("admins")]
        add = [i for i in ids if i not in have]
        if add:
            write_list("admins", have + add)
    if add:
        notes.append(f"{len(add)} admin(s) added from {ENV_ADMINS}")


# ------------------------------------------------------------------------------------------------
# JSON rule files (RaidTimes, EconomyOverride, Notifications)
# ------------------------------------------------------------------------------------------------

def cmd_file(args):
    if not args or args[0] not in JSON_FILES:
        fail(f"usage: file {{{'|'.join(JSON_FILES)}}}", 64)
    name = JSON_FILES[args[0]]
    text = read_text(os.path.join(CONFIG_DATA, name))
    if text is None:
        text = read_text(os.path.join(DATA_FILES_DIR, name)) or "{}\n"
    out({"name": args[0], "file": name, "text": text})


def cmd_set_file(args):
    if len(args) < 2 or args[0] not in JSON_FILES:
        fail(f"usage: set-file {{{'|'.join(JSON_FILES)}}} '<json text>'", 64)
    text = args[1]
    if len(text) > 2 * 1024 * 1024:
        fail("The file is too large.")
    try:
        parsed = json.loads(text)
    except ValueError as e:
        fail(f"Not valid JSON: {e}")
    if not isinstance(parsed, dict):
        fail("The file must be a JSON object.")
    write_text(os.path.join(CONFIG_DATA, JSON_FILES[args[0]]), text if text.endswith("\n") else text + "\n")
    out({"ok": True, "name": args[0]})


# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

def load_state():
    data = read_json(STATE_FILE, {})
    return data if isinstance(data, dict) else {}


def cmd_state(args):
    state = load_state()
    new = args[0] if args else "unknown"
    if new == "starting" and state.get("state") != "starting":
        state["generation"] = int(state.get("generation") or 0) + 1
    state["state"] = new
    state["message"] = args[1] if len(args) > 1 else ""
    state["since"] = int(time.time())
    if new == "running":
        state["runningSince"] = int(time.time())
    write_json(STATE_FILE, state)


def cmd_note(args):
    if not args:
        fail("usage: note <key> [value]", 64)
    state = load_state()
    if len(args) > 1 and args[1] != "":
        state[args[0]] = int(args[1]) if args[1].isdigit() else args[1]
    else:
        state.pop(args[0], None)
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# Environment, ports and the launch line
# ------------------------------------------------------------------------------------------------

def env_port(notes):
    """The game port from the environment, or None (with a note). The server also uses port + 2 (TCP,
    measured), so the highest must still be a port."""
    raw = os.environ.get("SCUM_GAME_PORT", "").strip() or str(DEFAULT_GAME_PORT)
    try:
        n = int(raw)
    except ValueError:
        notes.append(f"ERROR SCUM_GAME_PORT={raw!r} is not a port")
        return None
    if not 1024 <= n <= 65533:
        notes.append(f"ERROR SCUM_GAME_PORT={n} is not a port from 1024 to 65533")
        return None
    return n


def apply_env(notes):
    """Each SCUM_* value that is set, written when the file is new or the value differs from the
    one last applied."""
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    created = not os.path.isfile(ini_path()) or not (read_text(ini_path()) or "").strip()
    changed = False
    for name, key in ENV_KEYS.items():
        if not env_set(name):
            continue
        raw = os.environ[name]
        if not created and applied.get(name) == raw:
            continue
        done, errors = set_ini_values({key: raw})
        if errors:
            notes.append(f"WARN {name}: {errors[key]}; kept the current value")
        else:
            shown = "(set)" if key in SECRET_KEYS else done[key]
            notes.append(f"{key} = {shown} ({name}{', new file' if created else ', changed'})")
        applied[name] = raw
        changed = True
    if changed:
        write_json(ENV_APPLIED_FILE, applied)


def prune_game_files(notes):
    """The game makes its own copy of the database at every start (SaveFiles/SCUM_<time>.db-backup) and a
    set of log files (SaveFiles/Logs/<kind>_<time>.log); it deletes none of them (measured: eight starts,
    eight copies and 152 logs). On the local volume they would fill a plan with daily restarts, so the
    newest FLUX_GAME_DB_BACKUPS database copies (3) are kept, and logs older than FLUX_GAME_LOG_DAYS (14)
    except the newest three of each kind."""
    keep = int(os.environ.get("FLUX_GAME_DB_BACKUPS", "3"))
    removed = 0
    try:
        copies = sorted((f for f in os.listdir(SAVEFILES) if re.fullmatch(r"SCUM_\d{14}\.db-backup", f)), reverse=True)
    except OSError:
        copies = []
    for f in copies[keep:]:
        try:
            os.remove(os.path.join(SAVEFILES, f))
            removed += 1
        except OSError:
            pass
    days = int(os.environ.get("FLUX_GAME_LOG_DAYS", "14"))
    kinds = {}
    try:
        for f in os.listdir(LOGIN_LOG_DIR):
            m = re.fullmatch(r"(.+)_(\d{14})\.log", f)
            if m:
                kinds.setdefault(m.group(1), []).append(f)
    except OSError:
        kinds = {}
    cutoff = time.time() - days * 86400
    for files in kinds.values():
        for f in sorted(files, reverse=True)[3:]:
            path = os.path.join(LOGIN_LOG_DIR, f)
            try:
                if os.path.getmtime(path) < cutoff:
                    os.remove(path)
                    removed += 1
            except OSError:
                pass
    if removed:
        notes.append(f"{removed} old file(s) of the game's own database copies and logs removed")


def link_config(notes):
    """<install>/SCUM/Saved/Config/WindowsServer -> the data volume, made at every start. A real
    folder the game made there (a first run) is moved onto the volume first."""
    os.makedirs(CONFIG_DATA, exist_ok=True)
    os.makedirs(os.path.dirname(CONFIG_LINK), exist_ok=True)
    if os.path.islink(CONFIG_LINK):
        if os.readlink(CONFIG_LINK) == CONFIG_DATA:
            return
        os.remove(CONFIG_LINK)
    elif os.path.isdir(CONFIG_LINK):
        moved = 0
        for f in os.listdir(CONFIG_LINK):
            if not os.path.exists(os.path.join(CONFIG_DATA, f)):
                shutil.move(os.path.join(CONFIG_LINK, f), os.path.join(CONFIG_DATA, f))
                moved += 1
        shutil.rmtree(CONFIG_LINK, ignore_errors=True)
        notes.append(f"{moved} file(s) the game had made in its own Config moved to the data volume")
    os.symlink(CONFIG_DATA, CONFIG_LINK)


def build_args(port):
    args = ["-log", f"-port={port}", f"-MaxPlayers={ini_value('scum.MaxPlayers', '64')}"]
    if not truthy(os.environ.get("SCUM_BATTLEYE", "")):
        args.append("-nobattleye")
    extra = os.environ.get("SCUM_EXTRA_ARGS", "").strip()
    if extra:
        args += [a for a in re.split(r"\s+", extra) if a and not a.lower().startswith(("-port=", "-maxplayers="))]
    return args


def cmd_args(_args):
    port = env_port([])
    if port is None:
        sys.exit(2)
    print("\n".join(build_args(port)))


def cmd_apply(_args):
    notes = []
    os.makedirs(STATE_DIR, exist_ok=True)
    link_config(notes)
    port = env_port(notes)
    if port is None:
        for line in notes:
            print(f"# {line}")
        sys.exit(2)
    prune_game_files(notes)
    load_ini()
    apply_env(notes)
    apply_admins_env(notes)
    for f in LISTS.values():
        if not os.path.exists(os.path.join(CONFIG_DATA, f)):
            write_text(os.path.join(CONFIG_DATA, f), "")
    notes.append(f"{ini_value('scum.MaxPlayers')} slots, game port {port} (UDP), port {port + 2} (TCP)")
    for line in notes:
        print(f"# {line}")
    state = load_state()
    state["gamePort"] = port
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# Settings (the panel's form)
# ------------------------------------------------------------------------------------------------

def cmd_settings(_args):
    # inFile: is the key in the settings file the game itself wrote (or the image holds)? null when there is
    # no such file yet (first boot: load_ini() below makes it from the shipped defaults, so every key would
    # be "in the file" and say nothing).
    had_file = bool((read_text(ini_path()) or "").strip())
    rows, _, _ = load_ini()
    defaults = defaults_table()
    seen, items = set(), []
    for section, key, value, _i in rows:
        dsec, ddef, dkind = defaults.get(key, (section, value, infer_type(value)))
        items.append({"key": key, "section": section or dsec, "type": dkind, "default": ddef,
                      "value": "" if key in SECRET_KEYS else value, "known": key in defaults,
                      "inFile": True if had_file else None})
        seen.add(key)
    for key, (section, ddef, kind) in defaults.items():
        if key not in seen:
            items.append({"key": key, "section": section, "type": kind, "default": ddef, "value": ddef, "known": True, "inFile": False if had_file else None})
    out({"settings": items, "maxPlayersCap": MAX_PLAYERS_CAP, "secrets": sorted(SECRET_KEYS),
         "passworded": bool(ini_value("scum.ServerPassword", ""))})


def cmd_set_settings(args):
    try:
        values = json.loads(args[0])["values"]
        assert isinstance(values, dict)
    except (IndexError, ValueError, KeyError, AssertionError):
        fail('Expected {"values": {"scum.ServerName": "..."}}.')
    if len(values) > 600:
        fail("Too many settings at once.")
    applied, errors = set_ini_values(values)
    if errors:
        fail("; ".join(f"{k} {v}" for k, v in list(errors.items())[:5]))
    out({"ok": True, "applied": sorted(applied), "restartNeeded": True})


def cmd_join_password(_args):
    out({"joinPassword": ini_value("scum.ServerPassword", "")})


# ------------------------------------------------------------------------------------------------
# The save (SQLite)
# ------------------------------------------------------------------------------------------------

def db_ok(path):
    try:
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        try:
            return c.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        finally:
            c.close()
    except sqlite3.Error:
        return False


def sqlite_copy(src, dst, readonly=True):
    """SQLite's online backup of src into a new file dst: consistent whatever the writer is doing."""
    uri = f"file:{src}?mode=ro" if readonly else f"file:{src}"
    s = sqlite3.connect(uri, uri=True, timeout=30)
    d = sqlite3.connect(dst)
    try:
        s.backup(d)
    finally:
        d.close()
        s.close()


def clear_wal(db):
    for suffix in ("-wal", "-shm"):
        try:
            os.remove(db + suffix)
        except OSError:
            pass


# ---- identity of this node and the snapshot meta ---------------------------------------------------

def node_id():
    """Who this node is: made once, kept on the install volume (never synced, so two nodes never share it)."""
    try:
        with open(NODE_ID_FILE, encoding="utf-8") as f:
            value = f.read().strip()
        if value:
            return value
    except OSError:
        pass
    value = uuid.uuid4().hex
    os.makedirs(os.path.dirname(NODE_ID_FILE), exist_ok=True)
    with open(NODE_ID_FILE, "w", encoding="utf-8") as f:
        f.write(value + "\n")
    return value


def local_record():
    """The last snapshot meta this node WROTE or ADOPTED (node, time, size, write), or None on a node
    that has not run this version yet (an upgrade from 1.0.0)."""
    rec = read_json(LOCAL_SNAP_FILE)
    return rec if isinstance(rec, dict) and rec.get("time") else None


def write_local_record(meta):
    write_json(LOCAL_SNAP_FILE, {k: meta.get(k) for k in ("node", "time", "size", "write")})


def read_snapshot():
    """(meta, why_not). meta is the snapshot.json when it can be trusted: it parses, a snapshot DB exists and
    the meta's size is the DB's size (the two are separate files to the synchroniser, so one can arrive
    before the other). why_not says what is wrong otherwise. The integrity check is made when a snapshot is
    about to be used."""
    meta = read_json(SNAP_META)
    if not os.path.isfile(SNAP_DB):
        return None, "there is no snapshot"
    if not isinstance(meta, dict) or not meta.get("time"):
        return None, "the snapshot has no readable snapshot.json yet"
    try:
        size = os.path.getsize(SNAP_DB)
    except OSError:
        return None, "the snapshot cannot be read"
    if meta.get("size") != size:
        return None, f"snapshot.json says {meta.get('size')} bytes and SCUM.db is {size} (still synchronising?)"
    return meta, None


def snap_time():
    meta, _ = read_snapshot()
    return int(meta.get("time") or 0) if meta else 0


def meta_is_ours(meta, rec):
    """True when this snapshot is one this node wrote or already adopted (so it is not news), or when the node
    has nothing recorded to compare with."""
    if not rec:
        return True
    if meta.get("node") and meta.get("node") == node_id() and int(meta.get("time") or 0) >= int(rec.get("time") or 0):
        return True
    return (meta.get("node"), meta.get("time"), meta.get("write")) == (rec.get("node"), rec.get("time"), rec.get("write"))


def new_meta():
    return {"time": int(time.time()), "size": os.path.getsize(SNAP_DB), "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
            "node": node_id(), "write": uuid.uuid4().hex[:12]}


def publish_snapshot_meta():
    """Called once SNAP_DB is final: the record on this node, then the meta on the synced volume."""
    meta = new_meta()
    # The meta first, then the record: a kill in between leaves a meta of this node that is NEWER than the
    # record, which meta_is_ours() accepts. The other order would leave one that looks like an older restore.
    write_json(SNAP_META, meta)
    write_local_record(meta)
    write_json(DB_SEEN, {"time": meta["time"]})
    return meta


def keep_copy(src, label, move=False):
    """Keeps a copy of a save under flux-replaced (local), never overwriting a name: the same snapshot seen
    twice is kept once. Newest REPLACED_KEEP by mtime stay. Returns the file name."""
    os.makedirs(REPLACED_DIR, exist_ok=True)
    name = f"SCUM-{label}.db"
    dst = os.path.join(REPLACED_DIR, name)
    n = 1
    while os.path.exists(dst):
        if not move and os.path.getsize(dst) == os.path.getsize(src):
            return name
        n += 1
        name = f"SCUM-{label}-{n}.db"
        dst = os.path.join(REPLACED_DIR, name)
    if move:
        shutil.move(src, dst)
    else:
        shutil.copyfile(src, dst)
    os.utime(dst, None)
    old = sorted((os.path.getmtime(os.path.join(REPLACED_DIR, f)), f) for f in os.listdir(REPLACED_DIR))
    for _m, f in old[:-REPLACED_KEEP]:
        try:
            os.remove(os.path.join(REPLACED_DIR, f))
        except OSError:
            pass
    return name


def foreign_label(meta):
    if not meta:
        return "snapshot-unlabelled-" + time.strftime("%Y%m%d-%H%M%S", time.gmtime(os.path.getmtime(SNAP_DB)))
    return f"snapshot-{str(meta.get('node') or 'old')[:8]}-{meta.get('time')}"


def cmd_snapshot(_args):
    """The synchronised copy of the save. Skipped when there is no live save or it fails the check, or while a
    restore is waiting for the next start (it would overwrite the restored files with the live save). A
    snapshot on the volume that this node did not write (a restore it was not told about, another node) is
    copied to flux-replaced before it is overwritten."""
    if not os.path.isfile(LIVE_DB):
        print("# snapshot skipped: no save yet")
        return
    if os.path.exists(RESTORE_MARKER):
        print("# snapshot skipped: a restore waits for the next start")
        return
    os.makedirs(SNAP_DIR, exist_ok=True)
    tmp = SNAP_DB + ".part"
    try:
        if os.path.exists(tmp):
            os.remove(tmp)
        sqlite_copy(LIVE_DB, tmp)
        c = sqlite3.connect(tmp)
        ok = c.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        c.close()
        if not ok:
            raise sqlite3.Error("the copy failed its integrity check")
        rec = local_record()
        if rec and os.path.isfile(SNAP_DB):
            meta = read_json(SNAP_META)
            meta = meta if isinstance(meta, dict) and meta.get("time") else None
            if meta is None or not meta_is_ours(meta, rec):
                kept = keep_copy(SNAP_DB, foreign_label(meta))
                print(f"# snapshot on the volume was not written by this node: kept as flux-replaced/{kept}")
        os.replace(tmp, SNAP_DB)
    except (sqlite3.Error, OSError) as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        print(f"# WARN snapshot failed: {e}")
        sys.exit(1)
    meta = publish_snapshot_meta()
    print(f"# snapshot {meta['size'] // 1024} KB")


def install_db(src, why):
    """Puts src in place as the live save, keeping what was there under flux-replaced."""
    if os.path.isfile(LIVE_DB):
        keep_copy(LIVE_DB, time.strftime("%Y%m%d-%H%M%S", time.gmtime()), move=True)
    clear_wal(LIVE_DB)
    os.makedirs(SAVEFILES, exist_ok=True)
    shutil.copyfile(src, LIVE_DB)
    print(f"# save: {why}")


def adopt_snapshot(meta, why):
    """The synchronised snapshot becomes the live save, and this node records it as the one it holds."""
    install_db(SNAP_DB, why)
    write_local_record(meta)


def save_guard(decision, message, notice=False, **extra):
    """What the guard decided, in flux/save-guard.json (status.saveGuard): the panel shows it when `notice`."""
    data = {"decision": decision, "message": message, "notice": bool(notice), "time": int(time.time())}
    data.update(extra)
    try:
        write_json(SAVE_GUARD_FILE, data)
    except OSError:
        pass
    print(f"# save: {message}")


def clean_temp():
    """Temp dirs and half-written files left by a killed run or by older versions (1.0.0 made its
    .flux-backup-* and .flux-restore-* on the SYNCED volume). Only what has not been touched for a while, so
    a backup running at this moment is left alone."""
    now = time.time()

    def newest(path):
        m = os.path.getmtime(path)
        if os.path.isdir(path):
            for root, _d, files in os.walk(path):
                for f in files:
                    try:
                        m = max(m, os.path.getmtime(os.path.join(root, f)))
                    except OSError:
                        pass
        return m

    targets = []
    for base in (DATA_DIR, SERVER_DIR):
        try:
            for f in os.listdir(base):
                if f.startswith((".flux-backup-", ".flux-restore-")):
                    targets.append(os.path.join(base, f))
        except OSError:
            pass
    for base, suffix in ((BACKUP_DIR, ".tar.gz.part"), (SNAP_DIR, ".part")):
        try:
            targets += [os.path.join(base, f) for f in os.listdir(base) if f.endswith(suffix)]
        except OSError:
            pass
    for path in targets:
        try:
            if now - newest(path) > TEMP_STALE_SECONDS:
                shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
        except OSError:
            pass


def guard_restore_marker():
    """A restore the hub asked for with the marker. True: handled (start). Exits 1 while the restored files
    have not all arrived. False: given up (the marker is removed), carry on with the normal rules."""
    mk = read_json(RESTORE_MARKER)
    mk = mk if isinstance(mk, dict) else {}
    label = str(mk.get("label") or "restore from the hub")[:80]
    asked = int(mk.get("time") or os.path.getmtime(RESTORE_MARKER))
    meta, why = read_snapshot()
    if meta:
        # The marker may be dropped BEFORE the restored files arrive (the hub calls restore-mark while the
        # container still runs). Only a snapshot that is not the one seen at that moment is the restore.
        if "before" in mk:
            before = mk["before"]
            if before is not None and (meta.get("node"), meta.get("time"), meta.get("write")) == tuple(before):
                meta, why = None, "the restored files have not arrived yet (the snapshot is still the one from before the restore)"
        elif local_record() and meta_is_ours(meta, local_record()):
            meta, why = None, "the restored files have not arrived yet (the snapshot is still this node's own)"
    if meta and db_ok(SNAP_DB):
        adopt_snapshot(meta, f"restore marker honoured ({label}): the restored save is used")
        os.remove(RESTORE_MARKER)
        write_json(LAST_RESTORE_FILE, {"name": label, "ok": True, "error": None, "time": int(time.time())})
        save_guard("restore-marker", f"restore marker honoured ({label}): the restored save is used; this node's copy is in flux-replaced", notice=True)
        clear_db_missing()
        return True
    waited = int(time.time()) - asked
    if waited < DB_SYNC_GRACE:
        print(f"Waiting for the restored save to finish synchronising ({waited}s of {DB_SYNC_GRACE}s): {why or 'its integrity check failed'}.")
        sys.exit(1)
    try:
        os.remove(RESTORE_MARKER)
    except OSError:
        pass
    error = f"the restored save never became usable: {why or 'it failed its integrity check'}"
    write_json(LAST_RESTORE_FILE, {"name": label, "ok": False, "error": error, "time": int(time.time())})
    save_guard("restore-marker-failed", f"restore marker dropped: {error}", notice=True)
    return False


def cmd_db_guard(_args):
    """Which copy of the save the game starts on. Exit 0: start. Exit 1: wait (the last line says why).
    Never starts the game on an empty save when this server has had one: on a half-synchronised volume
    that would make a new world and synchronise it over the real one.

    With a live save and a trusted snapshot (snapshot.json exists and its size is the DB's size):
      own (this node wrote or adopted it)                      -> live
      foreign, newer than ours, live untouched since ours      -> FAILOVER: the snapshot (live kept)
      foreign, newer than ours, live also changed since ours   -> SPLIT-BRAIN: the later of the two (other kept)
      foreign, not newer than ours, no restore marker          -> live; the snapshot kept (a restore or a stale sync)
      restore marker present                                   -> the snapshot (live kept)
    Nothing recorded on this node (upgrade from 1.0.0): the old rule, snapshot much newer than live wins."""
    clean_temp()
    if os.path.exists(RESTORE_MARKER) and guard_restore_marker():
        return
    meta, why = read_snapshot()
    snap_file = os.path.isfile(SNAP_DB)
    rec = local_record()
    live = os.path.isfile(LIVE_DB)
    live_mtime = int(os.path.getmtime(LIVE_DB)) if live else 0
    live_wal = LIVE_DB + "-wal"
    if os.path.isfile(live_wal):
        live_mtime = max(live_mtime, int(os.path.getmtime(live_wal)))
    if live and not db_ok(LIVE_DB):
        print("# WARN the save on this node fails its integrity check")
        if meta and db_ok(SNAP_DB):
            adopt_snapshot(meta, "the damaged copy replaced by the synchronised snapshot")
            save_guard("damaged-live", "the save on this node was damaged: replaced by the synchronised snapshot (the damaged copy is in flux-replaced)", notice=True)
            return
        newest = newest_backup()
        if newest and restore_backup_db(newest):
            save_guard("damaged-live", f"the save on this node was damaged: replaced by backup {newest['name']}", notice=True)
            return
        print("The save on this node is damaged and there is no snapshot or backup to replace it. Restore one from the Backups tab.")
        sys.exit(1)
    if live:
        if meta is None:
            if snap_file:
                save_guard("snapshot-untrusted", f"the snapshot on the volume is not used ({why}); this node's save is kept", notice=False)
            else:
                save_guard("own", "this node's save is kept")
            clear_db_missing()
            return
        snap = int(meta.get("time") or 0)
        if rec is None:
            # Upgrade from 1.0.0: nothing to compare with. The old rule, and remember what we saw.
            if snap > live_mtime + SNAP_NEWER_BY and db_ok(SNAP_DB):
                adopt_snapshot(meta, "another node ran this server since: its newer snapshot is used (this node's copy is kept in flux-replaced)")
                save_guard("failover", "another node ran this server since: its newer snapshot is used (this node's copy is in flux-replaced)", notice=True)
            else:
                write_local_record(meta)
                save_guard("own", "this node's save is kept")
            clear_db_missing()
            return
        if meta_is_ours(meta, rec):
            save_guard("own", "this node's save is kept")
        elif snap > int(rec.get("time") or 0):
            advanced = live_mtime > int(rec["time"]) + DIVERGE_SECONDS
            if not db_ok(SNAP_DB):
                save_guard("snapshot-untrusted", "the newer snapshot on the volume fails its integrity check: not used; this node's save is kept", notice=True)
            elif not advanced:
                adopt_snapshot(meta, "another node ran this server since: its newer snapshot is used (this node's copy is kept in flux-replaced)")
                save_guard("failover", "another node ran this server since: its newer snapshot is used (this node's copy is in flux-replaced)", notice=True)
            elif snap > live_mtime:
                adopt_snapshot(meta, "SPLIT-BRAIN: both copies changed since the last snapshot; the later one (the snapshot) is used")
                save_guard("split-brain", "both this node and another one changed the save since the last shared snapshot. The later copy (the synchronised snapshot) is used; this node's copy is in flux-replaced. Check which is right.", notice=True)
            else:
                kept = keep_copy(SNAP_DB, foreign_label(meta))
                write_local_record(meta)
                save_guard("split-brain", f"both this node and another one changed the save since the last shared snapshot. This node's copy is the later one and is used; the other is kept as flux-replaced/{kept}. Check which is right.", notice=True, kept=kept)
        else:
            kept = keep_copy(SNAP_DB, foreign_label(meta))
            save_guard("older-snapshot", f"the snapshot on the volume is older than this node's save and was not written by it (a restore, or a stale sync). This node's save is kept; the snapshot is kept as flux-replaced/{kept}. To restore it, use the Backups tab or drop the restore marker.", notice=True, kept=kept)
        clear_db_missing()
        return
    # No live save here.
    if meta and db_ok(SNAP_DB):
        adopt_snapshot(meta, "restored from the synchronised snapshot (new node)")
        save_guard("new-node", "restored from the synchronised snapshot (new node)")
        clear_db_missing()
        return
    if not os.path.exists(DB_SEEN) and not snap_file:
        save_guard("new-world", "none yet, the game makes a new world")
        clear_db_missing()
        return
    # This server has had a save (or one is arriving), and none is usable here: the volume may not have finished synchronising.
    miss = read_json(DB_MISSING, {})
    miss = miss if isinstance(miss, dict) else {}
    first = int(miss.get("since") or time.time())
    if not miss:
        write_json(DB_MISSING, {"since": first})
    waited = int(time.time()) - first
    if waited < DB_SYNC_GRACE:
        print(f"Waiting for the save to finish synchronising to this node ({waited}s of {DB_SYNC_GRACE}s).")
        sys.exit(1)
    newest = newest_backup()
    if newest and restore_backup_db(newest):
        save_guard("from-backup", f"put back from backup {newest['name']} (no usable snapshot arrived)", notice=True)
        clear_db_missing()
        return
    print("This server had a save and it is missing, with no backup to put back. Not starting a new world over it; restore one in the Backups tab or redeploy.")
    sys.exit(1)


def clear_db_missing():
    try:
        os.remove(DB_MISSING)
    except OSError:
        pass


def cmd_restore_mark(args):
    """The hub calls this FIRST (it records the snapshot on the volume now), then stops the app, writes the
    older SCUM.db and then snapshot.json on the synced volume, and restarts. The next db-guard uses the
    first snapshot that differs from the recorded one instead of the save on this node, and snapshots stop
    overwriting the volume until then. A marker file written by hand (flux/restore-marker.json, {"time":
    epoch, "label": text}) has no record: then this node's own snapshot counts as "not arrived yet"."""
    label = (args[0] if args else "restore from the hub")[:80]
    seen, _why = read_snapshot()
    before = [seen.get("node"), seen.get("time"), seen.get("write")] if seen else None
    write_json(RESTORE_MARKER, {"time": int(time.time()), "label": label, "before": before})
    out({"ok": True, "label": label, "appliesOn": "restart"})


# ------------------------------------------------------------------------------------------------
# Backups: the save (a consistent copy of the database) and the config folder, as one .tar.gz
# ------------------------------------------------------------------------------------------------

def load_index():
    data = read_json(BACKUP_INDEX, {})
    return data if isinstance(data, dict) else {}


def list_backups():
    index = load_index()
    rows = []
    if os.path.isdir(BACKUP_DIR):
        for name in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if not BACKUP_NAME_RE.match(name):
                continue
            path = os.path.join(BACKUP_DIR, name)
            st = os.stat(path)
            meta = index.get(name, {})
            rows.append({"name": name, "size": st.st_size, "time": int(meta.get("time") or st.st_mtime),
                         "why": meta.get("why") or "", "keep": bool(meta.get("keep"))})
    return rows


def newest_backup():
    rows = list_backups()
    return rows[0] if rows else None


def prune_backups(keep):
    """The newest `keep` are kept, plus every one marked keep (made before a restore), plus the
    newest made while the server was up: a crash loop that backs up on every start can never
    rotate the last good save away."""
    rows = list_backups()
    index = load_index()
    kept = 0
    good_seen = False
    for row in rows:
        meta = index.get(row["name"], {})
        if meta.get("keep"):
            continue
        if not good_seen and meta.get("good"):
            good_seen = True
            continue
        kept += 1
        if kept > keep:
            try:
                os.remove(os.path.join(BACKUP_DIR, row["name"]))
            except OSError:
                pass
            index.pop(row["name"], None)
    write_json(BACKUP_INDEX, index)


def clean_label(why):
    """The label comes from the panel: one short line of printable text."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(why)).strip()
    return text[:80] or "by hand"


def make_backup(why, force=False):
    """Returns (result, note). result is the JSON the panel reads: {ok, name, size, why, keep} when a backup
    was made, {ok: false, skipped: true, error} when nothing was done on purpose (nothing saved yet, or the
    newest is under FLUX_BACKUP_MIN_AGE_MINUTES old and this is not forced), {ok: false, error} when it
    failed. note is the "# " line for the supervisor's log. A forced backup skips the age rule and is kept
    (never pruned), like the ones made before a restore."""
    why = clean_label(why)
    source = LIVE_DB if os.path.isfile(LIVE_DB) else (SNAP_DB if os.path.isfile(SNAP_DB) else None)
    if source is None:
        err = "There is no save to back up yet: the server makes it on its first start."
        return {"ok": False, "skipped": True, "error": err}, "# backup skipped: nothing saved yet"
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60")) * 60
    rows = list_backups()
    if not force and rows and time.time() - rows[0]["time"] < min_age:
        mins = int((time.time() - rows[0]["time"]) / 60)
        return ({"ok": False, "skipped": True, "error": f"The newest backup is only {mins} min old (a backup is skipped under {min_age // 60} min unless forced)."},
                f"# backup skipped: the newest is {mins} min old")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    # The name is reserved by creating its .part with O_EXCL, so two backups in the same second never share one.
    while True:
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-scum.tar.gz"
        path = os.path.join(BACKUP_DIR, name)
        if not os.path.exists(path):
            try:
                os.close(os.open(path + ".part", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o666))
                break
            except FileExistsError:
                pass
        time.sleep(1)
    # The consistent copy of the database is made on the install volume (local): a multi-GB temp dir must
    # not land on the synchronised one. Only the finished .tar.gz.part goes to the backup folder.
    os.makedirs(SERVER_DIR, exist_ok=True)
    tmpdb = tempfile.mkdtemp(dir=SERVER_DIR, prefix=".flux-backup-")
    try:
        copy = os.path.join(tmpdb, "SCUM.db")
        sqlite_copy(source, copy)
        with tarfile.open(path + ".part", "w:gz", compresslevel=3) as t:
            t.add(copy, arcname="SaveFiles/SCUM.db")
            if os.path.isdir(CONFIG_DATA):
                t.add(CONFIG_DATA, arcname="Config/WindowsServer")
    except Exception as e:  # noqa: BLE001 - whatever went wrong is the panel's answer, not a traceback
        shutil.rmtree(tmpdb, ignore_errors=True)
        try:
            os.remove(path + ".part")
        except OSError:
            pass
        return {"ok": False, "error": f"The backup failed: {e}"}, f"# WARN backup failed: {e}"
    shutil.rmtree(tmpdb, ignore_errors=True)
    os.replace(path + ".part", path)
    keep = why.startswith("before") or force
    with locked():
        index = load_index()
        state = load_state()
        index[name] = {"time": int(time.time()), "why": why, "keep": keep, "good": state.get("state") == "running"}
        write_json(BACKUP_INDEX, index)
        prune_backups(int(os.environ.get("FLUX_BACKUP_KEEP", "8")))
    size = os.path.getsize(path)
    return ({"ok": True, "name": name, "size": size, "why": why, "keep": keep},
            f"# backup {name} ({why}, {size // 1024} KB)")


def cmd_backup(args):
    """The panel's backup: exactly ONE JSON document on stdout, nothing else (exit 1 when ok is false)."""
    rest = list(args)
    why = rest[0] if rest else "by hand"
    result, _note = make_backup(why, force=len(rest) > 1 and rest[1] == "force")
    out(result)
    if not result.get("ok"):
        sys.exit(1)


def cmd_backup_plain(args):
    """The supervisor's backup: the "# " line only (its log)."""
    why = args[0] if args else "by hand"
    print(make_backup(why, force=len(args) > 1 and args[1] == "force")[1])


def cmd_backups(_args):
    out({"backups": list_backups()})


def safe_members(t, allowed_prefixes):
    for member in t.getmembers():
        parts = member.name.split("/")
        if member.name.startswith("/") or ".." in parts:
            raise ValueError(f"unsafe path {member.name}")
        if not any(member.name == p or member.name.startswith(p + "/") for p in allowed_prefixes):
            raise ValueError(f"unexpected entry {member.name}")
        if not (member.isfile() or member.isdir()):
            raise ValueError(f"not a file: {member.name}")


def restore_backup_db(row, with_config=False):
    """Extracts a backup's database over the live save. True when it was put back."""
    path = os.path.join(BACKUP_DIR, row["name"])
    tmp = tempfile.mkdtemp(dir=SERVER_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(path) as t:
            safe_members(t, ("SaveFiles", "Config"))
            t.extractall(tmp)  # noqa: S202 - every member checked above
        db = os.path.join(tmp, "SaveFiles", "SCUM.db")
        if not os.path.isfile(db) or not db_ok(db):
            return False
        install_db(db, f"backup {row['name']}")
        os.makedirs(SNAP_DIR, exist_ok=True)
        shutil.copyfile(db, SNAP_DB + ".part")
        os.replace(SNAP_DB + ".part", SNAP_DB)
        publish_snapshot_meta()
        cfg = os.path.join(tmp, "Config", "WindowsServer")
        if with_config and os.path.isdir(cfg):
            for f in os.listdir(cfg):
                if f in (list(LISTS.values()) + list(JSON_FILES.values()) + [INI]):
                    shutil.copyfile(os.path.join(cfg, f), os.path.join(CONFIG_DATA, f))
        return True
    except (OSError, ValueError, tarfile.TarError):
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def cmd_restore(args):
    name = os.path.basename(args[0]) if args else ""
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("No such backup.")
    write_json(RESTORE_FILE, {"name": name, "asked": int(time.time())})
    state = load_state()
    running = state.get("state") in ("running", "starting", "updating")
    if running and not os.path.exists(RESTART_MARKER):
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: restore {name}\nnotbefore=0\n")
    out({"ok": True, "restarting": running, "name": name})


def cmd_do_restore(_args):
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass
    name = os.path.basename(str(pending.get("name", "")))
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        print(f"# WARN the backup to restore is gone: {name}")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": False, "error": "that backup is gone", "time": int(time.time())})
        return
    print(make_backup(f"before restoring {name}", force=True)[1])
    if restore_backup_db({"name": name}, with_config=True):
        print(f"# restored {name}")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": True, "error": None, "time": int(time.time())})
    else:
        print(f"# WARN the restore of {name} failed")
        write_json(LAST_RESTORE_FILE, {"name": name, "ok": False, "error": "the backup could not be read or failed its check", "time": int(time.time())})


def cmd_import_save(args):
    """A SCUM.db from another server (an upload in flux/uploads) becomes a backup and is restored on the next start."""
    if not args:
        fail("usage: import-save <file>", 64)
    src = os.path.realpath(args[0])
    if not src.startswith(os.path.realpath(UPLOAD_DIR) + os.sep):
        fail("The file must be in the uploads folder.")
    try:
        if os.path.getsize(src) > IMPORT_MAX_BYTES:
            fail("The file is too large.")
        with open(src, "rb") as f:
            if f.read(16) != b"SQLite format 3\x00":
                fail("That is not a SCUM.db (not an SQLite file).")
        if not db_ok(src):
            fail("That save fails its integrity check.")
        probe = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        try:
            tables = {r[0] for r in probe.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        finally:
            probe.close()
        if not {"user", "user_profile", "prisoner"} <= tables:
            fail("That SQLite file is not a SCUM save.")
    except OSError as e:
        fail(f"The file could not be read: {e}")
    os.makedirs(BACKUP_DIR, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-scum.tar.gz"
    path = os.path.join(BACKUP_DIR, name)
    with tarfile.open(path + ".part", "w:gz", compresslevel=3) as t:
        t.add(src, arcname="SaveFiles/SCUM.db")
    os.replace(path + ".part", path)
    with locked():
        index = load_index()
        index[name] = {"time": int(time.time()), "why": "imported save", "keep": True, "good": False}
        write_json(BACKUP_INDEX, index)
    try:
        os.remove(src)
    except OSError:
        pass
    cmd_restore([name])


# ------------------------------------------------------------------------------------------------
# Players: the save's own table, and the game's login log
# ------------------------------------------------------------------------------------------------

LOGIN_RE = re.compile(r"(7656119\d{10})(?::([^'(]*))?.*?\blogged\s+(in|out)\b", re.IGNORECASE)


def log_encoding(head):
    """The codec of a game log from its first bytes: UTF-16 by BOM, UTF-16LE by NULs, else UTF-8."""
    if head[:2] == b"\xff\xfe":
        return "utf-16-le", 2
    if head[:2] == b"\xfe\xff":
        return "utf-16-be", 2
    if b"\x00" in head[:400]:
        return "utf-16-le", 0
    return "utf-8", 3 if head[:3] == b"\xef\xbb\xbf" else 0


def read_game_log(path, max_bytes=None):
    """The text of one of the game's own logs under SaveFiles/Logs. THEY ARE UTF-16LE (measured: no
    byte-order mark, a NUL after every character), unlike everything else this image reads. Decoded by
    the BOM when there is one, by NUL bytes when there is not, as UTF-8 when it is plain text.
    max_bytes: only the END of the file (at most about that many bytes), starting on a character boundary
    and at the start of a line, so a cap never turns the text into noise."""
    try:
        with open(path, "rb") as f:
            head = f.read(400)
            codec, skip = log_encoding(head)
            size = os.fstat(f.fileno()).st_size
            cut = bool(max_bytes) and size - skip > max_bytes
            if cut:
                width = 2 if codec.startswith("utf-16") else 1
                start = size - (max_bytes - max_bytes % width)
                start -= (start - skip) % width  # same parity as the character grid
                f.seek(start)
            else:
                f.seek(skip)
            raw = f.read()
    except OSError:
        return None
    text = raw.decode(codec, errors="replace")
    if cut:
        text = text.split("\n", 1)[1] if "\n" in text else ""
    return text


GAMELOG_KINDS = ("admin", "chat", "kill", "economy", "violations", "login")
GAMELOG_ALIASES = {"violation": "violations"}
GAMELOG_MAX_LINES = 2000
GAMELOG_MAX_BYTES = 512 * 1024


def gamelog_files():
    """{kind: [path newest first]} for the logs on disk, named <kind>_<14 digits>.log."""
    kinds = {}
    try:
        names = os.listdir(LOGIN_LOG_DIR)
    except OSError:
        return kinds
    for f in names:
        m = re.fullmatch(r"([A-Za-z0-9_]+?)_(\d{14})\.log", f)
        if m:
            kinds.setdefault(m.group(1).lower(), []).append((m.group(2), f))
    return {k: [os.path.join(LOGIN_LOG_DIR, f) for _t, f in sorted(v, reverse=True)] for k, v in kinds.items()}


def cmd_gamelog(args):
    """The tail of the game's own log of one kind: {ok, kind, files, lines}. Newest file last in `files`;
    `lines` oldest first. Capped in lines (default 200, at most 2000) and in bytes."""
    on_disk = gamelog_files()
    known = sorted(set(GAMELOG_KINDS) | set(on_disk))
    if not args:
        out({"ok": False, "error": "usage: gamelog <kind> [lines]", "kinds": known})
        sys.exit(64)
    kind = args[0].strip().lower()
    kind = GAMELOG_ALIASES.get(kind, kind)
    if kind not in known:
        out({"ok": False, "error": f"Unknown log kind {args[0][:40]!r}.", "kinds": known})
        sys.exit(1)
    want = 200
    if len(args) > 1:
        try:
            want = int(args[1])
        except ValueError:
            fail("lines must be a whole number.")
    want = max(1, min(want, GAMELOG_MAX_LINES))
    lines, used, budget = [], [], GAMELOG_MAX_BYTES
    for path in on_disk.get(kind, []):  # newest file first, until enough lines
        text = read_game_log(path, max_bytes=GAMELOG_MAX_BYTES)
        if text is None:
            continue
        got = [ln.rstrip("\r")[:2000] for ln in text.split("\n") if ln.strip()]
        lines = got + lines
        used.append(path)
        if len(lines) >= want:
            break
    lines = lines[-want:]
    truncated = False
    while lines and sum(len(ln.encode("utf-8")) + 1 for ln in lines) > budget:
        lines.pop(0)
        truncated = True
    out({"ok": True, "kind": kind, "files": [os.path.basename(p) for p in reversed(used)], "lines": lines,
         "count": len(lines), "truncated": truncated, "kinds": known})


def newest_login_log():
    try:
        files = [os.path.join(LOGIN_LOG_DIR, f) for f in os.listdir(LOGIN_LOG_DIR) if f.startswith("login_") and f.endswith(".log")]
    except OSError:
        return None
    return max(files, key=os.path.getmtime) if files else None


def online_players(path=None):
    """[{id, name}] logged in according to the newest login log, or None when there is no log yet."""
    path = path or newest_login_log()
    if not path:
        return None
    text = read_game_log(path)
    if text is None:
        return None
    who = {}
    for line in text.splitlines():
        m = LOGIN_RE.search(line)
        if not m:
            continue
        if m.group(3).lower() == "in":
            who[m.group(1)] = (m.group(2) or "").strip()
        else:
            who.pop(m.group(1), None)
    return [{"id": i, "name": n} for i, n in who.items()]


def cmd_players_online(_args):
    state = load_state()
    if state.get("state") != "running":
        return
    online = online_players()
    print(len(online) if online is not None else 0)


def known_players():
    """Every row of the save's `user` table. The id is what the table holds; when it carries a
    SteamID64 (a bare one, or inside a longer id) that is the id returned, so the panel can match it
    against the player lists."""
    source = LIVE_DB if os.path.isfile(LIVE_DB) else (SNAP_DB if os.path.isfile(SNAP_DB) else None)
    if not source:
        return []
    try:
        c = sqlite3.connect(f"file:{source}?mode=ro", uri=True, timeout=10)
        try:
            rows = c.execute("SELECT id, name, last_login_time, is_banned FROM user ORDER BY last_login_time DESC LIMIT 2000").fetchall()
        finally:
            c.close()
    except sqlite3.Error:
        return []
    players = []
    for rid, name, last, banned in rows:
        m = re.search(r"7656119\d{10}", str(rid))
        players.append({"id": m.group(0) if m else str(rid), "name": name or "", "lastLogin": last, "banned": bool(banned)})
    return players


def cmd_players(_args):
    online = online_players()
    ids = {p["id"] for p in (online or [])}
    banned = {r["id"] for r in read_list("banned")}
    admins = {r["id"] for r in read_list("admins")}
    players = known_players()
    for p in players:
        p["online"] = p["id"] in ids
        p["banned"] = p["banned"] or p["id"] in banned
        p["admin"] = p["id"] in admins
    out({"players": players, "online": online})


# ------------------------------------------------------------------------------------------------
# Status and restart
# ------------------------------------------------------------------------------------------------

def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{STEAM_APP}.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


# What the hub can call, and what this image can do. A hub that finds a verb or capability missing from
# `status` is talking to an older image and must not call it (an old image answers "usage" with exit 64).
HUB_VERBS = ["status", "settings", "set-settings", "list", "set-list", "list-add", "list-remove", "players", "file",
             "set-file", "gamelog", "backups", "backup", "restore", "restore-mark", "import-save", "restart", "join-password"]
CAPABILITIES = ["list-add", "list-remove", "gamelog", "backup-json", "backup-force-keep", "restore-marker", "save-guard", "settings-infile"]


def cmd_status(_args):
    state = load_state()
    running = state.get("state") == "running"
    online = online_players() if running else None
    snap = snap_time()
    result = {
        "state": state.get("state") or "unknown",
        "message": state.get("message") or "",
        "since": state.get("since"),
        "runningSince": state.get("runningSince"),
        "generation": int(state.get("generation") or 0),
        "serverName": ini_value("scum.ServerName", ""),
        "maxPlayers": int(ini_value("scum.MaxPlayers", "0") or 0),
        "passworded": bool(ini_value("scum.ServerPassword", "")),
        "ports": {"game": state.get("gamePort")},
        "build": installed_build(),
        "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
        "imageVersion": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
        "verbs": HUB_VERBS,
        "capabilities": CAPABILITIES,
        "saveGuard": read_json(SAVE_GUARD_FILE),
        "restoreMarkerPending": os.path.exists(RESTORE_MARKER),
        "playerCount": len(online) if online is not None else (0 if running else None),
        "players": online if online is not None else ([] if running else None),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "restorePending": os.path.exists(RESTORE_FILE),
        "lastRestore": read_json(LAST_RESTORE_FILE),
        "lastBackup": (list_backups() or [{}])[0].get("time"),
        "lastSnapshot": snap or None,
        "saveSize": os.path.getsize(LIVE_DB) if os.path.isfile(LIVE_DB) else None,
    }
    out(result)


def cmd_restart(_args):
    state = load_state()
    if state.get("state") not in ("running", "starting", "updating", "restarting"):
        fail("The server is not running.")
    if not os.path.exists(RESTART_MARKER):
        not_before = 0
        if state.get("state") == "running" and state.get("runningSince"):
            not_before = int(state["runningSince"]) + SETTLE_SECONDS
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: from the panel\nnotbefore={not_before}\n")
    out({"ok": True, "restarting": True})


def cmd_ready(_args):
    """For a HEALTHCHECK: the supervisor says the server is up and its TCP port accepts."""
    if load_state().get("state") != "running":
        sys.exit(1)
    port = (load_state().get("gamePort") or DEFAULT_GAME_PORT) + 2
    try:
        socket.create_connection(("127.0.0.1", port), timeout=2).close()
    except OSError:
        sys.exit(1)


# ------------------------------------------------------------------------------------------------
# Game updates that did not install
# ------------------------------------------------------------------------------------------------

def cmd_update_target(args):
    if args:
        write_json(UPDATE_TARGET_FILE, {"build": args[0], "time": int(time.time())})


def cmd_update_check(_args):
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    build = installed_build()
    if build != str(target.get("build")):
        write_json(UPDATE_FAILED_FILE, {"build": str(target.get("build")), "time": int(time.time())})
        print(f"# WARN the update to build {target.get('build')} did not install (still {build}); not retried for 6 hours")


def cmd_update_skip(args):
    failed = read_json(UPDATE_FAILED_FILE)
    if isinstance(failed, dict) and args and str(failed.get("build")) == args[0] \
            and time.time() - float(failed.get("time") or 0) < UPDATE_FAILED_SKIP:
        sys.exit(0)
    sys.exit(1)


COMMANDS = {
    "apply": cmd_apply, "args": cmd_args, "state": cmd_state, "note": cmd_note, "status": cmd_status,
    "settings": cmd_settings, "set-settings": cmd_set_settings, "join-password": cmd_join_password,
    "list": cmd_list, "set-list": cmd_set_list, "file": cmd_file, "set-file": cmd_set_file,
    "players": cmd_players, "players-online": cmd_players_online, "restart": cmd_restart,
    "backups": cmd_backups, "backup": cmd_backup, "backup-plain": cmd_backup_plain,
    "list-add": cmd_list_add, "list-remove": cmd_list_remove, "gamelog": cmd_gamelog, "restore-mark": cmd_restore_mark, "restore": cmd_restore, "do-restore": cmd_do_restore,
    "import-save": cmd_import_save, "snapshot": cmd_snapshot, "db-guard": cmd_db_guard,
    "update-target": cmd_update_target, "update-check": cmd_update_check, "update-skip": cmd_update_skip,
    "ready": cmd_ready,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 64
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
