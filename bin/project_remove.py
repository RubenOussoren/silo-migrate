"""Remove a project from this Migrations node, or start it over.

  silo-migrate-control remove-project --list
  silo-migrate-control remove-project PROJECT --plan [--keep-received]
  silo-migrate-control remove-project PROJECT --confirm PROJECT [--keep-received] [--by NAME]

`--plan` changes nothing: what would go, what would stay, and anything that stops it now. `--confirm`
does it. Reached from `silo remove-project` (a terminal) and the Project page; no agent tool maps to
it. Everything a project leaves belongs to this account:

  Docker    its source database (container, volume, network), data jobs and DBHub, by the label
            silo.workspace=PROJECT; review sites and conversion containers, by the label
            silo-migrate.run=RUN of each of its runs, and the IDs its site records hold
  mcp.json  its db-PROJECT entry (removed by bin/data_tools.py's own writer)
  folders   the workspace <base>/PROJECT, the drop folder <prefix>/intake/PROJECT and the chats'
            folder ~/projects/PROJECT
  term-llm  its chats and their agents' chats (sessions.db; deleted one by one with
            `term-llm sessions delete`, children first), their attachments (uploads/, upload-refs/)
            and the folder's handover files. A full removal archives the web UI project: term-llm
            0.9.93 can't delete one, and `silo intake` brings it back empty.

Start over (--keep-received) first puts each file taken from the drop folder back where it was, then
keeps the drop folder, the chats' folder (emptied) and the web UI project (with no chats). It refuses
while a run, a data job or one of the project's chats is busy, or when something of it belongs to
another user. A folder in ~/projects alone isn't a project: there must be a workspace, a drop folder,
a web UI project, an MCP entry or Docker objects of that name. Every step can run again: a removal
stopped part-way is finished by running it again (a full removal archives the web UI project last,
so that until then it is still found). Each removal appends a line to
<prefix>/state/removed-projects.jsonl: who, when, which project and counts, never file names.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import sqlite3
import stat
import subprocess
import time
import urllib.parse

RUN = re.compile(r"run-[0-9a-f]{32}\Z")
SESSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
WEB_PROJECT = re.compile(r"prj_[0-9a-f]{8,64}\Z")
UPLOAD_REF = re.compile(r"upl_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])")
BY = re.compile(r"[^\x00-\x1f\x7f]{1,120}\Z")
TOKEN = re.compile(r"[A-Za-z0-9._~+/=-]{16,512}\Z")
SERVICE_URL = re.compile(r"http://(?:localhost|127\.0\.0\.1):\d{1,5}/[A-Za-z0-9/_-]*\Z")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
SHOWN_NAMES = 5
BUSY = ("claimed", "running")


class Refusal(ValueError):
    pass


def refuse(code):
    raise Refusal(code)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def plural(count, word):
    return "%d %s%s" % (count, word, "" if count == 1 else "s")


def plain_dir(path, what):
    """True for a real folder of this account, False when there is none; anything else stops."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        refuse("STANDARD_PATH_INVALID: " + what + " is not a plain folder of this account")
    return True


def tree_size(path):
    """(bytes, files) of the regular files below a folder, links not followed."""
    total, files, _foreign = tree_facts(path)
    return total, files


def tree_facts(path):
    """(bytes, files, folders owned by another user) below a folder, links not followed. A folder of
    another user (a container's bind mount, a copy made as root) can't be emptied by this account."""
    total = files = foreign = 0
    for _folder, dirs, names, dirfd in os.fwalk(str(path), follow_symlinks=False):
        for name in dirs:
            try:
                info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(info.st_mode) and info.st_uid != os.getuid():
                foreign += 1
        for name in names:
            try:
                info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
                files += 1
    return total, files, foreign


def remove_tree(path):
    """Delete a folder of this account and everything in it, never through a link."""
    if not plain_dir(path, str(path)):
        return False
    # Folders made read-only (an extracted archive, a converter's fixtures) can't be emptied as they are.
    for _folder, dirs, _names, dirfd in os.fwalk(str(path), follow_symlinks=False):
        for name in dirs:
            try:
                fd = os.open(name, DIR_FLAGS, dir_fd=dirfd)
            except OSError:  # a link, or already gone
                continue
            try:
                if os.fstat(fd).st_uid == os.getuid():
                    os.fchmod(fd, 0o700)
            finally:
                os.close(fd)
    top = os.open(str(path), DIR_FLAGS)
    try:
        os.fchmod(top, 0o700)
    finally:
        os.close(top)
    shutil.rmtree(str(path))  # the descriptor-based version: links inside are removed, not followed
    return True


