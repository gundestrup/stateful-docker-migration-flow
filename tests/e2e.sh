#!/bin/bash
# End-to-end migration test against a REAL dockerd (docker-in-docker).
# Simulates a Synology-style 'db'-logger container by rewriting hostconfig.json
# while the daemon is stopped, then runs the actual tools unmocked and verifies
# that migration preserves data, configuration, and brings the container under
# Compose management.
set -euo pipefail

# The dind image entrypoint exports DOCKER_HOST=tcp://docker:2375 because no
# socket exists when it runs; this suite starts its own dockerd on the socket.
export DOCKER_HOST=unix:///var/run/docker.sock

repo_dir=$(cd "$(dirname "$0")/.." && pwd -P)
test_tmp=$(mktemp -d)
dockerd_pid=''

fail() {
  printf 'E2E FAIL: %s\n' "$1" >&2
  exit 1
}

start_dockerd() {
  dockerd >/tmp/dockerd.log 2>&1 &
  dockerd_pid=$!
  local tries=0
  until docker version >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ "$tries" -ge 600 ]]; then
      docker version 2>&1 | tail -5 >&2
      kill -0 "$dockerd_pid" 2>/dev/null && echo 'dockerd still running' >&2 || echo 'dockerd exited' >&2
      tail -60 /tmp/dockerd.log >&2
      fail 'dockerd did not start'
    fi
    sleep 0.2
  done
}

stop_dockerd() {
  [[ -n "$dockerd_pid" ]] || return 0
  kill "$dockerd_pid" 2>/dev/null || true
  wait "$dockerd_pid" 2>/dev/null || true
  dockerd_pid=''
}
trap 'stop_dockerd' EXIT

start_dockerd
docker info >/dev/null || fail 'dockerd not reachable'
printf 'dockerd started (version %s)\n' "$(docker version --format '{{.Server.Version}}')"

# Build a hermetic test image from the container's own busybox - no network pull.
# Alpine busybox is dynamically linked, so the musl loader must come along.
rootfs="$test_tmp/rootfs"
mkdir -p "$rootfs/bin" "$rootfs/lib"
cp /bin/busybox "$rootfs/bin/busybox"
cp /lib/ld-musl-*.so.1 "$rootfs/lib/"
for applet in sh sleep cat env; do
  ln -s busybox "$rootfs/bin/$applet"
done
tar -C "$rootfs" -cf - . | docker import - sdmf-e2e >/dev/null

# Fixture: unmanaged container with named volume + read-only bind + env + restart policy.
bind_dir="$test_tmp/bind-data"
mkdir -p "$bind_dir"
printf 'bind-canary-123\n' > "$bind_dir/canary.txt"
docker run -d --name e2e-app \
  -e E2E_SECRET=topsecret -e E2E_PLAIN=visible \
  -v e2e_data:/data \
  -v "$bind_dir:/bind:ro" \
  --restart unless-stopped \
  sdmf-e2e /bin/sh -c 'echo volume-canary-456 > /data/canary.txt; sleep 6000' >/dev/null

# A second, healthy unmanaged container used to prove --next generalizes beyond 'db'.
docker run -d --name e2e-plain sdmf-e2e /bin/sh -c 'sleep 6000' >/dev/null

# NordVPN->privoxy style dependency from the synoforum autocompose thread:
# e2e-priv shares e2e-vpn's network namespace and can only run while it does.
docker run -d --name e2e-vpn sdmf-e2e /bin/sh -c 'sleep 6000' >/dev/null
docker run -d --name e2e-priv --network container:e2e-vpn \
  sdmf-e2e /bin/sh -c 'sleep 6000' >/dev/null

# Portainer-style fixture: compose-managed labels but no project file on disk.
docker run -d --name e2e-portainer \
  --label com.docker.compose.project=portainer-stack \
  --label com.docker.compose.project.config_files=/nonexistent/portainer-stack.yml \
  sdmf-e2e /bin/sh -c 'sleep 6000' >/dev/null

# Simulate the Synology condition: rewrite the logger to 'db' while dockerd is
# stopped - the container can no longer start, exactly like post-upgrade DSM.
cid=$(docker inspect e2e-app --format '{{.Id}}')
docker stop e2e-app >/dev/null
stop_dockerd
hostconfig="/var/lib/docker/containers/${cid}/hostconfig.json"
[[ -f "$hostconfig" ]] || fail "hostconfig.json not found at $hostconfig"
jq '.LogConfig.Type = "db"' "$hostconfig" > "${hostconfig}.new"
mv "${hostconfig}.new" "$hostconfig"
start_dockerd
[[ "$(docker inspect e2e-app --format '{{.HostConfig.LogConfig.Type}}')" = 'db' ]] \
  || fail 'logger rewrite did not produce db'
if docker start e2e-app >/dev/null 2>&1; then
  fail 'container unexpectedly started with the removed db logger'
fi
printf 'db-logger condition simulated; container cannot start (as on DSM post-upgrade)\n'

# Platform detection: fake Synology DSM marker files, then TrueNAS.
mkdir -p /etc.defaults
printf 'majorversion="7"\nproductversion="7.2"\n' > /etc.defaults/VERSION
doctor_out=$("$repo_dir/sdmf" doctor)
[[ "$doctor_out" == *'Detected platform: synology'* ]] || fail 'synology platform not detected'
[[ "$doctor_out" == *'All prerequisites satisfied'* ]] || fail 'doctor failed under synology simulation'
rm -f /etc.defaults/VERSION
doctor_out=$(SDMF_PLATFORM=truenas "$repo_dir/sdmf" doctor)
[[ "$doctor_out" == *'Detected platform: truenas'* ]] || fail 'truenas platform override failed'
printf 'Platform detection verified (synology, truenas override, linux default)\n'

