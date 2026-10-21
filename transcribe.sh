#!/usr/bin/env bash
set -euo pipefail

# Resolve the real project directory even when this script is called through
# the global ~/.local/bin/trb symlink. Keep the caller's directory so the
# interactive picker lists media from where `trb` was invoked.
caller_dir="$(pwd)"
source_path="${BASH_SOURCE[0]}"
while [ -h "$source_path" ]; do
  source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
  source_path="$(readlink "$source_path")"
  case "$source_path" in
    /*) ;;
    *) source_path="$source_dir/$source_path" ;;
  esac
done
project_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
cd "$project_dir"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Не найден Python 3. Установите Python 3.9 или новее." >&2
  exit 1
fi

if [ ! -d ".venv" ]; then
  echo "Один раз создаю локальное окружение…" >&2
  python3 -m venv .venv
fi

source .venv/bin/activate

if ! python -c "import faster_whisper" >/dev/null 2>&1; then
  echo "Один раз устанавливаю локальный Whisper…" >&2
  python -m pip install -r requirements.txt
fi

cd "$caller_dir"
export PYTHONPATH="$project_dir${PYTHONPATH:+:$PYTHONPATH}"
exec "$project_dir/.venv/bin/python" -m voiceshelf.cli "$@"


