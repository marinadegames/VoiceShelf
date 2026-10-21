from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from functools import lru_cache
from typing import Any


@dataclass(frozen=True)
class TranscriptSegment:
    start: float
    end: float
    text: str

    def as_dict(self) -> dict[str, Any]:
        return {"start": self.start, "end": self.end, "text": self.text}


_model_lock = threading.Lock()
_active_install_lock = threading.Lock()
_active_install_process: subprocess.Popen[str] | None = None

WHISPER_MODELS = ("tiny", "base", "small", "medium", "large-v3")
OLLAMA_BASE_URL = "http://127.0.0.1:11434"


def cancel_active_install() -> None:
    """Stop an installer child process before the worker exits."""
    with _active_install_lock:
        process = _active_install_process
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def _find_ollama() -> str | None:
    configured = os.getenv("OLLAMA_BINARY")
    candidates = (
        configured,
        shutil.which("ollama"),
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    )
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def whisper_model_status(model_name: str) -> dict[str, Any]:
    """Report whether a faster-whisper model is already present locally."""
    if model_name not in WHISPER_MODELS:
        raise ValueError(f"Неизвестная модель Whisper: {model_name}")
    try:
        from faster_whisper.utils import download_model

        path = download_model(model_name, local_files_only=True)
        return {"model": model_name, "installed": True, "path": path}
    except Exception as exc:
        return {
            "model": model_name,
            "installed": False,
            "path": None,
            "detail": str(exc),
        }


def install_whisper_model(model_name: str) -> dict[str, Any]:
    """Download the selected Whisper model into the local Hugging Face cache."""
    if model_name not in WHISPER_MODELS:
        raise ValueError(f"Неизвестная модель Whisper: {model_name}")
    from faster_whisper.utils import download_model

    with _model_lock:
        path = download_model(model_name)
    return {"model": model_name, "installed": True, "path": path}


@lru_cache(maxsize=3)
def _load_whisper(model_name: str, device: str, compute_type: str):
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:  # pragma: no cover - depends on optional runtime
        raise RuntimeError(
            "faster-whisper не установлен. Выполните: pip install -r requirements.txt"
        ) from exc

    return WhisperModel(model_name, device=device, compute_type=compute_type)


def transcribe_file(
    path: str,
    *,
    model_name: str = "small",
    language: str | None = None,
    device: str = "auto",
    vocabulary: str = "",
) -> dict[str, Any]:
    """Transcribe media locally. Model downloads once and is then cached on disk."""
    media = os.path.abspath(path)
    if not os.path.isfile(media):
        raise ValueError(f"Файл записи не найден: {media}")
    if os.path.getsize(media) < 512:
        raise ValueError("Файл записи пуст или не успел сохраниться. Запишите заметку ещё раз.")
    compute_type = "int8" if device in {"auto", "cpu"} else "float16"
    with _model_lock:
        model = _load_whisper(model_name, device, compute_type)

    segments_iter, info = model.transcribe(
        media,
        language=language or None,
        initial_prompt=(
            "Русская речь может содержать английские термины. "
            "Сохраняй английские слова латиницей. "
            f"Возможные термины: {vocabulary.strip()}"
        ),
        beam_size=5,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 500},
        condition_on_previous_text=True,
    )
    segments = [
        TranscriptSegment(round(s.start, 2), round(s.end, 2), s.text.strip())
        for s in segments_iter
        if s.text.strip()
    ]
    return {
        "text": " ".join(segment.text for segment in segments),
        "segments": [segment.as_dict() for segment in segments],
        "language": info.language,
        "language_probability": round(info.language_probability, 3),
        "duration": round(info.duration, 2),
        "model": model_name,
    }


def _sentences(text: str) -> list[str]:
    clean = re.sub(r"\s+", " ", text).strip()
    if not clean:
        return []
    return [s.strip(" -–—") for s in re.split(r"(?<=[.!?])\s+", clean) if s.strip()]


def heuristic_organize(text: str) -> dict[str, Any]:
    """Useful no-LLM fallback: extract summary, tasks, decisions, and notes."""
    sentences = _sentences(text)
    task_words = re.compile(
        r"\b(надо|нужно|сделать|купить|позвонить|написать|проверить|не забыть|"
        r"задач[аи]|должен|планирую|need to|todo|must|should)\b",
        re.IGNORECASE,
    )
    decision_words = re.compile(
        r"\b(решил[аи]?|решение|договорились|выбираем|итого|значит|"
        r"decided|decision|agreed)\b",
        re.IGNORECASE,
    )
    question_words = re.compile(r"\?|\b(вопрос|уточнить|выяснить|почему|как|когда)\b", re.I)

    decisions = [s for s in sentences if decision_words.search(s)]
    tasks = [s for s in sentences if task_words.search(s) and s not in decisions]
    questions = [s for s in sentences if question_words.search(s)]
    used = set(tasks + decisions + questions)
    notes = [s for s in sentences if s not in used]
    summary = " ".join(sentences[:3])

    return {
        "title": _make_title(sentences),
        "summary": summary,
        "tasks": tasks,
        "decisions": decisions,
        "questions": questions,
        "notes": notes,
        "engine": "offline-rules",
    }


def _make_title(sentences: list[str]) -> str:
    if not sentences:
        return "Пустая заметка"
    words = re.findall(r"[\wА-Яа-яЁё-]+", sentences[0])[:8]
    title = " ".join(words)
    return title[:1].upper() + title[1:] if title else "Голосовая заметка"


