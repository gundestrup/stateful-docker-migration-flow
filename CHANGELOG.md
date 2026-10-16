# Changelog

## Unreleased

### Changed

- Updated the privileged end-to-end test image from Docker 28 to Docker 29.
- CI: Semgrep moved from an inline `pip3 install semgrep==1.176.0` pin
  to hashed `.github/requirements-ci.txt` (compiled from
  `requirements-ci.in`, Python 3.12), installed with `--require-hashes`.
  Bumped Semgrep to 1.180.0; the version is now Dependabot-visible via
  a new `pip` ecosystem entry for `/.github`.
- Added informational Bash line-coverage reporting: the mocked regression
  suite runs under kcov in CI and uploads a cobertura report to Codecov
  (never blocks CI). The e2e suite is deliberately uninstrumented.

## 0.0.1-alpha — 2026-10-11

Initial standalone release, extracted from the
[synology-docker](https://github.com/telnetdoogie-labs/synology-docker/pull/107)
recovery tooling at the upstream reviewer's suggestion.

- Added a Synology Container Manager JSON / `docker inspect` converter that
  generates a reviewed Compose file and private environment file,
  simplifying migration of non-Compose containers — including containers
  stuck on loggers removed by the platform, such as Synology's `db` driver.
  The container listing can convert one named container or all non-Compose
  containers with `--compose-dir`; `--container-dirs` writes per-container
  directories, `--next` selects one remaining unconverted container per run
  (removed-logger containers first), and a private JSON manifest records
  conversion state without environment values. Repeat runs report unchanged
  output as already converted and write differing candidates as `.generated`
  files instead of overwriting reviewed files. Generated Compose preserves
  anonymous volumes by default, with `--fresh-anonymous-volumes` available
  to recreate them instead, and maps Docker namespace modes to valid
  Compose `cgroup`, `uts`, and `userns_mode` fields.
- Added `sdmf` as a single guided menu/non-interactive entry point for
  prerequisite checks, inventory, export, validation, explicitly confirmed
  recreation, and manifest review; implementation scripts live in `lib/`
  and remain runnable standalone.
- Redacted container environment values from recreate suggestions, required
  an operator-supplied env file, preserved explicit port bind IPs,
  read-only/named mounts, TTY settings, restart policy, network mode, and
  entrypoint; recreated containers use the `local` logger, and the listing
  includes stopped containers.
- Made the `recreate` action stop a running container before removing it.
  The confirmed operation previously failed on `docker rm` when the target
  container was still running.
- Added a platform/runtime abstraction (`lib/platform.sh`): `SDMF_PLATFORM`
  selects synology/truenas/linux defaults and `DOCKER_BIN` selects the
  container runtime CLI, preparing TrueNAS and Podman (Cockpit) support.
- Added Docker-based mocked regression tests covering conversion, secret
  redaction, manifest state, multi-container and Compose-managed `--next`
  selection, stop-before-remove recreation, aborted confirmations, platform
  volume roots, and malformed input handling.
- Added an end-to-end suite (`tests/e2e.sh`, `docker:dind`) that runs a real
  `dockerd`, simulates the removed-`db`-logger condition by rewriting
  `hostconfig.json`, and verifies an unmocked migration preserves
  named-volume and bind-mount data, environment, and restart policy while
  switching the container to `local` under Compose management.
- Stopped the converter from freezing daemon-generated defaults into Compose
  output: the auto-assigned container-id hostname, the default `runc`
  runtime, and default `private` ipc/cgroup namespace modes are now skipped.
- Flagged containers that share another container's network namespace
  (`network_mode: container:X`): the inventory prints a migrate-first
  `NOTE`, the manifest records `network_dependency`, and `--next` exports
  dependency targets before their dependents — the NordVPN/privoxy
  ordering trap reported by autocompose users.
- Extended the end-to-end suite with shared-network-namespace and
  Portainer-labeled fixtures.
- Added GitHub Actions CI for the Docker regression suite, Bash syntax
  checks, ShellCheck, Semgrep (CE, repo-local rules), and markdownlint.
- Added architecture and development documentation
  (`README.architecture.md`, `README.devel.md`) covering the pipeline,
  safety invariants, test harness, and adapter seams for new platforms,
  runtimes, and export formats; documented platform test-coverage limits
  (TrueNAS/Podman untested on real hardware).
