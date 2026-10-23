# Garage V4 results (T-19)

Run on the qemu fixture, 2026-10-19 (guest clock), spec v1.3. VM state of V3 kept (no reset). Fake fixture secrets only.
Script: `tests/vm/scenarios/garage-v4-run.sh`. Logs: `$FIXTURE_VM_DIR/out/garage-v4/`.

| Scenario | Result | Evidence |
|---|---|---|
| GS-AC-23/fresh-output | PASS | `--tags garage -vvv` on a fresh store, rc=0, 4429 output lines, 0 matches for the fixture rpc_secret and admin_token |
| GS-AC-23/fresh-journal | PASS | `journalctl -u garage.service`: 0 matches |
| GS-AC-23/user-output | PASS | same run on the store with user-made state (buckets `sstate`, `private-test` listed: 2), rc=0, 0 matches |
| GS-AC-23/user-journal | PASS | `journalctl -u garage.service`: 0 matches |
| GS-AC-23/grep-sanity | PASS | the fixture token is present in the guest secret file, so the grep pattern is the real value |
| GS-AC-12/second-run | PASS | `--tags garage,caddy,btrbk`: first run rc=0 changed=0 (a previous identical run had converged it), second run rc=0 changed=0 |
| GS-AC-12/check-diff | PASS | `--check --diff` rc=0 changed=0, 0 diff hunks |

Notes:
- "Fresh store" = the role run with `garage_store_path=/mnt/data/garage-v4` and `garage_config_dir=/mnt/containers/garage-v4` (empty paths, subvolumes created by the role); the V3 store stays on disk and the next default-path run switches back. A literal wipe of the V3 state was not done, to keep it for later tasks. The fresh-store run was a real full role run (storage, secrets, Quadlet, readiness wait).
- The caddy role refuses an empty `cloudflare_dns_api_token`; the fixture inventory has none, so the GS-AC-12 runs pass a fake `cloudflare_dns_api_token=fixture-cloudflare-not-a-secret` as extra var (not a spec defect; fixture limitation). Not added to the fixture inventory (outside T-19 files).
- Script history: the first two runs of the script had a script bug (bucket count taken before the user-state run; caddy token missing), recorded as FAIL lines in `results.tsv`; the third run is the result above.
- Not run: GS-AC-12 against production vars (needs Vault).
