"""Negative tests for tests/static-checks.sh: one seeded defect per check, plus
a green baseline and the SKIPPED semantics (PLAN.md T-14)."""
import json
import re
import shutil
import subprocess

import pytest

from conftest import C, EXAMPLE, N, OPS_REAL, V, VARS, line_for, status

OPS_VARS = V + "/" + VARS
NAS_VARS = N + "/" + VARS
CLOUD_VARS = C + "/" + VARS
FAST = ("SH-AC-01,SH-AC-17,SH-AC-23,SH-AC-30,SH-AC-44,SH-AC-45,SH-AC-56,SH-AC-60,SH-FR-205")

NEW_KEY = ("from=\"203.0.113.9,10.243.1.5,172.29.30.0/24\" ssh-ed25519 "
           "AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXA semaphore-automation@ops.de.wahlberger.dev")


BAD_GUARD = """---
- name: bad
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.fail: {msg: seeded guard failure}
"""
STAGE_GUARD = """---
- name: stage
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.assert:
        that: (lookup('ansible.builtin.env', 'STATIC_CHECKS_STAGE') | default('A', true)) == 'A'
"""


OLD_BODY_REGEX = r"ssh_authorized_keys_body_regex: '^(?:.*?\s)?(?:ssh-\S+|ecdsa-sha2-\S+|sk-\S+)\s+(\S+)'"


def must_fail(repo, ident, needle, **env):
    rc, out = repo.static(ident, **env)
    assert status(out, ident) == "FAIL", out
    assert rc == 1, out
    assert needle in out, out


def test_baseline_all_fast_checks_pass(repo):
    rc, out = repo.static(FAST)
    assert rc == 0, out
    for ident in FAST.split(","):
        assert status(out, ident) == "PASS", out


# --- SH-AC-01 ------------------------------------------------------------------
@pytest.mark.parametrize("old,new,needle", [
    ("      tags: [semaphore]\n", "      tags: [other]\n", "tags must be"),
    ("    - role: restic_backup\n", "    - role: extra\n      tags: [extra]\n    - role: restic_backup\n", "site.yml roles"),
])
def test_ac01_site_yml_defects(repo, old, new, needle):
    repo.edit(V + "/site.yml", old, new)
    must_fail(repo, "SH-AC-01", needle)


SPEC = "semaphore-migration/reqs/semaphore-to-hetzner.md"


RESTIC_ENTRY = "    - role: restic_backup\n      tags: [restic_backup]\n"


def test_ac01_role_missing_from_site_yml(repo):
    repo.edit(V + "/site.yml", RESTIC_ENTRY, "")
    must_fail(repo, "SH-AC-01", "only in spec ['restic_backup']")


def test_ac01_role_added_to_site_yml_without_spec(repo):
    repo.edit(V + "/site.yml", RESTIC_ENTRY, RESTIC_ENTRY + "    - role: extra_role\n      tags: [extra_role]\n")
    must_fail(repo, "SH-AC-01", "only in site.yml ['extra_role']")


def test_ac01_spec_is_the_source_new_role_in_spec(repo):
    # The spec names a role that site.yml does not wire: the spec, not this script, decides.
    repo.edit(SPEC, "`restic_backup`.\n  - Amendment 2026-10-24", "`restic_backup`, `extra_role`.\n  - Amendment 2026-10-24")
    must_fail(repo, "SH-AC-01", "only in spec ['extra_role']")


def test_ac01_spec_amendment_removed(repo):
    repo.edit(SPEC, "  - Amendment 2026-11-24: `hush_recovery` added", "  - Amendment 2026-11-24: nothing")
    must_fail(repo, "SH-AC-01", "only in site.yml ['hush_recovery']")


def test_ac01_duplicate_role(repo):
    repo.edit(V + "/site.yml", RESTIC_ENTRY, RESTIC_ENTRY + RESTIC_ENTRY)
    must_fail(repo, "SH-AC-01", "more than once")


def test_ac01_second_host(repo):
    repo.edit(V + "/inventories/production/hosts.yml", "        ops.de.wahlberger.dev:\n",
              "        ops.de.wahlberger.dev:\n        other.example.org:\n")
    must_fail(repo, "SH-AC-01", "hosts.yml hosts")


