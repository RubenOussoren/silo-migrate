# Running a Migrations node day to day

> **Current stock workflow:** this release uses official, unmodified term-llm 0.9.103
> through normal `silo update`. Intake/reference preparation needs no fork package,
> native marker or capability command. Keep `TERM_LLM_PACKAGE` empty/unset. Earlier
> protected-native handoff instructions below are historical, not prerequisites.
> Conversation locking and trusted chat-upload import are deferred. Use Files intake
> and a new migration-data chat after updating; see [intake-preparation.md](intake-preparation.md).


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
| `silo doctor` | Checks the release and installer checkout, update source, web service, agents, skills link, ChatGPT/Frontier/Claude sign-ins, GitHub token, commit identity, Docker, disk, the read-only release and the DBHub limits; prints the exact fix for anything wrong. Nothing secret is printed. |
| `silo update [--branch B]` | (root) Pulls the installer checkout (fast-forward only), runs `metal update`, restarts the web service, then `silo doctor`. Branch defaults to the installed one. |
| `silo use-github` | (root, once) Points `SILO_REPO` in `/etc/silo-migrate/metal.conf` and the installer checkout at GitHub (silo-migrate is public), after checking GitHub is reachable; keeps a timestamped backup of the config. From then on updates need no copied bundles. `CONVERTER_REPO` is left as it is: `metal plan` resolves it without a token; workspaces clone the private converter with `converter clone WS --repo https://github.com/discourse-org/discourse-converters.git` and the token file. |
| `silo restart` | Restarts the term-llm web service (ends open web chats). |
| `silo shell` | (root) A login shell as the service account with the right environment. |
| `silo prime` | Signs in to 1Password (you type the password) and warms op-cache, so Frontier works for 24 hours. The session is kept only in memory. |
| `silo claude-login [--sso\|--console]` | Signs the service account in to Claude Code and links it as `<prefix>/bin/claude`, which is on the web service's PATH but not root's (an older `/usr/local/bin/claude` link can then be removed). |
| `silo intake PROJECT` | Creates the project's drop folder `<prefix>/intake/PROJECT/` (private to the account), its chat folder `~/projects/PROJECT` and its web UI project. Copy export files into the drop folder; run it again as root afterwards so the files belong to the account. |
| `silo set-contact NAME` | (root) Sets who the agents tell engineers to ask when they can't help. Stored in `<prefix>/etc/support-contact`, on this server only. |

## Intake

Copy whatever the customer sent into one folder per project, in any shape (SQL dumps, XML or
JSON exports, archives, folders of attachments):

```sh
ssh SERVER silo intake mybb-acme          # once: creates /srv/silo-migrate/intake/mybb-acme/
scp -r EXPORT-FILES SERVER:/srv/silo-migrate/intake/mybb-acme/
ssh SERVER silo intake mybb-acme          # hands the files to the service account, shows a count
```

Then, in the web UI, open the **Project** page for the project. On the **Files** tab, create the
workspace (first time only: type the source platform, which must match the converter's folder
`converters/PLATFORM` in discourse-converters, and press **Create workspace**) and say what the
files are for (Development, Launch or Base site). No chat is needed for either.
To merge another Discourse site into the customer's site instead of converting a forum, the platform
is `discourse`: see `docs/project-merge-run.md`.

Then open a chat with **migration-data** (Frontier only) in that project, for example:
"Take the export from the drop folder, register it, load it into the
source database, and tell me the forum software and version, table prefix, charset and the
main row counts. Then propose a schema finding with invented examples."

## Supporting references through Files intake

On the supported official stock host, upload XLSX/CSV/TSV or a supported small
reference document through the project's intake folder, then classify it as
**Supporting reference** on Project → Files. Ask migration-data in that project to
inspect the needed sheets/ranges and prepare the converter-native file. Original
bytes and provenance remain private to the workspace. This does not replace source
or Base, approve a plan or start a run. Use a new chat after an update so it selects
the current tool definitions. Chat-upload import/drag-drop provenance is deferred;
`STANDARD_SUPPORTING_USE_INTAKE` means use this flow, not install a native package.

## The data agent (migration-data)

migration-data is the only agent that handles customer data. Its tools (no approval prompts;
each is a fixed operation of `silo-migrate-control data WS`) can:

- look at the drop folder: list, head/tail/search (gzip/bzip2/xz decompressed on the fly),
  archive listings;
