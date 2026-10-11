#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd -P)
test_tmp_dir=$(mktemp -d)
trap 'rm -rf "$test_tmp_dir"' EXIT

docker() {
  case "$1" in
    inspect)
      if [[ "${3:-}" = '--format' ]] && [[ "${4:-}" = '{{.Config.Image}}' ]]; then
        printf 'example/test:1\n'
      elif [[ "${3:-}" = '--format' ]] && [[ "${4:-}" = '{{.HostConfig.NetworkMode}}' ]]; then
        case "$2" in
          net-dep-app) printf 'container:vpn-gw\n' ;;
          *) printf 'bridge\n' ;;
        esac
      elif [[ "${3:-}" = '--format' ]] && [[ "${4:-}" = '{{.Name}}' ]]; then
        printf '/%s\n' "$2"
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'true' ]]; then
        printf '/web %s local\n' "$COMPOSE_PATH"
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'unmanaged' ]]; then
        printf '/review-test !---not_managed_by_compose---! local\n'
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'unmanaged-db' ]]; then
        printf '/review-test !---not_managed_by_compose---! db\n'
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'compose-db' ]]; then
        printf '/compose-web %s db\n' "$COMPOSE_PATH"
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'multi' ]]; then
        case "$2" in
          compose-web) printf '/compose-web %s local\n' "$COMPOSE_PATH" ;;
          db-one) printf '/db-one !---not_managed_by_compose---! db\n' ;;
          db-two) printf '/db-two !---not_managed_by_compose---! db\n' ;;
          plain-app) printf '/plain-app !---not_managed_by_compose---! local\n' ;;
          *) return 1 ;;
        esac
      elif [[ "${3:-}" = '--format' ]] && [[ "${MOCK_LIST_MODE:-}" = 'dep' ]]; then
        case "$2" in
          vpn-gw) printf '/vpn-gw !---not_managed_by_compose---! local\n' ;;
          net-dep-app) printf '/net-dep-app !---not_managed_by_compose---! local\n' ;;
          *) return 1 ;;
        esac
      elif [[ "${3:-}" = '--format' ]] && [[ "${4:-}" = '{{.HostConfig.LogConfig.Type}}' ]]; then
        printf 'db\n'
      else
        printf '%s\n' "$DOCKER_FIXTURE"
      fi
      ;;
    ps)
      [[ "${2:-}" = '-aq' ]] || return 2
      printf '%s\n' "${MOCK_DOCKER_IDS:-}"
      ;;
    version)
      return 0
      ;;
    run)
      shift
      printf 'MOCK_DOCKER_RUN\n'
      printf '<%s>\n' "$@"
      ;;
    stop|rm)
      [[ -z "${MOCK_DOCKER_LOG:-}" ]] || printf '%s %s\n' "$1" "${2:-}" >> "$MOCK_DOCKER_LOG"
      ;;
    compose)
      shift
      [[ -z "${MOCK_DOCKER_LOG:-}" ]] || printf 'compose %s\n' "$*" >> "$MOCK_DOCKER_LOG"
      ;;
    *)
      return 2
      ;;
  esac
}
export -f docker

podman() {
  docker "$@"
}
export -f podman

