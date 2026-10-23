#!/usr/bin/env python3
"""Write the SLSA build provenance for a release (SLSA Build L1, AR-35).

Run on the Windows PC after every artifact is in installer\\Output and BEFORE
sign_manifest.ps1, which stays the last step:

    python scripts\\release_provenance.py X.Y.Z installer\\Output

It writes installer\\Output\\hollow-X.Y.Z.provenance.json: an in-toto
Statement v1 with a SLSA Provenance v1 predicate naming the sha256 of each of
the seven published artifacts, the source commit (plus a digest of the
tracked diff against it, since the release commit lands after go-live), the
lockfiles, the host each artifact was built on and this host's toolchain.
The file is published next to the artifacts and on the GitHub release.

The diff digest covers only this host's tracked files: untracked files are
left out (they would make the digest unreproducible), and the trees the Linux
VM and the Mac mini built from are not covered at all; their builtOn entries
are claims, not evidence.

It is unsigned: L1 asks only that provenance exists and is distributed. The
artifacts themselves stay pinned by the signed manifest.
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_URI = "git+https://github.com/VitalikPro13/HOLLOW"
BUILD_TYPE = "https://anonlisten.com/hollow/provenance/release-build/v1"
BUILDER_ID = "https://anonlisten.com/hollow/provenance/release-hosts/v1"
LOCKFILES = ["rust/hollow_core/Cargo.lock", "pubspec.lock"]

# The seven published artifacts and the host that builds each (release skill, steps 4-6).
ARTIFACTS = [
    ("hollow-{v}-win64-setup.exe", "windows-pc", "scripts/build_release.ps1"),
    ("hollow-{v}-win64.zip", "windows-pc", "scripts/build_release.ps1"),
    ("hollow-{v}-android.apk", "windows-pc", "scripts/build_release.ps1"),
    ("hollow-{v}-linux.tar.gz", "linux-vm", "scripts/build_linux_release.sh"),
    ("hollow-{v}-linux-x86_64.flatpak", "linux-vm", "scripts/build_linux_release.sh"),
    ("hollow-{v}.dmg", "mac-mini", "scripts/build_macos_release.sh"),
    ("hollow-{v}-macos.zip", "mac-mini", "scripts/build_macos_release.sh"),
]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def run(*cmd):
    try:
        out = subprocess.run(cmd, cwd=REPO, capture_output=True, check=True, shell=os.name == "nt")
        return out.stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def tool_version(*cmd):
    out = run(*cmd)
    return out.decode("utf-8", "replace").strip().splitlines()[0] if out else "unknown"


def uncommitted_change():
    """The tracked diff against HEAD, which anyone holding the same tree can recompute."""
    return run("git", "diff", "HEAD", "--binary") or b""


def statement(version, artifact_dir, host, now):
    subjects, byproducts, missing = [], [], []
    for pattern, built_on, script in ARTIFACTS:
        name = pattern.format(v=version)
        path = os.path.join(artifact_dir, name)
        if not os.path.isfile(path):
            missing.append(name)
            continue
        subjects.append({"name": name, "digest": {"sha256": sha256_file(path)}})
        byproducts.append({"name": name, "annotations": {"builtOn": built_on, "buildScript": script}})
    if missing:
        raise SystemExit("missing artifacts in %s: %s" % (artifact_dir, ", ".join(missing)))

    commit = run("git", "rev-parse", "HEAD")
    if not commit:
        raise SystemExit("not a git checkout: the source commit is the point of the file")
    commit = commit.decode().strip()
    source = {"uri": SOURCE_URI, "commit": commit}
    change = uncommitted_change()
    if change:
        source["uncommittedDiffSha256"] = hashlib.sha256(change).hexdigest()

    deps = [{"uri": "%s@%s" % (SOURCE_URI, commit), "digest": {"gitCommit": commit}}]
    for rel in LOCKFILES:
        path = os.path.join(REPO, rel)
        if os.path.isfile(path):
            deps.append({"name": rel, "digest": {"sha256": sha256_file(path)}})

    return {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": subjects,
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": BUILD_TYPE,
                "externalParameters": {"version": version, "source": source},
                "resolvedDependencies": deps,
            },
            "runDetails": {
                "builder": {
                    "id": BUILDER_ID,
                    "version": {
                        host: {
                            "flutter": tool_version("flutter", "--version"),
                            "rustc": tool_version("rustc", "--version"),
                            "cargo": tool_version("cargo", "--version"),
                        }
                    },
                },
                "metadata": {"invocationId": "hollow-%s" % version, "finishedOn": now},
                "byproducts": byproducts,
            },
        },
    }


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("version", help="three-part release version, e.g. 0.13.0")
    ap.add_argument("artifact_dir", help="folder holding the seven artifacts (installer\\Output)")
    ap.add_argument("--host", default="windows-pc", help="the host running this script")
    args = ap.parse_args(argv)
    if len(args.version.split(".")) != 3 or not all(p.isdigit() for p in args.version.split(".")):
        raise SystemExit("version must be three numeric parts, like the manifest's")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = statement(args.version, args.artifact_dir, args.host, now)
    out = os.path.join(args.artifact_dir, "hollow-%s.provenance.json" % args.version)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print("wrote %s (%d subjects, commit %s%s)" % (
        out, len(doc["subject"]), doc["predicate"]["buildDefinition"]["externalParameters"]["source"]["commit"][:12],
        " + uncommitted changes" if "uncommittedDiffSha256" in doc["predicate"]["buildDefinition"]["externalParameters"]["source"] else ""))


if __name__ == "__main__":
    main(sys.argv[1:])
