#!/usr/bin/env python3
"""Print the release version for a commit, independent of local timezone, date and tags."""
import plistlib
import re
import subprocess
import sys

def git(*args):
    return subprocess.check_output(["git", *args])

if git("rev-parse", "--is-shallow-repository").strip() != b"false":
    sys.exit("Fetch full history before building a release.")
ref = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
sha = git("rev-parse", "--verify", ref + "^{commit}").decode().strip()
info = plistlib.loads(git("show", f"{sha}:Resources/Info.plist"))
major_minor = ".".join(info["CFBundleShortVersionString"].split(".")[:2])
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)", major_minor):
    sys.exit("Invalid release series in Info.plist.")
revision = int(git("rev-list", "--first-parent", "--count", sha))
if any(int(part) > 65535 for part in [*major_minor.split("."), revision]):
    sys.exit("Version exceeds the Edge extension version range.")
print(f"{major_minor}.{revision}")
