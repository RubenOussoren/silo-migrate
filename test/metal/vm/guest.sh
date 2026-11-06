#!/usr/bin/env bash
set -euo pipefail
scenario=${1:-small}
sudo install -d -m 0755 /opt/metal-installer
sudo cp /home/metaladmin/installer/* /opt/metal-installer/
sudo chmod 0755 /opt/metal-installer/metal
sudo cp -a /home/metaladmin/repo.git /opt/metal-repo.git
sudo chmod -R a+rX /opt/metal-repo.git
cat > /tmp/metal.conf <<'EOF'
SILO_REPO=/opt/metal-repo.git
TERM_LLM_SERVICE=install-and-start
DOCKER_INSTALL=if-missing
EOF
if [[ $scenario == full ]]; then
  sudo mv /home/metaladmin/artifacts /opt/metal-artifacts
  # As an engineer would stage it: root-owned, not writable by others (B4/M1).
  sudo chown -R root:root /opt/metal-artifacts
  sudo chmod -R a+rX,go-w /opt/metal-artifacts
  printf 'ARTIFACT_PACKAGE=/opt/metal-artifacts\n' >> /tmp/metal.conf
  sudo cp -a /home/metaladmin/converter.git /opt/converter-repo.git
  printf 'CONVERTER_REPO=/opt/converter-repo.git\n' >> /tmp/metal.conf
  # The test VM is held to the Development host's 8 GiB envelope.
  printf 'VERIFY_MIN_AVAILABLE_MIB=6144\n' >> /tmp/metal.conf
fi
sudo install -m 0644 /tmp/metal.conf /opt/metal.conf
M=/opt/metal-installer/metal
step() { printf '\nSCENARIO %s\n' "$1"; }
step preflight
"$M" preflight --config /opt/metal.conf --json
if SILO_METAL_TESTING=1 SILO_METAL_TEST_ARCH=arm64 "$M" preflight --config /opt/metal.conf --json >/tmp/arch.json; then
  echo 'ERROR: unsupported architecture accepted'; exit 1
fi
grep -q METAL_ARCH_UNSUPPORTED /tmp/arch.json
step plan
if [[ $scenario == full ]]; then
  # A package owned by an ordinary login user must be refused, naming the path.
  sudo chown metaladmin /opt/metal-artifacts
  if "$M" plan --config /opt/metal.conf --plan /tmp/refused-plan.json 2>/tmp/authority.err; then
    echo 'ERROR: login-user-owned artifact package accepted'; exit 1
  fi
  grep -q 'METAL_PATH_AUTHORITY: /opt/metal-artifacts' /tmp/authority.err
  [[ ! -e /tmp/refused-plan.json ]]
  sudo chown root /opt/metal-artifacts
  echo 'AUTHORITY_REFUSAL_OK'
fi
"$M" plan --config /opt/metal.conf --plan /tmp/plan.json
step apply
if ! "$M" apply --config /opt/metal.conf --plan /tmp/plan.json; then
  # Only this public, synthetic, credential-free LOCAL fixture is diagnosed.
  # Never dump service/config output or a network Git diagnostic.
  echo 'DIAGNOSTIC: public local bare-fixture clone (no credentials/network)'
  sudo -u silomig -H env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/opt/metal-repo.git \
    git -c core.hooksPath=/dev/null clone --no-local --no-hardlinks --no-checkout \
    --upload-pack='git -c safe.directory=/opt/metal-repo.git upload-pack' \
    -- /opt/metal-repo.git /srv/silo-migrate/state/tmp/metal-git-diagnostic || true
  exit 1
fi
sudo -u silomig -H /srv/silo-migrate/bin/term-llm --version
sudo test -f /var/lib/systemd/linger/silomig
sudo -u silomig -H env XDG_RUNTIME_DIR="/run/user/$(id -u silomig)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u silomig)/bus" \
  systemctl --user is-active term-llm-web.service
sudo -u silomig -H env XDG_RUNTIME_DIR="/run/user/$(id -u silomig)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u silomig)/bus" \
  systemctl --user show term-llm-web.service --property=Environment --value | \
  python3 -I -c 'import shlex,sys; e=dict(x.split("=",1) for x in shlex.split(sys.stdin.read())); assert e.get("SILO_CONTROL")=="/srv/silo-migrate/bin/silo-migrate-control"; assert e.get("SILO_CONTROL_CONFIG")=="/srv/silo-migrate/etc/silo-control.env"; assert e.get("TMPDIR")=="/srv/silo-migrate/state/tmp"; print("METAL_SERVICE_CONTROL_ENV_OK")'
step existing-config-and-idempotency
sudo -u silomig -H sh -c 'printf "\n# existing-user-config-preserve-sentinel\n" >> "$HOME/.config/term-llm/config.yaml"'
before=$(sudo sha256sum /home/silomig/.config/term-llm/config.yaml)
# Force one real account reconfiguration with pre-existing user config first.
printf 'KEEP_RELEASES=4\n' | sudo tee -a /opt/metal.conf >/dev/null
"$M" plan --config /opt/metal.conf --plan /tmp/plan-preserve.json
"$M" apply --config /opt/metal.conf --plan /tmp/plan-preserve.json
[[ $before == "$(sudo sha256sum /home/silomig/.config/term-llm/config.yaml)" ]]
# Planning may use the private scratch directory transiently (e.g. Docker CLI
# image inspection with TMPDIR), so only state/tmp's own mtime is excluded; it
# must be left empty, and every other path's size and mtime must be unchanged.
snapshot() { sudo find /srv/silo-migrate -printf '%P %s %T@\n' | grep -v '^state/tmp [0-9]* ' | sort; }
snapshot > /tmp/before
"$M" plan --config /opt/metal.conf --plan /tmp/plan-again.json
"$M" apply --config /opt/metal.conf --plan /tmp/plan-again.json
snapshot > /tmp/after
if [[ -n $(sudo find /srv/silo-migrate/state/tmp -mindepth 1 -print -quit) ]]; then
  echo 'ERROR: unchanged apply left scratch entries in state/tmp'; exit 1
fi
if ! cmp -s /tmp/before /tmp/after; then
  # Disposable synthetic VM: path, size and mtime only, never file contents.
  echo 'IDEMPOTENCY_DIFF (metadata only):'
  diff /tmp/before /tmp/after | head -20
  exit 1
fi
[[ $before == "$(sudo sha256sum /home/silomig/.config/term-llm/config.yaml)" ]]
step status
"$M" status --config /opt/metal.conf
step update-and-rollback
first=$(sudo -u silomig readlink /srv/silo-migrate/current)
# Fixture commits are confined to this disposable VM's bare repository.
base=$(sudo git --git-dir=/opt/metal-repo.git rev-parse refs/heads/mvp/metal-installer)
tree=$(sudo git --git-dir=/opt/metal-repo.git rev-parse "$base^{tree}")
second=$(printf 'VM fixture second release\n' | sudo env GIT_AUTHOR_NAME=MetalTest GIT_AUTHOR_EMAIL=metal@example.invalid \
  GIT_COMMITTER_NAME=MetalTest GIT_COMMITTER_EMAIL=metal@example.invalid \
  git --git-dir=/opt/metal-repo.git commit-tree "$tree" -p "$base")
sudo git --git-dir=/opt/metal-repo.git update-ref refs/heads/metal-test-second "$second"
sudo chmod -R a+rX /opt/metal-repo.git
"$M" update --config /opt/metal.conf --branch metal-test-second
[[ $(sudo -u silomig readlink /srv/silo-migrate/current) != "$first" ]]
"$M" rollback --config /opt/metal.conf
[[ $(sudo -u silomig readlink /srv/silo-migrate/current) == "$first" ]]
if [[ $scenario == full ]]; then
  step synthetic-full-verify
  # Owned by the service account so its host git accepts the local repository.
  sudo chown -R silomig:silomig /opt/converter-repo.git
  "$M" verify --config /opt/metal.conf
else
  echo 'SKIPPED: artifact loading and full synthetic verify (1 vCPU/1GiB guest); NOT migration-ready acceptance'
fi
printf 'GUEST_SCENARIOS_OK %s\n' "$scenario"
