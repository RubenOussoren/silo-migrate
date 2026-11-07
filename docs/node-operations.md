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
| `silo doctor` | Checks the release and installer checkout, update source, web service, agents, ChatGPT/Frontier/Claude sign-ins, GitHub token, commit identity, Docker, disk and the read-only release; prints the exact fix for anything wrong. Nothing secret is printed. |
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

Sorting, converting and registering the files is the Frontier-only data agent's job (next
release), guided by skills; no other agent reads customer files.

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