- create the workspace when the engineer asks in chat instead of using the Files tab's **Create workspace** (named workspace, source + platform label, dataset, a clone of
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
  (`standard finding review/release`); only released text reaches converter-developer;
- for a merge project (platform `discourse`): take the source site's full backup, write and
  register a merge settings file, propose the merge run, and read a merge run's totals and the
  end of its private log. See `docs/project-merge-run.md`.

Every operation is logged in `workspaces/WS/.silo-migrate/data/audit.jsonl` (script code and
finding text by hash); moved and derived files in `provenance.jsonl`. Database passwords stay
in `.silo-migrate/data/db/` (0600): `secret.env` (administrator, given to the database and
loader containers) and `ro.env` (read-only user, host side only). They never appear in Docker
argv, and job logs are scrubbed of them.

Dumps are untrusted: the MariaDB client runs with `--sandbox` and psql under a random
`\restrict` key, so a dump can't run shell commands, and a dump's own query output is
discarded. After every load the read-only user is re-created and reduced to reading (MariaDB:
privileges, roles, other host entries; event scheduler off; PostgreSQL: role attributes,
settings, memberships, PUBLIC grants). That is best effort against a hostile dump, not a
boundary: the source database is disposable, and query access (DBHub) opens its sessions
read-only itself. The project network is `--internal` and gives the
host no address on it (`inhibit_ipv4`): containers can't reach the internet or host services.
Jobs stop, and new ones are refused, when the disk's free space drops below 20 GiB or 10%.

A file over 16 GiB is too big to take or register within a chat tool's 300 s. Run the same
request as the service account from a shell instead (no time limit), for example:

```sh
printf '%s' '{"op":"take","path":"forum.sql.gz","type":"mysql-dump"}' | /srv/silo-migrate/bin/silo-migrate-control data arc
```

An interrupted take or register resumes when it is run again (also when its registration
finished after the tool gave up).

**One project per chat (web UI projects).** Several customers share this node and its agents.
Each project's files, findings, notes, converter checkout, branches and database are separate,
and the web UI keeps chats apart:

- The web service runs with `--projects`, so every chat belongs to a project. `silo intake PROJECT`
  creates the folder `~/projects/PROJECT` and a web UI project of that name (if the service
  answers; otherwise choose New project and pick that folder). Chats from before projects were
  turned on, and server-support chats, live in the home project.
