#!/usr/bin/env python3
# Regenerate Bender.lock from Cheshire's and Spatz's locks.
#
# Cheshire's dependency tree has conflicting version requirements (e.g.
# register_interface ^0.3 vs ^0.4) that only its checked-in Bender.lock
# resolves, and Spatz pins older versions of several shared packages (e.g.
# axi =0.39.1-beta), so `bender update` cannot solve the tree from scratch.
# We merge both locks instead: a package in both takes the newer version
# (as Carfield does for Spatz on Cheshire), and cheshire, ara, cva6 and spatz
# point at this repo's submodules. Bender.local overrides the same versions.
# Run again after bumping the cheshire or spatz submodule.
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCAL = {"cheshire": "cheshire", "ara": "ara", "cva6": "cva6", "spatz": "spatz"}


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def semver(pkg):
    v = (pkg.get("version") or "0").split("-")[0]
    return tuple(int(x) for x in v.split("."))


lock = load("cheshire/Bender.lock")
pkgs = lock["packages"]

# Spatz's packages: new ones are added, shared ones keep the newer version.
# Spatz's own path dependencies (snitch, reqrsp_interface) are relative to it.
for name, pkg in load("spatz/Bender.lock")["packages"].items():
    if "Path" in pkg["source"]:
        pkg["source"] = {"Path": f"spatz/{pkg['source']['Path']}"}
    if name not in pkgs or semver(pkg) > semver(pkgs[name]):
        pkgs[name] = pkg

for name, manifest in (("cheshire", "cheshire/Bender.yml"), ("spatz", "spatz/Bender.yml")):
    deps = sorted(n.lower() for n in load(manifest)["dependencies"])
    pkgs[name] = {"revision": None, "version": None, "source": {}, "dependencies": deps}

for name, path in LOCAL.items():
    pkgs[name].update(revision=None, version=None, source={"Path": path})

lock["packages"] = dict(sorted(pkgs.items()))
(ROOT / "Bender.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