def test_ac01_missing_claude_md(repo):
    (repo.ops / "CLAUDE.md").unlink()
    must_fail(repo, "SH-AC-01", "CLAUDE.md missing")


def test_ac01_unencrypted_vault(repo):
    (repo.ops / "inventories/production/group_vars/all/vault.yml").write_text("vault_x: plain\n")
    must_fail(repo, "SH-AC-01", "not Ansible-Vault encrypted")


def test_ac01_wrong_vault_pass_item(repo):
    repo.edit(V + "/.vault_pass.sh", "ops-de-wahlberger-dev", "other-playbook")
    must_fail(repo, "SH-AC-01", ".vault_pass.sh does not read")


@pytest.mark.parametrize("where", [NAS_VARS, CLOUD_VARS, OPS_VARS])
def test_ac01_personal_key_missing(repo, where):
    repo.edit(where, "erikwahlberger@personal", "someone@else")
    must_fail(repo, "SH-AC-01", "personal key")


# --- SH-AC-17 / 17v ------------------------------------------------------------
def test_ac17_wrong_url(repo):
    repo.edit(OPS_VARS, "https://semaphore.de.int.wahlberger.dev", "https://wrong.example.org")
    must_fail(repo, "SH-AC-17", "semaphore_url")


def test_ac17_wrong_client_id(repo):
    repo.edit(OPS_VARS, "63093482-d2cc-4c77-89df-9f6ff78b160e", "00000000-0000-0000-0000-000000000000")
    must_fail(repo, "SH-AC-17", "semaphore_oidc_client_id")


def test_ac17_example_with_value(repo):
    repo.edit(V + "/" + EXAMPLE, 'vault_semaphore_admin_password: ""', 'vault_semaphore_admin_password: "real-looking"')
    must_fail(repo, "SH-AC-17", "empty placeholder")


def test_ac17_vars_reference_unknown_vault_key(repo):
    p = repo.ops / VARS
    p.write_text(p.read_text() + "\nsome_new_var: \"{{ vault_not_in_example }}\"\n")
    must_fail(repo, "SH-AC-17", "vault_not_in_example")


