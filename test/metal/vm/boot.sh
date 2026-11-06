#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /evidence
# Dated official release, never latest/daily. Check image against its official SHA512SUMS.
release=https://cloud.debian.org/images/cloud/bookworm/20261026-2643
image=debian-12-genericcloud-amd64-20261026-2643.qcow2
# One verified copy is shared by all runs (base-cache); never one per run.
base=/base-cache
if [[ ! -f $base/$image || ! -f $base/SHA512SUMS ]]; then
  curl -fsSL "$release/SHA512SUMS" -o "$base/SHA512SUMS.partial"
  curl -fsSL "$release/$image" -o "$base/$image.partial"
  mv "$base/SHA512SUMS.partial" "$base/SHA512SUMS"
  mv "$base/$image.partial" "$base/$image"
fi
[[ -n ${HOST_OWNER:-} ]] && chown "$HOST_OWNER" "$base/$image" "$base/SHA512SUMS"
cp "$base/SHA512SUMS" SHA512SUMS
# Verified on every run; a mismatched cached image is refused, not replaced.
python3 -I - "$base/$image" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
entries = [line.split()[0] for line in pathlib.Path('SHA512SUMS').read_text().splitlines()
           if len(line.split()) == 2 and line.split()[1].lstrip('*') == path.name]
h = hashlib.sha512()
with open(path, 'rb') as stream:
    for block in iter(lambda: stream.read(1048576), b''):
        h.update(block)
assert entries == [h.hexdigest()], 'Debian cloud SHA512 mismatch'
print('DEBIAN_CLOUD_SHA512_OK', h.hexdigest())
PY
# Copy-on-write overlay: only guest writes land here, capped by DISK_SIZE.
# QEMU opens the shared backing image read-only.
qemu-img create -f qcow2 -F qcow2 -b "$base/$image" guest.qcow2 "$DISK_SIZE"
ssh-keygen -q -t ed25519 -N '' -f ssh-key
key=$(cat ssh-key.pub)
cat > user-data <<EOF
#cloud-config
users:
  - name: metaladmin
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $key
ssh_pwauth: false
packages: []
EOF
printf 'instance-id: metal-installer-test\nlocal-hostname: metal-test\n' > meta-data
cloud-localds seed.img user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp "$GUEST_CPUS" -m "$GUEST_MEMORY" -nographic \
  -drive file=guest.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.img,if=virtio,format=raw,readonly=on \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  >serial.log 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; rm -f ssh-key; [[ -n ${HOST_OWNER:-} ]] && chown -R "$HOST_OWNER" /evidence || true' EXIT
sshargs=(-i ssh-key -p 2222 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/evidence/known_hosts -o ConnectTimeout=5)
ready=0
for _ in $(seq 1 180); do
  if ssh "${sshargs[@]}" metaladmin@127.0.0.1 true 2>/dev/null; then ready=1; break; fi
  kill -0 "$qemu_pid" || { echo QEMU_FAILED; exit 1; }
  sleep 5
done
[[ $ready == 1 ]] || { echo SSH_TIMEOUT; exit 1; }
ssh "${sshargs[@]}" metaladmin@127.0.0.1 'sudo cloud-init status --wait' >cloud-init.log 2>&1
scp_args=(-i ssh-key -P 2222 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/evidence/known_hosts)
scp "${scp_args[@]}" -r installer repo.git /harness/guest.sh metaladmin@127.0.0.1:/home/metaladmin/ >/dev/null
if [[ -d converter.git ]]; then
  scp "${scp_args[@]}" -r converter.git metaladmin@127.0.0.1:/home/metaladmin/ >/dev/null
fi
if [[ $SCENARIO == full ]]; then
  scp "${scp_args[@]}" -r /artifacts metaladmin@127.0.0.1:/home/metaladmin/artifacts >/dev/null
fi
# SCENARIO is a validated local enum (small/full), deliberately expanded here.
# shellcheck disable=SC2029
ssh "${sshargs[@]}" metaladmin@127.0.0.1 "bash /home/metaladmin/guest.sh $SCENARIO" 2>&1 | tee scenarios.log
ssh "${sshargs[@]}" metaladmin@127.0.0.1 'sudo tar -C /srv/silo-migrate/state -czf - .' > guest-state.tar.gz
printf 'VM_SCENARIOS_OK %s\n' "$SCENARIO"
