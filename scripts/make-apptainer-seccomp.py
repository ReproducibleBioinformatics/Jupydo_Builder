#!/usr/bin/env python3
"""
Builds security/apptainer-seccomp.json: the seccomp profile of JupyDo containers
with the Apptainer module. It is Docker's own default profile (moby/profiles,
downloaded here) with ONE change: the system calls Apptainer needs to run without
privileges (create user/mount namespaces, mount inside them) are allowed. Docker's
default allows them only to containers with CAP_SYS_ADMIN, which we do not give.
Every other rule is Docker's, unchanged. The kernel still checks permissions inside
the new namespaces: these calls give no privilege on the host by themselves.

Usage (from the builder folder):  scripts/make-apptainer-seccomp.py
"""
import json
import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = "https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json"
APPTAINER_SYSCALLS = sorted([
    "unshare", "setns", "clone", "clone3",                 # create / join namespaces
    "mount", "umount2", "pivot_root",                      # mount the container inside them
    "fsopen", "fsconfig", "fsmount", "move_mount", "open_tree", "mount_setattr",  # new mount API
])

profile = json.loads(urllib.request.urlopen(SOURCE, timeout=60).read())
rules = []
for rule in profile["syscalls"]:
    names = [n for n in rule["names"] if n not in APPTAINER_SYSCALLS]
    if names:  # Docker's rule, without the calls we decide about below
        rules.append(dict(rule, names=names))
rules.append({
    "names": APPTAINER_SYSCALLS,
    "action": "SCMP_ACT_ALLOW",
    "comment": "JupyDo Apptainer module: unprivileged namespaces (all other rules: Docker default)",
})
profile["syscalls"] = rules

out = os.path.join(ROOT, "security", "apptainer-seccomp.json")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump(profile, f, indent=1)
    f.write("\n")
print("written {} ({} rules; source {})".format(out, len(rules), SOURCE))
