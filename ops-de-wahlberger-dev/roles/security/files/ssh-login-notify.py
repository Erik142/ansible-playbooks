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
  RESEND_API_KEY, NOTIFY_FROM, NOTIFY_TO   from /etc/notify-failure/notify-failure.env
  SSH_LOGIN_NOTIFY_IGNORE   comma separated CIDRs/addresses that never trigger a mail
  SSH_LOGIN_NOTIFY_URL      Resend endpoint (default https://api.resend.com/emails)

Usage: ssh-login-notify.py            follow the journal (the systemd service)
       ssh-login-notify.py --stdin    read journal lines from stdin (tests)
"""
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = "https://api.resend.com/emails"
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


def build_payload(login, env, host, now):
    subject = "[%s] SSH login from %s as %s" % (host, login["addr"], login["user"])
    text = (
        "A public-source SSH login succeeded on %s at %s.\n\n"
        "User: %s\nSource: %s (port %s)\nKey: %s %s\n\n"
        "If this was not you, treat the key as stolen: see the README incident note.\n"
    ) % (host, now, login["user"], login["addr"], login["port"], login["alg"], login["fingerprint"])
    return {"from": env.get("NOTIFY_FROM", ""), "to": [env.get("NOTIFY_TO", "")], "subject": subject, "text": text}


def send(payload, env):
    """POST the mail to Resend. Raises on any failure; the caller logs it."""
    api_key = env.get("RESEND_API_KEY", "")
    if not api_key:
        raise RuntimeError("RESEND_API_KEY is empty")
    request = urllib.request.Request(
        env.get("SSH_LOGIN_NOTIFY_URL", DEFAULT_URL),
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
            # Resend sits behind Cloudflare, which rejects urllib's default agent.
            "User-Agent": "ssh-login-notify/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=SEND_TIMEOUT_SECONDS):
        pass


def process(lines, env, networks):
    """Handle journal lines; returns the number of mails sent successfully."""
    sent = 0
    host = socket.getfqdn()
    for line in lines:
        login = parse_login(line)
        if login is None or is_ignored(login["addr"], networks):
            continue
        payload = build_payload(login, env, host, time.strftime("%Y-%m-%d %H:%M:%S %Z"))
        try:
            send(payload, env)
            sent += 1
            log("mailed login of %s from %s" % (login["user"], login["addr"]))
        except (OSError, RuntimeError, urllib.error.URLError) as exc:
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