- term-llm runs a project chat's tools in the project's folder, and a chat can't move to
  another project. The tools use that: **every migration agent works only in a project chat, on
  that project's workspace**, and takes it from the chat (`STANDARD_CHAT_NOT_IN_PROJECT` outside one).
  The project folder holds nothing and should stay empty (term-llm would read project skills from
  it); customer data stays in the workspace. The lock doesn't reach DBHub: MCP servers start in
  the service's home folder, not the project's, so turning on only the chat's own `db-<project>`
  stays your job (migration-data is told to stop if another project's server is on).
- **Look and feel:** the web UI uses Varnish by Keegan George (`extensions/varnish`, a copy of upstream with two checked compatibility patches; `script/update-varnish COMMIT` replaces it and applies them) with our changes kept in `extensions/silo-theme`. Updates are deliberate: this code runs on pages showing customer data, so run the browser tests before shipping one.
- **The Project page** (the horizontal **Project** button in the chat header, and under Widgets) shows one project at a time: which data is in use, where it stands, what to do next. New files are labelled there as Development or Launch, and only there: the agent can't take a file until it's labelled, a plan's approval covers which delivery it uses, and a launch run is refused until running on launch data is built (the accepted process it will repeat is already recorded: see Accepting a site).
- **Faster navigation:** Findings and Runs share one read and keep a project-scoped snapshot in page memory. Previously loaded lists appear immediately and refresh in the background; no finding text is stored in persistent browser storage. Switching projects or making a decision clears the snapshots. Approval, release and site-acceptance details still read fresh state and retain their exact-text/digest checks. A failed refresh is shown rather than silently presenting the list as current.
- **What labels guard against:** mixing up data by accident. A script reads one delivery and its outputs belong to it, but migration-data can still read every delivery, so the labels don't stop an agent deliberately copying one delivery's content into another's script.
- **Rollback and labels:** a release from before labels ignores them. After rolling back, the agent can take unlabelled files again until you roll forward. If a take from before labels was interrupted and shows "ask the engineer", finish it by hand: as the service account, check `.silo-migrate/data/pending/` in the workspace and the file already in `inputs/`, then ask for help.
- **The guide:** every migration-data chat starts with `data_guide`, which works out from the project's state where it stands and what's next, so a new chat knows as much as an old one. Agents take the project from the chat, so they never need to be told which one it is.
- **Decisions:** `data_decide` records the engineer's rulings in an append-only log in the workspace; `data_decisions` reads them back.
- **Project notes** are migration-data's memory: `data_notes` / `data_notes_write` keep one notes
  file per workspace (`.silo-migrate/data/notes.md`, the last 20 versions in `notes-history/`).
  It reads them at the start of each chat and updates them after meaningful work. term-llm's own
  memory is kept per agent, so it would mix customers; it stays off on this node (no mining jobs).
  Notes are model-written: like findings, read them before trusting them (a hostile export could
  try to steer what gets written).

**Stock analysis preferences, not durable DLP.** `migration-data` retains Frontier-only
`allowed_models` and `search: false`. Use clean coding/research chats for public lookups,
with generic questions only; never send customer-derived values in a query or URL.
The supported stock host does not provide the experimental durable conversation lock
or trusted native session marker. Search preferences must not be described as guaranteed
web-tool removal. Initial full-flow testing uses invented data. Stronger restart,
retarget and configuration-widening privacy protections are explicitly deferred.
See [intake-preparation.md](intake-preparation.md) for the supported stock workflow.

**Private converter links never use web tools.** Links to
`github.com/discourse-org/discourse-converters` and PR numbers go through `dev_branch_resolve`
(converter-developer) or `data_branch_resolve` (migration-data), then branch list/diff/read tools.
These resolve only the workspace's configured origin. The data adapter uses the server-enforced
`reader` role: only `branches`, `branch-resolve`, `branch-diff`, `branch-read`, never tests or writes.
Repository content may flow to migration-data; customer data may not flow back through these tools.
A PR number of up to nine digits reaches GitHub during fetch, far narrower than the already accepted web tools.
PR heads use Git refs, not the GitHub API, with the existing private credential helper, workspace lock,
40-second timeout and shared 60-second fetch throttle. A different PR during that window may return
`STANDARD_DEV_PR_UNAVAILABLE`; wait, then retry. One private PR ref is retained, replaced on the next
PR fetch. Fork/moved heads return `sha` without `branch`; pass that SHA as `branch` to diff/read.
Only commits reachable from downloaded origin branches or that PR ref may be read by SHA.

### Free SQL: DBHub

When a project's source database is up (`data_db_up`, and every `data_db_status`), the tools
register an MCP server for it in `~/.config/term-llm/mcp.json`, after first writing the rule that
only migration-data may use it into `~/.config/term-llm/config.yaml` (with term-llm's own
`config set`, which keeps the rest of the file):

```json
"db-arc": {"command": "/srv/silo-migrate/bin/silo-migrate-control", "args": ["dbhub", "arc"]}
```

```yaml
mcp:
  servers:
    db-arc:
      agents:
        - migration-data
```

To use it, in a **migration-data** chat for that project open the MCP button and turn on
`db-<project>`. term-llm then starts DBHub 1.5.1 (`bytebase/dbhub`, pinned by digest, pulled on
first use) for that chat only: a container on the project's internal network, no other
network, read-only root, signed in as `silo_ro` (password from `ro.env` through the
environment, never argv or the config file; like any container environment it shows in
`docker inspect`, which needs the account's Docker access anyway). Its tools: `search_objects`,
`execute_sql` (DBHub's statement filter plus `READ ONLY` transactions, at most 50 rows) and
`explain_sql`. The container ends with the chat (also when term-llm kills it). `data_db_reset`
stops it and removes the entry; an `mcp.json` entry named `db-<project>` that silo-migrate
didn't write is left alone.

term-llm 0.9.96+ enforces the rule (SamSaffron/term-llm#1341): another agent's chat, or a chat
with no agent, is refused the server, also after a restart. It trusts only agents loaded from
`~/.config/term-llm/agents`, which is why that folder links to the release and the release isn't
on `agents.search_paths` (a search-path folder of the same name takes migration-data's access away).
The rule stays when the server goes (`data_db_reset`, Remove project), so a project re-created
under the same name is limited from the start. `silo update` writes the rule for every project
database already registered (`silo-migrate-control mcp-rules`, counts only); `silo doctor`'s DBHub
check is OK when every one has it, term-llm enforces it and the agents are trusted, and
`data_db_status` puts a missing rule back. A rollback to term-llm 0.9.93 ignores the rule: then
turn `db-*` servers on only in migration-data chats.

**Skills** ship in the release (`integrations/term-llm/skills`) and reach the account through
the link `~/.config/term-llm/skills` → `<prefix>/current/integrations/term-llm/skills` that
`metal apply/update` creates if absent (doctor shows the fix otherwise). Each agent's
`skills:` decides what it sees: migration-data gets all of them, the others none (term-llm
0.9.93 couldn't give an agent a subset; not rechecked on 0.9.99).

## Converter review (agents)

converter-developer starts converter-reviewer itself (`spawn_agent`, only that agent, one at a
time, which can't start agents in turn) after committing, fixes what it finds, and tells you the
verdict and must-fix list word for word; at most two rounds per change. The review is pinned to
**Opus 5.5** (`claude-bin:claude-opus-5-5`), in the same project; the reviewer refuses to work
outside a project chat. Both the parent and reviewer allow only that Claude model, and the
parent's `spawn.agent_models` supplies that exact route when the model argument is omitted.
Explicit older IDs (including Opus 4.6/4.8), the moving `opus` alias, and other reviewer
providers are refused by the model policy rather than used as alternatives. If the approved
model is unavailable, the developer must report the failed review, not call it passed or
retry on another model. This is a reviewed version pin, not an automatic latest-model updater.
Both agents see only converter code and released findings. The developer remains on
`chatgpt:gpt-6.1-sol`; Claude is in its allowed models only so it can start the reviewer
(term-llm checks a sub-agent against its parent's model rule too). Frontier-only migration-data
is unchanged. Pushing stays yours.

### Discourse version for a review or merge

Normal review runs choose their own Discourse runtime automatically. With no Base site, use the current supported public latest build. With a Base site, prefer its version/track and use a compatible newer build on the same track when its known core migrations require it. Label/take replacement Base backups normally: every subsequent proposal resolves again, including same-version backups whose schema has changed. Pending earlier plans become stale; existing sites/evidence are not upgraded in place. Reset an old site explicitly before replacing it when needed for capacity.

First-time public-image preparation may take several minutes. The Project page waits automatically; migration-data polls a `runtime_preparing` proposal. Preparation has no customer build context and does not start an import or merge. The engineer still approves and starts the finished plan. The plan/run show version, track, immutable image identity and core revision; run evidence includes actual schema observations. No normal per-project image/configuration terminal work is needed. See [Base-site review](project-base-site-review.md#automatic-discourse-version-selection) for supported-image limits, cache behavior and exceptions. The receiving hosted site must be on the same or a compatible newer version than the output backup.

### Applying the reviewer model update

As root, run `silo update`, then `silo doctor`. Reload the UI and start a **new
converter-developer chat in the existing project**; existing sessions/running children are
not retargeted by this update. There is no need to create another migration branch or project.
Doctor's Claude sign-in check is not proof that Opus 5.5 is available to the account.

Saved per-agent preferences in `config.yaml` take precedence over shipped model defaults
and can **replace** shipped allowlists. If preferences were previously customized, inspect
`term-llm agents get converter-developer` and `term-llm agents get converter-reviewer` inside
`silo shell` (the service account), not root's own term-llm configuration. No preferences is
normal: the release's definitions apply. To deliberately align customized routing with this
release, run these commands **inside that service-account shell**:

```sh
term-llm agents set converter-developer provider=chatgpt model=gpt-6.1-sol 'allowed_models=chatgpt:*,claude-bin:claude-opus-5-5'
term-llm agents set converter-reviewer provider=claude-bin model=claude-opus-5-5 'allowed_models=claude-bin:claude-opus-5-5'
claude --version
```

These change only the two coding agents' routing preferences, not tools, approvals, credentials,
Frontier, or global provider models. They persist across future releases, so deliberately
update them again when approving a newer model. Exit the shell, run `silo restart` as root to
reload changed preferences, then start a new developer chat. Do not run `agents clear`, which
would discard unrelated preferences. If the installed Claude Code/account rejects the explicit
model, keep the failure and ask the engineer to check version/availability; a Claude Code
upgrade is a separate operator action, not something this release performs automatically.
Confirm the requested reviewer route and any available runtime model metadata during a
clean/invented-code review; assistant self-identification or a catalog label alone is not
proof of which model executed. Do not paste customer transcripts or configuration secrets.

For local admission regression tests (no actual model calls), use the pinned term-llm binary:

```sh
TERM_LLM_BINARY=/path/to/term-llm python3 -I -B test/agent_model_policy_test.py
```

This uses temporary configuration and loopback fake providers to exercise direct and spawned
admission, old-model/alias refusals, inherited rules, stale preferences, and model-unavailable
errors. It does not validate real Claude authentication, backend fallback behavior, or the
server's effective model.

On a merge project the same two agents write and review the **merge layer**
(`mergers/<project>/merger.rb`), the code that changes what Discourse's merger does for this
customer. Their `dev_merge_guide` tool gives the contract and, for the last three merge runs, the
status, the layer's commit, where a run stopped, the fixed site counts and how many totals the
layer reported. The layer's own totals go to you (the run on the Project page) and migration-data,
not to them. A layer runs next to customer data exactly as committed, so have it reviewed before
you approve the plan that names its commit.

## Bringing upstream main into the converter branch

Ask **converter-developer** in the project's chat to bring in upstream work. It now has
`dev_rebase_main`: fixed `origin/main`, local only, no terminal or push permission.

1. It checkpoints its own uncommitted work with `dev_commit` first. This preserves unfinished
   edits without stashing anything, and leaves other people's hidden changes alone. Dirty
   tracked/index changes must be resolved before the rebase; unrelated private/untracked files
   are left untouched, but an incoming path may not replace one.
2. The tool fetches main and replays committed code in a disposable checkout. On a replay
   conflict, the live branch, index and files are unchanged and there is no live rebase to abort.
   Stop and agree a conflict-resolution approach rather than guessing, retrying blindly, or
   publishing an apparently synchronized branch. This version has no conflict-continue tool.
3. On success it keeps a pre-rebase backup ref, reports the main/head IDs, and the agent reruns
   tests/lint and obtains converter-reviewer review before proposing a new push. Old approvals
   do not cover rewritten commits. The branch name and draft PR are kept.
4. If the branch was already on GitHub, the existing Runs push card says **Push rebased branch…**.
   It shows the exact old remote commit and the new head, and explicitly asks to replace this
   migration branch's history—not main. Approval uses `--force-with-lease` pinned to that old
   commit; a teammate moving the remote branch makes it fail. A normal **Push** approval cannot
   authorize a rewrite, and neither agent can approve/push it itself.

The CLI equivalent of that explicit engineer approval is
`converter push WORKSPACE --sha256 DIGEST --allow-rewrite` through `silo-migrate-control`;
without `--allow-rewrite`, a rewrite proposal is refused before reading GitHub credentials.
Do not turn that into an agent tool or use an unqualified `--force`.

The rebase is serialized with developer writes and refused during an active migration/Git
operation. It is bounded to 50 local commits, 10,000 paths, 64 MiB of committed file bytes and
16 MiB per file. Ordinary directory-based Git checkouts and byte-identical checkouts are required
(no automatic line-ending/filter conversion). Unchanged tracked symlinks are checked without
following their targets; link changes, gitlinks/submodules, local merge commits and file/directory
transitions are safely refused rather than flattened or cleaned.

Backup refs (`refs/silo-migrate/rebase-backups/...`) are deliberately retained, including after a
rolled-back install, so the pre-rebase commits remain reachable. There is no automatic pruning.
Normal failures roll back tracked changes; process/power loss and same-account filesystem races
are not a transaction guarantee. If interrupted, preserve the checkout, backup refs and any
`.converter-rebase-*` temporary files, and have the engineer inspect them privately before any
recovery or cleanup. Do not auto-reset/clean/stash or expose hidden files to coding agents.

## Releasing findings (web UI)

migration-data proposes findings (schemas, a run's cause); nothing reaches the coding agents
until you release it. In the web UI:

- The **Project** tab on the right edge (the `silo-findings` extension) shows which projects have
  something waiting; it links to the **Project** page (also under Widgets in the sidebar), where
  findings are in the **Findings** tab of that project.
- The Findings tab lists **To review**, **Released** and **Everything else**, newest first. Lists
  are read straight from the project's store, so they stay quick with thousands of findings.
- **To review:** the proposal (read-only) and an editor prefilled with it. Edit it (only invented
  examples), then **Release** (exactly that text, its SHA-256 computed from it) or **Reject**.
- **Released:** **Amend…** releases corrected text as a new version that replaces it (the coding
  agents then see only the new one; Details shows the versions); **Withdraw** takes it back.
- Each decision runs `standard finding release|reject|amend|withdraw` as the account and is
  recorded with your commit identity's name plus "(web UI)" and the time.

**Withdraw** stops future agent reads; it can't erase what an agent already read (earlier chats,
code it wrote). Anyone who can open this node's web UI (directly or through the Hub) can decide
findings, as they can already chat with every agent: keep that access to engineers.

Why it's safe: the Project page runs on a Unix socket that only term-llm's signed-in proxy reaches;
term-llm accepts its POSTs only from the web UI's own origin (or with the bearer token), and the
widget also requires its page's header. No agent has the web UI sign-in, and `read_url` refuses
local addresses anyway. Only you see proposed text in the browser, as you already do in Frontier
chats. The page and extensions come from the sealed release; nothing else is loaded. The Findings and
Runs code under `widgets/` is the page's library: same checks and commands as before, no pages of its own. term-llm (0.9.93 to 0.9.99) keeps widget sockets in the fixed folder `/tmp/term-llm-widgets` without
checking its owner, so the installer reserves it for the service account (now and at every boot,
`/etc/tmpfiles.d/silo-migrate-term-llm.conf`), the widget refuses to start unless the folder is the
account's and private, and doctor's "widget folder" check fails otherwise. Without the widget (doctor's "findings widget" check), use the CLI in
`docs/standard-workbench.md` as the service account (`silo shell`; `silo-migrate-control` refuses
root).

## Accepting a site (web UI)

When a pass's convert and import runs both matched every check on development data, its card in the
Project page's **Runs** tab asks "Is this site right?":

- **Accept site…** shows what is accepted: data, converter commit, settings, checks and Discourse
  version (IDs under Details). Choose the basis: **the customer approved it** (this becomes the
  *accepted process* that launch will repeat) or **I checked it myself** (recorded and shown; the
  pass then asks whether the customer has approved it). The acceptance names exactly the process
  shown: if anything changed meanwhile it's refused (`STANDARD_APPROVAL_MISMATCH`). Reset is offered
  straight after, because the review site holds customer data.
- **Needs changes…** keeps a short note. migration-data gets it as its next step (`data_guide`) and
  is told never to quote it to the coding agents (a finding with invented examples instead).
- The Overview shows the accepted process with **Withdraw acceptance…**, and a banner when the
  converter, data or Discourse version changed since. Withdrawing leaves nothing accepted (never an
  older acceptance); an older pass whose acceptance a later one replaced shows "Accepted earlier".
- The record is append-only, in `.silo-migrate/named/site-reviews.json`, and only the engineer's
  page writes it (no agent tool maps to it; chat calls are refused). Notes are in the audit log by
  hash only.

## Removing a project or starting over

At the foot of a project's Overview: **Start over…** (everything goes except the customer's received
files, which return to the drop folder; the web UI project stays, without chats) and **Remove
project…** (everything, including the drop folder; the web UI project is archived, because
term-llm can't delete one, and `silo intake NAME` brings it back empty). Both list what goes and
what stays, with sizes, and ask you to type the project's name; they refuse while a run, a data job
or one of the project's chats is busy. The same as a root command: `silo remove-project` (lists the
projects), `silo remove-project NAME [--keep-received]`. A stopped removal finishes when run again;
each removal adds a line (who, when, counts, no file names) to `removed-projects.jsonl` in the
install's state folder. The converter's GitHub branches and pull requests stay.

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

## Stock native updates and deferred conversation protection

This release pins the official, unmodified **term-llm 0.9.103** archive and verifies
its reviewed SHA-256 against the official checksums. No capability command, native
session marker, `lock_session` key or `SILO_PROTECTED_SESSIONS` grant is required.

For an existing node whose installer tracks the right branch, the approved idle-window
operator command remains:

```sh
sudo silo update
```

That fast-forwards the installer, updates Silo and its pinned official native binary,
refreshes managed service arguments when needed, restarts the web service and runs
doctor. Existing 0.9.93/0.9.99 version settings are accepted as older release pins;
no manual version edit is needed. Keep `TERM_LLM_PACKAGE` empty/unset for stock
operation. A previously explicit experimental package needs review before returning
to stock; it is not silently ignored. The existing control-runtime artifact package
is separate and remains verified, not replaced with a native binary or Ruby gem.

Use an idle maintenance window and preserve the previous release/native receipts
and a consistent private session-database/configuration backup. Updates interrupt
chats. Verify the running service and start a new migration-data chat; do not alter
old session rows, remove locks or fabricate context to retrofit a conversation.

Stronger durable conversation locking, trusted native tool identity, cross-resume/
retarget privacy guarantees and trusted chat-upload import are **deferred**, not
implemented by stock settings. Frontier-only agent model rules, project-bound custom
tools and DBHub's migration-data rules remain, but are not universal DLP or OS
isolation. Doctor warns about the deferred guarantee without blocking intake tools.
Run invented-data acceptance before any separately approved customer-data use.
Source publication does not authorize a server connection, update or restart.

## Checking a change

Before shipping any change, from the repository root:

```sh
for f in test/*_test.py; do python3 -I -B "$f" || echo "FAILED: $f"; done
python3 -I -B -m unittest discover -s test/metal -p 'test_*.py'
```

`test/varnish_bundle_test.py` is what proves the bundled theme is exactly what `update-varnish` recorded.

For Prepare checkpoint protocol changes, the opt-in invented-data test invokes the
production checkpoint/activation SQL on cached PostgreSQL. It requires explicit
operator approval for uniquely owned local Docker resources; it never uses a
customer instance, published ports or downloaded images. Web/Redis/control-store
seams are documented in the test, so this is not full Prepare/MCP acceptance:

```sh
SILO_CHECKPOINT_PROTOCOL_LIVE=1 python3 -I -B test/checkpoint_protocol_live_test.py
```

`test/benchmark_base_inventory.rb` is a separate, invented-data profiling tool,
not part of `test/**/*_test.rb` and not a CI timing threshold. Its header documents
how to compare the original scanner and current scanner on the same generated
archive; results depend on row shape, compression and storage cache conditions.

For the Project launcher and navigation, also run the invented-data browser checks (Node,
Playwright Core and Chromium must already be available; this does not install anything):

```sh
export PLAYWRIGHT_CORE=/path/to/playwright-core/index.mjs
export CHROMIUM=/path/to/chromium
export TERM_LLM_SOURCE=/path/to/term-llm-checkout  # contains local tag v0.9.99
node test/launcher_extension_test.mjs
node test/project_navigation_browser.mjs
node test/file_roles_browser.mjs
node test/file_decision_polling_browser.mjs
node test/converter_rebase_browser.mjs
```

The launcher test covers stock/Varnish headers, narrow screens, keyboard focus and Hub-relative
links. Navigation checks cover immediate snapshots, deduplicated reads, stale response isolation,
unsaved edits, decision invalidation and fresh site-acceptance state. Files checks cover explicit
roles, exact-preview confirmation and stale/blocked decisions; the deterministic polling regression
also holds reads and decisions in both orders to check their barrier and polling resumption.
These fixture checks are not proof of work-server latency: also check the real pinned host locally
with invented data. Short engineer reads (`standard status`, `standard plan show`, `standard run show`) have a one-CPU control
ceiling to avoid throttling CLI startup; mutation/executor control commands retain 0.25 CPU, and
migration containers' own profile limits and all other isolation settings are unchanged.

**The Varnish patch (runtime marks):** term-llm 0.9.99 wraps each Runtime popover select in
`.control-select`, and upstream Varnish (`002f10e`) then showed ~320 px provider logos that multiplied
while the popover was open. `update-varnish` applies the same patch as the Development node (two
exact replacements, `main.js` and `style.css`), refuses an upstream change it doesn't recognise, and
records it under `patches` in `varnish-upstream.json`, with the upstream hashes of the two files. It
was submitted upstream (keegangeorge/term-llm-varnish#20). When upstream has the fix, the update
stops; review it, keep the patch only if needed, and check the Runtime popover in a browser: one
14 px mark inside each of the Provider and Model fields.

**The Varnish patch (Hub node ID):** through the Hub, a node's web UI is at `/hub/node/<id>/`, but
upstream finds the node only at the start of the path (`/node/<id>/`), so the node's own accent,
favicon and per-node settings don't apply there. `update-varnish` applies the Development node's
one-expression change in `util.js` (the same checks and record, under `hub_node_id`). Check: served
under `--base-path /hub/node/<id>`, Varnish's `NODE_ID` is the node's id; served directly, none.
