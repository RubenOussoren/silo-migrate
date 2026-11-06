#!/usr/bin/env bash
# Launch only a fresh bounded container; no host installs or named demo objects.
#
# Disk safety (the host is a shared VM; filling it breaks unrelated services):
#   * the guest disk's virtual size is a hard upper bound on its qcow2 growth;
#   * the run is refused unless host free space >= guest disk + reserve;
#   * a watchdog kills the harness if host free space falls below the reserve;
#   * on every exit the guest disk, seed and copied repositories are deleted
#     (--keep-disk to retain them for debugging) and files are returned to the
#     invoking user, so cleanup never needs root;
#   * the verified Debian cloud image is downloaded once into base-cache/.
set -euo pipefail
cd "$(dirname "$0")/../../.."
cpus=0.5 memory=1408m disk= scenario=small artifacts= keep_disk=0
reserve_gib=${METAL_TEST_RESERVE_GIB:-12}
while (($#)); do
  case "$1" in
    --cpus) cpus=$2; shift 2 ;;
    --memory) memory=$2; shift 2 ;;
    --disk) disk=$2; shift 2 ;;
    --artifacts) artifacts=$(realpath "$2"); shift 2 ;;
    --keep-disk) keep_disk=1; shift ;;
    small|full) scenario=$1; shift ;;
    *) echo 'Usage: run.sh [small|full] [--cpus N] [--memory SIZE] [--disk NG] [--artifacts DIR] [--keep-disk]' >&2; exit 2 ;;
  esac
done
if [[ $scenario == full && -z $artifacts ]]; then
  echo 'full requires --artifacts DIR' >&2; exit 2
fi
# Sized to the workload: small = OS + installer; full = OS + loaded images +
# artifact copy + one synthetic run. The virtual size caps actual growth.
[[ -n $disk ]] || disk=$([[ $scenario == full ]] && echo 24G || echo 8G)
[[ $disk =~ ^([0-9]+)G$ ]] || { echo '--disk must be whole GiB, e.g. 24G' >&2; exit 2; }
disk_gib=${BASH_REMATCH[1]}
cache=../../.runtime-cache/metal-installer-tests
mkdir -p "$cache" "$cache/base-cache"
cache=$(realpath "$cache")
free_gib() { df -P --block-size=1G "$cache" | awk 'NR==2 {print $4}'; }
tag=silo-metal-vm-harness:local
# Remove large leftovers from earlier runs (e.g. SIGKILLed, so their trap never ran).
# Only our own run-* directories, and only when no harness container is alive.
scrub() {
  local dir=$1; shift
  if docker image inspect "$tag" >/dev/null 2>&1; then
    docker run --rm --network none --cpus 0.5 --memory 128m --entrypoint sh \
      --mount "type=bind,src=$dir,dst=/e" "$tag" -c \
      'cd /e && rm -rf -- "$@" && chown -R '"$(id -u):$(id -g)"' /e' sh "$@" >/dev/null 2>&1 || true
  fi
  (cd "$dir" && rm -rf -- "$@") 2>/dev/null || true
}
if [[ -z $(docker ps -q --filter name=metal-installer-test-run-) ]]; then
  for old in "$cache"/run-*; do
    [[ -d $old && ! -L $old ]] || continue
    if compgen -G "$old/guest.qcow2" >/dev/null || compgen -G "$old/seed.img" >/dev/null || [[ -d $old/repo.git ]]; then
      scrub "$old" guest.qcow2 seed.img repo.git converter.git installer
      echo "Swept leftovers from ${old##*/}"
    fi
  done
fi
need=$((disk_gib + reserve_gib))
[[ $scenario == full ]] && need=$((need + $(du -s --block-size=1G "$artifacts" | cut -f1)))
have=$(free_gib)
if ((have < need)); then
  echo "Refusing: ${have} GiB free on $(df -P "$cache" | awk 'NR==2 {print $6}'), need ${need} GiB (guest disk ${disk_gib} + reserve ${reserve_gib}$([[ $scenario == full ]] && echo ' + artifact copy'))." >&2
  exit 3
fi
run=$(mktemp -d "$cache/run-XXXXXXXX")
chmod 700 "$run"
name="metal-installer-test-${run##*/}"
watchdog=
cleanup() {
  local status=$?
  [[ -n $watchdog ]] && kill "$watchdog" 2>/dev/null || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  local remove=(repo.git converter.git installer seed.img)
  ((keep_disk)) || remove+=(guest.qcow2)
  # Files written by the root harness: remove large ones, return the rest.
  scrub "$run" "${remove[@]}"
  printf 'Cleanup: removed %s; evidence %s (%s)\n' "${remove[*]}" "$run" "$(du -sh "$run" 2>/dev/null | cut -f1)"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Worktree branch is deliberately not pushed; bare fixture refs never modify it.
git clone --bare --no-local . "$run/repo.git" >"$run/clone.log" 2>&1
if [[ $scenario == full ]]; then
  # The synthetic smoke selects the converter fixture branch; the VM has no
  # credentials for the private upstream, so it receives a bare copy of that branch only.
  git clone --bare --no-local --single-branch --branch mvp/metal-installer \
    "$(cd ../.. && pwd -P)/sources/discourse-converters" "$run/converter.git" >>"$run/clone.log" 2>&1
fi
git --git-dir="$run/repo.git" config core.sharedRepository all
chmod -R a+rX "$run/repo.git"
mkdir "$run/installer"
cp script/metal script/package-artifacts script/image_identity.py "$run/installer/"
cp config/metal.example.conf "$run/installer/"
# Build has no runtime demo mounts, socket or host package installation.
docker build -t "$tag" test/metal/vm >"$run/build.log" 2>&1
args=(run --rm --name "$name" --device /dev/kvm --cpus "$cpus" --memory "$memory"
  --mount "type=bind,src=$run,dst=/evidence"
  --mount "type=bind,src=$cache/base-cache,dst=/base-cache"
  -e "DISK_SIZE=$disk" -e "SCENARIO=$scenario" -e "HOST_OWNER=$(id -u):$(id -g)")
if [[ -n $artifacts ]]; then
  args+=(--mount "type=bind,src=$artifacts,dst=/artifacts,readonly")
fi
guest_cpus=$(python3 -I -c 'import math,sys; print(max(1, math.ceil(float(sys.argv[1]))))' "$cpus")
guest_memory=$(python3 -I -c 'import re,sys; m=re.fullmatch(r"([0-9]+)([mMgG]?)",sys.argv[1]); assert m, "use memory in m or g"; n=int(m[1]) * (1024 if m[2].lower()=="g" else 1); assert n>=1408; print(n-384)' "$memory")
args+=(-e "GUEST_CPUS=$guest_cpus" -e "GUEST_MEMORY=$guest_memory")
printf 'Evidence: %s\nContainer: %s; CPUs=%s memory=%s; guest=%s vCPU/%sMiB; disk cap %s; host free %s GiB, reserve %s GiB\n' \
  "$run" "$name" "$cpus" "$memory" "$guest_cpus" "$guest_memory" "$disk" "$have" "$reserve_gib"
(
  while sleep 10; do
    if (( $(free_gib) < reserve_gib )); then
      echo "DISK_WATCHDOG_STOP: host free space below ${reserve_gib} GiB" | tee -a "$run/watchdog.log" >&2
      docker kill "$name" >/dev/null 2>&1 || true
      exit 0
    fi
  done
) &
watchdog=$!
# No published Docker ports. QEMU's SSH listener is container-loopback-only.
docker "${args[@]}" "$tag" 2>&1 | tee "$run/harness.log"
