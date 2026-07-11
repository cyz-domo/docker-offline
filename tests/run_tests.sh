#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

bash "$script_dir/test_build_outputs.sh"
bash "$script_dir/test_migrate_data_root.sh"

echo "All tests passed"
