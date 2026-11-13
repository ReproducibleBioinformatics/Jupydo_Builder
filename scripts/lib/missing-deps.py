#!/usr/bin/env python3
"""Dependencies a pip --target folder is missing FOR ANOTHER Python version.

pip evaluates environment markers (e.g. 'exceptiongroup; python_version < "3.11"')
with the Python that RUNS pip, not with the one given by --python-version: building
the kernel libraries for Python 3.10 with a Python 3.12 skips every dependency that
only older Pythons need. This reads the requirements of every package in the folder,
evaluates their markers for the target Python and architecture, and prints the ones
not installed (name and version specifier, one per line).
Usage: missing-deps.py <site folder> <python version, e.g. 3.10> <x86_64|aarch64>
"""
import glob
import os
import sys
from email.parser import Parser

from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name

site, version, machine = sys.argv[1:4]
env = {"python_version": version, "python_full_version": version + ".0",
       "implementation_name": "cpython", "platform_python_implementation": "CPython",
       "sys_platform": "linux", "platform_system": "Linux", "os_name": "posix",
       "platform_machine": machine, "implementation_version": version + ".0", "extra": ""}

installed, requires = set(), []
for meta in glob.glob(os.path.join(site, "*.dist-info", "METADATA")):
    with open(meta, encoding="utf-8", errors="replace") as f:
        msg = Parser().parse(f, headersonly=True)
    installed.add(canonicalize_name(msg["Name"]))
    requires += msg.get_all("Requires-Dist") or []

missing = {}
for line in requires:
    req = Requirement(line)
    if req.marker is not None and not req.marker.evaluate(env):
        continue
    name = canonicalize_name(req.name)
    if name not in installed:
        missing[name] = req.name + str(req.specifier)
print("\n".join(sorted(missing.values())))
