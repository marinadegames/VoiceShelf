#!/usr/bin/env bash
set -euo pipefail

source_path="${BASH_SOURCE[0]}"
project_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
target_dir="$HOME/.local/bin"
target="$target_dir/trb"

mkdir -p "$target_dir"
ln -sfn "$project_dir/transcribe.sh" "$target"

echo "Установлено: $target -> $project_dir/transcribe.sh"
echo "Теперь из любой папки доступны команды:"
echo "  trb"
echo "  trb recording.m4a"

