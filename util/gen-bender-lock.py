#!/usr/bin/env python3
# Regenerate Bender.lock from Cheshire's lock.
#
# Cheshire's dependency tree has conflicting version requirements (e.g.
# register_interface ^0.3 vs ^0.4) that only its checked-in Bender.lock
# resolves, so `bender update` cannot solve it from scratch. We reuse that
# lock and point cheshire, ara and cva6 at this repo's submodules.
# Run again after bumping the cheshire submodule.
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = {"cheshire": "cheshire", "ara": "ara", "cva6": "cva6"}

lock = yaml.safe_load((ROOT / "cheshire" / "Bender.lock").read_text())
pkgs = lock["packages"]

chs = yaml.safe_load((ROOT / "cheshire" / "Bender.yml").read_text())
pkgs["cheshire"] = {"dependencies": sorted(n.lower() for n in chs["dependencies"])}

for name, path in LOCAL.items():
    pkgs[name].update(revision=None, version=None, source={"Path": path})

lock["packages"] = dict(sorted(pkgs.items()))
(ROOT / "Bender.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
