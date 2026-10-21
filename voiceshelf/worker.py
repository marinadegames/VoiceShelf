"""JSON-lines bridge between the Flutter UI and local Python models."""

from __future__ import annotations

import json
import signal
import sys
from typing import Any

from .core import (
    WHISPER_MODELS,
    cancel_active_install,
    check_ollama_model,
    diagram_from_organized,
    organize_text,
    organized_to_markdown,
    transcribe_file,
    ensure_ollama_running,
    install_ollama_model,
    install_whisper_model,
    whisper_model_status,
)


def _stop_worker(_signal_number: int, _frame: object) -> None:
    cancel_active_install()
    raise SystemExit(0)


def handle(request: dict[str, Any]) -> dict[str, Any]:
    action = request.get("action")
    if action == "ping":
        return {"ok": True, "local": True}
    if action == "organizer_status":
        model = str(request.get("model", "qwen2.5:7b"))
        status = ensure_ollama_running(model) if request.get("autostart", True) else check_ollama_model(model)
        return {"ok": True, "model": model, **status}
    if action == "models_status":
        ollama_model = str(request.get("ollama_model", "qwen2.5:7b"))
        ollama = ensure_ollama_running(ollama_model) if request.get("autostart", True) else check_ollama_model(ollama_model)
        whisper = [whisper_model_status(name) for name in WHISPER_MODELS]
        return {
            "ok": True,
            "python": sys.executable,
            "whisper": whisper,
            "ollama": {"model": ollama_model, **ollama},
        }
    if action == "install_whisper":
        return {"ok": True, **install_whisper_model(str(request["model"]))}
    if action == "install_ollama":
        return {"ok": True, "model": str(request["model"]), **install_ollama_model(str(request["model"]))}
    if action == "transcribe":
        result = transcribe_file(
            str(request["path"]),
            model_name=str(request.get("model", "small")),
            language=request.get("language") or None,
            device=str(request.get("device", "auto")),
            vocabulary=str(request.get("vocabulary", ""))[:1000],
        )
        return {"ok": True, "result": result}
    if action == "organize":
        result = organize_text(
            str(request.get("text", "")),
            engine=str(request.get("engine", "ollama")),
            ollama_model=str(request.get("ollama_model", "qwen2.5:7b")),
        )
        result["markdown"] = organized_to_markdown(result)
        result["diagram"] = diagram_from_organized(result)
        return {"ok": True, "result": result}
    raise ValueError(f"Неизвестная команда: {action}")


def main() -> None:
    signal.signal(signal.SIGTERM, _stop_worker)
    signal.signal(signal.SIGINT, _stop_worker)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = handle(request)
        except Exception as exc:
            response = {"ok": False, "error": str(exc), "type": type(exc).__name__}
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()

