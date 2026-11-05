#!/usr/bin/env bash
# Launch only a fresh bounded container; no host installs or named demo objects.
set -euo pipefail
cd "$(dirname "$0")/../../.."
cpus=0.5 memory=1408m disk=64G scenario=small artifacts=
while (($#)); do
  case "$1" in
    --cpus) cpus=$2; shift 2 ;;
    --memory) memory=$2; shift 2 ;;
    --disk) disk=$2; shift 2 ;;
    --artifacts) artifacts=$(realpath "$2"); shift 2 ;;
    small|full) scenario=$1; shift ;;
    *) echo 'Usage: run.sh [small|full] [--cpus N] [--memory SIZE] [--disk SIZE] [--artifacts DIR]' >&2; exit 2 ;;
  esac
done
if [[ $scenario == full && -z $artifacts ]]; then
  echo 'full requires --artifacts DIR' >&2; exit 2
fi
cache=../../.runtime-cache/metal-installer-tests
mkdir -p "$cache"
run=$(mktemp -d "$cache/run-XXXXXXXX")
run=$(realpath "$run")
chmod 700 "$run"
# Worktree branch is deliberately not pushed; bare fixture refs never modify it.
git clone --bare --no-local . "$run/repo.git" >"$run/clone.log" 2>&1
git --git-dir="$run/repo.git" config core.sharedRepository all
chmod -R a+rX "$run/repo.git"
mkdir "$run/installer"
cp script/metal script/package-artifacts script/image_identity.py "$run/installer/"
cp config/metal.example.conf "$run/installer/"
# Build has no runtime demo mounts, socket or host package installation.
tag=silo-metal-vm-harness:local
docker build -t "$tag" test/metal/vm >"$run/build.log" 2>&1
name="metal-installer-test-${run##*/}"
args=(run --rm --name "$name" --device /dev/kvm --cpus "$cpus" --memory "$memory"
  --mount "type=bind,src=$run,dst=/evidence" -e "DISK_SIZE=$disk" -e "SCENARIO=$scenario")
if [[ -n $artifacts ]]; then
  args+=(--mount "type=bind,src=$artifacts,dst=/artifacts,readonly")
fi
guest_cpus=$(python3 -I -c 'import math,sys; print(max(1, math.ceil(float(sys.argv[1]))))' "$cpus")
guest_memory=$(python3 -I -c 'import re,sys; m=re.fullmatch(r"([0-9]+)([mMgG]?)",sys.argv[1]); assert m, "use memory in m or g"; n=int(m[1]) * (1024 if m[2].lower()=="g" else 1); assert n>=1408; print(n-384)' "$memory")
args+=(-e "GUEST_CPUS=$guest_cpus" -e "GUEST_MEMORY=$guest_memory")
printf 'Evidence: %s\nContainer: %s; CPUs=%s memory=%s; guest=%s vCPU/%sMiB\n' "$run" "$name" "$cpus" "$memory" "$guest_cpus" "$guest_memory"
# No published Docker ports. QEMU's SSH listener is container-loopback-only.
docker "${args[@]}" "$tag" 2>&1 | tee "$run/harness.log"