def empty_folder(path):
    if not plain_dir(path, str(path)):
        return 0
    removed = 0
    with os.scandir(str(path)) as entries:
        names = [entry.name for entry in entries]
    for name in names:
        child = Path(path) / name
        if stat.S_ISDIR(os.lstat(child).st_mode):
            remove_tree(child)
        else:
            os.unlink(child)
        removed += 1
    return removed


def lock_held(path):
    """Whether someone holds this lock file now (it is left as it was)."""
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)  # closing releases it
    return False


@contextlib.contextmanager
def hold(path):
    """Take a lock file the way its owners do (created if missing, never through a link)."""
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileNotFoundError:  # its folder is already gone
        yield
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            refuse("STANDARD_BUSY: the project is busy right now; try again in a minute")
        yield
    finally:
        os.close(fd)


def handover_name(folder):
    """term-llm's handover folder for a working folder: <basename>-<first 3 bytes of sha256(path)>."""
    return os.path.basename(folder) + "-" + hashlib.sha256(folder.encode("utf-8")).hexdigest()[:6]


class Removal:
    def __init__(self, dt, ws, keep):
        self.dt, self.ws, self.keep = dt, ws, keep
        # term-llm finds its data and the chats' folders from $HOME, as `silo` and the web service set it.
        home = os.environ.get("HOME") or ""
        self.home = Path(home) if home.startswith("/") else Path(pwd.getpwuid(os.getuid()).pw_dir)
        self.chats_folder = self.home / "projects" / ws.name
        xdg = os.environ.get("XDG_DATA_HOME")
        self.term_data = (Path(xdg) if xdg and xdg.startswith("/") else self.home / ".local/share") / "term-llm"
        self.uploads = self.term_data / "uploads"
        self.record_file = ws.prefix / "state" / "removed-projects.jsonl"
        self.has_workspace = False

    # -- what there is ---------------------------------------------------------------------

    def folders(self):
        """The project's two chat-folder spellings: as term-llm was given it, and resolved."""
        return sorted({str(self.chats_folder), os.path.realpath(self.chats_folder)})

    def standard(self):
        path = self.ws.root / ".silo-migrate/named/standard/state.json"
        if not self.has_workspace or not os.path.lexists(path):
            return {}
        try:
            if path.is_symlink():
                raise ValueError
            state = json.loads(path.read_text())
        except (OSError, ValueError):
            # Without it, its review sites can't be found: stop rather than leave them running.
            refuse("STANDARD_STATE_INVALID: the project's workbench state can't be read; ask for help")
        return state if isinstance(state, dict) else {}

    def received(self):
        """Files taken from the drop folder that are still in inputs/, with where each goes back."""
        ws, found, seen = self.ws, [], set()
        inputs = ws.root / "inputs"
        if not self.has_workspace or not plain_dir(inputs, "inputs"):
            return found

        def add(name, origin):
            if name in seen or not isinstance(name, str) or "/" in name or name in ("", ".", ".."):
                return
            try:
                parts = self.dt.parts_of(origin)
                info = os.lstat(inputs / name)
            except (self.dt.Refusal, OSError):
                return
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                seen.add(name)
                found.append({"name": name, "bytes": info.st_size, "from": "/".join(parts), "ino": info.st_ino})

        provenance = ws.data / "provenance.jsonl"
        lines = provenance.read_text(errors="replace").splitlines() if provenance.is_file() and not provenance.is_symlink() else []
        for line in lines:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            path, origin = record.get("path"), record.get("from")
            if record.get("event") == "take" and isinstance(path, str) and path.startswith("inputs/") and isinstance(origin, str) and origin.startswith("intake/"):
                add(path[len("inputs/"):], origin[len("intake/"):])
        # A take stopped after its move but before its record: its pending note knows where the file
        # came from, and the file's inode which one it is.
        pending = ws.data / "pending"
        if pending.is_dir() and not pending.is_symlink():
            for note in sorted(pending.glob("*.json")):
                try:
                    record = self.ws.read_json(note, {}) if not note.is_symlink() else {}
                except ValueError:
                    continue
                provenance = record.get("provenance") if isinstance(record, dict) else None
                origin = provenance.get("from") if isinstance(provenance, dict) else None
                if not (isinstance(origin, str) and origin.startswith("intake/") and provenance.get("event") == "take"):
                    continue
                with os.scandir(str(inputs)) as entries:
                    for entry in entries:
                        info = entry.stat(follow_symlinks=False)
                        if stat.S_ISREG(info.st_mode) and (info.st_dev, info.st_ino) == (record.get("dev"), record.get("ino")):
                            add(entry.name, origin[len("intake/"):])
        # Back where it was; if that place is taken, beside it under the name it had in inputs/.
        taken = set()
        for item in found:
            parts = item["from"].split("/")
            item["to"] = None
            for choice in ("/".join(parts), "/".join(parts[:-1] + [item["name"]])):
                if choice not in taken and not os.path.lexists(ws.intake / choice):
                    item["to"] = choice
                    taken.add(choice)
                    break
        return found

    def docker_lines(self, argv):
        result = self.dt.docker(argv, timeout=60)
        if result.returncode:
            refuse("STANDARD_DOCKER_UNAVAILABLE: Docker didn't answer; try again, or run silo doctor")
        return [line.split("\t") for line in result.stdout.decode("utf-8", "replace").splitlines() if line.strip()]

    def docker_objects(self, state):
        """Every container, network and volume of this project: {kind: {id: {state, role, run}}}. Only exact
        labels count (a review site's stack carries its run's label from creation), and the source
        database's volume by its exact name."""
        names = self.dt.db_names(self.ws)
        runs = {run_id for run_id in (state.get("runs") or {}) if isinstance(run_id, str) and RUN.fullmatch(run_id)}
        labels = '\t{{.Label "silo.workspace"}}\t{{.Label "silo-migrate.run"}}\t{{.Label "silo.role"}}\t{{.Label "silo-migrate.role"}}'
        found = {"containers": {}, "networks": {}, "volumes": {}}
        for kind, argv in (("containers", ["ps", "-a", "--no-trunc", "--format", "{{.ID}}\t{{.State}}" + labels]),
                           ("networks", ["network", "ls", "--no-trunc", "--format", "{{.ID}}\t{{.Name}}" + labels]),
                           ("volumes", ["volume", "ls", "--format", "{{.Name}}\t{{.Name}}" + labels])):
            for fields in self.docker_lines(argv):
                identity, extra, workspace, run, role, run_role = (fields + [""] * 6)[:6]
                # The source database's volume is made by `docker run --mount`, so it has no labels.
                mine = workspace == self.ws.name or run in runs or (kind == "volumes" and identity == names["volume"])
                if identity and mine:
                    found[kind][identity] = {"state": extra if kind == "containers" else "", "role": role or run_role, "run": run}
        return found

    def mcp_present(self):
        try:
            config = json.loads(self.dt.mcp_config_path().read_text())
        except (OSError, ValueError):
            return False
        servers = config.get("servers") if isinstance(config, dict) else None
        entry = servers.get(self.dt.mcp_name(self.ws)) if isinstance(servers, dict) else None
        return isinstance(entry, dict) and (entry.get("args") or [None])[0] == "dbhub"

    def converter_unsaved(self):
        """What the converter checkout holds that GitHub doesn't: a short phrase, '' or None (unknown)."""
        checkout = self.ws.root / "converter"
        if not self.has_workspace or not (checkout / ".git").is_dir() or checkout.is_symlink():
            return ""
        host = self.ws.host
        try:
            host.converter_config_safe(checkout)  # nothing in its .git/config can run while this looks
            git = host.converter_git(checkout)
            ahead = int(host.capture(git + ["rev-list", "--count", "HEAD", "--not", "--remotes"]) or 0)
            changed = bool(host.capture(git + ["--no-optional-locks", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all"]))
        except (ValueError, OSError, AttributeError):
            return None
        parts = ([plural(ahead, "commit")] if ahead else []) + (["changes not committed"] if changed else [])
        return " and ".join(parts)

    def chats(self):
        """The project's chats in term-llm: IDs (children first), top-level count, how many are
        answering now, and the attachments their messages name."""
        out = {"project_id": None, "archived": False, "ids": [], "top": 0, "running": 0, "uploads": [], "refs": []}
        db = self.term_data / "sessions.db"
        if not db.is_file() or db.is_symlink():
            return out
        try:
            connection = sqlite3.connect("file:" + urllib.parse.quote(str(db)) + "?mode=ro", uri=True, timeout=15)
        except sqlite3.Error:
            refuse("STANDARD_CHATS_UNREADABLE: term-llm's chat database can't be read; try again")
        try:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            if "sessions" not in tables:
                return out
            folders = self.folders()
            if "projects" in tables:
                for project_id, archived in connection.execute("SELECT id, archived_at FROM projects WHERE canonical_dir IN (%s)" % ",".join("?" * len(folders)), folders):
                    out["project_id"], out["archived"] = project_id, archived is not None
            columns = {row[1] for row in connection.execute("PRAGMA table_info(sessions)")}
            pick = [name if name in columns else "NULL" for name in ("parent_id", "root_id", "project_id", "cwd")]
            rows = connection.execute("SELECT id, %s FROM sessions" % ", ".join(pick)).fetchall()
            mine = {sid for sid, _parent, _root, project, cwd in rows
                    if (out["project_id"] and project == out["project_id"])
                    or (isinstance(cwd, str) and any(cwd == folder or cwd.startswith(folder + "/") for folder in folders))}
            links = {sid: {parent, root} - {None, sid} for sid, parent, root, _project, _cwd in rows}
            others = str(self.home / "projects") + "/"

            def not_elsewhere(project, cwd):
                """An agent's chat belongs here unless it is another project's, or ran in another project's folder."""
                if project and project != out["project_id"]:
                    return False
                return not (isinstance(cwd, str) and cwd.startswith(others) and not any(cwd == f or cwd.startswith(f + "/") for f in folders))
            free = {sid for sid, _parent, _root, project, cwd in rows if not_elsewhere(project, cwd)}
            grown = True
            while grown:  # every agent's chat started from one of these, however deep
                grown = False
                for sid, refs in links.items():
                    if sid not in mine and sid in free and refs & mine:
                        mine.add(sid)
                        grown = True
            left = set(mine)
            while left:  # a chat goes only after every chat that points at it
                ready = sorted(sid for sid in left if not any(sid in links[other] for other in left if other != sid)) or sorted(left)
                out["ids"] += ready
                left -= set(ready)
            out["top"] = sum(1 for sid, parent, root, _project, _cwd in rows if sid in mine and not parent and not root)
            if "serve_response_lifecycle" in tables:
                answering = {row[0] for row in connection.execute("SELECT session_id FROM serve_response_lifecycle WHERE state = 'running'")}
                out["running"] = len(answering & mine)
            uploads, refs = set(), set()
            if "messages" in tables and mine:
                ids = sorted(mine)
                for start in range(0, len(ids), 400):
                    chunk = ids[start:start + 400]
                    for (parts,) in connection.execute("SELECT parts FROM messages WHERE session_id IN (%s)" % ",".join("?" * len(chunk)), chunk):
                        self.attachments(parts, uploads, refs)
            uploads = {name for name in uploads if self.upload_file(name)}
            refs = {ref for ref in refs if self.upload_file(ref) or self.upload_file(ref + ".json", "upload-refs")}
            if "messages" in tables:  # an attachment another chat also names stays with that chat
                for name in sorted(uploads | refs):
                    users = {row[0] for row in connection.execute("SELECT DISTINCT session_id FROM messages WHERE instr(parts, ?) > 0", (name,))}
                    if users - mine:
                        uploads.discard(name)
                        refs.discard(name)
            out["uploads"], out["refs"] = sorted(uploads), sorted(refs)
        except sqlite3.Error:
            refuse("STANDARD_CHATS_UNREADABLE: term-llm's chat database can't be read; try again")
        finally:
            connection.close()
        return out

    def attachments(self, parts, uploads, refs):
        """Attachment files a message names: paths straight inside uploads/, and upl_ references."""
        try:
            value = json.loads(parts) if isinstance(parts, str) else None
        except ValueError:
            value = parts
        texts, stack = [], [value]
        while stack:
            item = stack.pop()
            if isinstance(item, str):
                texts.append(item)
            elif isinstance(item, dict):
                stack.extend(item.values())
            elif isinstance(item, list):
                stack.extend(item)
        prefixes = sorted({str(self.uploads), os.path.realpath(self.uploads)})
        for text in texts:
            refs.update(UPLOAD_REF.findall(text))
            for prefix in prefixes:
                rest = text[len(prefix) + 1:] if text.startswith(prefix + "/") else None
                if rest and "/" not in rest:
                    uploads.add(rest)
                for found in re.findall(re.escape(prefix + "/") + r"([^/\s\"'<>()\[\]\\]{1,255})", text):
                    uploads.update({found, found.rstrip(".,;:!?")} - {""})  # a path at the end of a sentence

    def upload_file(self, name, folder="uploads"):
        if name in (".", "..") or "/" in name or "\x00" in name:
            return False
        try:
            info = os.lstat(self.term_data / folder / name)
        except OSError:
            return False
        return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()

    # -- the plan ----------------------------------------------------------------------------

    def survey(self):
        ws = self.ws
        self.has_workspace = plain_dir(ws.root, "the workspace")
        facts = {"drop": plain_dir(ws.intake, "the drop folder"), "chats_folder": plain_dir(self.chats_folder, "the chats' folder")}
        facts["state"] = self.standard()
        facts["received"] = self.received()
        facts["docker"] = self.docker_objects(facts["state"])
        facts["chats"] = self.chats()
        facts["mcp"] = self.mcp_present()
        # Only folders that will be emptied: Start over keeps the drop folder.
        places = [ws.root] if self.has_workspace else []
        places += [] if self.keep or not facts["drop"] else [ws.intake]
        places += [self.chats_folder] if facts["chats_folder"] else []
        facts["foreign"] = sum(tree_facts(place)[2] for place in places)
        return facts

    def blockers(self, facts):
        ws, out = self.ws, []
        runs = (facts["state"].get("runs") or {}).values()
        if any(isinstance(run, dict) and run.get("status") in BUSY for run in runs):
            out.append({"code": "STANDARD_BUSY_RUN", "text": "A run is still running. Wait for it to finish, or stop it from the Runs tab."})
        if any(item["role"] == "data-job" and item["state"] == "running" for item in facts["docker"]["containers"].values()):
            out.append({"code": "STANDARD_BUSY_JOB", "text": "A data job is still running. Wait for it to finish, or ask migration-data to stop it."})
        if self.has_workspace and (lock_held(ws.root / ".silo-migrate/named/standard/op.lock") or lock_held(ws.data / "lock")):
            out.append({"code": "STANDARD_BUSY", "text": "The project is busy right now (an agent or a decision is working on it). Try again in a minute."})
        if facts["chats"]["running"]:
            out.append({"code": "STANDARD_BUSY_CHAT", "text": "A chat in this project is still answering. Stop it or let it finish, then try again."})
        if facts.get("foreign"):
            out.append({"code": "STANDARD_REMOVE_NOT_OWNED", "text": "Some of its folders belong to another user (root, say), so this account can't remove them. Ask for help; nothing was changed."})
        if self.keep and any(not item["to"] for item in facts["received"]):
            out.append({"code": "STANDARD_REMOVE_DROP_TAKEN", "text": "A received file can't go back: the drop folder already has files of those names. Move them away, then try again."})
        return out

    def plan(self, facts=None):
        facts = facts or self.survey()
        ws, removed, kept = self.ws, [], []

        def item(text, size=None, warn=False):
            return {"text": text, "bytes": size, "warn": warn}

        received = facts["received"]
        received_bytes = sum(entry["bytes"] for entry in received)
        names = ", ".join(entry["name"] for entry in received[:SHOWN_NAMES]) + (" and %d more" % (len(received) - SHOWN_NAMES) if len(received) > SHOWN_NAMES else "")
        if self.has_workspace:
            state = facts["state"]
            total, _ = tree_size(ws.root)
            checkout = ws.root / "converter"
            converter = tree_size(checkout)[0] if plain_dir(checkout, "the converter checkout") else 0
            work = [plural(len(state.get("plans") or {}), "plan"), plural(len(state.get("runs") or {}), "run"),
                    plural(len(state.get("findings") or {}), "finding"), "labels, notes and decisions"]
            removed.append(item("Work: " + ", ".join(work), max(total - converter - received_bytes, 0)))
            if converter:
                unsaved = self.converter_unsaved()
                text = "Converter checkout on this server"
                if unsaved:
                    text += ", with " + unsaved + " that aren't on GitHub"
                elif unsaved is None:
                    text += " (couldn't check it for work that isn't on GitHub)"
                removed.append(item(text, converter, warn=unsaved is None or bool(unsaved)))
        docker = facts["docker"]
        count = sum(len(objects) for objects in docker.values())
        if count:
            sites = len({entry["run"] for entry in docker["containers"].values() if entry["role"] == "review" and entry["run"]})
            source = any(entry["role"] == "source-db" for entry in docker["containers"].values()) or self.dt.db_names(ws)["volume"] in docker["volumes"]
            what = ([plural(sites, "review site")] if sites else []) + (["the source database"] if source else [])
            text = " and ".join(what) if what else "Containers left from earlier work"
            removed.append(item(text[0].upper() + text[1:] + " (%s)" % plural(count, "Docker object"), None))
        elif facts["mcp"]:
            removed.append(item("The agents' query access to the source database", None))
        chats = facts["chats"]
        if chats["ids"]:
            attachments = len(set(chats["uploads"]) | set(chats["refs"]))
            text = plural(chats["top"] or len(chats["ids"]), "chat") + " in the web UI" + (", with " + plural(attachments, "attachment") if attachments else "")
            removed.append(item(text, None))
        if received:
            if self.keep:
                kept.append(item("Received files: " + names + ", back in the drop folder to label again", received_bytes))
            else:
                removed.append(item("Received files: " + names, received_bytes))
        if facts["drop"]:
            other_bytes, other_files = tree_size(ws.intake)
            if not self.keep:
                removed.append(item("The drop folder" + (", with " + plural(other_files, "file") + " not taken yet" if other_files else ""), other_bytes))
            elif other_files:
                kept.append(item(plural(other_files, "other file") + " in the drop folder", other_bytes))
        if facts["chats_folder"]:
            leftover_bytes, leftover = tree_size(self.chats_folder)
            if leftover:
                removed.append(item(plural(leftover, "file") + " in the chats' folder", leftover_bytes))
        if chats["project_id"] and not chats["archived"]:
            if self.keep:
                kept.append(item("The web UI project, with no chats", None))
            else:
                removed.append(item("The web UI project (archived: term-llm can't delete projects)", None))
        if self.has_workspace and (ws.root / "converter").is_dir():
            kept.append(item("The converter's branch and pull requests on GitHub", None))
        # A folder in ~/projects (or chats run in one) isn't a project by itself.
        exists = bool(self.has_workspace or facts["drop"] or count or facts["mcp"] or (chats["project_id"] and not chats["archived"]))
        return {"version": 1, "project": ws.name, "mode": "start_over" if self.keep else "remove", "exists": exists,
                "blocked": self.blockers(facts), "removed": removed, "kept": kept}

    # -- doing it ----------------------------------------------------------------------------

    def remove_mcp(self):
        if not self.mcp_present():
            return False
        try:
            self.dt.mcp_register(self.ws, present=False)
        except OSError:  # its audit line, when the workspace is already gone; the entry itself went first
            pass
        if self.mcp_present():
            refuse("STANDARD_REMOVE_INCOMPLETE: its db-" + self.ws.name + " entry in term-llm's MCP settings couldn't be removed")
        return True

    def remove_docker(self, state):
        first = None
        for attempt in range(4):
            objects = self.docker_objects(state)
            if first is None:
                first = sum(len(found) for found in objects.values())
            if not any(objects.values()):
                return first
            if attempt:
                time.sleep(2)  # a DBHub a chat just closed can hold the network for a moment
            for identity in objects["containers"]:
                self.dt.docker(["rm", "--force", "--volumes", identity], timeout=120)
            for identity in objects["networks"]:
                self.dt.docker(["network", "rm", identity], timeout=60)
            for identity in objects["volumes"]:
                self.dt.docker(["volume", "rm", "--force", identity], timeout=120)
        if any(self.docker_objects(state).values()):
            refuse("STANDARD_REMOVE_INCOMPLETE: some of its containers, networks or volumes are still there; run it again")
        return first

    def term_llm(self):
        """The node's term-llm, <prefix>/bin/term-llm; else the one on PATH (`silo` sets PATH to <prefix>/bin
        first, and the web service runs with it)."""
        installed = self.ws.prefix / "bin/term-llm"
        if installed.is_file() and os.access(installed, os.X_OK):
            return str(installed)
        return shutil.which("term-llm")

    def remove_chats(self, chats):
        if chats["ids"]:
            binary = self.term_llm()
            if not binary:
                refuse("STANDARD_REMOVE_INCOMPLETE: term-llm isn't where it should be, so its chats are still there")
            for sid in chats["ids"]:
                if SESSION.fullmatch(sid):
                    try:
                        subprocess.run([binary, "sessions", "delete", "--", sid], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=60)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
        for name in chats["uploads"]:
            if self.upload_file(name):
                os.unlink(self.uploads / name)
        for ref in chats["refs"]:
            for folder, name in (("uploads", ref), ("upload-refs", ref + ".json")):
                if self.upload_file(name, folder):
                    os.unlink(self.term_data / folder / name)
        handover = self.term_data / "handover"
        for folder in self.folders():
            if handover.is_dir() and not handover.is_symlink():
                remove_tree(handover / handover_name(folder))
        left = self.chats()["ids"]
        if left:
            refuse("STANDARD_REMOVE_INCOMPLETE: %s couldn't be deleted; run it again" % plural(len(left), "chat"))
        return len(chats["ids"])

    def archive_web_project(self, project_id):
        """A full removal's last term-llm step. Returns what happened, in a few words."""
        if not (isinstance(project_id, str) and WEB_PROJECT.fullmatch(project_id)):
            return "none"
        manual = "archive it in the web UI (Projects, " + self.ws.name + ", Archive)"
        try:
            spec = json.loads((self.home / ".config/term-llm/services/web/service.json").read_text())
            url = str(spec.get("url") or "") if isinstance(spec, dict) else ""
        except (OSError, ValueError):
            return manual
        binary = self.term_llm()
        if not SERVICE_URL.fullmatch(url) or not binary:
            return manual
        try:
            token = subprocess.run([binary, "service", "token", "web"], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return manual
        if not TOKEN.fullmatch(token):
            return manual
        import http.client
        import urllib.error
        import urllib.request

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        # Straight to the local service: no proxy, and no redirect carrying the token.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        request = urllib.request.Request(url.replace("localhost", "127.0.0.1").rstrip("/") + "/v1/projects/" + project_id, method="PATCH",
                                         data=b'{"archived": true}', headers={"content-type": "application/json", "authorization": "Bearer " + token})
        try:
            with opener.open(request, timeout=20) as response:
                response.read(65536)
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
            return manual
        return "archived"

    def return_received(self, files):
        """Put each received file back in the drop folder: a rename, or a checked copy across disks."""
        if not files:
            return []
        dt, ws = self.dt, self.ws
        if not plain_dir(ws.intake, "the drop folder"):
            ws.intake.parent.mkdir(mode=0o700, exist_ok=True)
            ws.intake.mkdir(mode=0o700)
        returned = []
        inputs, drop = dt.open_root(str(ws.root / "inputs")), dt.open_root(str(ws.intake))
        try:
            for entry in files:
                parts = dt.parts_of(entry["to"])
                parent = os.dup(drop)
                try:
                    for part in parts[:-1]:
                        try:
                            os.mkdir(part, 0o700, dir_fd=parent)
                        except FileExistsError:
                            pass
                        child = os.open(part, DIR_FLAGS, dir_fd=parent)
                        os.close(parent)
                        parent = child
                    source = os.open(entry["name"], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=inputs)
                    try:
                        if os.fstat(source).st_ino != entry["ino"]:
                            refuse("STANDARD_INPUT_CHANGED: a received file changed while this ran; run it again")
                        placed, _how = dt.place(ws, source, inputs, entry["name"], parent, parts[-1])
                        os.fchmod(placed, 0o600)
                        os.close(placed)
                    finally:
                        os.close(source)
                finally:
                    os.close(parent)
                returned.append({"name": entry["name"], "bytes": entry["bytes"], "to": entry["to"]})
        finally:
            os.close(inputs)
            os.close(drop)
        return returned

    def record(self, entry):
        """True once the line is written."""
        try:
            self.record_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(str(self.record_file), os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            with os.fdopen(fd, "a") as handle:
                handle.write(json.dumps(dict(entry, at=now(), project=self.ws.name, mode="start_over" if self.keep else "remove"), sort_keys=True) + "\n")
        except OSError:
            return False
        return True

    def locks(self):
        """New workspaces, agents' data operations and the workbench all wait while this runs."""
        ws = self.ws
        paths = [ws.base / ".silo-data-create.lock"]
        if self.has_workspace and (ws.root / ".silo-migrate").is_dir() and not (ws.root / ".silo-migrate").is_symlink():
            if ws.data.is_dir() and not ws.data.is_symlink():
                paths.append(ws.data / "lock")
            standard = ws.root / ".silo-migrate/named/standard"
            if standard.is_dir() and not standard.is_symlink():
                paths.append(standard / "op.lock")
        return paths

    def run(self, confirm, by):
        ws = self.ws
        if confirm != ws.name:
            refuse("STANDARD_CONFIRMATION_REQUIRED: type the project's name to confirm")
        if by is not None and not BY.fullmatch(by):
            refuse("STANDARD_ARGUMENTS_INVALID: by")
        facts = self.survey()
        plan = self.plan(facts)
        if not plan["exists"]:
            refuse("STANDARD_REFERENCE_INVALID: there is nothing of " + ws.name + " on this server")
        if plan["blocked"]:
            refuse(plan["blocked"][0]["code"] + ": " + plan["blocked"][0]["text"])
        self.record({"event": "started", "by": by or "unknown"})
        done = {"docker_objects": 0, "chats": 0, "attachments": 0, "returned": 0, "mcp_entry": False, "web_project": "kept" if self.keep else "none"}
        returned = []
        try:
            with contextlib.ExitStack() as stack:
                for path in self.locks():
                    stack.enter_context(hold(path))
                # Again, now that nothing new can start, and before anything is touched.
                state = self.standard()
                if any(isinstance(run, dict) and run.get("status") in BUSY for run in (state.get("runs") or {}).values()):
                    refuse("STANDARD_BUSY_RUN: a run is still running")
                if any(item["role"] == "data-job" and item["state"] == "running" for item in self.docker_objects(state)["containers"].values()):
                    refuse("STANDARD_BUSY_JOB: a data job is still running")
                chats = self.chats()
                if chats["running"]:
                    refuse("STANDARD_BUSY_CHAT: a chat in this project is still answering")
                # The customer's files go back first: a name in the way stops it before anything is removed.
                if self.keep:
                    received = self.received()
                    if any(not entry["to"] for entry in received):
                        refuse("STANDARD_REMOVE_DROP_TAKEN: the drop folder already has files of those names")
                    returned = self.return_received(received)
                    done["returned"] = len(returned)
                done["mcp_entry"] = self.remove_mcp()
                done["docker_objects"] = self.remove_docker(state)
                done["attachments"] = len(set(chats["uploads"]) | set(chats["refs"]))
                done["chats"] = self.remove_chats(chats)
                if self.has_workspace:
                    remove_tree(ws.root)
            if self.keep:
                empty_folder(self.chats_folder)
            else:
                remove_tree(ws.intake)
                remove_tree(self.chats_folder)
                # Last: until it's archived, a removal stopped part-way is still found and finished.
                done["web_project"] = self.archive_web_project(chats["project_id"]) if not chats["archived"] else "archived before"
        except (ValueError, OSError) as error:  # data_tools' refusals too (a file in the way, say)
            code = str(error).split(":")[0] if isinstance(error, ValueError) and str(error).startswith("STANDARD_") else "STANDARD_OPERATION_FAILED"
            self.record({"event": "stopped", "by": by or "unknown", "code": code, **{k: v for k, v in done.items() if k != "web_project"}})
            raise
        recorded = self.record({"event": "finished", "by": by or "unknown", **done})
        if self.keep:
            # As for a new project: migration-data sets the workspace up, then the engineer labels the files.
            following = ("Next: start a new chat with migration-data in project " + ws.name + " and ask what's next. It sets up the workspace; "
                         "then label the returned files on the Files tab." if returned
                         else "Next: copy the files into the drop folder again and run silo intake " + ws.name + " as root.")
        else:
            following = "Nothing of " + ws.name + " is left on this server."
        notes = []
        if not self.keep and done["web_project"] not in ("archived", "none", "archived before"):
            notes.append("The web UI project is still listed: " + done["web_project"] + ".")
        if not recorded:
            notes.append("The record of this removal couldn't be written to " + str(self.record_file) + ".")
        return {"version": 1, "project": ws.name, "mode": plan["mode"], "status": "done", "returned": returned, "removed": done,
                "next": following, "notes": notes}


def project_names(ws_base, intake):
    names = set()
    for folder in (ws_base, intake):
        try:
            with os.scandir(str(folder)) as entries:
                names |= {entry.name for entry in entries if re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}", entry.name) and entry.is_dir(follow_symlinks=False)}
        except OSError:
            continue
    return sorted(names)


def main(args, values, base, repo, host, dt):
    """`remove-project ...` as the module docstring says; prints one JSON line."""
    if args == ["remove-project", "--list"]:
        prefix = dt.Workspace.repo_prefix(Path(repo), Path(base))
        print(json.dumps({"version": 1, "projects": project_names(base, prefix / "intake")}))
        return 0
    if len(args) < 3 or args[0] != "remove-project":
        refuse("STANDARD_ARGUMENTS_INVALID")
    rest = args[2:]
    keep = "--keep-received" in rest
    rest = [arg for arg in rest if arg != "--keep-received"]
    removal = Removal(dt, dt.Workspace(base, args[1], repo, host, values, None), keep)
    if rest == ["--plan"]:
        result = removal.plan()
    elif len(rest) == 2 and rest[0] == "--confirm":
        result = removal.run(rest[1], None)
    elif len(rest) == 4 and rest[0] == "--confirm" and rest[2] == "--by":
        result = removal.run(rest[1], rest[3])
    else:
        refuse("STANDARD_ARGUMENTS_INVALID")
    print(json.dumps(result))
    return 0