def _ollama_request(text: str, model: str, base_url: str) -> dict[str, Any]:
    prompt = f"""Ты редактор голосовых заметок. Разложи текст по полочкам.
Верни ТОЛЬКО валидный JSON без markdown с ключами:
title (короткий заголовок), summary (2-4 предложения), tasks (массив),
decisions (массив), questions (массив), notes (массив тематических тезисов).
Не выдумывай факты. Сохрани язык исходника.

Текст:
{text}
"""
    payload = json.dumps(
        {"model": model, "prompt": prompt, "stream": False, "format": "json"}
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        body = json.loads(response.read().decode("utf-8"))
    result = json.loads(body["response"])
    result["engine"] = f"ollama:{model}"
    return result


def check_ollama_model(
    model: str = "qwen2.5:7b", base_url: str | None = None
) -> dict[str, Any]:
    """Check the local Ollama server and model without silently degrading."""
    url = (base_url or OLLAMA_BASE_URL).rstrip("/")
    try:
        with urllib.request.urlopen(f"{url}/api/tags", timeout=3) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return {
            "available": False,
            "model_installed": False,
            "message": "Ollama не запущена. Запустите приложение Ollama.",
            "detail": str(exc),
        }
    names = sorted(str(item.get("name", "")) for item in payload.get("models", []))
    installed = model in names
    return {
        "available": True,
        "model_installed": installed,
        "ollama_path": _find_ollama(),
        "installed_models": names,
        "message": (
            f"Модель {model} готова"
            if installed
            else f"Модель {model} не установлена. Выполните: ollama pull {model}"
        ),
    }


def install_ollama_model(model: str) -> dict[str, Any]:
    """Start Ollama if needed and pull one explicitly selected model."""
    global _active_install_process
    status = ensure_ollama_running(model)
    binary = status.get("ollama_path") or _find_ollama()
    if not binary:
        raise RuntimeError("Ollama не установлена. Установите Ollama, затем повторите попытку.")
    process = subprocess.Popen(
        [binary, "pull", model],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    with _active_install_lock:
        _active_install_process = process
    try:
        stdout, stderr = process.communicate(timeout=7200)
    except subprocess.TimeoutExpired as exc:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
        raise RuntimeError(f"Установка {model} не завершилась за 2 часа") from exc
    finally:
        with _active_install_lock:
            if _active_install_process is process:
                _active_install_process = None
    if process.returncode != 0:
        detail = (stderr or stdout).strip()
        raise RuntimeError(f"Не удалось установить {model}: {detail[-1200:]}")
    result = check_ollama_model(model)
    result["install_output"] = (stdout or stderr).strip()[-1200:]
    return result


def ensure_ollama_running(model: str = "qwen2.5:7b") -> dict[str, Any]:
    """Start the local Ollama service when installed, then report model readiness."""
    status = check_ollama_model(model)
    if status["available"]:
        return status
    binary = _find_ollama()
    if not binary:
        return {
            "available": False,
            "model_installed": False,
            "ollama_path": None,
            "message": "Ollama не установлена",
        }
    kwargs: dict[str, Any] = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "stdin": subprocess.DEVNULL,
    }
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen([binary, "serve"], **kwargs)
    except OSError as exc:
        return {
            "available": False,
            "model_installed": False,
            "ollama_path": binary,
            "message": f"Не удалось запустить Ollama: {exc}",
        }
    for _ in range(24):
        time.sleep(0.25)
        status = check_ollama_model(model)
        if status["available"]:
            status["autostarted"] = True
            return status
    return {
        "available": False,
        "model_installed": False,
        "ollama_path": binary,
        "message": "Ollama установлена, но сервер не запустился",
    }


def organize_text(
    text: str,
    *,
    engine: str = "auto",
    ollama_model: str = "qwen2.5:7b",
) -> dict[str, Any]:
    if not text.strip():
        raise ValueError("Нет текста для обработки")
    if engine == "rules":
        return heuristic_organize(text)

    base_url = OLLAMA_BASE_URL
    status = check_ollama_model(ollama_model, base_url)
    if not status["available"]:
        raise RuntimeError(status["message"])
    if not status["model_installed"]:
        raise RuntimeError(status["message"])
    try:
        return _ollama_request(text, ollama_model, base_url)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as exc:
        raise RuntimeError(f"Ollama не смогла обработать заметку: {exc}") from exc


def diagram_from_organized(data: dict[str, Any]) -> dict[str, Any]:
    """Return a small, renderer-agnostic tree consumed by the web UI."""
    root = {"label": str(data.get("title") or "Заметка"), "children": []}
    sections = [
        ("Главное", [data.get("summary")] if data.get("summary") else []),
        ("Задачи", data.get("tasks") or []),
        ("Решения", data.get("decisions") or []),
        ("Вопросы", data.get("questions") or []),
        ("Тезисы", data.get("notes") or []),
    ]
    for label, items in sections:
        normalized = [str(item).strip() for item in items if str(item).strip()]
        if normalized:
            root["children"].append(
                {"label": label, "children": [{"label": item} for item in normalized[:8]]}
            )
    return root


def organized_to_markdown(data: dict[str, Any]) -> str:
    lines = [f"# {data.get('title', 'Голосовая заметка')}", ""]
    if data.get("summary"):
        lines.extend([str(data["summary"]), ""])
    for key, title in (
        ("tasks", "Задачи"),
        ("decisions", "Решения"),
        ("questions", "Открытые вопросы"),
        ("notes", "Тезисы"),
    ):
        items = data.get(key) or []
        if items:
            lines.extend([f"## {title}", *[f"- {item}" for item in items], ""])
    return "\n".join(lines).strip() + "\n"

