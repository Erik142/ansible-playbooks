# Garage low-severity security fixes (findings 2-5)

Run on the qemu fixture (FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage), V3/V4 state kept, no reset. Fake fixture secrets only.
Not fixed on purpose (Erik decides): finding 1 (dedicated network), 6 (web headers), 7 (image digest).

| Finding | Change | Result |
|---|---|---|
| 2 Quadlet hardening | `NoNewPrivileges=true`, `DropCapability=ALL`, `ReadOnly=true` in garage.container.j2 | all three kept, none broke the container. Guest: unit active, health `healthy`, `garage status` lists the node; container PID has CapEff=CapBnd=0 and NoNewPrivs=1; podman reports ReadonlyRootfs=true. No Tmpfs needed. |
| 3 charset asserts | preflight.yml: garage_s3_domain hostname charset, garage_s3_region `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, all six garage_*_path/dir `^/[A-Za-z0-9._/-]+$` without `..`; caddy main.yml: site.host hostname (optional `*.`); btrbk validate.yml: snapshot_dir charset | valid fixture values unchanged (0 changed). Negative: region `a b`, empty region, secrets dir with a space, domain with a quote each fail the run (--check). |
| 4 secrets guard | secrets_guard.yml: `configs=$(LC_ALL=C snapper list-configs) \|\| exit 2`, loop reads from process substitution | a fake failing snapper gives exit 2 in the guest. `LC_ALL=C` added because snapper prints `│` instead of `\|` in a UTF-8 locale, which the awk split missed (pre-existing latent gap). |
| 5 README | no secret on a command line: `read -rs` + inherited `-e AWS_SECRET_ACCESS_KEY`, env-file alternative | docs only |

VM runs (`--tags garage`): `--check --diff` rc=0 (only the Quadlet changed); real run rc=0 changed=2 (Quadlet + restart); second and third run changed=0; final `--check --diff` changed=0.

Local: ansible-lint production on roles/garage, caddy, btrbk passed; yamllint clean; tests/syntax-check-role.sh garage, caddy, btrbk ok; pytest test_garage_preflight, test_garage_secrets, test_btrbk_sources, test_caddy_body 31 passed.
tests/render-check.sh: rc=1, one failed assertion (garage.toml `[s3_api]..[admin]` multi-line regex in tests/render.d/40-garage.yml:49). The identical failure occurs on a clean HEAD worktree, so it is pre-existing and not caused by these changes; not investigated further.
