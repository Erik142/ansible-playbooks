"""Unit tests for roles/security/files/ssh-login-notify.py (SH-FR-125): the HTML
login email must escape everything the login controls, substitute in one pass,
and keep the Resend payload shape. The script is a standalone file, so it is
imported by path. Stdlib + pytest only; no network."""
import importlib.util
import io
import re
import urllib.request
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[2]
SCRIPT = OPS / "roles/security/files/ssh-login-notify.py"
TEMPLATE = OPS / "roles/security/templates/login-email-template.html.j2"

ENV = {"NOTIFY_FROM": "Alerts <a@example.test>", "NOTIFY_TO": "owner@example.test", "RESEND_API_KEY": "k-secret"}
HOSTILE = [
    "<script>alert(1)</script>",
    '"><img src=x onerror=alert(1)>',
    "@@HOST@@",
    "a\nBcc: evil@example.test",
    "u" * 5000,
    "@@HOST@@<b>",
]


@pytest.fixture(scope="module")
def mod():
    spec = importlib.util.spec_from_file_location("ssh_login_notify", SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


@pytest.fixture(scope="module")
def template():
    # The Jinja comment on line 1 is the only Ansible-side syntax in the file.
    text = TEMPLATE.read_text(encoding="utf-8")
    assert "{{" not in text and "{%" not in text
    return re.sub(r"\{#.*?#\}\n?", "", text, flags=re.S)


def login(user="alice", addr="203.0.113.9"):
    return {"user": user, "addr": addr, "port": "51234", "alg": "ED25519", "fingerprint": "SHA256:abc"}


def tags_of(html_text):
    return set(re.findall(r"<\s*([a-zA-Z0-9]+)", html_text))


def test_payload_shape(mod, template):
    p = mod.build_payload(login(), ENV, "host.example", "2026-01-01 10:00:00 UTC", template)
    assert set(p) == {"from", "to", "subject", "text", "html"}
    assert p["from"] == ENV["NOTIFY_FROM"] and p["to"] == [ENV["NOTIFY_TO"]]
    assert p["subject"] == "[host.example] SSH login from 203.0.113.9 as alice"
    assert "User: alice" in p["text"] and "Source: 203.0.113.9 (port 51234)" in p["text"]
    assert "@@" not in p["html"]
    for needle in ("host.example", "alice", "203.0.113.9", "51234", "SHA256:abc", "2026-01-01 10:00:00 UTC"):
        assert needle in p["html"]


def test_no_template_means_text_only(mod):
    assert "html" not in mod.build_payload(login(), ENV, "h", "t")


def test_template_covers_known_placeholders(mod, template):
    assert set(re.findall(r"@@([A-Z_]+)@@", template)) <= {"HOST", "TIME", "USER", "ADDR", "PORT", "ALG", "FINGERPRINT"}


@pytest.mark.parametrize("user", HOSTILE)
def test_hostile_user_is_escaped(mod, template, user):
    baseline = tags_of(mod.build_payload(login(), ENV, "h.example", "t", template)["html"])
    p = mod.build_payload(login(user=user), ENV, "h.example", "t", template)
    # No tag may appear that the template itself does not contain.
    assert tags_of(p["html"]) == baseline
    assert "<script" not in p["html"] and "<img" not in p["html"]
    assert "\n" not in p["subject"] and "\r" not in p["subject"]
    assert len(p["subject"]) < 400 and len(p["text"]) < 1000


def test_exact_escaped_forms(mod, template):
    p = mod.build_payload(login(user="<script>"), ENV, "h", "t", template)
    assert "&lt;script&gt;" in p["html"]
    p = mod.build_payload(login(user='"><img src=x onerror=alert(1)>'), ENV, "h", "t", template)
    assert "&quot;&gt;&lt;img src=x onerror=alert(1)&gt;" in p["html"]


def test_substitution_is_not_reentrant(mod, template):
    p = mod.build_payload(login(user="@@HOST@@"), ENV, "real-host", "t", template)
    # The literal text survives once (as the user), HOST appears only where the template put it.
    assert p["html"].count("@@HOST@@") == 1
    assert "User</td><td style=\"color:#1b1f24;word-break:break-all;\">@@HOST@@<" in p["html"]


def test_hostname_and_other_values_are_escaped_too(mod, template):
    p = mod.build_payload(login(addr="<b>"), ENV, "<i>h</i>", "<u>", template)
    for raw in ("<b>", "<i>", "<u>"):
        assert raw not in p["html"]
    assert "&lt;i&gt;h&lt;/i&gt;" in p["html"]


def test_newline_in_subject_stripped(mod, template):
    p = mod.build_payload(login(user="a\r\nBcc: x@example.test"), ENV, "h", "t", template)
    assert "\n" not in p["subject"] and "\r" not in p["subject"]
    # The injected line break must not start a new line in the text part.
    assert "\nBcc:" not in p["text"]


def test_long_value_is_capped(mod, template):
    p = mod.build_payload(login(user="u" * 5000), ENV, "h", "t", template)
    assert "u" * 101 not in p["html"] and "u" * 101 not in p["text"]


def test_send_posts_json_with_bearer(mod, monkeypatch):
    seen = {}

    def fake_urlopen(request, timeout):
        seen.update(url=request.full_url, method=request.get_method(), headers=dict(request.header_items()),
                    body=request.data, timeout=timeout)
        return io.BytesIO(b"{}")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    payload = {"from": "f", "to": ["t"], "subject": "s", "text": "x", "html": "<p>x</p>"}
    mod.send(payload, ENV)
    import json
    assert seen["url"] == mod.DEFAULT_URL and seen["method"] == "POST"
    assert seen["headers"]["Authorization"] == "Bearer k-secret"
    assert seen["headers"]["Content-type"] == "application/json"
    assert json.loads(seen["body"]) == payload


def test_process_sends_html_and_text(mod, template, tmp_path, monkeypatch):
    tpl = tmp_path / "t.html"
    tpl.write_text(template, encoding="utf-8")
    sent = []
    monkeypatch.setattr(mod, "send", lambda payload, env: sent.append(payload))
    env = dict(ENV, SSH_LOGIN_NOTIFY_TEMPLATE=str(tpl))
    lines = [
        "Accepted publickey for <script> from 203.0.113.9 port 1 ssh2: ED25519 SHA256:x\n",
        "Accepted publickey for bob from 10.0.0.1 port 1 ssh2: ED25519 SHA256:y\n",
    ]
    assert mod.process(lines, env, mod.parse_ignore("10.0.0.0/8")) == 1
    assert len(sent) == 1 and "&lt;script&gt;" in sent[0]["html"] and "text" in sent[0]


def test_missing_template_falls_back_to_text(mod, tmp_path, monkeypatch, capsys):
    sent = []
    monkeypatch.setattr(mod, "send", lambda payload, env: sent.append(payload))
    env = dict(ENV, SSH_LOGIN_NOTIFY_TEMPLATE=str(tmp_path / "nope.html"))
    line = "Accepted publickey for bob from 203.0.113.9 port 1 ssh2: ED25519 SHA256:y\n"
    assert mod.process([line], env, []) == 1
    assert "html" not in sent[0] and "text" in sent[0]
    assert "plain text only" in capsys.readouterr().err
