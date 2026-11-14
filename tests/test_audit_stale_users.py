# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

"""Unit tests for script/openqa-audit-stale-users."""

import importlib.util
import json
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import requests
from typer.testing import CliRunner

script_path = str(Path("script/openqa-audit-stale-users").resolve())
loader = SourceFileLoader("audit_module", script_path)
spec = importlib.util.spec_from_loader("audit_module", loader)
if spec is None:
    msg = "Could not load script/openqa-audit-stale-users"
    raise ImportError(msg)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)


@pytest.fixture
def runner() -> CliRunner:
    return CliRunner()


@pytest.fixture
def sample_users() -> list[dict]:
    return [
        {
            "id": 1,
            "username": "system",
            "nickname": "system",
            "email": "system@example.com",
            "is_admin": 1,
            "is_operator": 1,
            "api_keys": [],
        },
        {
            "id": 2,
            "username": "admin",
            "nickname": "admin",
            "email": "admin@example.com",
            "is_admin": 1,
            "is_operator": 1,
            "api_keys": [],
        },
        {
            "id": 3,
            "username": "https://www.opensuse.org/openid/user/activeuser",
            "nickname": "activeuser",
            "email": "active@example.com",
            "is_admin": 0,
            "is_operator": 0,
            "api_keys": [{"key": "KEY1", "t_expiration": None}],
        },
        {
            "id": 4,
            "username": "staleuser1",
            "nickname": "staleuser1",
            "email": "stale1@example.com",
            "is_admin": 0,
            "is_operator": 1,
            "api_keys": [
                {"key": "KEY2", "t_expiration": None},
                {"key": "KEY3", "t_expiration": "2099-01-01T00:00:00Z"},
                {"key": "KEY4", "t_expiration": "2020-01-01T00:00:00Z"},
            ],
        },
        {
            "id": 5,
            "username": "https://openid.example.com/staleuser2",
            "nickname": None,
            "email": "stale2@example.com",
            "is_admin": 1,
            "is_operator": 0,
            "api_keys": [],
        },
    ]


def test_strip_openid_and_extract_nick() -> None:
    assert mod.strip_openid("https://www.opensuse.org/openid/user/arthur") == "arthur"
    assert mod.strip_openid("http://example.com/user/alice/") == "alice"
    assert mod.strip_openid("bob") == "bob"
    assert not mod.strip_openid(None)

    assert mod.extract_nick({"nickname": "artie", "username": "arthur"}) == "artie"
    assert mod.extract_nick({"username": "https://openid.camelot.uk/lancelot"}) == "lancelot"


def test_check_geekos() -> None:
    session = MagicMock()

    mock_200 = MagicMock()
    mock_200.status_code = 200
    session.get.return_value = mock_200
    assert mod.check_geekos(session, "https://geekos.test", "alice") == ("active", "Geekos: active")

    mock_404 = MagicMock()
    mock_404.status_code = 404
    session.get.return_value = mock_404
    assert mod.check_geekos(session, "https://geekos.test", "bob") == ("stale", "Geekos: user not found (404)")

    mock_500 = MagicMock()
    mock_500.status_code = 500
    session.get.return_value = mock_500
    assert mod.check_geekos(session, "https://geekos.test", "carol") == ("error", "Geekos error: HTTP 500")

    session.get.side_effect = requests.RequestException("connection failed")
    assert mod.check_geekos(session, "https://geekos.test", "dan")[0] == "error"


def test_check_ldap() -> None:
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout="suseudbenabled: 1\ndn: uid=u", stderr="")
        assert mod.check_ldap("ldaps://test", "dc=test", "alice") == ("active", "LDAP: enabled (suseudbenabled: 1)")

        mock_run.return_value = MagicMock(returncode=0, stdout="suseudbenabled: 0\ndn: uid=u", stderr="")
        assert mod.check_ldap("ldaps://test", "dc=test", "bob") == ("stale", "LDAP: disabled (suseudbenabled: 0)")

        mock_run.return_value = MagicMock(returncode=0, stdout="# numEntries: 0\n", stderr="")
        assert mod.check_ldap("ldaps://test", "dc=test", "carol") == ("stale", "LDAP: user not found in directory")

        mock_run.return_value = MagicMock(returncode=32, stdout="", stderr="No such object (32)")
        assert mod.check_ldap("ldaps://test", "dc=test", "dan") == ("stale", "LDAP: user not found in directory")

        mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="failed connection")
        assert mod.check_ldap("ldaps://test", "dc=test", "eve")[0] == "error"


