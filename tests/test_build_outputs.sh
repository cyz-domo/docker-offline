#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

cp "$repo_root/build_offline.sh" "$work_dir/"
mkdir -p "$work_dir/fakebin"
mkdir -p "$work_dir/docker"

touch "$work_dir/docker/docker" "$work_dir/docker/dockerd" "$work_dir/docker/containerd" "$work_dir/docker/runc"
tar -czf "$work_dir/docker-29.6.1.tgz" -C "$work_dir" docker

cat > "$work_dir/docker-compose-linux" <<'EOF'
#!/bin/bash
echo compose
EOF
chmod +x "$work_dir/docker-compose-linux"

cat > "$work_dir/fakebin/curl" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cp "$TEST_DOCKER_TGZ" "$out"
EOF
chmod +x "$work_dir/fakebin/curl"

cat > "$work_dir/fakebin/file" <<'EOF'
#!/bin/bash
echo "$1: ELF 64-bit LSB executable"
EOF
chmod +x "$work_dir/fakebin/file"

export PATH="$work_dir/fakebin:$PATH"
export TEST_DOCKER_TGZ="$work_dir/docker-29.6.1.tgz"

cd "$work_dir"
bash build_offline.sh --version 29.6.1 --arch x86_64 --compose-file "$work_dir/docker-compose-linux" --non-interactive >/dev/null

output_dir="$work_dir/offline-docker-29.6.1"
test -f "$output_dir/migrate-data-root.sh"
test -f "$output_dir/README.md"

grep -q 'restores the previous `daemon.json` automatically if migration fails' "$output_dir/README.md"
grep -q 'write_daemon_json_with_data_root' "$output_dir/migrate-data-root.sh"
grep -q 'trap rollback EXIT' "$output_dir/migrate-data-root.sh"
grep -q 'rsync -aHAX --delete' "$output_dir/migrate-data-root.sh"

echo "test_build_outputs.sh: PASS"
