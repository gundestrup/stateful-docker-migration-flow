# Architecture

How `stateful-docker-migration-flow` (sdmf) is built and why. For
user-facing usage see [README.md](README.md); for extending the tool see
[README.devel.md](README.devel.md).

## Design intent

Migrate existing containers — created by a vendor UI (Synology Container
Manager), `docker run`, or other tooling — into reviewed, per-container
Docker Compose projects, **without data loss**.

Two constraints shape everything:

- **Runs on the NAS itself** — plain Bash + `jq`, no Python, no
  containers-in-containers. Every script is `#!/bin/bash` +
  `set -euo pipefail` (except `lib/platform.sh`, which stays POSIX-sh so
  it can be sourced anywhere).
- **Review-first, not blind automation** — generated files are
  candidates. Nothing existing is silently overwritten, secrets never
  reach stdout, and destroying a container record requires a typed
  `RECREATE`.

## Component map

```text
sdmf                      menu + non-interactive entry point
 │                        (doctor, list, next, export-all, validate,
 │                         recreate, compose-recreate, manifest)
 ├─ lib/platform.sh        sourced by everything: SDMF_PLATFORM detection,
 │                         DOCKER_BIN runtime selection, sdmf_compose
 │                         provider chain, per-platform path defaults
 ├─ lib/list_containers.sh inventory table + export orchestration +
 │    │                    manifest bookkeeping
 │    ├─ docker ps/inspect        live container enumeration
 │    ├─ lib/container_recreate.sh  best-effort `docker run` hint
 │    └─ lib/export_to_compose.sh   inspect/Synology-JSON → Compose+env
 └─ docker/podman CLI      all runtime access goes through $DOCKER_BIN
```

`sdmf` is the only user interface. Everything in `lib/` is machinery, but
each script also runs standalone (e.g.
`lib/export_to_compose.sh inspect.json outdir`) — each resolves
`SCRIPT_DIR` to its own directory and sources `platform.sh` as a sibling.

## Pipeline

```text
inventory ──► export ──► validate ──► recreate ──► manifest
 (list)      (next/      (compose     (RECREATE →   (JSON state
             export-all)  config)     stop→rm→up)    tracking)
```

1. **Inventory** — `docker ps -aq` (stopped containers included), then one
   `inspect --format` per container for name, Compose project file label,
   log driver, and network mode. Compose-labelled containers whose
   project file is missing on disk are flagged `maybe_managed_by_portainer`
   and never converted. `network_mode: container:X` is resolved to the
   dependency's name for warnings and ordering.
2. **Export** — `docker inspect` output is written to a temp file inside
   the output dir and handed to `export_to_compose.sh`, which emits
   `<name>.docker-compose.yml` + private `<name>.env`. The conversion
   result comes back through a `--status-file` and is recorded in the
   manifest.