def test_cli_option_validation(runner: CliRunner) -> None:
    res = runner.invoke(mod.app, ["--help"])
    assert res.exit_code == 0
    assert "--dry-run" in res.stdout
    assert "--apply" in res.stdout
    assert "--backend" in res.stdout

    res = runner.invoke(mod.app, ["--apply", "--dry-run"])
    assert res.exit_code != 0
    assert "Cannot specify both --apply and --dry-run" in res.stderr

    res = runner.invoke(mod.app, ["--backend", "unknown"])
    assert res.exit_code != 0
    assert "Invalid backend" in res.stderr

    res = runner.invoke(mod.app, ["--format", "unknown"])
    assert res.exit_code != 0
    assert "Invalid format" in res.stderr


def test_audit_dry_run_table(runner: CliRunner, sample_users: list[dict], tmp_path: Path) -> None:
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({"users": sample_users}), encoding="utf-8")

    def mock_get(url: str, **_kwargs: dict) -> MagicMock:
        res = MagicMock()
        if "activeuser" in url:
            res.status_code = 200
        else:
            res.status_code = 404
        return res

    with patch("requests.Session.get", side_effect=mock_get):
        res = runner.invoke(mod.app, ["--users-file", str(users_file)])
        assert res.exit_code == 0
        assert "staleuser1" in res.stdout
        assert "staleuser2" in res.stdout
        assert "activeuser" not in res.stdout
        assert "Total active users: 5" in res.stdout
        assert "Confirmed stale accounts: 2" in res.stdout
        assert "Active API keys held by stale accounts: 2" in res.stdout
        assert "Privileged roles held by stale accounts: 2" in res.stdout


def test_audit_json_and_csv(runner: CliRunner, sample_users: list[dict], tmp_path: Path) -> None:
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({"users": sample_users}), encoding="utf-8")

    def mock_get(url: str, **_kwargs: dict) -> MagicMock:
        res = MagicMock()
        res.status_code = 200 if "activeuser" in url else 404
        return res

    with patch("requests.Session.get", side_effect=mock_get):
        json_res = runner.invoke(mod.app, ["--users-file", str(users_file), "--format", "json"])
        assert json_res.exit_code == 0
        data = json.loads(json_res.stdout)
        assert data["summary"]["stale_accounts"] == 2
        assert data["summary"]["active_api_keys"] == 2
        assert len(data["stale_users"]) == 2

        csv_res = runner.invoke(mod.app, ["--users-file", str(users_file), "--format", "csv"])
        assert csv_res.exit_code == 0
        assert "id,username,nickname,email,is_admin,is_operator,api_keys,status,reason" in csv_res.stdout
        assert "staleuser1" in csv_res.stdout


def test_audit_both_backends(runner: CliRunner, sample_users: list[dict], tmp_path: Path) -> None:
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({"users": sample_users}), encoding="utf-8")

    def mock_get(_url: str, **_kwargs: dict) -> MagicMock:
        res = MagicMock()
        res.status_code = 404
        return res

    def mock_run(cmd: list[str], **_kwargs: dict) -> MagicMock:
        nick = cmd[6].replace("(uid=", "").replace(")", "")
        if nick == "staleuser1":
            return MagicMock(returncode=0, stdout="suseudbenabled: 0\ndn: uid=staleuser1", stderr="")
        if nick == "staleuser2":
            return MagicMock(returncode=0, stdout="# numEntries: 0\n", stderr="")
        return MagicMock(returncode=0, stdout="suseudbenabled: 1\ndn: uid=activeuser", stderr="")

    with patch("requests.Session.get", side_effect=mock_get), patch("subprocess.run", side_effect=mock_run):
        res = runner.invoke(mod.app, ["--users-file", str(users_file), "--backend", "both", "--format", "json"])
        assert res.exit_code == 0
        data = json.loads(res.stdout)
        assert data["summary"]["stale_accounts"] == 2


def test_audit_apply_mode(runner: CliRunner, sample_users: list[dict], tmp_path: Path) -> None:
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({"users": sample_users}), encoding="utf-8")

    def mock_get(url: str, **_kwargs: dict) -> MagicMock:
        res = MagicMock()
        res.status_code = 200 if "activeuser" in url else 404
        return res

    with patch("requests.Session.get", side_effect=mock_get), patch("subprocess.run") as mock_run:
        res = runner.invoke(mod.app, ["--users-file", str(users_file), "--apply"])
        assert res.exit_code == 0
        assert "Summary (applied):" in res.stdout
        assert "anonymized" in res.stdout
        assert mock_run.call_count == 2