marker="$test_tmp_dir/command-injected"
anon_volume='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DOCKER_FIXTURE=$(jq -cn --arg marker "$marker" --arg anon_volume "$anon_volume" '[{Id:"a1b2c3d4e5f6aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",Name:"/review-test",Config:{Image:"example/test:1",Hostname:"a1b2c3d4e5f6",Env:["RECREATE_TEST_APP=one","RECREATE_TEST_APP_EXTRA=two",("RECREATE_TEST_DANGEROUS=$(touch "+$marker+")")],Entrypoint:["/entry","--entry-flag"],Cmd:["argument with spaces","second-argument","line1\nline2"],Tty:true,OpenStdin:false},HostConfig:{PortBindings:{"80/tcp":[{HostIp:"127.0.0.1",HostPort:"8080"}]},RestartPolicy:{Name:"unless-stopped"},NetworkMode:"custom-net",LogConfig:{Type:"db"},CgroupnsMode:"host",UsernsMode:"host",UtsMode:"host",Runtime:"runc",IpcMode:"private"},Mounts:[{Type:"bind",Source:"/tmp/source path",Destination:"/data path",RW:false,Mode:""},{Type:"volume",Name:"config_volume",Source:"/var/lib/docker/volumes/config_volume/_data",Destination:"/config",RW:true,Mode:""},{Type:"volume",Name:$anon_volume,Source:"/var/lib/docker/volumes/anonymous/_data",Destination:"/storage",RW:true,Mode:""},{Type:"tmpfs",Destination:"/cache",RW:true}]}]')
export DOCKER_FIXTURE
unset RECREATE_TEST_APP RECREATE_TEST_APP_EXTRA RECREATE_TEST_DANGEROUS
suggestion=$("$repo_dir/container_recreate.sh" review-test)
run_result=$(eval "$suggestion") # nosemgrep: shell-eval-usage — the eval is the test
[[ ! -e "$marker" ]]
[[ "$suggestion" != *"$marker"* ]]
[[ "$suggestion" != *'RECREATE_TEST_APP=one'* ]]
[[ "$run_result" == *'</REVIEW_AND_CREATE_ENV_FILE_BEFORE_RUNNING>'* ]]
[[ "$run_result" == *'<argument with spaces>'* ]]
[[ "$run_result" == *'<second-argument>'* ]]
[[ "$run_result" == *$'line1\nline2'* ]]
[[ "$run_result" == *'<127.0.0.1:8080:80/tcp>'* ]]
[[ "$run_result" == *'</tmp/source path:/data path:ro>'* ]]
[[ "$run_result" == *'<config_volume:/config>'* ]]
[[ "$run_result" == *'</cache>'* ]]
[[ "$run_result" == *'<-t>'* && "$run_result" != *'<-i>'* ]]
[[ "$run_result" == *'<--log-driver>'*'<local>'* ]]
[[ "$run_result" == *'<--restart>'*'<unless-stopped>'* ]]
[[ "$run_result" == *'<--network>'*'<custom-net>'* ]]
[[ "$run_result" == *'<--entrypoint>'*'</entry>'*'--entry-flag'* ]]
printf 'Container recreation rendering tests passed\n'

compose_path="$test_tmp_dir/compose  file.yml"
: > "$compose_path"
MOCK_LIST_MODE=true
MOCK_DOCKER_IDS=review-list-test
export MOCK_LIST_MODE MOCK_DOCKER_IDS COMPOSE_PATH="$compose_path"
listing=$("$repo_dir/list_containers.sh")
[[ "$listing" == *"$compose_path"* ]]
MOCK_LIST_MODE=unmanaged
export MOCK_LIST_MODE
listing=$("$repo_dir/list_containers.sh")
[[ "$listing" != *"$marker"* ]]
[[ "$listing" != *'RECREATE_TEST_APP=one'* ]]
[[ "$listing" == *'/REVIEW_AND_CREATE_ENV_FILE_BEFORE_RUNNING'* ]]
printf 'Container listing path and secret-redaction tests passed\n'

podman_listing=$(DOCKER_BIN=podman "$repo_dir/list_containers.sh")
[[ "$podman_listing" == *'review-test'* ]]
[[ "$podman_listing" == *'/REVIEW_AND_CREATE_ENV_FILE_BEFORE_RUNNING'* ]]
printf 'Alternate runtime (DOCKER_BIN) listing tests passed\n'

