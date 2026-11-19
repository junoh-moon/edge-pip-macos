#!/usr/bin/env python3
"""Build a universal DMG and unpacked Edge extension from the checked-out commit."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
os.chdir(root)
def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

# Ignore non-source files in the checkout and compile an exact git archive below.
version = subprocess.check_output([sys.executable, "scripts/release-version.py"], text=True).strip()
if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"]).strip():
    sys.exit("Commit tracked changes before packaging.")
out = root / "build" / "releases" / version
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="edge-pip-release-") as scratch:
    scratch = Path(scratch)
    archive = scratch / "source.tar"
    run("git", "archive", "--format=tar", "-o", archive, "HEAD")
    src = scratch / "src"
    src.mkdir()
    run("tar", "-xf", archive, "-C", src)
    env = os.environ.copy()
    env.pop("EDGE_PIP_SIGNING_SHA1", None)
    # Seven local development builds predate the first public commit.
    env.update(EDGE_PIP_BUILD_DIR="build", EDGE_PIP_ARCHS="arm64 x86_64",
               EDGE_PIP_RELEASE_VERSION=version, EDGE_PIP_BUILD_NUMBER=str(7 + int(version.split(".")[2])))
    run(src / "scripts/build.sh", cwd=src, env=env)
    volume = scratch / "volume"
    volume.mkdir()
    bundle = volume / "Edge PiP.app"
    shutil.copytree(src / "build/Edge PiP.app", bundle)
    run("codesign", "--verify", "--strict", "--deep", bundle)
    for binary in (bundle / "Contents/MacOS").iterdir():
        run("xcrun", "lipo", "-verify_arch", "arm64", "x86_64", binary)
    (volume / "Applications").symlink_to("/Applications")
    setup = volume / "Setup"
    setup.mkdir()
    for name in ("register-host.py", "extension-id"):
        shutil.copyfile(src / "scripts" / name, setup / name)
    shutil.copyfile(src / "Resources/Install.txt", volume / "Install.txt")
    dmg = out / f"Edge-PiP-{version}-macOS.dmg"
    run("hdiutil", "create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO",
        "-volname", "Edge PiP", "-srcfolder", volume, dmg)
    run("hdiutil", "verify", "-quiet", dmg)

    extension = out / f"Edge-PiP-Controls-{version}.zip"
    with zipfile.ZipFile(extension, "w") as dest:
        for file in sorted((src / "extension").rglob("*")):
            if not file.is_file():
                continue
            entry = zipfile.ZipInfo(file.relative_to(src / "extension").as_posix())
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            data = file.read_bytes()
            if entry.filename == "manifest.json":
                manifest = json.loads(data)
                manifest["version"] = version
                data = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
            dest.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED)
    with zipfile.ZipFile(extension) as check:
        if check.testzip() or json.loads(check.read("manifest.json"))["version"] != version:
            sys.exit("Invalid extension package.")
    sums = [f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}\n" for f in (dmg, extension)]
    (out / "SHA256SUMS.txt").write_text("".join(sums))
print(out)
