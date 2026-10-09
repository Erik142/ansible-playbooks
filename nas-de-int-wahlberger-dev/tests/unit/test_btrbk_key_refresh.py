"""Tests for roles/btrbk/files/btrbk-key-refresh.py (BD-FR-162 to BD-FR-168).

Fakes stand in for curl, gpg, rpm, zypper (one ``Runner``) and the clock.
"""

from __future__ import annotations

import importlib.util
import io
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "roles/btrbk/files/btrbk-key-refresh.py"
PINNED = "B1FB53748720472205FA601998C97FE7324E6311"
OTHER = "A" * 40
URL = "https://download.opensuse.org/x/repodata/repomd.xml.key"
DAY = 86400
NOW = 1_800_000_000


@pytest.fixture(scope="module")
def mod():
    spec = importlib.util.spec_from_file_location("btrbk_key_refresh", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["btrbk_key_refresh"] = module
    spec.loader.exec_module(module)
    return module


def colons(fpr: str = PINNED, expires: str = "", extra_pub: bool = False, subs: int = 1) -> str:
    lines = [f"pub:-:4096:1:98C97FE7324E6311:1:{expires}::::scESC:::+:::23::0:", f"fpr:::::::::{fpr}:"]
    for i in range(subs):
        lines += [f"sub:-:4096:1:{i:016X}:1::::::e:::+:::23:", f"fpr:::::::::{'B' * 39}{i}:"]
    if extra_pub:
        lines += ["pub:-:4096:1:1111111111111111:1:::::scESC:::+:::23::0:", f"fpr:::::::::{OTHER}:"]
    return "\n".join(lines) + "\n"


class Host:
    """Fake command runner; records argv, answers per binary."""

    def __init__(self, gpg_out: str, curl=0, rpm=0, zypper=0):
        self.gpg_out, self.status = gpg_out, {"curl": curl, "rpm": rpm, "zypper": zypper}
        self.calls: list[list[str]] = []

    def __call__(self, argv):
        self.calls.append(list(argv))
        name = argv[0]
        if name == "gpg":
            return 0, self.gpg_out
        return self.status[name], "" if self.status[name] == 0 else f"{name} boom"

    def names(self) -> list[str]:
        return [c[0] for c in self.calls]


def run(mod, host, warn_days=60, url=URL, fpr=PINNED):
    out = io.StringIO()
    code = mod.refresh_key(
        url=url, fingerprint=fpr, alias="filesystems", warn_days=warn_days,
        run=host, now=lambda: NOW, out=out,
    )  # fmt: skip
    return code, out.getvalue()


class TestParseKeyInfo:
    def test_single_key_returns_fingerprint_and_epoch_expiry(self, mod):
        info = mod.parse_key_info(colons(expires="1809000000"))
        assert info == mod.KeyInfo(PINNED, 1_809_000_000)

    def test_empty_expiry_field_means_never_expires(self, mod):
        assert mod.parse_key_info(colons(expires="")).expires_at is None

    def test_lowercase_fingerprint_is_normalised(self, mod):
        assert mod.parse_key_info(colons(fpr=PINNED.lower())).fingerprint == PINNED

    def test_second_primary_key_is_rejected(self, mod):
        with pytest.raises(mod.KeyMismatch, match="exactly one primary key"):
            mod.parse_key_info(colons(extra_pub=True))

    def test_no_key_is_rejected(self, mod):
        with pytest.raises(mod.KeyMismatch, match="0 pub"):
            mod.parse_key_info("")

    def test_malformed_fingerprint_is_rejected(self, mod):
        with pytest.raises(mod.KeyMismatch, match="malformed"):
            mod.parse_key_info(colons(fpr="XYZ"))

    def test_iso_date_expiry_is_rejected_not_guessed(self, mod):
        with pytest.raises(mod.KeyMismatch, match="unreadable expiry"):
            mod.parse_key_info(colons(expires="2027-05-07"))


class TestDaysUntil:
    def test_never_expires_is_none(self, mod):
        assert mod.days_until(None, NOW) is None

    def test_exactly_sixty_days(self, mod):
        assert mod.days_until(NOW + 60 * DAY, NOW) == 60

    def test_one_second_short_of_sixty_floors_to_fifty_nine(self, mod):
        assert mod.days_until(NOW + 60 * DAY - 1, NOW) == 59

    def test_expiry_now_is_zero(self, mod):
        assert mod.days_until(NOW, NOW) == 0

    def test_expired_one_second_ago_is_minus_one(self, mod):
        assert mod.days_until(NOW - 1, NOW) == -1


class TestRefreshKey:
    def test_matching_key_far_from_expiry_imports_refreshes_and_exits_0(self, mod):
        host = Host(colons(expires=str(NOW + 200 * DAY)))
        code, text = run(mod, host)
        assert code == 0
        assert host.names() == ["curl", "gpg", "rpm", "zypper"]
        assert host.calls[2][:2] == ["rpm", "--import"]
        assert host.calls[3] == ["zypper", "--non-interactive", "refresh", "filesystems"]
        assert "expires in 200 days" in text

    def test_key_without_expiry_exits_0(self, mod):
        code, text = run(mod, Host(colons(expires="")))
        assert code == 0
        assert "never expires" in text

    def test_fetch_uses_https_only_and_a_timeout(self, mod):
        host = Host(colons())
        run(mod, host)
        curl = host.calls[0]
        assert curl[curl.index("--proto") + 1] == "=https"
        assert "--max-time" in curl and curl[-1] == URL

    def test_fingerprint_mismatch_fails_loudly_and_never_imports(self, mod):
        host = Host(colons(fpr=OTHER, expires=str(NOW + 900 * DAY)))
        code, text = run(mod, host)
        assert code == mod.EXIT_KEY_MISMATCH == 2
        assert "rpm" not in host.names() and "zypper" not in host.names()
        assert OTHER in text and PINNED in text and "osc signkey filesystems" in text

    def test_second_primary_key_never_imports(self, mod):
        host = Host(colons(extra_pub=True))
        code, _ = run(mod, host)
        assert code == 2
        assert "rpm" not in host.names()

    def test_pinned_fingerprint_comparison_ignores_case(self, mod):
        host = Host(colons(expires=str(NOW + 200 * DAY)))
        code, _ = run(mod, host, fpr=PINNED.lower())
        assert code == 0

    def test_fetch_failure_exits_3_without_gpg_or_import(self, mod):
        host = Host(colons(), curl=22)
        code, text = run(mod, host)
        assert code == 3
        assert host.names() == ["curl"]
        assert "cannot fetch" in text and "curl boom" in text

    def test_non_https_url_is_refused_before_any_command(self, mod):
        host = Host(colons())
        code, _ = run(mod, host, url="http://example.org/key")
        assert code == 3
        assert host.calls == []

    def test_key_near_expiry_is_imported_then_fails_with_days_left(self, mod):
        host = Host(colons(expires=str(NOW + 59 * DAY + 10)))
        code, text = run(mod, host)
        assert code == 1
        assert host.names() == ["curl", "gpg", "rpm", "zypper"]  # renewal still tried
        assert "expires in 59 days (< 60)" in text

    def test_key_exactly_at_threshold_passes(self, mod):
        code, _ = run(mod, Host(colons(expires=str(NOW + 60 * DAY))))
        assert code == 0

    def test_expired_key_is_imported_and_reported(self, mod):
        host = Host(colons(expires=str(NOW - 3 * DAY)))
        code, text = run(mod, host)
        assert code == 1
        assert "rpm" in host.names()
        assert "expires in -3 days" in text

    def test_zypper_refresh_failure_is_reported_even_when_key_is_fresh(self, mod):
        host = Host(colons(expires=str(NOW + 300 * DAY)), zypper=106)
        code, text = run(mod, host)
        assert code == 1
        assert "zypper refresh filesystems failed (exit 106)" in text

    def test_rpm_import_failure_is_reported_and_refresh_still_runs(self, mod):
        host = Host(colons(expires=str(NOW + 300 * DAY)), rpm=1)
        code, text = run(mod, host)
        assert code == 1
        assert "rpm --import failed (exit 1)" in text
        assert "zypper" in host.names()

    def test_all_problems_are_listed_together(self, mod):
        host = Host(colons(expires=str(NOW + DAY)), zypper=106)
        _, text = run(mod, host)
        assert "zypper refresh" in text and "expires in 1 days" in text

    def test_scratch_key_file_is_removed_after_the_run(self, mod):
        host = Host(colons())
        run(mod, host)
        key_file = host.calls[0][host.calls[0].index("--output") + 1]
        assert not Path(key_file).exists()


def test_run_command_reports_missing_binary_as_127(mod):
    status, text = mod.run_command(["/nonexistent/binary-xyz"])
    assert status == 127 and "not found" in text