export_dir=$(mktemp -d)
jq -n '{
  name:"exported-app", image:"example/exported:1", cmd:"/init",
  enable_restart_policy:true, network_mode:"custom-net", use_host_network:false,
  network:[{driver:"bridge",name:"custom-net"}],
  env_variables:[{key:"TEST_SECRET",value:"do-not-print"},{key:"EMPTY_VALUE",value:""}],
  port_bindings:[{container_port:8443,host_port:9443,type:"tcp"}],
  volume_bindings:[{host_volume_file:"/docker/exported-app",is_directory:true,mount_point:"/config",type:"rw"}],
  labels:{owner:"test"}, cpu_priority:50
}' > "$export_dir/exported.json"
converter_output=$(SDMF_PLATFORM=synology "$repo_dir/export_to_compose.sh" "$export_dir/exported.json" "$export_dir")
[[ "$converter_output" != *'do-not-print'* ]]
[[ -f "$export_dir/exported-app.docker-compose.yml" ]]
grep -Fq 'container_name: "exported-app"' "$export_dir/exported-app.docker-compose.yml"
grep -Fq 'restart: unless-stopped' "$export_dir/exported-app.docker-compose.yml"
grep -Fq 'driver: local' "$export_dir/exported-app.docker-compose.yml"
grep -Fq '"9443:8443/tcp"' "$export_dir/exported-app.docker-compose.yml"
grep -Fq '"/volume1/docker/exported-app:/config:rw"' "$export_dir/exported-app.docker-compose.yml"
grep -Fq 'custom-net' "$export_dir/exported-app.docker-compose.yml"
grep -Fq 'external: true' "$export_dir/exported-app.docker-compose.yml"
grep -Fxq 'TEST_SECRET=do-not-print' "$export_dir/exported-app.env"
grep -Fxq 'EMPTY_VALUE=' "$export_dir/exported-app.env"
[[ "$(stat -c '%a' "$export_dir/exported-app.env")" == '600' ]]
second_conversion=$(SDMF_PLATFORM=synology "$repo_dir/export_to_compose.sh" "$export_dir/exported.json" "$export_dir")
[[ "$second_conversion" == *'Already converted'* ]]
[[ ! -e "$export_dir/exported-app.docker-compose.yml.generated" ]]
printf '# locally reviewed change\n' >> "$export_dir/exported-app.docker-compose.yml"
changed_conversion=$(SDMF_PLATFORM=synology "$repo_dir/export_to_compose.sh" "$export_dir/exported.json" "$export_dir")
[[ "$changed_conversion" == *'Existing Compose file differs'* ]]
[[ "$changed_conversion" == *'Generated candidate'* ]]
[[ "$changed_conversion" == *'locally reviewed change'* ]]
[[ -f "$export_dir/exported-app.docker-compose.yml.generated" ]]
"$repo_dir/export_to_compose.sh" --force "$export_dir/exported.json" "$export_dir" >/dev/null
[[ ! -e "$export_dir/exported-app.docker-compose.yml.generated" ]]
printf 'Synology export conversion and reconciliation tests passed\n'

custom_volume_dir=$(mktemp -d)
"$repo_dir/export_to_compose.sh" --volume-root /volume7 \
  "$export_dir/exported.json" "$custom_volume_dir" >/dev/null
grep -Fq '"/volume7/docker/exported-app:/config:rw"' \
  "$custom_volume_dir/exported-app.docker-compose.yml"
if grep -Fq '"/volume1/docker/exported-app:/config:rw"' \
  "$custom_volume_dir/exported-app.docker-compose.yml"; then
  printf 'Custom volume root was ignored\n' >&2
  exit 1
fi
truenas_volume_dir=$(mktemp -d)
SDMF_PLATFORM=truenas "$repo_dir/export_to_compose.sh" \
  "$export_dir/exported.json" "$truenas_volume_dir" >/dev/null
grep -Fq '"/mnt/docker/exported-app:/config:rw"' \
  "$truenas_volume_dir/exported-app.docker-compose.yml"
linux_volume_dir=$(mktemp -d)
SDMF_PLATFORM=linux "$repo_dir/export_to_compose.sh" \
  "$export_dir/exported.json" "$linux_volume_dir" >/dev/null
grep -Fq '"/docker/exported-app:/config:rw"' \
  "$linux_volume_dir/exported-app.docker-compose.yml"
if volume_root_error=$("$repo_dir/export_to_compose.sh" --volume-root 2>&1); then
  printf 'Missing volume-root argument was accepted\n' >&2
  exit 1
fi
[[ "$volume_root_error" == *'--volume-root requires a path'* ]]

invalid_json_dir=$(mktemp -d)
printf '{invalid\n' > "$invalid_json_dir/invalid.json"
if invalid_json_output=$("$repo_dir/export_to_compose.sh" \
  "$invalid_json_dir/invalid.json" "$invalid_json_dir" 2>&1); then
  printf 'Invalid JSON export was accepted\n' >&2
  exit 1
fi
[[ "$invalid_json_output" == *'Invalid JSON export'* ]]
[[ ! -e "$invalid_json_dir/invalid.docker-compose.yml" ]]
[[ ! -e "$invalid_json_dir/invalid.env" ]]
printf '{"image":"example/missing-name:1"}\n' > "$invalid_json_dir/missing-name.json"
if missing_name_output=$("$repo_dir/export_to_compose.sh" \
  "$invalid_json_dir/missing-name.json" "$invalid_json_dir" 2>&1); then
  printf 'Export without a container name was accepted\n' >&2
  exit 1
fi
[[ "$missing_name_output" == *'Export does not contain a container name'* ]]
printf '{"name":"missing-image"}\n' > "$invalid_json_dir/missing-image.json"
if missing_image_output=$("$repo_dir/export_to_compose.sh" \
  "$invalid_json_dir/missing-image.json" "$invalid_json_dir" 2>&1); then
  printf 'Export without an image was accepted\n' >&2
  exit 1
