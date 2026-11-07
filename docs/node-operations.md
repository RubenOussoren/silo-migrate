# Running a Migrations node day to day

`silo` (in every release at `<prefix>/current/bin/silo`) wraps the routine work. Link it once
as root so it's on your PATH and always follows the current release:

```sh
ln -sfn /srv/silo-migrate/current/bin/silo /usr/local/bin/silo
```

Run it as root or as the service account. Steps that belong to the service account always
run as that account with its environment (no `sudo -u … env HOME=… XDG_RUNTIME_DIR=…` lines).
Root running `silo` runs release code the account owns; that adds no authority, since the
account is root-equivalent through Docker anyway, but keep the release sealed (`silo doctor`).

| Command | What it does |
| --- | --- |
| `silo doctor` | Checks the release and installer checkout, update source, web service, agents, skills link, ChatGPT/Frontier/Claude sign-ins, GitHub token, commit identity, Docker, disk and the read-only release; prints the exact fix for anything wrong. Nothing secret is printed. |
| `silo update [--branch B]` | (root) Pulls the installer checkout (fast-forward only), runs `metal update`, restarts the web service, then `silo doctor`. Branch defaults to the installed one. |
| `silo use-github` | (root, once) Points `SILO_REPO` in `/etc/silo-migrate/metal.conf` and the installer checkout at GitHub (silo-migrate is public), after checking GitHub is reachable; keeps a timestamped backup of the config. From then on updates need no copied bundles. `CONVERTER_REPO` is left as it is: `metal plan` resolves it without a token; workspaces clone the private converter with `converter clone WS --repo https://github.com/discourse-org/discourse-converters.git` and the token file. |
| `silo restart` | Restarts the term-llm web service (ends open web chats). |
| `silo shell` | (root) A login shell as the service account with the right environment. |
| `silo prime` | Signs in to 1Password (you type the password) and warms op-cache, so Frontier works for 24 hours. The session is kept only in memory. |
| `silo claude-login [--sso\|--console]` | Signs the service account in to Claude Code and links it as `<prefix>/bin/claude`, which is on the web service's PATH but not root's (an older `/usr/local/bin/claude` link can then be removed). |
| `silo intake PROJECT` | Creates the project's drop folder `<prefix>/intake/PROJECT/` (private to the account). Copy export files into it; run it again as root afterwards so the files belong to the account. |

## Intake

Copy whatever the customer sent into one folder per project, in any shape (SQL dumps, XML or
JSON exports, archives, folders of attachments):

```sh
ssh SERVER silo intake mybb-acme          # once: creates /srv/silo-migrate/intake/mybb-acme/
scp -r EXPORT-FILES SERVER:/srv/silo-migrate/intake/mybb-acme/
ssh SERVER silo intake mybb-acme          # hands the files to the service account, shows a count
```

Then open a chat with **migration-data** (Frontier only) in the web UI, for example:
"Workspace mybb-acme: take the export from the drop folder, register it, load it into the
source database, and tell me the forum software and version, table prefix, charset and the
main row counts. Then propose a schema finding with invented examples."

## The data agent (migration-data)

migration-data is the only agent that handles customer data. Its tools (no approval prompts;
each is a fixed operation of `silo-migrate-control data WS`) can:

- look at the drop folder: list, head/tail/search (gzip/bzip2/xz decompressed on the fly),
  archive listings;
- create the workspace once (named workspace, source + platform label, dataset, a clone of
  discourse-converters with your GitHub token, the standard workflow binding);
- **take** files: moved into `workspaces/WS/inputs/`, read-only, SHA-256, registered, with a
  provenance record. Bytes are never changed;
- run its own Ruby/Python scripts and archive extraction in a sandbox (control image, no
  network, read-only root, inputs read-only, one new `work/<name>` output folder, 2 CPUs,
  4 GB, time limit), as jobs it polls; register finished outputs into `inputs/derived/`
  with the script's hash and inputs;
- run the project's **source database**: `silo-src-WS`, MariaDB (MySQL dumps) or PostgreSQL 18
  with Discourse's extensions (PostgreSQL dumps, Discourse backups), images from the runtime
  profile, data in volume `silo-src-WS-data`, on internal network `silo-src-WS` (no way out),
  with a read-only user `silo_ro`; load dumps as jobs, show tables and sizes, reset;
- read a failed run's evidence, and propose findings: a **schema finding** (no run: tables,
  columns, counts, invented examples) or a run's cause. You review and release them
  (`standard finding review/release`); only released text reaches converter-developer.

Every operation is logged in `workspaces/WS/.silo-migrate/data/audit.jsonl` (script code and
finding text by hash); moved and derived files in `provenance.jsonl`. Database passwords stay
in `.silo-migrate/data/db/` (0600): `secret.env` (administrator, given to the database and
loader containers) and `ro.env` (read-only user, host side only). They never appear in Docker
argv, and job logs are scrubbed of them.

Dumps are untrusted: the MariaDB client runs with `--sandbox` and psql under a random
`\restrict` key, so a dump can't run shell commands; after every load the read-only user is
reset to read-only, whatever the dump did. The project network is `--internal` and gives the
host no address on it (`inhibit_ipv4`): containers can't reach the internet or host services.
Jobs stop, and new ones are refused, when the disk's free space drops below 20 GiB or 10%.

A file over 16 GiB is too big to take or register within a chat tool's 300 s. Run the same
request as the service account from a shell instead (no time limit), for example:

```sh
printf '%s' '{"op":"take","path":"forum.sql.gz","type":"mysql-dump"}' | /srv/silo-migrate/bin/silo-migrate-control data arc
```

An interrupted take or register resumes when it is run again.

Free SQL queries come with DBHub once term-llm can attach an MCP server to one agent only
(in term-llm 0.9.93 any chat can switch on any configured MCP server).

**Skills** ship in the release (`integrations/term-llm/skills`) and reach the account through
the link `~/.config/term-llm/skills` → `<prefix>/current/integrations/term-llm/skills` that
`metal apply/update` creates if absent (doctor shows the fix otherwise). Each agent's
`skills:` decides what it sees: migration-data gets all of them, the others none (term-llm
0.9.93 can't give an agent a subset).

## op-cache (Frontier's key)

The service account needs its own `~/.config/op-cache/config.yaml` (mode 0600). Without it,
op-cache uses a socket in the shared `/tmp` and a 24-hour cache. As root:

```sh
sudo -u silomig -H /usr/local/bin/op-cache stop        # before changing the socket
U=$(id -u silomig)
sudo -u silomig mkdir -p -m 700 /home/silomig/.config/op-cache
printf 'socket_path: /run/user/%s/op-cache.sock\nop_path: /usr/bin/op\nttl_seconds: 2592000\n' "$U" \
  | sudo -u silomig tee /home/silomig/.config/op-cache/config.yaml >/dev/null
sudo -u silomig chmod 600 /home/silomig/.config/op-cache/config.yaml
silo prime                                             # on its own: it asks for your password
```

`silo doctor` shows the socket and cache time. `op-cache stop` (as the account) clears the key at once.
