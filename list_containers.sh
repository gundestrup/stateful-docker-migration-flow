#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
readonly SCRIPT_DIR
# shellcheck source=lib/platform.sh
. "${SCRIPT_DIR}/lib/platform.sh"
readonly NOT_COMPOSE="!---not_managed_by_compose---!"
readonly MAYBE_PORTAINER="!---maybe_managed_by_portainer---!"

usage() {
  echo "Usage: $0 [--compose-dir DIR] [--container-dirs] [--manifest FILE] [--next] [--fresh-anonymous-volumes] [--force] [CONTAINER]" >&2
  echo "With --compose-dir, existing Compose output is compared and differences are saved as .generated unless --force is used." >&2
  echo "With --next, one container still needing Compose conversion is processed per run; containers on the removed 'db' logger are selected first." >&2
  exit 1
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

compose_dir=''
container_dirs='false'
manifest_file=''
next_container='false'
fresh_anonymous_volumes='false'
force='false'
target_container=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --compose-dir)
      shift
      [[ "${1:-}" != '' ]] || usage
      compose_dir=$1
      shift
      ;;
    --container-dirs)
      container_dirs='true'
      shift
      ;;
    --manifest)
      shift
      [[ "${1:-}" != '' ]] || usage
      manifest_file=$1
      shift
      ;;
    --next)
      next_container='true'
      shift
      ;;
    --fresh-anonymous-volumes)
      fresh_anonymous_volumes='true'
      shift
      ;;
    -f|--force)
      force='true'
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      usage
      ;;
    *)
      [[ -z "$target_container" ]] || usage
      target_container=$1
      shift
      ;;
  esac
done

if [[ "$next_container" = 'true' ]] && [[ -n "$target_container" ]]; then
  fail "--next cannot be combined with a container name"
fi
if [[ -z "$compose_dir" ]] && { [[ "$container_dirs" = 'true' ]] || [[ "$next_container" = 'true' ]] || [[ -n "$manifest_file" ]]; }; then
  fail "--container-dirs, --manifest, and --next require --compose-dir"