fi
[[ "$missing_image_output" == *'Export does not contain an image'* ]]
if missing_file_output=$("$repo_dir/export_to_compose.sh" \
  "$invalid_json_dir/missing.json" "$invalid_json_dir" 2>&1); then
  printf 'Missing export input was accepted\n' >&2
  exit 1
fi
[[ "$missing_file_output" == *'Export file not found'* ]]
printf 'Volume-root, platform, and malformed export tests passed\n'

inspect_dir=$(mktemp -d)
printf '%s\n' "$DOCKER_FIXTURE" > "$inspect_dir/inspect.json"
converter_output=$("$repo_dir/export_to_compose.sh" "$inspect_dir/inspect.json" "$inspect_dir")
[[ "$converter_output" != *"$marker"* ]]
[[ -f "$inspect_dir/review-test.docker-compose.yml" ]]
grep -Fq 'restart: unless-stopped' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq 'driver: local' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq '"127.0.0.1:8080:80/tcp"' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq '"/tmp/source path:/data path:ro"' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq 'config_volume:/config:rw' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq 'external: true' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq 'cgroup: "host"' "$inspect_dir/review-test.docker-compose.yml"
if grep -Eq '^(    )?(hostname|runtime|ipc):' "$inspect_dir/review-test.docker-compose.yml"; then
  printf 'Daemon-generated defaults leaked into generated Compose\n' >&2
  exit 1
fi
grep -Fq 'userns_mode: "host"' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq 'uts: "host"' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq '/entry' "$inspect_dir/review-test.docker-compose.yml"
grep -Fq '/cache' "$inspect_dir/review-test.docker-compose.yml"
grep -Fxq 'RECREATE_TEST_APP=one' "$inspect_dir/review-test.env"
grep -Fxq 'RECREATE_TEST_APP_EXTRA=two' "$inspect_dir/review-test.env"
grep -Fq "$anon_volume:/storage:rw" "$inspect_dir/review-test.docker-compose.yml"

fresh_dir=$(mktemp -d)
"$repo_dir/export_to_compose.sh" --fresh-anonymous-volumes "$inspect_dir/inspect.json" "$fresh_dir" >/dev/null
grep -Fq '"/storage:rw"' "$fresh_dir/review-test.docker-compose.yml"
if grep -Fq "$anon_volume" "$fresh_dir/review-test.docker-compose.yml"; then
  printf 'Fresh anonymous volume conversion retained the old volume name\n' >&2
  exit 1
fi
printf 'Docker inspect conversion tests passed\n'

selected_dir=$(mktemp -d)
MOCK_LIST_MODE=unmanaged
export MOCK_LIST_MODE
selected_output=$("$repo_dir/list_containers.sh" --compose-dir "$selected_dir" review-test)
[[ "$selected_output" != *"$marker"* ]]
[[ "$selected_output" != *'RECREATE_TEST_APP=one'* ]]
[[ -f "$selected_dir/review-test.docker-compose.yml" ]]
[[ -f "$selected_dir/review-test.env" ]]
grep -Fq 'restart: unless-stopped' "$selected_dir/review-test.docker-compose.yml"
manifest_file="$selected_dir/compose-export-manifest.json"
[[ -f "$manifest_file" ]]
[[ "$(stat -c '%a' "$manifest_file")" == '600' ]]
jq -e '.containers["review-test"].conversion == "written" and .containers["review-test"].requires_recreate == false' "$manifest_file" >/dev/null

next_dir=$(mktemp -d)
MOCK_LIST_MODE=unmanaged-db
export MOCK_LIST_MODE
next_output=$("$repo_dir/list_containers.sh" --compose-dir "$next_dir" --container-dirs --next)
[[ "$next_output" == *'Manifest updated'* ]]
[[ -f "$next_dir/review-test/review-test.docker-compose.yml" ]]
jq -e '.containers["review-test"].conversion == "written" and .containers["review-test"].requires_recreate == true' "$next_dir/compose-export-manifest.json" >/dev/null
MOCK_LIST_MODE=unmanaged
export MOCK_LIST_MODE
next_output=$("$repo_dir/list_containers.sh" --compose-dir "$next_dir" --container-dirs --next)
[[ "$next_output" == *'No containers still need Compose conversion'* ]]
jq -e '.containers["review-test"].conversion == "updated" and .containers["review-test"].requires_recreate == false' "$next_dir/compose-export-manifest.json" >/dev/null