# Inventory: the tool must show the db logger and compose status on a REAL daemon.
listing=$("$repo_dir/sdmf" list)
[[ "$listing" == *'e2e-app'* ]] || fail 'inventory missing e2e-app'
printf '%s\n' "$listing" | grep -Fq 'db' || fail 'db logger absent from inventory'
[[ "$listing" == *'maybe_managed_by_portainer'* ]] || fail 'portainer container not flagged'
[[ "$listing" == *'e2e-priv'*'network namespace'*'e2e-vpn'* ]] \
  || fail 'network dependency hint missing from inventory'

# Export the next container (db prioritized on real state).
stacks="$test_tmp/stacks"
next_out=$("$repo_dir/sdmf" next "$stacks")
[[ "$next_out" != *'topsecret'* ]] || fail 'environment value leaked to stdout'
[[ -f "$stacks/e2e-app/e2e-app.docker-compose.yml" ]] || fail 'compose file not generated'
[[ -f "$stacks/e2e-app/e2e-app.env" ]] || fail 'env file not generated'
[[ "$(stat -c '%a' "$stacks/e2e-app/e2e-app.env")" = '600' ]] || fail 'env file not private'
grep -Fxq 'E2E_SECRET=topsecret' "$stacks/e2e-app/e2e-app.env" || fail 'env value missing from env file'
jq -e '.containers["e2e-app"].logger == "db" and .containers["e2e-app"].requires_recreate == true' \
  "$stacks/compose-export-manifest.json" >/dev/null || fail 'manifest did not record db container'
printf 'Export produced reviewed Compose + private env; no secret on stdout\n'

validate_out=$("$repo_dir/sdmf" validate "$stacks" e2e-app)
[[ "$validate_out" == *'Compose configuration is valid'* ]] || fail 'generated compose did not validate'

# Aborted confirmation must not touch the container.
if printf 'NOPE\n' | "$repo_dir/sdmf" recreate "$stacks" e2e-app >/dev/null 2>&1; then
  fail 'recreate proceeded without RECREATE confirmation'
fi
docker inspect e2e-app >/dev/null || fail 'container vanished after aborted recreate'

# Confirmed migration: stop + remove + compose recreate.
printf 'RECREATE\n' | "$repo_dir/sdmf" recreate "$stacks" e2e-app >/dev/null

[[ "$(docker inspect e2e-app --format '{{.HostConfig.LogConfig.Type}}')" = 'local' ]] \
  || fail 'recreated container is not on the local logger'
[[ "$(docker inspect e2e-app --format '{{index .Config.Labels "com.docker.compose.project"}}')" != '' ]] \
  || fail 'recreated container is not Compose-managed'
[[ "$(docker inspect e2e-app --format '{{.State.Running}}')" = 'true' ]] \
  || fail 'recreated container is not running'
[[ "$(docker inspect e2e-app --format '{{.HostConfig.RestartPolicy.Name}}')" = 'unless-stopped' ]] \
  || fail 'restart policy not preserved'

# The no-data-loss assertions: named volume and bind mount content intact.
[[ "$(docker exec e2e-app /bin/busybox cat /data/canary.txt)" = 'volume-canary-456' ]] \
  || fail 'named volume data lost during migration'
[[ "$(docker exec e2e-app /bin/busybox cat /bind/canary.txt)" = 'bind-canary-123' ]] \
  || fail 'bind mount data lost during migration'
docker inspect e2e-app --format '{{.Config.Env}}' | grep -Fq 'E2E_SECRET=topsecret' \
  || fail 'environment not preserved during migration'
printf 'MIGRATION VERIFIED: logger=local, Compose-managed, volumes intact, env preserved\n'

# Generalized --next: dependency targets are exported before their dependents,
# even though other unmanaged containers sort earlier alphabetically.
next_out=$("$repo_dir/sdmf" next "$stacks")
[[ "$next_out" == *"$stacks/e2e-vpn"* ]] || fail 'dependency target not exported first'
[[ -f "$stacks/e2e-vpn/e2e-vpn.docker-compose.yml" ]] || fail 'dependency target export missing'

next_out=$("$repo_dir/sdmf" next "$stacks")
[[ "$next_out" == *"$stacks/e2e-plain"* ]] || fail 'non-db container not selected after db migration'
[[ -f "$stacks/e2e-plain/e2e-plain.docker-compose.yml" ]] \
  || fail 'non-db container export not generated'

next_out=$("$repo_dir/sdmf" next "$stacks")
[[ "$next_out" == *"$stacks/e2e-priv"* ]] || fail 'dependent container not selected'
priv_mode=$(docker inspect e2e-priv --format '{{.HostConfig.NetworkMode}}')
[[ "$priv_mode" == container:* ]] || fail "unexpected e2e-priv network mode: $priv_mode"
grep -Fq "network_mode: \"$priv_mode\"" "$stacks/e2e-priv/e2e-priv.docker-compose.yml" \
  || fail 'shared network namespace not preserved in generated Compose'
jq -e '.containers["e2e-priv"].network_dependency == "e2e-vpn"' \
  "$stacks/compose-export-manifest.json" >/dev/null \
  || fail 'manifest did not record network_dependency'
[[ ! -e "$stacks/e2e-portainer" ]] || fail 'portainer container was exported'
printf 'Dependency ordering, shared-netns export, and portainer exclusion verified\n'

# Rerun safety: identical output is reported, not overwritten.
second_out=$("$repo_dir/sdmf" next "$stacks")
[[ "$second_out" == *'No containers still need Compose conversion'* ]] \
  || fail "rerun did not converge: $second_out"
printf 'All containers migrated; tool reports convergence\n'

printf 'E2E PASSED\n'
