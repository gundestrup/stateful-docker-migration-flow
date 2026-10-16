# stateful-docker-migration-flow

[![CI](https://github.com/gundestrup/stateful-docker-migration-flow/actions/workflows/ci.yml/badge.svg)](https://github.com/gundestrup/stateful-docker-migration-flow/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![codecov](https://codecov.io/gh/gundestrup/stateful-docker-migration-flow/branch/main/graph/badge.svg)](https://codecov.io/gh/gundestrup/stateful-docker-migration-flow)
[![Changelog](https://img.shields.io/badge/CHANGELOG-Updated-brightgreen.svg)](./CHANGELOG.md)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gundestrup/stateful-docker-migration-flow)
[![CodeFactor](https://www.codefactor.io/repository/github/gundestrup/stateful-docker-migration-flow/badge)](https://www.codefactor.io/repository/github/gundestrup/stateful-docker-migration-flow)
[![Semgrep CE](https://img.shields.io/badge/Semgrep_CE-security-success)](./.semgrep.yml)

Safely migrate existing Docker containers — created by a vendor UI, `docker
run`, or other tooling — into reviewed, per-container **Docker Compose**
projects, without data loss.

Generated output is a standard `docker-compose.yml` + `.env` per container,
laid out as one directory per stack. That layout drops straight into
Compose-aware managers such as **Dockge**, **dockhand**, **Arcane**,
**Komodo**, and plain `docker compose` on the CLI.

> Generated files are **candidates for review**, not blind automation. The
> tool never overwrites a file you have edited without producing a
> `*.generated` diff first, never prints environment values to the terminal
> or manifest, and requires a typed `RECREATE` confirmation before it stops
> and removes an existing container record.

## Warning — read before use

> [!WARNING]
> This tool stops and removes live containers and changes how they are
> managed. That is inherently risky: a misconfiguration, a platform quirk,
> or a bug can leave a container down — or in the worst case, its data
> inaccessible. The safety invariants are engineered and e2e-tested, but
> no test suite covers your specific NAS.

Before you migrate anything:

- **Make backups.** Snapshot or copy named volumes and bind-mounted config
  directories first (DSM snapshots, `docker volume` backup, or your normal
  backup tool). Generated Compose files are designed to *reuse* volumes,
  never recreate them — but a backup is the only real safety net if
  something goes wrong anyway.
- **Review before you recreate.** Read the generated Compose file, run
  `sdmf validate`, and only then type `RECREATE`. A stopped container is
  downtime even when everything works.
- **Start with a throwaway container.** `sdmf next` migrates exactly one
  container per run — prove the flow on something non-critical first.
- **On Synology DSM:** recreated containers become plain Docker/Compose
  objects. Container Manager may display them differently and its original
  project entry can remain — cosmetic, but know it before you start.

**Disclaimer:** this tool is provided in good faith, but the authors make
no representation or warranty of any kind, express or implied, regarding
its accuracy, adequacy, validity, reliability, or fitness for any purpose.
Under no circumstance shall the authors or contributors have any liability
to you for any loss or damage — including data loss, container downtime,
or broken services — incurred as a result of using this tool or relying on
its output. Your use of the tool, and your reliance on anything it
generates, is solely at your own risk.

The governing text, verbatim from [LICENSE](LICENSE) (AGPL-3.0, §15–16):

> THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY
> APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT
> HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY
> OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO,
> THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
> PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM
> IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF
> ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
>
> IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL
> ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS THE
> PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY
> GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
> USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED TO LOSS OF
> DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD
> PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS),
> EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
> SUCH DAMAGES.

If that is not acceptable, do not run the tool.

## Why this exists

Tools like [docker-autocompose](https://github.com/Red5d/docker-autocompose),
[composerize](https://github.com/composerize/composerize), and
[composeverter](https://github.com/outilslibre/composeverter) solve adjacent
problems, but leave a gap for a *safe migration workflow*:

- **autocompose** inspects running containers like this tool does, but dumps
  everything into a single file, runs as a Python/Docker image, and has no
  review/candidate/manifest workflow, no per-stack layout, and no safe
  re-run semantics.
- **composerize** converts a *`docker run` command line* into Compose YAML.
  It cannot see a container that was created by a NAS UI or another tool —
  there is no command line to parse.
- **composeverter** converts between Compose file *versions*, not live
  containers into Compose.

What we learned from them, applied here:

- Inspect-based generation (autocompose's approach) is the only way to
  capture how a container was *actually* created — required for vendor-UI
  containers.
- Generated Compose must be treated as a best-effort draft;
  composerize/autocompose users hit the same imperfect-conversion edge
  cases. Hence: candidate files, diffs, `compose config` validation, and
  typed confirmation instead of silent cut-over.
- Portainer-managed containers need care (the
  [synology-docker review](https://github.com/telnetdoogie-labs/synology-docker/pull/107)
  that inspired this project raised it): a container labeled as
  Compose-managed whose project file is missing on the host is flagged
  `maybe_managed_by_portainer` and is never converted — Portainer stacks
  store their Compose file inside Portainer's own data directory.
- The [SynoForum autocompose thread](https://www.synoforum.com/threads/docker-autocompose.4644/)
  captures the real-world failure modes: `docker ps`-only export loops miss
  stopped containers (our inventory includes them), Compose project-name
  prefixing silently renames volumes and networks (hence `external: true`
  on generated output), and NordVPN→privoxy-style startup ordering — a
  container sharing another's network namespace
  (`network_mode: container:X`) can only run while its dependency does.
  Those get a `NOTE:` in the inventory, a `network_dependency` entry in the
  manifest, and `--next` exports the dependency target first.

## Requirements

- `bash`, `jq`, `docker` (or another runtime via `DOCKER_BIN`), and a
  Compose provider (`docker compose`, `docker-compose`, or `podman-compose`)
- No Python, no containers-in-containers: the tool is plain Bash + `jq` so
  it runs directly on a NAS.

## Quick start

```bash
./sdmf            # interactive menu (recommended)
./sdmf doctor     # check platform, runtime, jq, compose provider
./sdmf list       # inventory: container, compose location, logger
./sdmf next       # export ONE remaining unconverted container
./sdmf validate /path/to/root my-container
./sdmf recreate /path/to/root my-container   # typed RECREATE required
./sdmf manifest   # show conversion state per container
```

The menu prints the recommended order at every step:

```text
doctor -> inventory -> export -> validate -> recreate -> manifest
```

## The workflow

1. **Inventory** — `lib/list_containers.sh` shows every container (running
   *and* stopped), its Compose project file (if any), and its log driver.
   Containers not managed by Compose get a best-effort `docker run` hint
   for reference.
2. **Export** — `next` converts one container per run (removed-logger
   containers such as Synology's `db` are selected first), or `export-all`
   converts every non-Compose container. Each produces
   `ROOT/<name>/<name>.docker-compose.yml` and a private
   `ROOT/<name>/<name>.env` (mode `600`).
3. **Validate** — runs `compose config` against the generated file.
4. **Recreate** — after you type `RECREATE`, the old container is stopped,
   removed, and recreated by Compose. Bind-mounted folders and named
   volumes are untouched.
5. **Track** — a private `compose-export-manifest.json` (mode `600`)
   records each container's logger and conversion state (`pending`,
   `written`, `candidate-generated`, `already-converted`,
   `compose-managed`, `pending-compose-recreate`, `conversion-failed`).
   Re-runs are safe: unchanged output is reported as `Already converted`;
   edited output produces `*.generated` candidates and a diff instead of
   an overwrite.

## Safety properties

- Named volumes are emitted as `external: true` — they are **reused**,
  never recreated.
- Anonymous volumes are preserved by default; `--fresh-anonymous-volumes`
  opts into replacing them.
- Containers sharing another's network namespace
  (`network_mode: container:X`) keep that mode in the generated file; the
  inventory warns that the dependency must be migrated and started first,
  and `--next` exports dependency targets before their dependents.
- Environment values go only into a `600` `.env` file — never to stdout,
  logs, or the manifest.
- Command-line-rendering suggestions (`lib/container_recreate.sh`) shell-escape
  every argument so container metadata can never become executable syntax.
- Detection failures abort instead of silently passing.

## Platforms

| Platform | Status | Volume root default |
| --- | --- | --- |
| Synology DSM | supported (incl. Container Manager JSON exports) | `/volume1` |
| TrueNAS SCALE | detection + path defaults only — untested; native "Convert to custom app" already covers catalog apps | `/mnt` |
| Generic Linux | works for `docker inspect` input | `/` |
| Podman (e.g. Cockpit) | planned; runtime CLI overridable via `DOCKER_BIN` | — |

Environment overrides: `SDMF_PLATFORM=synology|truenas|linux`,
`DOCKER_BIN=docker`, `MIGRATION_ROOT=<dir>`.

> [!NOTE]
> **Test coverage.** The e2e suite exercises the full flow against a real
> `dockerd` (the generic-Linux path) and *simulates* Synology detection
> via marker files. TrueNAS and Podman are covered only by detection,
> path-default, and mocked-CLI tests — the tool has not been run on real
> DSM or TrueNAS SCALE systems. Field-test on a throwaway container
> before trusting it on a new platform.

On TrueNAS specifically, note that SCALE 24.10+ already ships **Convert
to custom app** (catalog app → editable YAML app) and **Install via
YAML** (paste a Compose file). sdmf's niche there is narrower:
containers created *outside* the Apps system — raw `docker run` or
external tooling — which TrueNAS has no built-in converter for.
Generated Compose can be imported via *Install via YAML*.

## Input formats

`lib/export_to_compose.sh` auto-detects two inputs:

- `docker inspect <container>` JSON (any Docker host)
- Synology Container Manager container-export JSON (pass `--volume-root
  /volumeN` when data is not under `/volume1`)

## Files

- `sdmf` — menu + non-interactive entry point (all actions above)
- `lib/list_containers.sh` — inventory table, export orchestration, manifest
- `lib/export_to_compose.sh` — inspect/Synology-JSON → Compose + env
  converter
- `lib/container_recreate.sh` — best-effort `docker run` hint generator
  (secrets redacted)
- `lib/platform.sh` — platform detection and runtime/Compose abstraction
- `tests/` — Docker-based mocked regression suite (same style as
  synology-docker)
- `README.architecture.md` — internals: pipeline, manifest, safety
  invariants, test harness
- `README.devel.md` — contributor guide: platform, runtime, and
  input-format adapter seams

## Tests

Mocked regression suite (fast, no daemon needed):

```bash
docker build -t sdmf-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/workspace:ro" sdmf-tests
```

End-to-end suite — a real `dockerd` inside a privileged container creates a
fixture container, rewrites its `hostconfig.json` to the removed `db` logger
(the exact broken state after a Synology Docker upgrade), then runs the tools
**unmocked** and asserts data survives (`tests/e2e.sh`):

```bash
docker build -t sdmf-e2e-tests -f tests/Dockerfile.e2e .
docker run --rm --privileged -v "$PWD:/workspace:ro" sdmf-e2e-tests
```

Verified in e2e: the `db` container cannot start → export → `RECREATE` →
`local` logger, Compose-managed, running, named volume + bind mount + env +
restart policy intact, `--next` converges when nothing remains.

## License

AGPL-3.0 — see [LICENSE](LICENSE). `lib/list_containers.sh` and
`lib/container_recreate.sh` are derived from the MIT-licensed
[synology-docker](https://github.com/telnetdoogie/synology-docker) project;
see [NOTICE](NOTICE).
