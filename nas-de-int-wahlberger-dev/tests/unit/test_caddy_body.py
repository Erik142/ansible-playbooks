"""Tests for `caddy_sites[].body` of roles/caddy (GS-FR-95 to GS-FR-97, GS-FR-130).

Byte-identity with the template on master (GS-FR-96), `caddy adapt` of the O-6
body (GS-AC-57), and the validation failures (GS-E-23, GS-AC-58 local half).
The validation cases run the role on localhost with an empty Cloudflare token:
the site check runs first and fails naming the host; if it ever passed, the
token assert right after it would stop the role before any change.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

NAS = Path(__file__).resolve().parents[2]
REPO = NAS.parent
TEMPLATE = NAS / "roles/caddy/templates/Caddyfile.j2"
VENV_BIN = Path.home() / ".pyenv/versions/ansible-bind9-venv/bin"
ANSIBLE = shutil.which("ansible-playbook") or (
    str(VENV_BIN / "ansible-playbook") if (VENV_BIN / "ansible-playbook").exists() else None
)
pytestmark = pytest.mark.skipif(ANSIBLE is None, reason="ansible-playbook not available")

EXISTING = [
    {"host": "recipes.example.test", "upstream": "tandoor:80"},
    {"host": "docs.example.test", "upstream": "paperless:8000", "extra": "encode gzip"},
    {"host": "blank.example.test", "upstream": "x:1", "extra": ""},
]
O6_BODY = """@web {
\tmethod GET HEAD
\theader !Authorization
\tnot query X-Amz-Signature=*
\tpath_regexp bucket ^/([^/]+)(/.*)?$
}
handle @web {
\trewrite * {re.bucket.2}
\treverse_proxy garage:3902 {
\t\theader_up Host {re.bucket.1}
\t}
}
handle {
\treverse_proxy garage:3900
}
"""


def run(args, tmp_path, **kw):
    env = {**os.environ, "ANSIBLE_LOCAL_TEMP": str(tmp_path / "tmp"), "ANSIBLE_NOCOLOR": "1",
           "ANSIBLE_CONFIG": str(tmp_path / "ansible.cfg"), "ANSIBLE_ROLES_PATH": str(NAS / "roles")}
    (tmp_path / "ansible.cfg").write_text("[defaults]\nretry_files_enabled = false\nlocalhost_warning = false\n")
    return subprocess.run(args, env=env, capture_output=True, text=True, cwd=tmp_path, timeout=120, **kw)


def render(tmp_path, sites, template=TEMPLATE):
    play = tmp_path / "render.yml"
    out = tmp_path / "Caddyfile"
    play.write_text(
        "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n"
        "    - ansible.builtin.template:\n"
        f"        src: {template}\n        dest: {out}\n        mode: '0644'\n"
    )
    vars_file = tmp_path / "vars.json"
    vars_file.write_text(json.dumps({"caddy_sites": sites, "caddy_acme_email": "a@example.test"}))
    proc = run([ANSIBLE, "-i", "localhost,", "-e", f"@{vars_file}", str(play)], tmp_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return out.read_text()


def test_entries_without_body_render_identically_to_master(tmp_path):
    """GS-FR-96, GS-AC-57 second bullet."""
    git = subprocess.run(
        ["git", "show", "master:nas-de-int-wahlberger-dev/roles/caddy/templates/Caddyfile.j2"],
        cwd=REPO, capture_output=True, text=True,
    )
    if git.returncode != 0:
        pytest.skip("master template not available")
    old = tmp_path / "old.j2"
    old.write_text(git.stdout)
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    assert render(tmp_path / "a", EXISTING, old) == render(tmp_path / "b", EXISTING)


def test_body_renders_block_without_generated_reverse_proxy(tmp_path):
    """GS-FR-95, GS-AC-57 first bullet."""
    text = render(tmp_path, [{"host": "a.example.test", "body": O6_BODY}])
    block = text[text.index("a.example.test {"):]
    assert block.count("reverse_proxy") == 2
    assert "".join(block.split()) == "a.example.test{" + "".join(O6_BODY.split()) + "}"


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")
def test_caddy_adapt_accepts_rendered_body(tmp_path):
    text = render(tmp_path, [*EXISTING[:1], {"host": "a.example.test", "body": O6_BODY}])
    # acme_dns needs the cloudflare module; adapt only the site blocks.
    sites = text[text.index("recipes.example.test"):]
    (tmp_path / "Caddyfile.sites").write_text(sites)
    proc = subprocess.run(
        ["docker", "run", "--rm", "-v", f"{tmp_path}:/c:ro", "caddy:2",
         "caddy", "adapt", "--config", "/c/Caddyfile.sites", "--adapter", "caddyfile"],
        capture_output=True, text=True, timeout=300,
    )
    assert proc.returncode == 0, proc.stderr


@pytest.mark.parametrize(
    "site",
    [
        {"host": "a.example.test", "body": "respond 200", "upstream": "x:1"},
        {"host": "a.example.test", "body": "respond 200", "extra": "encode gzip"},
        {"host": "a.example.test"},
    ],
)
def test_invalid_site_fails_naming_host(tmp_path, site):
    """GS-FR-97, GS-E-23, GS-AC-58 local half."""
    play = tmp_path / "play.yml"
    play.write_text("- hosts: localhost\n  connection: local\n  gather_facts: false\n  roles:\n    - role: caddy\n")
    vars_file = tmp_path / "vars.json"
    vars_file.write_text(json.dumps({
        "caddy_sites": [site], "caddy_data_dir": str(tmp_path / "caddy"),
        "cloudflare_dns_api_token": "",
    }))
    proc = run([ANSIBLE, "-i", "localhost,", "-e", f"@{vars_file}", str(play)], tmp_path)
    out = proc.stdout + proc.stderr
    assert proc.returncode != 0
    assert "a.example.test" in out and "is invalid" in out
    assert not (tmp_path / "caddy").exists()


def test_valid_sites_pass_validation(tmp_path):
    """A valid body entry gets past the site check (stops at the empty token)."""
    play = tmp_path / "play.yml"
    play.write_text("- hosts: localhost\n  connection: local\n  gather_facts: false\n  roles:\n    - role: caddy\n")
    vars_file = tmp_path / "vars.json"
    vars_file.write_text(json.dumps({
        "caddy_sites": [{"host": "a.example.test", "body": "respond 200"}, *EXISTING],
        "caddy_data_dir": str(tmp_path / "caddy"), "cloudflare_dns_api_token": "",
    }))
    proc = run([ANSIBLE, "-i", "localhost,", "-e", f"@{vars_file}", str(play)], tmp_path)
    out = proc.stdout + proc.stderr
    assert "is invalid" not in out and "cloudflare_dns_api_token is empty" in out
    assert not (tmp_path / "caddy").exists()