migration_dir=$(mktemp -d)
MOCK_LIST_MODE=unmanaged-db
export MOCK_LIST_MODE
migration_output=$("$repo_dir/sdmf" next "$migration_dir" --fresh-anonymous-volumes)
[[ "$migration_output" == *'Next: use the validate action'* ]]
[[ -f "$migration_dir/review-test/review-test.docker-compose.yml" ]]
grep -Fq '"/storage:rw"' "$migration_dir/review-test/review-test.docker-compose.yml"
manifest_output=$("$repo_dir/sdmf" manifest "$migration_dir")
[[ "$manifest_output" == *'review-test'* && "$manifest_output" == *'logger=db'* && "$manifest_output" == *'written'* ]]
menu_output=$(printf '0\n' | "$repo_dir/sdmf")
[[ "$menu_output" == *'Migrate containers to Compose projects'* ]]
[[ "$menu_output" == *'inventory -> export -> validate -> recreate'* ]]
doctor_output=$("$repo_dir/sdmf" doctor)
[[ "$doctor_output" == *'Detected platform: linux'* ]]
[[ "$doctor_output" == *'All prerequisites satisfied'* ]]
doctor_output=$(SDMF_PLATFORM=truenas "$repo_dir/sdmf" doctor)
[[ "$doctor_output" == *'Detected platform: truenas'* ]]
[[ "$doctor_output" == *'Default migration root: /mnt/migration'* ]]
printf 'Single-container, manifest, menu, doctor, and next-container Compose export tests passed\n'

MOCK_LIST_MODE=unmanaged-db
MOCK_DOCKER_LOG="$test_tmp_dir/docker-calls.log"
: > "$MOCK_DOCKER_LOG"
export MOCK_LIST_MODE MOCK_DOCKER_LOG
recreate_output=$(printf 'RECREATE\n' | "$repo_dir/sdmf" recreate "$next_dir" review-test)
[[ "$recreate_output" == *'currently uses logger'* ]]
grep -Fxq 'stop review-test' "$MOCK_DOCKER_LOG"
grep -Fxq 'rm review-test' "$MOCK_DOCKER_LOG"
grep -Fq 'up -d --force-recreate' "$MOCK_DOCKER_LOG"
stop_line=$(grep -nFx 'stop review-test' "$MOCK_DOCKER_LOG" | cut -d: -f1)
rm_line=$(grep -nFx 'rm review-test' "$MOCK_DOCKER_LOG" | cut -d: -f1)
[[ "$stop_line" -lt "$rm_line" ]]
printf 'Recreate stop-before-remove tests passed\n'

validate_output=$("$repo_dir/sdmf" validate "$next_dir" review-test)
[[ "$validate_output" == *'Compose configuration is valid'* ]]
: > "$MOCK_DOCKER_LOG"
printf 'RECREATE\n' | "$repo_dir/sdmf" \
  compose-recreate "$next_dir/review-test/review-test.docker-compose.yml" >/dev/null
grep -Fq 'compose -f review-test.docker-compose.yml up -d --force-recreate' "$MOCK_DOCKER_LOG"
: > "$MOCK_DOCKER_LOG"
if printf 'WRONG\n' | "$repo_dir/sdmf" recreate "$next_dir" review-test >/dev/null 2>&1; then
  printf 'Recreate proceeded without RECREATE confirmation\n' >&2
  exit 1
fi
if grep -Eq '^(stop|rm) ' "$MOCK_DOCKER_LOG"; then
  printf 'Recreate touched Docker after an aborted confirmation\n' >&2
  exit 1
fi
if "$repo_dir/sdmf" recreate "$next_dir" missing-container </dev/null >/dev/null 2>&1; then
  printf 'Recreate succeeded for a missing container export\n' >&2
  exit 1
fi
printf 'Validate, compose-recreate, and aborted-confirmation tests passed\n'

multi_dir=$(mktemp -d)
MOCK_LIST_MODE=multi
MOCK_DOCKER_IDS=$'compose-web\ndb-one\ndb-two\nplain-app'
export MOCK_LIST_MODE MOCK_DOCKER_IDS
next_multi_output=$("$repo_dir/list_containers.sh" --compose-dir "$multi_dir" --container-dirs --next)
[[ "$next_multi_output" == *"$multi_dir/db-one"* ]]
[[ -f "$multi_dir/db-one/review-test.docker-compose.yml" ]]
[[ ! -e "$multi_dir/db-two/review-test.docker-compose.yml" ]]
jq -e '.containers["db-one"].conversion == "written"
  and .containers["db-two"].conversion == "pending"
  and .containers["plain-app"].conversion == "pending"
  and .containers["compose-web"].conversion == "compose-managed"' \
  "$multi_dir/compose-export-manifest.json" >/dev/null
