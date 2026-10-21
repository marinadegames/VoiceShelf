#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "DMG можно собрать только на macOS." >&2
  exit 1
fi

flutter_bin="$project_dir/.tools/flutter/bin/flutter"
if [ ! -x "$flutter_bin" ]; then
  flutter_bin="$(command -v flutter || true)"
fi
if [ -z "$flutter_bin" ]; then
  echo "Flutter не найден. Установите Flutter 3.47.7+ и повторите запуск." >&2
  exit 1
fi

if [ ! -x "$project_dir/.venv/bin/python" ]; then
  echo "Сначала создайте окружение: python3 -m venv .venv" >&2
  exit 1
fi
if ! "$project_dir/.venv/bin/python" -c "import PyInstaller" >/dev/null 2>&1; then
  echo "Не найден PyInstaller. Выполните:" >&2
  echo "  .venv/bin/python -m pip install -r requirements-build.txt" >&2
  exit 1
fi

export XDG_CONFIG_HOME="$project_dir/.tools/config"
export PUB_CACHE="$project_dir/.tools/pub-cache"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export FLUTTER_NO_UPDATE_CHECK=true
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "1/4 · Собираю Flutter-приложение…"
(cd desktop_ui && "$flutter_bin" build macos --release)

echo "2/4 · Упаковываю локальный Python-движок…"
"$project_dir/.venv/bin/pyinstaller" \
  --noconfirm \
  --clean \
  --workpath "$project_dir/packaging/build/pyinstaller" \
  --distpath "$project_dir/packaging/build/worker" \
  "$project_dir/packaging/voiceshelf-worker.spec"

app="$project_dir/desktop_ui/build/macos/Build/Products/Release/VoiceShelf.app"
resources="$app/Contents/Resources"
worker_target="$resources/worker"
mkdir -p "$worker_target"
ditto "$project_dir/packaging/build/worker/voiceshelf-worker" "$worker_target"

identity="${CODESIGN_IDENTITY:--}"
echo "3/4 · Подписываю приложение ($identity)…"
if [ "$identity" = "-" ]; then
  codesign --force --deep \
    --entitlements "$project_dir/desktop_ui/macos/Runner/Release.entitlements" \
    --sign - "$app"
else
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$project_dir/desktop_ui/macos/Runner/Release.entitlements" \
    --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"

echo "4/4 · Создаю DMG с ярлыком «Программы»…"
mkdir -p "$project_dir/dist"
stage="$(mktemp -d /tmp/voiceshelf-dmg.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/VoiceShelf.app"
ln -s /Applications "$stage/Applications"
dmg="$project_dir/dist/VoiceShelf-0.1.0-macOS-arm64.dmg"
hdiutil create -quiet -ov -format UDZO -volname VoiceShelf -srcfolder "$stage" "$dmg"

if [ "$identity" != "-" ]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi

echo "Готово: $dmg"