def _make_vault(repo, drop=None, empty=None):
    """Encrypt a vault.yml with a throwaway password; returns the password file."""
    keys = re.findall(r"^(vault_\w+):", (repo.ops / EXAMPLE).read_text(), re.M)
    data = {k: "CANARY-SECRET-%s" % k for k in keys if k != drop}
    if empty:
        data[empty] = ""
    plain = repo.tmp / "plain.yml"
    plain.write_text("---\n" + "".join("%s: %s\n" % (k, json.dumps(v)) for k, v in data.items()))
    pw = repo.tmp / "throwaway-pass"
    pw.write_text("throwaway-not-a-secret\n")
    target = repo.ops / "inventories/production/group_vars/all/vault.yml"
    target.write_text(plain.read_text())
    p = subprocess.run(["ansible-vault", "encrypt", "--vault-password-file", str(pw), str(target)],
                       env=repo.env(), capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    plain.unlink()
    return pw


def test_ac17v_skipped_without_password(repo):
    rc, out = repo.static("SH-AC-17v")
    assert status(out, "SH-AC-17v") == "SKIPPED" and rc == 0, out


def test_ac17v_pass_with_complete_vault(repo):
    pw = _make_vault(repo)
    rc, out = repo.static("SH-AC-17v", STATIC_CHECKS_VAULT_PASSWORD_FILE=str(pw))
    assert status(out, "SH-AC-17v") == "PASS", out
    assert "CANARY-SECRET" not in out


def test_ac17v_missing_key_fails_without_leaking(repo):
    pw = _make_vault(repo, drop="vault_semaphore_cookie_hash")
    rc, out = repo.static("SH-AC-17v", STATIC_CHECKS_VAULT_PASSWORD_FILE=str(pw))
    assert status(out, "SH-AC-17v") == "FAIL" and "vault_semaphore_cookie_hash" in out, out
    assert "CANARY-SECRET" not in out


def test_ac17v_empty_value_fails(repo):
    pw = _make_vault(repo, empty="vault_semaphore_admin_password")
    rc, out = repo.static("SH-AC-17v", STATIC_CHECKS_VAULT_PASSWORD_FILE=str(pw))
    assert status(out, "SH-AC-17v") == "FAIL" and "is empty" in out, out
    assert "CANARY-SECRET" not in out


def test_ac17v_wrong_password_is_skipped_not_passed(repo):
    _make_vault(repo)
    bad = repo.tmp / "wrong-pass"
    bad.write_text("not-the-password\n")
    rc, out = repo.static("SH-AC-17v", STATIC_CHECKS_VAULT_PASSWORD_FILE=str(bad))
    assert status(out, "SH-AC-17v") == "SKIPPED", out


def test_ac17v_malformed_yaml_withholds_plaintext(repo):
    pw = _make_vault(repo)
    target = repo.ops / "inventories/production/group_vars/all/vault.yml"
    plain = repo.tmp / "bad.yml"
    plain.write_text("vault_a: 'CANARY-SECRET-unterminated\n  : [\n")
    target.write_text(plain.read_text())
    p = subprocess.run(["ansible-vault", "encrypt", "--vault-password-file", str(pw), str(target)],
                       env=repo.env(), capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    rc, out = repo.static("SH-AC-17v", STATIC_CHECKS_VAULT_PASSWORD_FILE=str(pw))
    assert status(out, "SH-AC-17v") == "FAIL" and "CANARY-SECRET" not in out, out


# --- SH-AC-23 ------------------------------------------------------------------
def _add_new_key(repo, nas=True, cloud=True, ops=True, key=NEW_KEY, zt="10.243.1.5"):
    line = '  - "%s"\n' % key.replace('"', '\\"')
    for flag, rel in ((nas, NAS_VARS), (cloud, CLOUD_VARS), (ops, OPS_VARS)):
        if flag:
            p = repo.path(rel)
            text = p.read_text()
            i = text.index("ssh_authorized_keys_list:")
            j = text.index("\n", text.index("erikwahlberger@personal", i)) + 1
            if rel != OPS_VARS:
                j = text.index("\n", text.index("semaphore-automation@pi.", i)) + 1
            p.write_text(text[:j] + line + text[j:])
    repo.edit(OPS_VARS, 'vm_zt_ip: ""', 'vm_zt_ip: "%s"' % zt)


def test_ac23_new_key_everywhere_passes(repo):
    _add_new_key(repo)
    rc, out = repo.static("SH-AC-23")
    assert status(out, "SH-AC-23") == "PASS", out


def test_ac23_new_key_missing_in_ops(repo):
    _add_new_key(repo, ops=False)
    must_fail(repo, "SH-AC-23", "exactly once")


def test_ac23_new_key_differs_between_files(repo):
    _add_new_key(repo, cloud=False)
    repo.edit(CLOUD_VARS, "erikwahlberger@personal\"\n", "erikwahlberger@personal\"\n  - '" +
              NEW_KEY.replace("203.0.113.9", "203.0.113.10") + "'\n", count=1)
    must_fail(repo, "SH-AC-23", "same string")


def test_ac23_new_key_without_from(repo):
    _add_new_key(repo, key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLE semaphore-automation@ops.de.wahlberger.dev")
    must_fail(repo, "SH-AC-23", "from=")


def test_ac23_from_lacks_zt_ip(repo):
    _add_new_key(repo, zt="10.243.9.9")
    must_fail(repo, "SH-AC-23", "from= lacks vm_zt_ip")


def test_ac23_from_lacks_public_ip(repo):
    _add_new_key(repo)
    must_fail(repo, "SH-AC-23", "from= lacks VM_PUBLIC_IP", VM_PUBLIC_IP="198.51.100.7")


def test_ac23_from_with_only_two_entries(repo):
    _add_new_key(repo, key=NEW_KEY.replace(",172.29.30.0/24", ""))
    must_fail(repo, "SH-AC-23", "from= lacks semaphore_network_subnet")


def test_ac23_old_key_in_ops_list(repo):
    old = [l for l in repo.path(NAS_VARS).read_text().splitlines() if "semaphore-automation@pi." in l][0]
    repo.edit(OPS_VARS, 'erikwahlberger@personal"\n', 'erikwahlberger@personal"\n' + old + "\n")
    must_fail(repo, "SH-AC-23", "ops list holds")


def test_ac23_nas_and_cloud_differ(repo):
    lines = [l for l in repo.path(CLOUD_VARS).read_text().splitlines() if "semaphore-automation@pi." in l][0]
    repo.edit(CLOUD_VARS, lines + "\n", "")
    must_fail(repo, "SH-AC-23", "nas and cloud")


def test_ac23_private_key_in_repo(repo):
    repo.write(V + "/leak.txt", "-----BEGIN OPENSSH PRIVATE" + " KEY-----\n")
    must_fail(repo, "SH-AC-23", "leak.txt")


def test_ac23_stage_e_requires_new_key_and_no_old(repo):
    rc, out = repo.static("SH-AC-23", STATIC_CHECKS_STAGE="E")
    assert status(out, "SH-AC-23") == "FAIL" and "stage E" in out, out


# --- SH-AC-30 ------------------------------------------------------------------
@pytest.mark.parametrize("rel,old,new,needle", [
    ("roles/restic_backup/templates/restic-backup.sh.j2", "restic check", "restic forget\nrestic check", "forget or prune"),
    ("roles/restic_backup/templates/restic-backup.timer.j2", "Persistent=true", "Persistent=false", "Persistent"),
    ("roles/restic_backup/defaults/main.yml", '"10%"', '"20%"', "read-data-subset"),
    ("roles/restic_backup/defaults/main.yml", "  - identity.secret\n", "", "identity.secret"),
    ("roles/restic_backup/defaults/main.yml", '  - "*.env"\n', "", "*.env"),
    ("roles/restic_backup/defaults/main.yml", "  - config.json\n", "", "config.json"),
])
def test_ac30_defects(repo, rel, old, new, needle):
    repo.edit(V + "/" + rel, old, new)
    must_fail(repo, "SH-AC-30", needle)


def test_ac30_vars_override_of_calendar(repo):
    repo.edit(OPS_VARS, 'restic_backup_on_calendar: "*-*-* 05:00:00"', 'restic_backup_on_calendar: "*-*-* 03:00:00"')
    must_fail(repo, "SH-AC-30", "OnCalendar")


def test_ac30r_skipped_when_render_skipped(repo):
    rc, out = repo.static("SH-AC-30r")
    assert status(out, "SH-AC-30r") == "SKIPPED" and rc == 0, out


# --- SH-AC-44 ------------------------------------------------------------------
@pytest.mark.parametrize("d", [N, C, V])
def test_ac44_default_not_empty_list(repo, d):
    repo.edit(d + "/roles/ssh_authorized_keys/defaults/main.yml", "ssh_authorized_keys_revoked: []",
              "ssh_authorized_keys_revoked: [x]")
    must_fail(repo, "SH-AC-44", "ssh_authorized_keys_revoked")


@pytest.mark.parametrize("d", [N, C, V])
def test_ac44_spec_type_wrong(repo, d):
    p = repo.path(d + "/roles/ssh_authorized_keys/meta/argument_specs.yml")
    text = p.read_text()
    i = text.index("ssh_authorized_keys_revoked:")
    j = text.index("elements: str", i)
    p.write_text(text[:j] + "elements: int" + text[j + len("elements: str"):])
    must_fail(repo, "SH-AC-44", "list of str")


def test_ac44_missing_molecule_verify(repo):
    (repo.ops / "molecule/default/verify-ssh-keys.yml").unlink()
    must_fail(repo, "SH-AC-44", "verify-ssh-keys.yml")


# The role is a copy per playbook: any drift between the three copies fails.
@pytest.mark.parametrize("d,part", [
    (N, "tasks/main.yml"), (C, "tasks/main.yml"), (V, "tasks/main.yml"),
    (N, "vars/main.yml"), (C, "vars/main.yml"), (V, "defaults/main.yml"), (C, "meta/argument_specs.yml"),
])
def test_ac44_role_copies_must_not_drift(repo, d, part):
    p = repo.path(d + "/roles/ssh_authorized_keys/" + part)
    p.write_text(p.read_text() + "\n# drift\n")
    must_fail(repo, "SH-AC-44", "differs between")


def test_ac44_missing_vars_dir_in_one_copy_fails(repo):
    shutil.rmtree(repo.path(C + "/roles/ssh_authorized_keys/vars"))
    must_fail(repo, "SH-AC-44", "missing in")


def test_ac44_readme_and_meta_main_may_differ(repo):
    repo.write(N + "/roles/ssh_authorized_keys/README.md", "other\n")
    repo.write(C + "/roles/ssh_authorized_keys/meta/main.yml", "other: true\n")
    rc, out = repo.static("SH-AC-44")
    assert status(out, "SH-AC-44") == "PASS", out


# --- SH-GUARDS: every other guard of tests/guards.d is wired --------------------
def test_guards_pass_when_all_pass(repo):
    (repo.ops / "tests/guards.d/bad.yml").unlink()
    rc, out = repo.static("SH-GUARDS")
    assert status(out, "SH-GUARDS") == "PASS", out


def test_guards_fail_names_the_guard(repo):
    rc, out = repo.static("SH-GUARDS")   # the fixture holds ok.yml and bad.yml
    assert status(out, "SH-GUARDS") == "FAIL" and "[guard bad] failed" in out and rc == 1, out


def test_a_new_guard_is_picked_up_without_editing_the_script(repo):
    (repo.ops / "tests/guards.d/bad.yml").unlink()
    (repo.ops / "tests/guards.d/brand_new.yml").write_text((repo.ops / "tests/guards.d/ok.yml").read_text().replace("ok", "x"))
    assert status(repo.static("SH-GUARDS")[1], "SH-GUARDS") == "PASS"
    (repo.ops / "tests/guards.d/brand_new.yml").write_text(BAD_GUARD)
    rc, out = repo.static("SH-GUARDS")
    assert status(out, "SH-GUARDS") == "FAIL" and "[guard brand_new] failed" in out, out


def test_guards_with_their_own_id_are_not_run_twice(repo):
    (repo.ops / "tests/guards.d/bad.yml").unlink()
    (repo.ops / "tests/guards.d/caddy.yml").write_text(BAD_GUARD)
    rc, out = repo.static("SH-GUARDS")
    assert status(out, "SH-GUARDS") == "PASS", out


def test_container_guards_are_a_separate_id_and_skippable(repo):
    (repo.ops / "tests/guards.d/bad.yml").unlink()
    (repo.ops / "tests/guards.d/semaphore.yml").write_text(BAD_GUARD)
    rc, out = repo.static("SH-GUARDS,SH-GUARDS-C", STATIC_CHECKS_SKIP_CONTAINER_GUARDS="1")
    assert status(out, "SH-GUARDS") == "PASS" and status(out, "SH-GUARDS-C") == "SKIPPED" and rc == 0, out


def test_guards_see_the_stage_from_the_environment(repo):
    (repo.ops / "tests/guards.d/bad.yml").unlink()
    (repo.ops / "tests/guards.d/stage.yml").write_text(STAGE_GUARD)
    assert status(repo.static("SH-GUARDS")[1], "SH-GUARDS") == "PASS"          # default A
    assert status(repo.static("SH-GUARDS", STATIC_CHECKS_STAGE="D")[1], "SH-GUARDS") == "FAIL"


# --- ssh_authorized_keys key-line regexes (code review PR A, item 1) ------------
def _real_regex_guard(repo):
    gd = repo.ops / "tests/guards.d/ssh_authorized_keys_regex.yml"
    gd.write_text((OPS_REAL / "tests/guards.d/ssh_authorized_keys_regex.yml").read_text())


def test_regex_guard_passes_for_the_three_copies(repo):
    _real_regex_guard(repo)
    rc, out = repo.run("guard-tests.sh", "ssh_authorized_keys_regex")
    assert rc == 0, out


@pytest.mark.parametrize("d", [N, C, V])
def test_regex_guard_catches_the_old_unanchored_regex(repo, d):
    # The reproducer: `ssh-ed25519 AAAA my ssh-thing x` made the old regex pick `x`.
    _real_regex_guard(repo)
    p = repo.path(d + "/roles/ssh_authorized_keys/vars/main.yml")
    p.write_text(re.sub(r"ssh_authorized_keys_body_regex: .*", lambda m: OLD_BODY_REGEX, p.read_text()))
    rc, out = repo.run("guard-tests.sh", "ssh_authorized_keys_regex")
    assert rc == 1 and "wrong body or comment" in out, out


# --- SH-AC-45 ------------------------------------------------------------------
def test_ac45_validate_removed(repo):
    p = repo.ops / "roles/security/tasks/sshd.yml"
    text, n = re.subn(r"^(\s*)validate:", r"\1x_validate:", p.read_text(), count=1, flags=re.M)
    assert n == 1, "fixture drift: sshd.yml has no validate: key to remove"
    p.write_text(text)
    must_fail(repo, "SH-AC-45", "without `validate")


def test_ac45_missing_molecule_scenario(repo):
    repo.edit(V + "/molecule/default/verify-security.yml", "SH-AC-45", "SH-AC-XX", count=100)
    must_fail(repo, "SH-AC-45", "SH-AC-45 scenario")


# --- SH-AC-56 ------------------------------------------------------------------
def test_ac56_sshd_handler_restarts(repo):
    repo.edit(V + "/roles/security/handlers/main.yml", "    name: sshd\n    state: reloaded", "    name: sshd\n    state: restarted")
    must_fail(repo, "SH-AC-56", "expected reloaded")


def test_ac56_other_handler_may_restart(repo):
    # The ssh-login-notify handler legitimately restarts; the grep is scoped to sshd.
    rc, out = repo.static("SH-AC-56")
    assert status(out, "SH-AC-56") == "PASS", out


def test_ac56_firewall_reload_in_task(repo):
    repo.write(V + "/roles/firewall/tasks/extra.yml", "- name: Reload\n  ansible.builtin.command: firewall-cmd --reload\n")
    must_fail(repo, "SH-AC-56", "must not reload/restart firewalld")


def test_ac56_firewall_restart_state(repo):
    repo.write(V + "/roles/firewall/tasks/extra.yml", "- ansible.builtin.systemd:\n    name: firewalld\n    state: restarted\n")
    must_fail(repo, "SH-AC-56", "extra.yml:3")


def test_ac56_firewall_comment_mentioning_reload_is_fine(repo):
    repo.write(V + "/roles/firewall/tasks/extra.yml", "# never reload firewalld here\n[]\n")
    rc, out = repo.static("SH-AC-56")
    assert status(out, "SH-AC-56") == "PASS", out


@pytest.mark.parametrize("call", ["systemctl reboot", "reboot", "/sbin/shutdown -r now", "systemctl --force reboot"])
def test_ac56_script_reboots_itself(repo, call):
    repo.edit(V + "/roles/security/templates/zypper-dup-request-reboot.sh.j2",
              "  rebootmgrctl reboot ||", "  %s\n  rebootmgrctl reboot ||" % call)
    must_fail(repo, "SH-AC-56", "reboot call other than")


def test_ac56_script_without_rebootmgrctl(repo):
    repo.edit(V + "/roles/security/templates/zypper-dup-request-reboot.sh.j2", "  rebootmgrctl reboot ||", "  true ||")
    must_fail(repo, "SH-AC-56", "no `rebootmgrctl reboot`")


# --- SH-AC-60 ------------------------------------------------------------------
def _renovate(repo, drop):
    p = repo.path("renovate.json")
    cfg = json.loads(p.read_text())
    cfg["packageRules"] = [r for r in cfg["packageRules"] if drop not in r["matchFileNames"][0]]
    p.write_text(json.dumps(cfg))


def test_ac60_missing_vm_rule(repo):
    _renovate(repo, "ops-de-wahlberger-dev")
    must_fail(repo, "SH-AC-60", "FR-161")


def test_ac60_rule_not_disabled(repo):
    p = repo.path("renovate.json")
    p.write_text(p.read_text().replace("false", "true"))
    must_fail(repo, "SH-AC-60", "lacks")


def test_ac60_stage_d_passes_without_vm_rule(repo):
    _renovate(repo, "ops-de-wahlberger-dev")
    rc, out = repo.static("SH-AC-60", STATIC_CHECKS_STAGE="D")
    assert status(out, "SH-AC-60") == "PASS", out


def test_ac60_stage_d_needs_vm_rule_gone(repo):
    must_fail(repo, "SH-AC-60", "still has", STATIC_CHECKS_STAGE="D")


def test_ac60_stage_e_needs_vm_rule_gone(repo):
    must_fail(repo, "SH-AC-60", "still has", STATIC_CHECKS_STAGE="E")


# --- SH-FR-205 -----------------------------------------------------------------
FAKE_TOKEN = "Qz3vK9mP2xL7nR4tB8wY1cF6hJ0sD5gA"   # 32 URL-safe characters, token-shaped


@pytest.mark.parametrize("rel,text", [
    (V + "/roles/zerotier/defaults/main.yml", "zerotier_central_api_token: %s\n" % FAKE_TOKEN),
    (V + "/vars/x.yml", "ZT_TOKEN: %s\n" % FAKE_TOKEN),
    (V + "/config/zt.json", '{"zerotier_token": "%s"}\n' % FAKE_TOKEN),
    (V + "/README.md.extra.md", "ZT_TOKEN=abc\n"),   # Markdown: caught by the assignment check
])
def test_fr205_token_found(repo, rel, text):
    repo.write(rel, text)
    must_fail(repo, "SH-FR-205", rel.split("/")[-1] if rel.endswith(".md") else rel)


# The false positive this check used to report: a Renovate denylist regex and an
# unrelated word on one line. Neither is an assignment of a token value.
RENOVATE_LIKE = '{"ignorePaths": ["zerotier.*"], "tokenRotation": "weekly"}\n'


def test_fr205_renovate_json_is_not_matched(repo):
    repo.write(V + "/renovate-extra.json", RENOVATE_LIKE)
    rc, out = repo.static("SH-FR-205")
    assert status(out, "SH-FR-205") == "PASS", out


def test_fr205_prose_in_markdown_is_fine(repo):
    repo.write(V + "/roles/zerotier/README.md", "No API token is used: a deliberate ZeroTier design choice.\n")
    rc, out = repo.static("SH-FR-205")
    assert status(out, "SH-FR-205") == "PASS", out


def test_fr205_prose_in_code_comment_is_fine(repo):
    repo.write(V + "/roles/zerotier/tasks/main.yml", "# the zerotier token is set by hand in Central\n")
    rc, out = repo.static("SH-FR-205")
    assert status(out, "SH-FR-205") == "PASS", out


# --- SH-AC-62: the two guard tests are separate checks -------------------------
def test_ac62_each_guard_fails_on_its_own(repo):
    gd = repo.ops / "tests/guards.d"
    (gd / "cloudflare_dns.yml").write_text((gd / "bad.yml").read_text())
    (gd / "caddy.yml").write_text((gd / "ok.yml").read_text())
    rc, out = repo.static("SH-AC-62a,SH-AC-62b")
    assert status(out, "SH-AC-62a") == "FAIL" and status(out, "SH-AC-62b") == "PASS" and rc == 1, out
    (gd / "cloudflare_dns.yml").write_text((gd / "ok.yml").read_text())
    (gd / "caddy.yml").write_text((gd / "bad.yml").read_text())
    rc, out = repo.static("SH-AC-62a,SH-AC-62b")
    assert status(out, "SH-AC-62a") == "PASS" and status(out, "SH-AC-62b") == "FAIL" and rc == 1, out


# --- SH-BR-16 hook and runner semantics ----------------------------------------
def test_br16_skipped_without_pr(repo):
    rc, out = repo.static("SH-BR-16")
    assert status(out, "SH-BR-16") == "SKIPPED", out


def test_br16_runs_boundary_check(repo):
    repo.write("some-other-host/x", "x")
    rc, out = repo.static("SH-BR-16", STATIC_CHECKS_PR="A")
    assert status(out, "SH-BR-16") == "FAIL", out


def test_exit_code_is_nonzero_on_any_fail_and_zero_when_only_skips(repo):
    ids = ["SH-AC-17v", "SH-AC-30r", "SH-BR-16"]
    rc, out = repo.static(",".join(ids))
    assert rc == 0, out
    for ident in ids:
        assert status(out, ident) == "SKIPPED", out
    repo.edit(OPS_VARS, "https://semaphore.de.int.wahlberger.dev", "https://wrong.example.org")
    rc, out = repo.static("SH-AC-17v,SH-AC-17")
    assert rc == 1, out


def test_invalid_stage_is_a_usage_error(repo):
    rc, out = repo.static("SH-AC-17", STATIC_CHECKS_STAGE="Z")
    assert rc == 2, out
