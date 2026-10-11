# Development guide

How to work on `stateful-docker-migration-flow` and extend it to new
platforms, runtimes, and vendor export formats. For how the pieces fit
together see [README.architecture.md](README.architecture.md).

## Setup and verification

Plain Bash + `jq` — no build step, no dependencies to install into the
repo. Run everything before pushing (same as CI):

```bash
# Mocked regression suite (fast, no daemon)
docker build -t sdmf-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/workspace:ro" sdmf-tests

# End-to-end suite (real dockerd in dind; needs --privileged)
docker build -t sdmf-e2e-tests -f tests/Dockerfile.e2e .
docker run --rm --privileged -v "$PWD:/workspace:ro" sdmf-e2e-tests

# Lint / static analysis
bash -n lib/*.sh tests/*.sh sdmf
shellcheck -x lib/*.sh tests/*.sh sdmf
semgrep scan --config .semgrep.yml --oss-only --metrics off \
  --disable-version-check --error .
markdownlint-cli2
```

## Conventions

- `#!/bin/bash` + `set -euo pipefail` in every executable script.
  `lib/platform.sh` is the exception: it is *sourced* and stays
  POSIX-sh compatible (`# shellcheck shell=sh`), so no bashisms there.
- Errors go to stderr via `fail()` and exit non-zero — never silently
  pass a failed detection.
- Every script resolves `SCRIPT_DIR` from `realpath "$0"` and sources
  `platform.sh` relative to it, so `lib/` scripts run standalone.
- All container-runtime access goes through `$DOCKER_BIN`; all Compose
  calls go through `sdmf_compose`. Never call `docker` or
  `docker-compose` directly.
- Write output to temp files and `mv` into place; `chmod 600` anything
  that can hold environment-derived data.
- No new comments unless they explain *why* (see the daemon-defaults
  filter in `export_to_compose.sh` for the house style).

## Adapter seams

The tool has three intentional extension points. Adding support for a new
NAS platform, runtime, or export format should touch only that seam plus
tests — never the safety invariants.

### Platform adapter — `lib/platform.sh`

Three functions define a platform:

```sh
sdmf_detect_platform()      # marker files -> synology | truenas | linux
sdmf_default_volume_root()  # where short host paths remap (e.g. /volume1)
sdmf_default_output_root()  # default migration output dir
```

Current platform maturity: Synology is the target platform (its `db`
logger is the e2e fixture), but detection is *simulated* — the suite
fakes `/etc.defaults/VERSION`; nothing has run on real DSM. Generic
Linux is the only fully e2e-exercised path. TrueNAS is detection plus
path defaults only — code-complete, hardware-untested, and partially
redundant: SCALE 24.10+ natively converts catalog apps to custom apps
and accepts pasted Compose via *Install via YAML*. sdmf's real TrueNAS
niche is out-of-band containers (`docker run`, external managers) that
the Apps system cannot see — the generated YAML then feeds *Install via
YAML* or an external manager.

To add a platform (e.g. Unraid, OMV, a finalized TrueNAS path):

1. Add detection to `sdmf_detect_platform` using stable on-disk markers
   (Synology: `/etc.defaults/VERSION`, `/etc/synoinfo.conf`; TrueNAS:
   `/etc/truenas_version`, `/etc/truenas`). Keep `SDMF_PLATFORM` as the
   manual override and keep `linux` as the fallback.
2. Add `case` arms for the platform in `sdmf_default_volume_root` and
   `sdmf_default_output_root`. `--volume-root` and `MIGRATION_ROOT`
   remain explicit overrides.
3. Update the platform table in `README.md`.
4. Tests: the mocked suite already covers `SDMF_PLATFORM=<name>` via the
   override; the e2e suite fakes detection by writing marker files
   (`/etc.defaults/VERSION`) — add the equivalent for the new platform.

### Runtime adapter — `DOCKER_BIN`

`platform.sh` sets `: "${DOCKER_BIN:=docker}"`. Every script calls
`"$DOCKER_BIN" inspect|ps|stop|rm`, so an alternate runtime needs no code
changes where its CLI is flag-compatible — the mocked suite already
smoke-tests `DOCKER_BIN=podman`.

Compose access goes through `sdmf_compose`, which tries providers in
order:

1. `$DOCKER_BIN compose` (plugin — covers `podman compose` too)
2. `docker-compose` (legacy binary)
3. `podman-compose`

`doctor` reports which provider was found and fails if none exists.

To finish Podman support:

- Verify `podman inspect` field parity for everything the converter
  reads: `.Mounts[].Type`, `.HostConfig.LogConfig`, `.HostConfig.NetworkMode`,
  restart policy, port bindings, env. Podman's inspect is largely
  Docker-compatible, but check `NetworkMode` naming and Compose label
  keys on your target version.
- Extend the e2e image (`tests/Dockerfile.e2e`) or add a parallel podman
  job so the unmocked flow runs against the real runtime — Podman's
  `hostconfig.json` layout differs, so the db-logger simulation needs a
  podman equivalent or a skip.