next_multi_output=$("$repo_dir/list_containers.sh" --compose-dir "$multi_dir" --container-dirs --next)
[[ -f "$multi_dir/db-two/review-test.docker-compose.yml" ]]
jq -e '.containers["db-two"].conversion == "written"' \
  "$multi_dir/compose-export-manifest.json" >/dev/null
next_multi_output=$("$repo_dir/list_containers.sh" --compose-dir "$multi_dir" --container-dirs --next)
[[ "$next_multi_output" == *"$multi_dir/plain-app"* ]]
[[ -f "$multi_dir/plain-app/review-test.docker-compose.yml" ]]
jq -e '.containers["plain-app"].conversion == "written"' \
  "$multi_dir/compose-export-manifest.json" >/dev/null
next_multi_output=$("$repo_dir/list_containers.sh" --compose-dir "$multi_dir" --container-dirs --next)
[[ "$next_multi_output" == *'No containers still need Compose conversion'* ]]

all_dir=$(mktemp -d)
"$repo_dir/list_containers.sh" --compose-dir "$all_dir" --container-dirs >/dev/null
[[ -f "$all_dir/db-one/review-test.docker-compose.yml" ]]
[[ -f "$all_dir/db-two/review-test.docker-compose.yml" ]]
[[ -f "$all_dir/plain-app/review-test.docker-compose.yml" ]]
jq -e '.containers["db-one"].conversion == "written"
  and .containers["db-two"].conversion == "written"
  and .containers["plain-app"].conversion == "written"
  and .containers["compose-web"].conversion == "compose-managed"' \
  "$all_dir/compose-export-manifest.json" >/dev/null
printf 'Multi-container export and generalized next-selection tests passed\n'

cdb_dir=$(mktemp -d)
MOCK_LIST_MODE=compose-db
MOCK_DOCKER_IDS=compose-web
export MOCK_LIST_MODE MOCK_DOCKER_IDS
cdb_output=$("$repo_dir/list_containers.sh" --compose-dir "$cdb_dir" --container-dirs --next)
[[ "$cdb_output" == *'already Compose-managed'* ]]
[[ "$cdb_output" == *'docker compose -f'*'--force-recreate'* ]]
[[ ! -e "$cdb_dir/compose-web" ]]
jq -e '.containers["compose-web"].conversion == "pending-compose-recreate"' \
  "$cdb_dir/compose-export-manifest.json" >/dev/null
printf 'Compose-managed next-container tests passed\n'

dep_dir=$(mktemp -d)
MOCK_LIST_MODE=dep
MOCK_DOCKER_IDS=$'vpn-gw\nnet-dep-app'
export MOCK_LIST_MODE MOCK_DOCKER_IDS
dep_listing=$("$repo_dir/list_containers.sh")
[[ "$dep_listing" == *'net-dep-app'*'network namespace'*'vpn-gw'* ]]
# net-dep-app sorts before vpn-gw alphabetically; the dependency target must
# still be exported first because net-dep-app shares its network namespace.
dep_next=$("$repo_dir/list_containers.sh" --compose-dir "$dep_dir" --container-dirs --next)
[[ "$dep_next" == *"$dep_dir/vpn-gw"* ]]
[[ -f "$dep_dir/vpn-gw/review-test.docker-compose.yml" ]]
[[ ! -e "$dep_dir/net-dep-app/review-test.docker-compose.yml" ]]
jq -e '.containers["vpn-gw"].conversion == "written"
  and .containers["net-dep-app"].network_dependency == "vpn-gw"' \
  "$dep_dir/compose-export-manifest.json" >/dev/null
dep_next=$("$repo_dir/list_containers.sh" --compose-dir "$dep_dir" --container-dirs --next)
[[ "$dep_next" == *"$dep_dir/net-dep-app"* ]]
printf 'Network-dependency hint and ordering tests passed\n'

for script in "$repo_dir"/*.sh "$repo_dir"/lib/*.sh "$repo_dir"/sdmf; do
  bash -n "$script"
done
printf 'Shell syntax tests passed\n'
