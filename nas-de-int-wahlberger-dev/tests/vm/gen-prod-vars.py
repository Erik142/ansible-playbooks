#!/usr/bin/env python3
"""Write the production NON-secret vars (vars.yml only, never vault.yml) minus
every key the VM fixture overrides, so site.yml's argument-spec validation of
unrelated roles has its inputs. Usage: gen-prod-vars.py <out.yml>"""
import sys, yaml, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
prod = yaml.safe_load((root / "inventories/production/group_vars/all/vars.yml").read_text())
vm = yaml.safe_load((root / "inventories/vm/group_vars/all/vars.yml").read_text())
out = {k: v for k, v in prod.items() if k not in vm}
pathlib.Path(sys.argv[1]).write_text("---\n# generated, do not edit\n" + yaml.safe_dump(out, width=1000))
