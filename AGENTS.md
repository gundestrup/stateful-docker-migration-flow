# AGENTS.md — stateful-docker-migration-flow

Migrate existing Docker containers — created by a vendor UI (Synology
Container Manager), `docker run`, or other tooling — into reviewed,
per-container Docker Compose projects, without data loss. Extracted from
[gundestrup/synology-docker](https://github.com/gundestrup/synology-docker).

Global knowledge: <https://github.com/gundestrup/engineering-memory>
Relevant notes: `frameworks/shell/`, `tools/shellcheck.md`,
`tools/semgrep.md`, `tools/markdownlint.md`, `tools/sonarqube.md`,
`tools/deepwiki.md`, `languages/shell.md`.

## Stack

Plain **Bash + jq**. No Python, no containers-in-containers — it must run
directly on a NAS.

| File | Role |
| --- | --- |
| `sdmf` | Menu + non-interactive entry point (`doctor`, `list`, `next`, `export-all`, `validate`, `recreate`, `compose-recreate`, `manifest`) — the only root-level executable |
| `lib/list_containers.sh` | Inventory table, export orchestration, manifest (`compose-export-manifest.json`) |
| `lib/export_to_compose.sh` | `docker inspect` / Synology-JSON → Compose + env converter |
| `lib/container_recreate.sh` | Best-effort `docker run` hint (secrets redacted, args shell-escaped) |
| `lib/platform.sh` | Platform detection (`SDMF_PLATFORM`) + runtime/Compose abstraction (`DOCKER_BIN`) |

Implementation scripts live in `lib/` — they are `sdmf` machinery, not the
interface. They remain runnable standalone (`lib/export_to_compose.sh
inspect.json outdir`); each resolves `SCRIPT_DIR` to its own directory and
sources `platform.sh` as a sibling.

## Commands

```bash
# Mocked regression suite (fast, no daemon)
docker build -t sdmf-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/workspace:ro" sdmf-tests

# End-to-end suite (real dockerd in dind; needs --privileged)
docker build -t sdmf-e2e-tests -f tests/Dockerfile.e2e .
docker run --rm --privileged -v "$PWD:/workspace:ro" sdmf-e2e-tests

# Regression suite with Bash line coverage (cobertura XML → coverage/)
mkdir -p coverage
docker run --rm --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -v "$PWD:/workspace:ro" -v "$PWD/coverage:/coverage" sdmf-tests \
  kcov --include-path=/workspace --exclude-path=/workspace/tests \
    /coverage /workspace/tests/run.sh

# Lint / static analysis (same as CI)
bash -n lib/*.sh tests/*.sh sdmf
shellcheck -x lib/*.sh tests/*.sh sdmf
semgrep scan --config .semgrep.yml --oss-only --metrics off \
  --disable-version-check --error .
markdownlint-cli2
```

## Conventions

- `#!/bin/bash` + `set -euo pipefail`. `DOCKER_BIN` selects the runtime
  CLI (`docker`/`podman`), `SDMF_PLATFORM` selects
  `synology`/`truenas`/`linux` defaults.
- GitHub Actions: `permissions: contents: read`, full-SHA action pins,
  dependabot with `cooldown.default-days: 7`.
- Manifest (`compose-export-manifest.json`) is mode `600`, records
  per-container `logger`, `requires_recreate`, `network_dependency`, and
  `conversion` state — never environment values.

## Safety invariants — do not weaken

- Named volumes and networks are emitted `external: true` — reused,
  never recreated. Without this, Compose silently mounts a fresh
  project-prefixed volume (apparent data loss).
- Anonymous volumes are preserved by default; `--fresh-anonymous-volumes`
  is opt-in.
- Environment values go only into a mode-`600` `.env` — never stdout,
  logs, or the manifest (e2e asserts this).
- Existing output is never overwritten: identical → `Already converted`;
  differing → `*.generated` candidates + diff (unless `--force`).
- `recreate` requires a typed `RECREATE`, re-validates with
  `compose config`, then `docker stop` → `docker rm` (never `-v`) →
  `compose up -d --force-recreate`. Aborted confirmation touches nothing.
- Containers flagged `maybe_managed_by_portainer` (compose labels but no
  project file on disk) are never converted.
- `network_mode: container:X` dependencies get a `NOTE:` in the listing,
  a `network_dependency` manifest entry, and `--next` exports the
  dependency target before its dependents.
- Daemon-generated defaults must not freeze into output: container-id
  hostname, `runc` runtime, `private` ipc/cgroup modes are skipped.

## Gotchas

- `tests/run.sh` mocks the `docker` CLI function — inspect `--format`
  strings are matched literally; new inspect calls need new mock
  branches *before* the `MOCK_LIST_MODE` branches.
- The e2e suite simulates Synology's removed `db` logger by rewriting
  `hostconfig.json` while `dockerd` is stopped — keep that intact; it is
  the exact failure this tool exists for.
- `tests/run.sh` deliberately `eval`s a generated `docker run` hint to
  prove env values cannot inject commands — semgrep's default scope
  skips `tests/`; if scanned explicitly it is suppressed inline.
- kcov (regression suite only) must take the *script* as its in-file —
  `kcov out bash tests/run.sh` traces the interpreter binary and records
  nothing. It needs `SYS_PTRACE` + `seccomp=unconfined`, and the e2e
  suite is deliberately uninstrumented (dockerd under ptrace in dind).
