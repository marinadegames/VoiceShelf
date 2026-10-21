"""Console interface for local audio/video transcription."""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path
from typing import Any, Sequence

from .core import transcribe_file


MEDIA_SUFFIXES = {
    ".mp3",
    ".wav",
    ".m4a",
    ".aac",
    ".flac",
    ".ogg",
    ".opus",
    ".webm",
    ".mp4",
    ".mov",
    ".mkv",
    ".avi",
    ".mpeg",
    ".mpg",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="voiceshelf",
        description=(
            "Локально расшифровывает аудио или видео и сохраняет чистый текст "
            "в Markdown-файл рядом с исходником."
        ),
    )
    parser.add_argument(
        "media",
        nargs="?",
        type=Path,
        help="путь к аудио или видео; без аргумента откроется консольный выбор",
    )
    parser.add_argument(
        "-m",
        "--model",
        default="small",
        choices=("tiny", "base", "small", "medium", "large-v3"),
        help="модель Whisper (по умолчанию: small)",
    )
    parser.add_argument(
        "-l",
        "--language",
        default="auto",
        choices=("auto", "ru", "en"),
        help="язык: auto, ru или en (по умолчанию: auto)",
    )
    parser.add_argument(
        "-t",
        "--terms",
        default="",
        help='частые имена и английские термины, например "Figma, Notion, Андрей"',
    )
    parser.add_argument(
        "--timestamps",
        action="store_true",
        help="добавить таймкоды перед фрагментами",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="свой путь результата; по умолчанию <имя исходника>.md",
    )
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="перезаписать существующий Markdown-файл",
    )
    return parser


def discover_media(directory: Path) -> list[Path]:
    try:
        paths = [
            path
            for path in directory.iterdir()
            if path.is_file() and path.suffix.lower() in MEDIA_SUFFIXES
        ]
    except OSError:
        return []
    return sorted(paths, key=lambda path: path.name.lower())


def _clean_dropped_path(value: str) -> Path:
    """Accept normal paths and paths dragged into common terminal applications."""
    value = value.strip()
    if not value:
        raise ValueError("Путь не указан")
    try:
        parts = shlex.split(value)
        if len(parts) == 1:
            value = parts[0]
    except ValueError:
        value = value.strip("'\"")
    return Path(value).expanduser()


def choose_media(directory: Path) -> Path:
    candidates = discover_media(directory)
    print("\nVoiceShelf CLI — локальная расшифровка\n")
    if candidates:
        print("Файлы в текущей папке:")
        for index, path in enumerate(candidates, start=1):
            print(f"  {index:>2}. {path.name}")
        print("\nВведите номер или перетащите сюда другой файл.")
    else:
        print("В текущей папке нет аудио или видео.")
        print("Перетащите файл в окно терминала и нажмите Enter.")

    while True:
        try:
            answer = input("\nФайл: ").strip()
        except (EOFError, KeyboardInterrupt) as exc:
            print("\nОтменено.", file=sys.stderr)
            raise SystemExit(130) from exc
        if candidates and answer.isdigit():
            index = int(answer)
            if 1 <= index <= len(candidates):
                return candidates[index - 1]
        try:
            path = _clean_dropped_path(answer)
        except ValueError:
            print("Введите номер или путь к файлу.")
            continue
        if path.is_file():
            return path
        print(f"Файл не найден: {path}")


def validate_media(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"Файл не найден: {path}")
    if path.suffix.lower() not in MEDIA_SUFFIXES:
        supported = ", ".join(sorted(MEDIA_SUFFIXES))
        raise ValueError(f"Неподдерживаемый формат {path.suffix}. Поддерживаются: {supported}")
    return path


def choose_output(media: Path, requested: Path | None, force: bool) -> Path:
    output = requested.expanduser() if requested else media.with_suffix(".md")
    if not output.is_absolute():
        output = (Path.cwd() / output).resolve()
    if force or not output.exists():
        return output

    counter = 2
    while True:
        candidate = output.with_name(f"{output.stem}-{counter}{output.suffix}")
        if not candidate.exists():
            return candidate
        counter += 1


def render_text(result: dict[str, Any], timestamps: bool = False) -> str:
    if not timestamps:
        return str(result.get("text", "")).strip() + "\n"
    lines = []
    for segment in result.get("segments", []):
        seconds = int(float(segment["start"]))
        lines.append(f"[{seconds // 60:02d}:{seconds % 60:02d}] {segment['text']}")
    return "\n\n".join(lines).strip() + "\n"


def run(argv: Sequence[str] | None = None) -> Path:
    args = build_parser().parse_args(argv)
    media = validate_media(args.media if args.media else choose_media(Path.cwd()))
    output = choose_output(media, args.output, args.force)

    print(f"\nИсточник: {media}", file=sys.stderr)
    print(f"Модель:   Whisper {args.model} (локально)", file=sys.stderr)
    print("Расшифровываю… Первый запуск может скачать модель один раз.", file=sys.stderr)

    result = transcribe_file(
        str(media),
        model_name=args.model,
        language=None if args.language == "auto" else args.language,
        vocabulary=args.terms,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_text(result, args.timestamps), encoding="utf-8")
    print(f"\nГотово: {output}", file=sys.stderr)
    return output


def main() -> None:
    try:
        run()
    except (ValueError, RuntimeError, OSError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()

