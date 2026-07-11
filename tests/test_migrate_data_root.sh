#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

extract_script() {
    awk '
        /write_migrate_data_root_sh_v2\(\)/ { in_func=1 }
        in_func { print }
        in_func && /^}/ { exit }
    ' "$repo_root/build_offline.sh" > "$work_dir/extract.txt"

    start_line=$(grep -n "cat > .*migrate-data-root.sh.*MIGRATE_EOF" "$work_dir/extract.txt" | cut -d: -f1)
    end_line=$(grep -n '^MIGRATE_EOF$' "$work_dir/extract.txt" | tail -1 | cut -d: -f1)
    sed -n "$((start_line + 1)),$((end_line - 1))p" "$work_dir/extract.txt" > "$work_dir/migrate-data-root.sh"
    chmod +x "$work_dir/migrate-data-root.sh"
}

setup_mocks() {
    mkdir -p "$work_dir/fakebin"
    : > "$work_dir/commands.log"

    cat > "$work_dir/fakebin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$TEST_COMMAND_LOG"
if [ "${TEST_SYSTEMCTL_FAIL_START_DOCKER:-0}" = "1" ] && [ "$1" = "start" ] && [ "$2" = "docker.service" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$work_dir/fakebin/systemctl"

    cat > "$work_dir/fakebin/docker" <<'EOF'
#!/bin/bash
if [ "$1" = "info" ]; then
    echo "Docker Root Dir: ${TEST_DOCKER_ROOT_DIR}"
    exit 0
fi
echo "docker $*" >> "$TEST_COMMAND_LOG"
EOF
    chmod +x "$work_dir/fakebin/docker"

    cat > "$work_dir/fakebin/rsync" <<'EOF'
#!/bin/bash
src="${@: -2:1}"
dst="${@: -1}"
cp -a "${src}/." "$dst/"
EOF
    chmod +x "$work_dir/fakebin/rsync"

    export PATH="$work_dir/fakebin:$PATH"
    export TEST_COMMAND_LOG="$work_dir/commands.log"
}

run_success_case() {
    local daemon_json="$work_dir/success-daemon.json"
    local current_root="$work_dir/success-current-root"
    local target_root="$work_dir/success-new-root"

    mkdir -p "$current_root/containers"
    echo sample > "$current_root/containers/data.txt"

    cat > "$daemon_json" <<EOF
{
  "log-driver": "json-file"
}
EOF

    export DOCKER_DAEMON_JSON="$daemon_json"
    export DOCKER_DATA_ROOT_DEFAULT="$current_root"
    export TEST_DOCKER_ROOT_DIR="$target_root"
    unset TEST_SYSTEMCTL_FAIL_START_DOCKER

    printf '%s\n%s\n' "$target_root" "y" | bash "$work_dir/migrate-data-root.sh" >/dev/null

    grep -q '"data-root": "'"$target_root"'"' "$daemon_json"
    test -f "$target_root/containers/data.txt"
}

run_rollback_case() {
    local daemon_json="$work_dir/fail-daemon.json"
    local current_root="$work_dir/fail-current-root"
    local target_root="$work_dir/fail-new-root"

    mkdir -p "$current_root/containers"
    echo sample > "$current_root/containers/data.txt"

    cat > "$daemon_json" <<EOF
{
  "data-root": "$current_root",
  "log-driver": "json-file"
}
EOF

    export DOCKER_DAEMON_JSON="$daemon_json"
    export DOCKER_DATA_ROOT_DEFAULT="$current_root"
    export TEST_DOCKER_ROOT_DIR="$target_root"
    export TEST_SYSTEMCTL_FAIL_START_DOCKER=1

    if printf '%s\n%s\n' "$target_root" "y" | bash "$work_dir/migrate-data-root.sh" >/dev/null 2>&1; then
        echo "rollback case unexpectedly succeeded" >&2
        exit 1
    fi

    grep -q '"data-root": "'"$current_root"'"' "$daemon_json"
    grep -q 'systemctl start docker.service' "$work_dir/commands.log"
}

extract_script
setup_mocks
run_success_case
run_rollback_case

echo "test_migrate_data_root.sh: PASS"