3. **Validate** — `compose -f <file> config` against the generated file
   (or its `.generated` candidate if the user hasn't reconciled yet).
4. **Recreate** — re-validates, prints the current logger, requires typed
   `RECREATE`, then `docker stop` → `docker rm` (never `-v`) →
   `compose up -d --force-recreate`.
5. **Manifest** — `compose-export-manifest.json` (mode `600`) records
   state so re-runs converge instead of redoing work.

`--next` selects one container per run in priority order: (1) containers
on a removed logger such as Synology's `db` — they cannot start at all;
(2) network-namespace dependency targets; (3) any remaining unmanaged
container. If the top priority is a Compose-managed container needing
recreation, it is reported as `pending-compose-recreate` with the exact
command to run.

## Canonical intermediate record

`export_to_compose.sh` accepts two input formats but converts through
**one** code path. A leading jq pass detects `docker inspect` JSON by
`has("Config") and has("HostConfig")` and rewrites it into the Synology
Container Manager export shape (`docker_inspect_to_export`). All
Compose-generation logic below that point consumes the normalized record
— restart policy, networks, ports, volumes, env, devices, healthcheck,
namespaces, sysctls, ulimits, labels.

This record is the format adapter seam: adding a new vendor export format
means writing one jq normalizer, not touching the emitter. See
[README.devel.md](README.devel.md#input-format-adapter).

Daemon-generated values that must **not** freeze into Compose are
filtered at emit time: a hostname equal to the container-id prefix, the
`runc`/`io.containerd.runc.*` runtime, and `private` ipc/cgroup modes are
skipped.

## Reconciliation states

Every export ends with a status word (via `--status-file` or stdout
message) that is recorded in the manifest:

| State | Meaning |
| --- | --- |
| `pending` | unmanaged, not yet exported |
| `written` | Compose/env files written this run |
| `updated` | previously written, still current |
| `already-converted` | regenerated output identical — nothing changed |
| `candidate-generated` | existing file differs; `*.generated` written + diff shown |
| `compose-managed` | already has a Compose project file on disk |
| `pending-compose-recreate` | Compose-managed but needs `up -d --force-recreate` |
| `conversion-failed` | converter errored; export aborted non-zero |

## Manifest

`ROOT/compose-export-manifest.json`, mode `600`, schema `version: 1` with
`updated_at` and a `containers` map. Per container:

| Field | Source |
| --- | --- |
| `image` | `.Config.Image` |
| `compose_location` | `com.docker.compose.project.config_files` label |
| `logger` | `.HostConfig.LogConfig.Type` |
| `requires_recreate` | `true` when logger is `db` |
| `network_dependency` | resolved name from `network_mode: container:X` |
| `conversion` | one of the states above |
| `compose_file` / `env_file` | output paths |
| `generated_compose_file` / `generated_env_file` | pending `*.generated` candidates |
| `inspected_at` | UTC timestamp |

The manifest never contains environment **values** — only file paths and
state.

## Generated output layout

```text
ROOT/
├── compose-export-manifest.json          (mode 600)
└── <container>/
    ├── <container>.docker-compose.yml    (mode 600)
    └── <container>.env                   (mode 600)
```

One directory per stack — drops straight into Dockge, dockhand, Arcane,
Komodo, or plain `docker compose`.

## Safety invariants — the no-data-loss design

Each invariant has at least one test asserting it:

- Named volumes and networks are emitted `external: true` — reused, never
  recreated. Without this, Compose's project-name prefixing silently
  mounts a *fresh* volume (apparent data loss). Proven end-to-end:
  `volume-canary-456` and `bind-canary-123` survive a real recreate.
- Anonymous volumes (64-hex names) are preserved by default;
  `--fresh-anonymous-volumes` replaces them only on explicit request.
- Environment values go only into a mode-`600` `.env` — never stdout,
  logs, or the manifest.
- Existing output is never overwritten: identical → `Already converted`;
  differing → `*.generated` candidates + unified diff. `--force` is the
  only override, and it diffs first.
- `recreate` requires a typed `RECREATE`, re-validates with
  `compose config`, and runs `docker rm` **without `-v`** so anonymous
  volumes survive container removal. An aborted confirmation touches
  nothing — asserted in both suites.
- `maybe_managed_by_portainer` containers are never converted; their
  Compose file lives inside Portainer's own data directory.
- The `docker run` hint generator shell-escapes every argument (`%q`) and
  replaces env values with an `--env-file` placeholder — container
  metadata can never become executable syntax.

## Test architecture

### Mocked regression suite — `tests/run.sh` in `tests/Dockerfile`

Debian + bash + jq, no daemon. The suite defines a `docker()` shell
function (and a `podman()` passthrough) exported with `export -f`, which
shadows the real CLI in every child script. Fixtures are injected via
environment variables:

| Variable | Role |
| --- | --- |
| `DOCKER_FIXTURE` | canned `docker inspect` JSON |
| `MOCK_DOCKER_IDS` | what `docker ps -aq` returns |
| `MOCK_LIST_MODE` | selects canned `--format` listing responses |
| `MOCK_DOCKER_LOG` | file recording `stop`/`rm`/`compose` calls |

Gotcha: `inspect --format` strings are matched **literally** and in order
— new inspect calls need new mock branches *before* the
`MOCK_LIST_MODE` branches.

Coverage: recreate-hint rendering (escaping, ports, mounts, tty, env
redaction — including `eval`ing the generated hint to prove a
`$(touch ...)` env value cannot inject), listing/secret redaction,
`DOCKER_BIN=podman`, both converter input paths, `--volume-root` and
platform path defaults, malformed-input rejection, daemon-default
filtering, reconciliation transitions, manifest assertions via `jq -e`,
`--next` ordering (db-logger first, dependency target before dependent),
stop-before-rm ordering, aborted-confirmation, `validate`,
`compose-recreate`, and a final `bash -n` over every script.

### End-to-end suite — `tests/e2e.sh` in `tests/Dockerfile.e2e`

`docker:28-dind` with `--privileged`; starts a real `dockerd` on the
socket, builds a hermetic test image by `docker import`ing the
container's own busybox + musl loader (zero network pulls), then creates
real fixtures:

- `e2e-app` — named volume + read-only bind canaries, secret + plain env,
  restart policy
- `e2e-plain` — healthy unmanaged container
- `e2e-vpn` / `e2e-priv` — `network_mode: container:e2e-vpn` dependency
- `e2e-portainer` — Compose labels pointing at a nonexistent file

Then it simulates the Synology failure this tool exists for: stop the
container, stop dockerd, rewrite `hostconfig.json` to `"LogConfig.Type":
"db"`, restart dockerd — the container can no longer start, exactly like
post-upgrade DSM. Platform detection is exercised by writing a fake
`/etc.defaults/VERSION` (synology) and via `SDMF_PLATFORM=truenas`.

Coverage limit: this is a real Docker daemon on the generic-Linux path
with *simulated* platform detection. TrueNAS and Podman get only
detection/path-default/mocked-CLI coverage — nothing has run on actual
DSM or TrueNAS SCALE hardware.

The unmocked flow is asserted: `doctor` → `list` (db logger visible,
portainer flagged, netns note) → `next` (secret never on stdout, `.env`
mode 600, manifest records `logger=db` + `requires_recreate`) →
`validate` → aborted `NOPE` leaves the container untouched → `RECREATE`
yields logger=`local`, Compose labels present, running, restart policy
preserved, both canaries intact, env preserved. `--next` then exports the
dependency target before dependents, skips portainer entirely, and
converges with "No containers still need Compose conversion".

### CI — `.github/workflows/ci.yml`

| Job | What it runs |
| --- | --- |
| `regression-tests` | build + run `tests/Dockerfile` |
| `e2e-tests` | build + run `tests/Dockerfile.e2e` (`--privileged`) |
| `shell-analysis` | `bash -n` + `shellcheck -x` over all scripts |
| `semgrep` | `.semgrep.yml` repo-local rules, `--error` |
| `markdownlint` | markdownlint-cli2 over docs globs |

Workflow hardening: `permissions: contents: read`, full-SHA action pins,
concurrency cancel-in-progress, dependabot with a 7-day cooldown.

## Toolchain and knowledge base

Project conventions are synced from
[engineering-memory](https://github.com/gundestrup/engineering-memory)
via `kb-sync.rb` (sync state in `.engineering-memory.yml`). Notes in use:
`frameworks/shell/` (`.semgrep.yml` is copied from it verbatim),
`tools/shellcheck.md`, `tools/semgrep.md`, `tools/markdownlint.md`,
`tools/sonarqube.md` (`.sonarcloud.properties` + SonarLint connected
mode), `tools/deepwiki.md` (DeepWiki MCP + README badge), and
`languages/shell.md`.