fi
if [[ -n "$compose_dir" ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq is required to maintain the export manifest"
  mkdir -p "$compose_dir" || fail "Could not create compose directory: $compose_dir"
  manifest_file=${manifest_file:-"${compose_dir}/compose-export-manifest.json"}
  mkdir -p "$(dirname "$manifest_file")" || fail "Could not create manifest directory"
fi

manifest_conversion_for() {
  local name=$1
  if [[ -n "$manifest_file" ]] && [[ -f "$manifest_file" ]]; then
    jq -r --arg name "$name" '.containers[$name].conversion // empty' "$manifest_file" 2>/dev/null || true
  fi
}

manifest_output_dir_for() {
  local name=$1
  if [[ "$container_dirs" = 'true' ]]; then
    printf '%s/%s\n' "$compose_dir" "$name"
  else
    printf '%s\n' "$compose_dir"
  fi
}

record_manifest() {
  local name=$1
  local compose_location=$2
  local logger=$3
  local conversion=$4
  local output_dir=${5:-}
  local netdep=${6:-}
  local image requires_recreate compose_output env_output generated_compose generated_env
  local manifest_source manifest_temp now

  [[ "$compose_location" != "$NOT_COMPOSE" ]] || compose_location=''
  image=$("$DOCKER_BIN" inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)
  requires_recreate='false'
  [[ "$logger" = 'db' ]] && requires_recreate='true'
  compose_output=''
  env_output=''
  generated_compose=''
  generated_env=''
  if [[ -n "$output_dir" ]]; then
    compose_output="${output_dir}/${name}.docker-compose.yml"
    [[ -e "${output_dir}/${name}.env" ]] && env_output="${output_dir}/${name}.env"
    [[ -e "${compose_output}.generated" ]] && generated_compose="${compose_output}.generated"
    [[ -e "${output_dir}/${name}.env.generated" ]] && generated_env="${output_dir}/${name}.env.generated"
  fi
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if [[ -f "$manifest_file" ]]; then
    manifest_source=$manifest_file
  else
    manifest_source=$(mktemp "${manifest_file}.source.XXXXXX")
    jq -n '{version: 1, containers: {}}' > "$manifest_source"
  fi
  manifest_temp=$(mktemp "${manifest_file}.XXXXXX")

  if ! jq \
    --arg name "$name" \
    --arg image "$image" \
    --arg compose_location "$compose_location" \
    --arg logger "$logger" \
    --arg conversion "$conversion" \
    --arg compose_output "$compose_output" \
    --arg env_output "$env_output" \
    --arg generated_compose "$generated_compose" \
    --arg generated_env "$generated_env" \
    --arg netdep "$netdep" \
    --arg now "$now" \
    --argjson requires_recreate "$requires_recreate" '
      def optional($value): if $value == "" then null else $value end;
      .version = 1
      | .updated_at = $now
      | .containers[$name] = {
          image: optional($image),
          compose_location: optional($compose_location),
          logger: $logger,
          requires_recreate: $requires_recreate,
          network_dependency: optional($netdep),
          conversion: $conversion,
          compose_file: optional($compose_output),
          env_file: optional($env_output),
          generated_compose_file: optional($generated_compose),
          generated_env_file: optional($generated_env),
          inspected_at: $now
        }
    ' "$manifest_source" > "$manifest_temp"; then
    rm -f "$manifest_temp"
    [[ "$manifest_source" = "$manifest_file" ]] || rm -f "$manifest_source"
    fail "Could not update manifest: $manifest_file"
  fi

  [[ "$manifest_source" = "$manifest_file" ]] || rm -f "$manifest_source"
  mv "$manifest_temp" "$manifest_file"
  chmod 600 "$manifest_file"
}

containers=()
if [[ -n "$target_container" ]]; then
  "$DOCKER_BIN" inspect "$target_container" >/dev/null
  containers+=("$target_container")
else
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && containers+=("$container_id")
  done < <("$DOCKER_BIN" ps -aq)
fi

# Store container information in an array
containers_info=()
netdep_names=()
netdep_values=()
# Get the list of containers and their compose locations
for c in "${containers[@]}"; do
  container_info=$("$DOCKER_BIN" inspect "$c" --format "{{.Name}} {{if index .Config.Labels \"com.docker.compose.project.config_files\"}}{{index .Config.Labels \"com.docker.compose.project.config_files\"}}{{else}}${NOT_COMPOSE}{{end}} {{.HostConfig.LogConfig.Type}}")
  container_info=${container_info#/}
  containers_info+=("$container_info")
  # A container sharing another container's network namespace can only run
  # while its dependency does; record it so we can warn and export it first.
  netdep=''
  network_mode=$("$DOCKER_BIN" inspect "$c" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
  if [[ "$network_mode" == container:* ]]; then
    netdep=${network_mode#container:}
    resolved=$("$DOCKER_BIN" inspect "$netdep" --format '{{.Name}}' 2>/dev/null || true)
    resolved=${resolved#/}
    [[ -n "$resolved" && "$resolved" != *' '* ]] && netdep=$resolved
  fi
  netdep_names+=("${container_info%% *}")
  netdep_values+=("$netdep")
done

# Resolve a container name to the name of the container whose network
# namespace it shares (network_mode container:X), or empty when standalone.
netdep_for() {
  local target=$1 i
  for i in "${!netdep_names[@]}"; do
    if [[ "${netdep_names[$i]}" = "$target" ]]; then
      printf '%s' "${netdep_values[$i]}"
      return 0
    fi
  done
  printf ''
}

# Sort the array based on the second field (compose location)
sorted_containers_info=()
while IFS= read -r info; do
  [[ -n "$info" ]] || continue
  sorted_containers_info+=("$info")
done < <(printf "%s\n" "${containers_info[@]}" | sort -t " " -k 2)
# Original with -u - this unfortunately hides portainer containers.
# IFS=$'\n' sorted_containers_info=($(printf "%s\n" "${containers_info[@]}" | sort -t -u " " -k 2))

# Calculate the maximum length for the container names and compose locations
max_container_length=0
max_location_length=0
max_logger_length=7
for info in "${sorted_containers_info[@]}"; do
  container=${info%% *}
  logger=${info##* }
  location=${info#* }
  location=${location% *}
  [[ "${#container}" -gt "$max_container_length" ]] && max_container_length=${#container}
  [[ "${#location}" -gt "$max_location_length" ]] && max_location_length=${#location}
  [[ "${#logger}" -gt "$max_logger_length" ]] && max_logger_length=${#logger}
done

# Print the header
echo
printf "%-${max_container_length}s  %-${max_location_length}s %-${max_logger_length}s\n" \
  "Container" "Compose_Location" "Logger"
printf "%-${max_container_length}s  %-${max_location_length}s %-${max_logger_length}s\n" \
  "$(printf '%*s' "${max_container_length}" '' | tr ' ' '-')" \
  "$(printf '%*s' "${max_location_length}" '' | tr ' ' '-')" \
  "$(printf '%*s' "${max_logger_length}" '' | tr ' ' '-')"

docker_managed=()
container_names=()
container_locations=()
container_loggers=()
dep_warnings=()
# Print the sorted container information
for info in "${sorted_containers_info[@]}"; do
  container=${info%% *}
  logger=${info##* }
  location=${info#* }
  location=${location% *}
  raw_location=$location
  container_names+=("$container")
  container_locations+=("$raw_location")
  container_loggers+=("$logger")
  if [[ "$location" != "$NOT_COMPOSE" ]] && [[ ! -f "$location" ]];then
  location="${MAYBE_PORTAINER}"
  fi
  if [[ "$raw_location" == "$NOT_COMPOSE" ]]; then
  docker_managed+=("$container")
  fi
  netdep=$(netdep_for "$container")
  if [[ -n "$netdep" ]]; then
    dep_warnings+=("$container shares the network namespace of '$netdep' (network_mode container:$netdep); migrate and start '$netdep' first")
  fi
  printf "%-${max_container_length}s  %-${max_location_length}s %s\n" "$container" "$location" "$logger"
done

for warning in ${dep_warnings[@]+"${dep_warnings[@]}"}; do
  echo
  printf 'NOTE: %s\n' "$warning"
done

if [[ ${#docker_managed[@]} -gt 0 ]]; then
  # There are containers not managed by compose nor portainer.
  # Provide some clues on how to restart those containers.
  echo
  echo "The following containers may have been created with docker commands."
  echo "Below are some clues on the command needed to to recreate them ONLY IF YOU HAVE NO OTHER WAY TO DO SO."
  echo "...this is a best guess and may not be 100% accurate."
  echo "If these containers already show as 'local' logger, there is no need to recreate them manually"
  echo
  for container in "${docker_managed[@]}"; do
    docker_command=$("${SCRIPT_DIR}/container_recreate.sh" "$container")
    echo "----------------------------------------------------"
    echo "Container: ${container}"
    echo "----------------------------------------------------"
    printf '%s\n' "$docker_command"
    echo
  done
fi

if [[ -n "$compose_dir" ]]; then
  converter_args=()
  [[ "$force" = 'true' ]] && converter_args+=(--force)
  [[ "$fresh_anonymous_volumes" = 'true' ]] && converter_args+=(--fresh-anonymous-volumes)

  if [[ "$next_container" = 'true' ]]; then
    next_index=''
    # Priority 1: containers still on a removed logger (for example Synology's 'db')
    # that do not have generated Compose output or a pending manual recreate yet.
    for index in "${!container_names[@]}"; do
      [[ "${container_loggers[$index]}" = 'db' ]] || continue
      next_conversion=$(manifest_conversion_for "${container_names[$index]}")
      case "$next_conversion" in
        written|already-converted|candidate-generated|updated|pending-compose-recreate) continue ;;
      esac
      next_index=$index
      break
    done
    # Priority 2: unmanaged containers that do not have generated Compose output yet.
    # A container whose network namespace others share is exported first: the
    # dependency must be migrated and started before its dependents can run.
    if [[ -z "$next_index" ]]; then
      for index in "${!container_names[@]}"; do
        [[ "${container_locations[$index]}" = "$NOT_COMPOSE" ]] || continue
        next_conversion=$(manifest_conversion_for "${container_names[$index]}")
        case "$next_conversion" in
          written|already-converted|candidate-generated|updated|pending-compose-recreate) continue ;;
        esac
        is_dep_target='false'
        for other in "${!container_names[@]}"; do
          [[ "$other" != "$index" ]] || continue
          if [[ "$(netdep_for "${container_names[$other]}")" = "${container_names[$index]}" ]]; then
            is_dep_target='true'
            break
          fi
        done
        [[ "$is_dep_target" = 'true' ]] || continue
        next_index=$index
        break
      done
    fi
    if [[ -z "$next_index" ]]; then
      for index in "${!container_names[@]}"; do
        [[ "${container_locations[$index]}" = "$NOT_COMPOSE" ]] || continue
        next_conversion=$(manifest_conversion_for "${container_names[$index]}")
        case "$next_conversion" in
          written|already-converted|candidate-generated|updated|pending-compose-recreate) continue ;;
        esac
        next_index=$index
        break
      done
    fi

    if [[ -z "$next_index" ]]; then
      for index in "${!container_names[@]}"; do
        conversion='updated'
        manifest_output_dir=''
        if [[ "${container_locations[$index]}" != "$NOT_COMPOSE" ]]; then
          conversion='compose-managed'
        else
          manifest_output_dir=$(manifest_output_dir_for "${container_names[$index]}")
        fi
        record_manifest "${container_names[$index]}" "${container_locations[$index]}" \
          "${container_loggers[$index]}" "$conversion" "$manifest_output_dir" \
          "$(netdep_for "${container_names[$index]}")"
      done
      echo "No containers still need Compose conversion."
      printf 'Manifest updated: %s\n' "$manifest_file"
      exit 0
    fi

    if [[ "${container_locations[$next_index]}" != "$NOT_COMPOSE" ]]; then
      for index in "${!container_names[@]}"; do
        conversion='updated'
        manifest_output_dir=''
        [[ "${container_loggers[$index]}" = 'db' ]] && conversion='pending'
        if [[ "${container_locations[$index]}" != "$NOT_COMPOSE" ]]; then
          conversion='compose-managed'
        else
          manifest_output_dir=$(manifest_output_dir_for "${container_names[$index]}")
        fi
        if [[ "$index" -eq "$next_index" ]]; then
          conversion='pending-compose-recreate'
        fi
        record_manifest "${container_names[$index]}" "${container_locations[$index]}" \
          "${container_loggers[$index]}" "$conversion" "$manifest_output_dir" \
          "$(netdep_for "${container_names[$index]}")"
      done
      compose_path=${container_locations[$next_index]}
      echo "Next container requiring recreation: ${container_names[$next_index]}"
      if [[ -f "$compose_path" ]]; then
        echo "It is already Compose-managed. Review its Compose file, then run:"
        printf '  cd %q && %s compose -f %q up -d --force-recreate\n' \
          "$(dirname "$compose_path")" "$DOCKER_BIN" "$(basename "$compose_path")"
      else
        echo "Its recorded Compose file is missing; it may be managed by Portainer: $compose_path"
      fi
      printf 'Manifest updated: %s\n' "$manifest_file"
      exit 0
    fi
  fi

  for index in "${!container_names[@]}"; do
    container=${container_names[$index]}
    raw_location=${container_locations[$index]}
    logger=${container_loggers[$index]}

    if [[ "$raw_location" != "$NOT_COMPOSE" ]]; then
      record_manifest "$container" "$raw_location" "$logger" 'compose-managed' '' "$(netdep_for "$container")"
      continue
    fi

    output_dir=$(manifest_output_dir_for "$container")

    if [[ "$next_container" = 'true' ]] && [[ "$index" -ne "$next_index" ]]; then
      conversion=$(manifest_conversion_for "$container")
      if [[ -z "$conversion" ]]; then
        conversion='pending'
      fi
      record_manifest "$container" "$raw_location" "$logger" "$conversion" "$output_dir" "$(netdep_for "$container")"
      continue
    fi

    mkdir -p "$output_dir"
    inspect_temp=$(mktemp "${output_dir}/.docker-inspect.XXXXXX")
    status_temp=$(mktemp "${output_dir}/.conversion-status.XXXXXX")
    "$DOCKER_BIN" inspect "$container" > "$inspect_temp"
    conversion='conversion-failed'
    if "${SCRIPT_DIR}/export_to_compose.sh" "${converter_args[@]}" \
      --status-file "$status_temp" "$inspect_temp" "$output_dir"; then
      conversion=$(cat "$status_temp")
    else
      printf 'Conversion failed for %s\n' "$container" >&2
    fi
    rm -f "$inspect_temp" "$status_temp"
    record_manifest "$container" "$raw_location" "$logger" "$conversion" "$output_dir" "$(netdep_for "$container")"
    [[ "$conversion" != 'conversion-failed' ]] || exit 1
  done
  printf 'Manifest updated: %s\n' "$manifest_file"
elif [[ -n "$target_container" ]] && [[ ${#docker_managed[@]} -eq 0 ]]; then
  echo "Container is already Compose-managed or was not found."
fi
