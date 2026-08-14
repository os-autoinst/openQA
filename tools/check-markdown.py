#!/usr/bin/env python3

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

"""Script to run style, syntax, and consistency checks on Markdown documents."""

import re
from pathlib import Path
from typing import Annotated

import typer

app = typer.Typer()

anchor_pattern = re.compile(r'<a\s+(?:id|name)="([^"]+)"')
markdown_link_pattern = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
MIN_PARTS_FOR_ANCHOR = 2


def _get_anchors_from_file(file_path: Path) -> list[str]:
    content = file_path.read_text(encoding="utf-8")
    return [match.group(1) for match in anchor_pattern.finditer(content)]


def _get_markdown_links_from_file(file_path: Path) -> list[str]:
    content = file_path.read_text(encoding="utf-8")
    return [match.group(1) for match in markdown_link_pattern.finditer(content)]


def _get_anchor_keys_from_markdown(markdown_files: list[Path]) -> dict[str, tuple[str, str]]:
    return {f"{f.name}#{anchor}": (f.name, anchor) for f in markdown_files for anchor in _get_anchors_from_file(f)}


def _resolve_target_anchor_key(source_file_name: str, link_target: str) -> str | None:
    if link_target.lower().startswith("http"):
        return None
    link_parts = link_target.split("#")
    if len(link_parts) < MIN_PARTS_FOR_ANCHOR:
        return None
    file_part, anchor_part = link_parts[0], link_parts[1]
    resolved_file_name = file_part or source_file_name
    return f"{resolved_file_name}#{anchor_part}"


def _get_referenced_keys_from_markdown(markdown_files: list[Path]) -> set[str]:
    return {
        resolved_key
        for f in markdown_files
        for link in _get_markdown_links_from_file(f)
        if (resolved_key := _resolve_target_anchor_key(f.name, link)) is not None
    }


def _get_source_files() -> list[Path]:
    extensions = ("*.pm", "*.ep", "*.js", "*.pl", "*.t", "*.sh")
    return [
        f
        for ext in extensions
        for f in Path().glob(f"**/{ext}")
        if "node_modules" not in f.parts
        and ".git" not in f.parts
        and "local" not in f.parts
        and "cover_db" not in f.parts
        and "external" not in f.parts
    ]


def _get_source_file_contents() -> list[str]:
    return [f.read_text(encoding="utf-8") for f in _get_source_files() if f.exists()]


def _get_referenced_keys_from_source(defined_anchors: dict[str, tuple[str, str]], file_contents: list[str]) -> set[str]:
    return {
        key
        for key, (file_name, anchor) in defined_anchors.items()
        if any(f"{file_name}#{anchor}" in content for content in file_contents)
    }


@app.command()
def check_anchors(
    docs_dir_path: Annotated[
        Path, typer.Option("--docs-dir", "-d", help="Path to the documentation directory containing Markdown files.")
    ] = Path("docs"),
) -> None:
    """Verify that all explicit HTML anchors in Markdown documents are referenced.

    This tool scans all Markdown files for explicit HTML anchors (e.g. <a id="anchor">)
    and checks if they are referenced anywhere in markdown links or codebase source files.
    If any unused anchors are found, the tool exits with a non-zero code.
    """
    if not docs_dir_path.exists() or not docs_dir_path.is_dir():
        typer.echo(f"Error: Directory {docs_dir_path} does not exist.", err=True)
        raise typer.Exit(code=1)

    markdown_files = list(docs_dir_path.glob("**/*.md"))
    defined_anchors = _get_anchor_keys_from_markdown(markdown_files)

    referenced_in_markdown = _get_referenced_keys_from_markdown(markdown_files)
    file_contents = _get_source_file_contents()
    referenced_in_source = _get_referenced_keys_from_source(defined_anchors, file_contents)

    used_anchors = referenced_in_markdown.union(referenced_in_source)

    unused_anchors = [
        f"{anchor} (defined in docs/{file_name})"
        for key, (file_name, anchor) in defined_anchors.items()
        if key not in used_anchors
    ]

    if unused_anchors:
        typer.echo("Error: Found unused HTML anchors in documentation:", err=True)
        for item in sorted(unused_anchors):
            typer.echo(f"  - {item}", err=True)
        raise typer.Exit(code=1)

    typer.echo("All explicit markdown anchors are used successfully.")


if __name__ == "__main__":
    app()
