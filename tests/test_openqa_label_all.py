# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

"""Tests for script/openqa-label-all."""

import argparse
import logging
import runpy
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from pytest_mock import MockerFixture

_script_path = Path(__file__).resolve().parent.parent / "script" / "openqa-label-all"
_loader = SourceFileLoader("openqa_label_all", str(_script_path))
_spec = spec_from_loader(_loader.name, _loader)
assert _spec is not None
openqa_label_all = module_from_spec(_spec)
sys.modules["openqa_label_all"] = openqa_label_all
_loader.exec_module(openqa_label_all)

default_host = "https://openqa.suse.de"


@pytest.fixture(autouse=True)
def _reset_module_globals(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(openqa_label_all, "openqa_cmd", [])
    monkeypatch.setattr(openqa_label_all, "args", argparse.Namespace())


def _invoke_main(
    mocker: MockerFixture, jobs: list[dict], *argv: str, url: str = default_host, existing_comments: str = ""
) -> tuple[MagicMock, MagicMock]:
    response = mocker.Mock(url=f"{url}/api/v1/jobs")
    response.json.return_value = {"jobs": jobs}
    get = mocker.patch.object(openqa_label_all.requests, "get", return_value=response)
    openqa_call = mocker.patch.object(openqa_label_all, "_openqa_call")
    mocker.patch.object(openqa_label_all, "_comments", return_value=existing_comments)
    mocker.patch.object(sys, "argv", ["openqa-label-all", "--module", "module", *argv])
    return get, openqa_call


def _job(job_id: int, module_name: str = "module", module_result: str = "failed") -> dict:
    return {"id": job_id, "modules": [{"name": module_name, "result": module_result}]}


def test_setup_parser_defaults() -> None:
    args = openqa_label_all._setup_parser().parse_args(["--module", "module"])
    assert args.verbose == 1
    assert args.build is None
    assert args.groupid is None
    assert args.openqa_host == default_host
    assert args.result == "failed"
    assert not args.label
    assert args.dry_run is False
    assert args.no_restart is False
    assert args.timeout == 60


@pytest.mark.parametrize(
    ("description", "verbosity_flags", "expected_level"),
    [
        ("default verbosity logs errors", [], logging.ERROR),
        ("one -v logs warnings", ["-v"], logging.WARNING),
        ("two -v log info", ["-v", "-v"], logging.INFO),
        ("three -v log debug", ["-v", "-v", "-v"], logging.DEBUG),
        ("verbosity above the mapping logs debug", ["-v"] * 5, logging.DEBUG),
    ],
)
def test_parse_args_maps_verbosity_to_log_level(
    description: str, verbosity_flags: list[str], expected_level: int, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "argv", ["openqa-label-all", "--module", "module", *verbosity_flags])
    openqa_label_all._parse_args()
    assert openqa_label_all.log.level == expected_level, description


@pytest.mark.parametrize(
    ("description", "dry_run", "expected_command"),
    [
        ("dry run only simulates the command", True, ["echo", "Simulating: ", "openqa-cli", "api"]),
        ("real run executes the command", False, ["openqa-cli", "api"]),
    ],
)
def test_call_prepends_simulation_only_for_dry_run(
    description: str, expected_command: list[str], *, dry_run: bool, mocker: MockerFixture
) -> None:
    run = mocker.patch.object(openqa_label_all.subprocess, "run", return_value=mocker.Mock(returncode=3))
    assert openqa_label_all._call(["openqa-cli", "api"], argparse.Namespace(dry_run=dry_run)) == 3, description
    run.assert_called_once_with(expected_command, check=True)


def test_openqa_call_appends_to_openqa_cmd(mocker: MockerFixture, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(openqa_label_all, "openqa_cmd", ["openqa-cli", "api"])
    monkeypatch.setattr(openqa_label_all, "args", argparse.Namespace(dry_run=True))
    run = mocker.patch.object(openqa_label_all.subprocess, "run", return_value=mocker.Mock(returncode=0))
    assert openqa_label_all._openqa_call(["-X", "post", "jobs/1/restart"]) == 0
    run.assert_called_once_with(
        ["echo", "Simulating: ", "openqa-cli", "api", "-X", "post", "jobs/1/restart"], check=True
    )


def test_comments_joins_comment_texts(mocker: MockerFixture, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(openqa_label_all, "openqa_cmd", ["openqa-cli", "api"])
    run = mocker.patch.object(
        openqa_label_all.subprocess, "run", return_value=mocker.Mock(stdout=b'[{"text": "first"}, {"text": "second"}]')
    )
    assert openqa_label_all._comments({"id": 42}) == "first second"
    run.assert_called_once_with(["openqa-cli", "api", "jobs/42/comments"], capture_output=True, check=True)


@pytest.mark.parametrize(
    ("description", "existing_comments", "expected"),
    [
        ("a job without the label needs it", "", True),
        ("a job with the label does not need it", "ticket#12345", False),
    ],
)
def test_needs_label(
    description: str, existing_comments: str, *, expected: bool, monkeypatch: pytest.MonkeyPatch, mocker: MockerFixture
) -> None:
    monkeypatch.setattr(openqa_label_all, "_comments", mocker.Mock(return_value=existing_comments))
    assert openqa_label_all._needs_label("ticket#12345", {"id": 1}) is expected, description


def test_main_returns_61_without_matching_jobs(mocker: MockerFixture) -> None:
    get, openqa_call = _invoke_main(mocker, [])
    assert openqa_label_all._main() == 61
    get.assert_called_once_with(
        f"{default_host}/api/v1/jobs",
        params={"result": "failed", "latest": 1, "scope": "relevant"},
        timeout=60,
    )
    openqa_call.assert_not_called()


def test_main_passes_group_build_and_defaults_host_scheme(mocker: MockerFixture) -> None:
    get, _ = _invoke_main(
        mocker,
        [_job(1)],
        "--groupid",
        "5",
        "--build",
        "20261125",
        "--openqa-host",
        "openqa.example.com",
        url="https://openqa.example.com",
    )
    openqa_label_all._main()
    get.assert_called_once_with(
        "https://openqa.example.com/api/v1/jobs",
        params={"result": "failed", "latest": 1, "scope": "relevant", "groupid": "5", "build": "20261125"},
        timeout=60,
    )


def test_main_makes_no_calls_without_matching_module(mocker: MockerFixture) -> None:
    _, openqa_call = _invoke_main(mocker, [_job(1, module_name="other")])
    assert openqa_label_all._main() == 0
    openqa_call.assert_not_called()


def test_main_labels_and_restarts_jobs_with_the_failing_module(mocker: MockerFixture) -> None:
    jobs = [_job(1), _job(2, module_name="other"), _job(3, module_result="passed"), _job(4)]
    _, openqa_call = _invoke_main(mocker, jobs, "--label", "ticket#12345")
    assert openqa_label_all._main() == 0
    assert [call.args[0] for call in openqa_call.call_args_list] == [
        ["-X", "post", "jobs/1/comments", "text=ticket#12345"],
        ["-X", "post", "jobs/4/comments", "text=ticket#12345"],
        ["-X", "post", "jobs/1/restart"],
        ["-X", "post", "jobs/4/restart"],
    ]


def test_main_skips_jobs_that_already_carry_the_label(mocker: MockerFixture) -> None:
    _, openqa_call = _invoke_main(mocker, [_job(1)], "--label", "ticket#12345", existing_comments="ticket#12345")
    assert openqa_label_all._main() == 0
    assert [call.args[0] for call in openqa_call.call_args_list] == [["-X", "post", "jobs/1/restart"]]


def test_main_does_not_restart_with_no_restart(mocker: MockerFixture) -> None:
    _, openqa_call = _invoke_main(mocker, [_job(1)], "--label", "ticket#12345", "--no-restart")
    assert openqa_label_all._main() == 0
    assert [call.args[0] for call in openqa_call.call_args_list] == [
        ["-X", "post", "jobs/1/comments", "text=ticket#12345"]
    ]


def test_module_runs_main_when_executed_as_script(mocker: MockerFixture, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "argv", ["openqa-label-all", "--module", "module"])
    response = mocker.Mock(url=f"{default_host}/api/v1/jobs")
    response.json.return_value = {"jobs": []}
    get = mocker.patch.object(openqa_label_all.requests, "get", return_value=response)
    runpy.run_path(str(_script_path), run_name="__main__")
    get.assert_called_once()
