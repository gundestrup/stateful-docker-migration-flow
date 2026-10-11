# Platform and container-runtime abstraction for stateful-docker-migration-flow.
# Source this file; it must remain POSIX-sh compatible.
# shellcheck shell=sh

# Container runtime CLI. Override with DOCKER_BIN=podman for Podman hosts
# (for example Cockpit-managed machines) once Podman support lands.
: "${DOCKER_BIN:=docker}"

# Optional platform override: synology | truenas | linux
: "${SDMF_PLATFORM:=}"

sdmf_detect_platform() {
  if [ -n "$SDMF_PLATFORM" ]; then
    printf '%s\n' "$SDMF_PLATFORM"
    return
  fi
  if [ -f /etc.defaults/VERSION ] || [ -f /etc/synoinfo.conf ]; then
    printf 'synology\n'
  elif [ -f /etc/truenas_version ] || [ -f /etc/truenas-version ] || [ -d /etc/truenas ]; then
    printf 'truenas\n'
  else
    printf 'linux\n'
  fi
}

# Root used to remap relative/short host paths found in NAS export formats.
sdmf_default_volume_root() {
  case "$(sdmf_detect_platform)" in
    synology) printf '/volume1\n' ;;
    truenas) printf '/mnt\n' ;;
    *) printf '/\n' ;;
  esac
}

# Default directory where generated per-container Compose projects are written.
sdmf_default_output_root() {
  case "$(sdmf_detect_platform)" in
    synology) printf '/volume1/docker/migration\n' ;;
    truenas) printf '/mnt/migration\n' ;;
    *) printf '%s/migration\n' "${PWD}" ;;
  esac
}

# Run a Compose command against whichever provider is installed:
# "<runtime> compose" plugin, legacy docker-compose, or podman-compose.
sdmf_compose() {
  if "$DOCKER_BIN" compose version >/dev/null 2>&1; then
    "$DOCKER_BIN" compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  elif command -v podman-compose >/dev/null 2>&1; then
    podman-compose "$@"
  else
    printf 'Error: no Compose provider found (%s compose, docker-compose, or podman-compose)\n' "$DOCKER_BIN" >&2
    return 1
  fi
}
