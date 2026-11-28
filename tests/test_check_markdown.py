# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

"""Tests for the explicit anchor checker in tools/check-markdown.py."""

import runpy
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from types import ModuleType

import pytest
import typer
from pytest_mock import MockerFixture
from typer.testing import CliRunner


def _load_check_markdown() -> ModuleType:
    loader = SourceFileLoader("check_markdown", "tools/check-markdown.py")
    spec = spec_from_loader(loader.name, loader)
    assert spec is not None
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


check_markdown = _load_check_markdown()
runner = CliRunner()


def test_get_anchors_from_file_selects_id_and_name_attributes(tmp_path: Path) -> None:
    markdown_file = tmp_path / "file.md"
    markdown_file.write_text('<a id="first"></a>\n<a name="second"></a>\n<a href="ignored"></a>\n', encoding="utf-8")
    assert check_markdown._get_anchors_from_file(markdown_file) == ["first", "second"]


def test_get_markdown_links_from_file_returns_link_targets(tmp_path: Path) -> None:
    markdown_file = tmp_path / "file.md"
    markdown_file.write_text("[relative](other.md#anchor) and [absolute](https://example.com)\n", encoding="utf-8")
    assert check_markdown._get_markdown_links_from_file(markdown_file) == ["other.md#anchor", "https://example.com"]


def test_get_anchor_keys_from_markdown_keys_by_file_name_and_anchor(tmp_path: Path) -> None:
    first = tmp_path / "first.md"
    first.write_text('<a id="one"></a>\n', encoding="utf-8")
    second = tmp_path / "second.md"
    second.write_text('<a id="two"></a><a id="three"></a>\n', encoding="utf-8")
    assert check_markdown._get_anchor_keys_from_markdown([first, second]) == {
        "first.md#one": ("first.md", "one"),
        "second.md#two": ("second.md", "two"),
        "second.md#three": ("second.md", "three"),
    }


@pytest.mark.parametrize(
    ("description", "link_target", "expected"),
    [
        ("http link is not an anchor reference", "http://example.com/page#anchor", None),
        ("https link is not an anchor reference", "https://example.com/page#anchor", None),
        ("link without fragment is not an anchor reference", "other.md", None),
        ("empty file part refers to the source file", "#anchor", "source.md#anchor"),
        ("relative file with anchor", "other.md#anchor", "other.md#anchor"),
    ],
)
def test_resolve_target_anchor_key(description: str, link_target: str, expected: str | None) -> None:
    assert check_markdown._resolve_target_anchor_key("source.md", link_target) == expected, description


def test_get_referenced_keys_from_markdown_resolves_only_anchor_links(tmp_path: Path) -> None:
    markdown_file = tmp_path / "file.md"
    markdown_file.write_text(
        "[a](other.md#anchor) [b](#local) [c](https://example.com/page#anchor)\n", encoding="utf-8"
    )
    assert check_markdown._get_referenced_keys_from_markdown([markdown_file]) == {
        "other.md#anchor",
        "file.md#local",
    }


def test_get_source_files_skips_ignored_directories_and_extensions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    for ignored_dir in ("node_modules", ".git", "local", "cover_db", "external"):
        (tmp_path / ignored_dir).mkdir()
        (tmp_path / ignored_dir / "ignored.pm").write_text("", encoding="utf-8")
    (tmp_path / "nested").mkdir()
    (tmp_path / "nested" / "kept.pm").write_text("", encoding="utf-8")
    (tmp_path / "ignored.txt").write_text("", encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    assert check_markdown._get_source_files() == [Path("nested/kept.pm")]


def test_get_source_file_contents_skips_vanished_files(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    existing = tmp_path / "existing.pm"
    existing.write_text("file.md#anchor", encoding="utf-8")
    monkeypatch.setattr(check_markdown, "_get_source_files", lambda: [existing, tmp_path / "vanished.pm"])
    assert check_markdown._get_source_file_contents() == ["file.md#anchor"]


def test_get_referenced_keys_from_source_selects_referenced_keys() -> None:
    defined_anchors = {"file.md#used": ("file.md", "used"), "file.md#unused": ("file.md", "unused")}
    assert check_markdown._get_referenced_keys_from_source(defined_anchors, ["see file.md#used"]) == {"file.md#used"}


def test_check_anchors_fails_for_missing_directory(tmp_path: Path) -> None:
    result = runner.invoke(check_markdown.app, ["--docs-dir", str(tmp_path / "missing")])
    assert result.exit_code == 1
    assert "does not exist" in result.output


def test_check_anchors_fails_for_file_instead_of_directory(tmp_path: Path) -> None:
    docs_file = tmp_path / "docs"
    docs_file.write_text("", encoding="utf-8")
    result = runner.invoke(check_markdown.app, ["--docs-dir", str(docs_file)])
    assert result.exit_code == 1
    assert "does not exist" in result.output


def test_check_anchors_fails_for_unused_anchor(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    docs_dir = tmp_path / "docs"
    docs_dir.mkdir()
    (docs_dir / "file.md").write_text('<a id="unused"></a>\n', encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    result = runner.invoke(check_markdown.app, ["--docs-dir", "docs"])
    assert result.exit_code == 1
    assert "unused (defined in docs/file.md)" in result.output


def test_check_anchors_passes_for_anchor_referenced_from_source(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    docs_dir = tmp_path / "docs"
    docs_dir.mkdir()
    (docs_dir / "file.md").write_text('<a id="anchor"></a>\n', encoding="utf-8")
    lib_dir = tmp_path / "lib"
    lib_dir.mkdir()
    (lib_dir / "x.pm").write_text("# see file.md#anchor\n", encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    result = runner.invoke(check_markdown.app, ["--docs-dir", "docs"])
    assert result.exit_code == 0
    assert "All explicit markdown anchors are used successfully." in result.output


def test_module_runs_app_when_executed_as_script(mocker: MockerFixture) -> None:
    app_call = mocker.patch.object(typer.Typer, "__call__")
    runpy.run_path("tools/check-markdown.py", run_name="__main__")
    app_call.assert_called_once()