- Update the `DOCKER_BIN` rows in `README.md` and the `sdmf` usage text.

### Input-format adapter — the canonical record

`export_to_compose.sh` never emits from raw input directly. A leading jq
pass normalizes any supported export into one canonical record; the
emitter consumes only that shape. Today two inputs exist:

- `docker inspect` JSON → rewritten by the `docker_inspect_to_export` jq
  function (detected via `has("Config") and has("HostConfig")`)
- Synology Container Manager export → already in record shape, passed
  through unchanged

To add a vendor format (TrueNAS UI export, Portainer API response, OMV,
CasaOS, ...):

1. Write a `<format>_to_export` jq function producing the record fields
   below.
2. Extend the discriminator after the normalization def:

   ```jq
   | if has("Config") and has("HostConfig") then docker_inspect_to_export
     elif <your predicate> then <format>_to_export
     else . end
   ```

3. Add a fixture to `tests/run.sh` exercising the new path, including
   malformed/missing-name/missing-image rejection.

Required fields: `name`, `image`. Everything else is optional.

| Group | Record fields |
| --- | --- |
| Identity | `name`, `image`, `container_id` |
| Command | `cmd`/`cmd_v2`, `entrypoint`, `env_variables[]` (`key`/`value`) |
| TTY/user | `tty`, `stdin_open`, `user`, `working_dir`, `hostname`, `domainname` |
| Restart | `enable_restart_policy`, `restart_policy`, `restart_maximum_retry_count` |
| Network | `network_mode` (`bridge`/`host`/`none`/`service:X`/`container:X`/name), `use_host_network`, `network[].name`, `port_bindings[]` (`container_port`, `host_port`, `host_ip`, `type`), `dns`, `dns_search`, `extra_hosts`, `links` |
| Storage | `volume_bindings[]` (`host_volume_file`, `mount_point`, `type` `ro`/`rw`, `named_volume`, `anonymous_volume`, `absolute_host_path`), `tmpfs[]`, `storage_opt` |
| Security | `CapAdd`, `CapDrop`, `security_opt`, `privileged`, `devices[]`, `group_add`, `ulimits[]`, `sysctls`, `read_only`, `oom_kill_disable` |
| Namespaces | `runtime`, `uts`, `ipc`, `pid`, `cgroupns`, `userns` |
| Health | `healthcheck` (`Test`, `Interval`, `Timeout`, `StartPeriod`, `Retries`), `stop_signal`, `stop_timeout` |
| Meta | `labels`, `memory_limit`, `shm_size`, `cpu_priority`, `inspect_source` |

Notes on semantics the emitter relies on:

- `volume_bindings[].named_volume` + `anonymous_volume` drive the
  `external: true` table and `--fresh-anonymous-volumes` — get these
  right or volumes silently become empty. Anonymous = named volume whose
  name is 64 hex chars.
- `absolute_host_path` controls whether `--volume-root` remapping
  applies. Relative host paths are rejected outright.
- `inspect_source: true` marks inspect-origin records: `memory_limit`
  becomes `mem_limit`, while Synology-only `cpu_priority` is emitted as
  a review comment instead.

## Changing the inspect surface

If you read a new `inspect --format` field in `list_containers.sh` or a
new JSON path in the converter:

- Add the field to `docker_inspect_to_export` and the emitter.
- In `tests/run.sh`, add a mock branch for the new `--format` string
  **before** the `MOCK_LIST_MODE` branches — matches are literal and
  ordered.
- If the field affects the `docker run` hint, update
  `container_recreate.sh` and its rendering assertions.
- If it affects data safety or the recreate flow, extend
  `tests/e2e.sh` too — the mocked suite cannot prove real-daemon
  behavior.

## Contribution safety rules

Do not weaken these — they are the product (full rationale in
[AGENTS.md](AGENTS.md)):

- `external: true` on named volumes and networks; anonymous volumes
  preserved unless `--fresh-anonymous-volumes`.
- Env values only in mode-`600` files — never stdout, logs, manifest.
- No overwrite of differing output without `--force`; identical output
  reports `Already converted`.
- `recreate` needs typed `RECREATE`, re-validates, `docker rm` without
  `-v`, and an aborted confirmation touches nothing.
- `maybe_managed_by_portainer` containers are never converted.
- `container:X` dependencies export before dependents.
- Daemon-generated defaults (container-id hostname, `runc`, `private`
  ipc/cgroup) are never frozen into output.

## House tooling

`AGENTS.md` is the authoritative contributor contract. Config details
live with the tools: `.semgrep.yml` (copied from
`engineering-memory/frameworks/shell/`; `tests/` is out of default scope
because `run.sh` deliberately `eval`s a generated hint — inline
`nosemgrep` if scanned explicitly), `.markdownlint-cli2.jsonc` (120-char
prose lines, tables/code exempt), `.sonarcloud.properties`, and
`.github/dependabot.yml` (7-day cooldown, full-SHA pins in workflows).
