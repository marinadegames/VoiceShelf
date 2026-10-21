from voiceshelf.core import diagram_from_organized, heuristic_organize, organized_to_markdown
from voiceshelf.cli import choose_output, render_text


def test_heuristic_organize_russian_note():
    note = (
        "Обсудили запуск проекта. Решили выпустить первую версию в пятницу. "
        "Нужно позвонить дизайнеру. Когда будет готов макет?"
    )
    result = heuristic_organize(note)
    assert result["title"].startswith("Обсудили")
    assert len(result["tasks"]) == 1
    assert len(result["decisions"]) == 1
    assert len(result["questions"]) == 1


def test_diagram_omits_empty_sections():
    tree = diagram_from_organized({"title": "План", "tasks": ["Сделать MVP"]})
    assert tree["label"] == "План"
    assert [section["label"] for section in tree["children"]] == ["Задачи"]


def test_diagram_keeps_full_text():
    long_text = "Очень длинный текст " * 30
    tree = diagram_from_organized({"title": "План", "notes": [long_text]})
    assert tree["children"][0]["children"][0]["label"] == long_text.strip()


def test_markdown_export():
    text = organized_to_markdown({"title": "План", "summary": "Коротко", "tasks": ["MVP"]})
    assert text.startswith("# План")
    assert "## Задачи\n- MVP" in text


def test_cli_plain_text_has_no_heading():
    result = {
        "text": "Привет, это чистая расшифровка.",
        "segments": [{"start": 3.0, "text": "Привет, это чистая расшифровка."}],
    }
    assert render_text(result) == "Привет, это чистая расшифровка.\n"
    assert render_text(result, timestamps=True).startswith("[00:03]")


def test_cli_does_not_overwrite_existing_file(tmp_path):
    media = tmp_path / "note.m4a"
    media.touch()
    (tmp_path / "note.md").touch()
    assert choose_output(media, None, force=False).name == "note-2.md"

