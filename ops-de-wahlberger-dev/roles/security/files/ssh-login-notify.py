#!/usr/bin/python3
"""Email the owner when someone logs in over SSH from a public address.

Deployed by the `security` role (SH-FR-125). Follows sshd's journal and, for
each "Accepted publickey" line whose source is outside the ignore list, sends
one email through Resend naming the user, the source address and the key
fingerprint.

Failing to send must never matter to the login (SH-E-32): the login already
happened, this only watches the log. A failed send is logged to stderr (the
journal) and the next line is processed; there is no retry.

Environment:
  HUSH_TOKEN, NOTIFY_FROM, NOTIFY_TO   from /etc/notify-failure/notify-failure.env
  SSH_LOGIN_NOTIFY_IGNORE   comma separated CIDRs/addresses that never trigger a mail
  SSH_LOGIN_NOTIFY_SOURCE   hush source id (default hooks-ops)
  SSH_LOGIN_NOTIFY_TEMPLATE HTML template (default /etc/ssh-login-notify/email-template.html);
                            if unreadable the mail goes out as plain text only

Usage: ssh-login-notify.py            follow the journal (the systemd service)
       ssh-login-notify.py --stdin    read journal lines from stdin (tests)
"""
import datetime
import html
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

HUSH_POST = "/usr/local/bin/hush-post"
HUSH_SOURCE_DEFAULT = "hooks-ops"
DEFAULT_TEMPLATE = "/etc/ssh-login-notify/email-template.html"
MAX_VALUE_LENGTH = 100
SEND_TIMEOUT_SECONDS = 15

# sshd logs e.g.:
#   Accepted publickey for alice from 203.0.113.9 port 51234 ssh2: ED25519 SHA256:abc...
ACCEPTED = re.compile(
    r"^Accepted publickey for (?P<user>\S+) from (?P<addr>\S+) port (?P<port>\d+)"
    r" ssh2: (?P<alg>\S+) (?P<fingerprint>SHA256:\S+)\s*$"
)


def log(message):
    print("ssh-login-notify: " + message, file=sys.stderr, flush=True)


def parse_ignore(raw):
    """Return the networks in the comma/space separated `raw`; bad entries are logged and skipped."""
    networks = []
    for entry in re.split(r"[,\s]+", raw.strip()):
        if not entry:
            continue
        try:
            networks.append(ipaddress.ip_network(entry, strict=False))
        except ValueError:
            log("ignoring invalid ignore-list entry %r" % entry)
    return networks


def parse_login(line):
    """Return the fields of an accepted public-key login line, or None."""
    match = ACCEPTED.match(line.strip())
    return match.groupdict() if match else None


def is_ignored(addr, networks):
    """True if `addr` is inside the ignore list. An unparsable address is NOT ignored: notify."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return any(ip.version == net.version and ip in net for net in networks)


_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]+")
_PLACEHOLDER = re.compile(r"@@([A-Z_]+)@@")


def clean(value):
    """Control characters (newlines included) become one space; overlong values are cut.

    Everything that ends up in the subject, the text or the HTML passes through here:
    the user name and more are chosen by whoever logs in.
    """
    value = _CONTROL.sub(" ", str(value)).strip()
    if len(value) > MAX_VALUE_LENGTH:
        value = value[: MAX_VALUE_LENGTH - 3] + "..."
    return value


def render_html(template, values):
    """Fill the @@NAME@@ placeholders of `template` with the HTML-escaped `values`.

    One pass over the template: substituted text is never scanned again, so a value
    such as '@@HOST@@' stays literal. Unknown placeholders are left as they are.
    """
    escaped = {key: html.escape(clean(value), quote=True) for key, value in values.items()}
    return _PLACEHOLDER.sub(lambda m: escaped.get(m.group(1), m.group(0)), template)


def load_template(env):
    """The HTML template, or None (logged) if it cannot be read: the mail then has no html part."""
    path = env.get("SSH_LOGIN_NOTIFY_TEMPLATE", DEFAULT_TEMPLATE)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        log("cannot read the email template %s, sending plain text only: %s" % (path, exc))
        return None


def build_payload(login, env, host, now, template=None):
    values = {
        "HOST": host, "TIME": now, "USER": login["user"], "ADDR": login["addr"],
        "PORT": login["port"], "ALG": login["alg"], "FINGERPRINT": login["fingerprint"],
    }
    c = {key: clean(value) for key, value in values.items()}
    subject = "[%s] SSH login from %s as %s" % (c["HOST"], c["ADDR"], c["USER"])
    text = (
        "A public-source SSH login succeeded on %s at %s.\n\n"
        "User: %s\nSource: %s (port %s)\nKey: %s %s\n\n"
        "If this was not you, treat the key as stolen: see the README incident note.\n"
    ) % (c["HOST"], c["TIME"], c["USER"], c["ADDR"], c["PORT"], c["ALG"], c["FINGERPRINT"])
    payload = {"from": env.get("NOTIFY_FROM", ""), "to": [env.get("NOTIFY_TO", "")], "subject": subject, "text": text}
    if template is not None:
        payload["html"] = render_html(template, values)
    return payload


def send(payload, env):
    """Post the login to hush as a problem event (hush sends the mail). Raises on any failure."""
    token = env.get("HUSH_TOKEN", "")
    if not token:
        raise RuntimeError("HUSH_TOKEN is empty")
    event = {
        "schema": "hush.event.v1",
        "host": socket.getfqdn(),
        "check": "ssh-login",
        "service": "",
        "status": "problem",
        "message": payload["subject"],
        "log_excerpt": payload["text"],
        "occurred_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    source = env.get("SSH_LOGIN_NOTIFY_SOURCE", HUSH_SOURCE_DEFAULT)
    with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
        json.dump(event, handle)
        handle.flush()
        subprocess.run(
            [HUSH_POST, source, "bearer", handle.name],
            env={**env, "HUSH_TOKEN": token},
            check=True,
            timeout=SEND_TIMEOUT_SECONDS,
        )


def process(lines, env, networks):
    """Handle journal lines; returns the number of mails sent successfully."""
    sent = 0
    host = socket.getfqdn()
    template = load_template(env)
    for line in lines:
        login = parse_login(line)
        if login is None or is_ignored(login["addr"], networks):
            continue
        payload = build_payload(login, env, host, time.strftime("%Y-%m-%d %H:%M:%S %Z"), template)
        try:
            send(payload, env)
            sent += 1
            log("mailed login of %s from %s" % (login["user"], login["addr"]))
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            # Never the key or the request: only the reason.
            log("sending the login mail for %s from %s failed: %s" % (login["user"], login["addr"], exc))
    return sent


def main(argv):
    env = dict(os.environ)
    networks = parse_ignore(env.get("SSH_LOGIN_NOTIFY_IGNORE", ""))
    if argv[1:] == ["--stdin"]:
        process(sys.stdin, env, networks)
        return 0
    if len(argv) > 1:
        print(__doc__, file=sys.stderr)
        return 2
    # --lines=0: only logins from now on, never old history after a restart.
    journal = subprocess.Popen(
        ["journalctl", "--unit=sshd.service", "--follow", "--lines=0", "--output=cat", "--no-pager"],
        stdout=subprocess.PIPE,
        text=True,
        errors="replace",
    )
    process(journal.stdout, env, networks)
    # journalctl ended (journald restart, ...): exit non-zero so systemd restarts us.
    return journal.wait() or 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
