#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export XDG_CONFIG_HOME="$(pwd)/.tools/config"
export PUB_CACHE="$(pwd)/.tools/pub-cache"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export FLUTTER_NO_UPDATE_CHECK=true
export HF_HOME="$(pwd)/.tools/huggingface"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Не найден Python 3. Установите Python 3.9 или новее."
  exit 1
fi

flutter_bin="$(pwd)/.tools/flutter/bin/flutter"
if [ ! -x "$flutter_bin" ] && command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
fi

if [ ! -x "$flutter_bin" ]; then
  echo "Не найден Flutter SDK. Установите его: https://docs.flutter.dev/get-started/install"
  echo "После установки снова запустите ./start.sh"
  exit 1
fi

if [ ! -d ".venv" ]; then
  echo "Создаю локальное окружение…"
  python3 -m venv .venv
fi

source .venv/bin/activate

if ! python -c "import faster_whisper" >/dev/null 2>&1; then
  echo "Один раз устанавливаю локальные зависимости…"
  python -m pip install --upgrade pip
  python -m pip install -r requirements.txt
fi

platform="linux"
if [ "$(uname -s)" = "Darwin" ]; then
  platform="macos"
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Для сборки macOS нужен полный Xcode из App Store (сейчас стоят только Command Line Tools)."
    echo "После установки выполните: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "Затем снова запустите ./start.sh"
    exit 1
  fi
fi

if [ ! -d "desktop_ui/$platform" ]; then
  echo "Один раз создаю платформенные файлы Flutter…"
  (cd desktop_ui && "$flutter_bin" create --platforms=macos,windows,linux .)
fi

echo "Запускаю VoiceShelf как отдельное desktop-приложение…"
export VOICESHELF_PYTHON="$(pwd)/.venv/bin/python"
export VOICESHELF_ROOT="$(pwd)"
if [ "$platform" = "macos" ]; then
  app_path="$(pwd)/desktop_ui/build/macos/Build/Products/Release/VoiceShelf.app"
  app_executable="$app_path/Contents/MacOS/VoiceShelf"
  newest_source="$(find desktop_ui/lib desktop_ui/macos -type f -newer "$app_executable" -print -quit 2>/dev/null || true)"
  if [ ! -x "$app_executable" ] || [ -n "$newest_source" ]; then
    echo "Исходники изменились — пересобираю VoiceShelf…"
    (cd desktop_ui && "$flutter_bin" build macos --release)
  fi
  open -n --env "VOICESHELF_PYTHON=$VOICESHELF_PYTHON" --env "VOICESHELF_ROOT=$VOICESHELF_ROOT" --env "HF_HOME=$HF_HOME" "$app_path"
else
  (cd desktop_ui && "$flutter_bin" run -d "$platform")
fi

