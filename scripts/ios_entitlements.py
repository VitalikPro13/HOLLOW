#!/usr/bin/env python3
"""The entitlements one iOS bundle is signed with, checked against its profile.

    ios_entitlements.py SOURCE XCCONFIG TEAM BUNDLE_ID OUT [PROFILE_PLIST CERT_SHA1]

SOURCE is the target's committed .entitlements file; its $(VARS) resolve from
XCCONFIG (ios/Flutter/Variant-prod.xcconfig) and the team. With a profile (the
decoded embedded.mobileprovision) the profile must be an App Store profile of
TEAM for exactly BUNDLE_ID that holds the signing certificate CERT_SHA1, and every
entitlement written to OUT must be one it grants. Without one (the CI dry run)
only the resolution runs. Run with Apple's /usr/bin/python3 -I: standard library only.
"""
import datetime
import fnmatch
import hashlib
import plistlib
import re
import sys

VAR = re.compile(r"\$[({]([A-Za-z0-9_]+)[)}]")


def fail(msg):
    sys.exit("ERROR: " + msg)


def read_xcconfig(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.split("//", 1)[0].strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if sep:
                values[key.strip()] = value.strip()
    return values


def resolve(text, values):
    for _ in range(10):
        new = VAR.sub(lambda m: values[m.group(1)] if m.group(1) in values else m.group(0), text)
        if new == text:
            break
        text = new
    if VAR.search(text):
        fail("unresolved build setting in %r" % text)
    return text


def resolve_all(node, values):
    if isinstance(node, str):
        return resolve(node, values)
    if isinstance(node, list):
        return [resolve_all(v, values) for v in node]
    if isinstance(node, dict):
        return {k: resolve_all(v, values) for k, v in node.items()}
    return node


def granted(want, have):
    if isinstance(want, bool) or isinstance(have, bool):
        return want is have
    if isinstance(want, str):
        if isinstance(have, list):
            return any(isinstance(h, str) and fnmatch.fnmatchcase(want, h) for h in have)
        return isinstance(have, str) and fnmatch.fnmatchcase(want, have)
    if isinstance(want, list):
        return all(granted(w, have if isinstance(have, list) else [have]) for w in want)
    return False


def check_profile(profile, team, bundle_id, cert_sha1):
    if profile.get("TeamIdentifier") != [team]:
        fail("profile %r is not for team %s" % (profile.get("Name"), team))
    ents = profile.get("Entitlements", {})
    if ents.get("application-identifier") != "%s.%s" % (team, bundle_id):
        fail("profile %r is for %r, not %s.%s" % (profile.get("Name"), ents.get("application-identifier"), team, bundle_id))
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        fail("profile %r is not an App Store profile (it names devices)" % profile.get("Name"))
    if ents.get("get-task-allow") is not False:
        fail("profile %r allows get-task-allow (a development profile)" % profile.get("Name"))
    if "iOS" not in profile.get("Platform", []):
        fail("profile %r is not an iOS profile" % profile.get("Name"))
    expires = profile.get("ExpirationDate")
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=None) <= now:
        fail("profile %r has expired" % profile.get("Name"))
    certs = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    if cert_sha1.upper() not in certs:
        fail("profile %r does not hold the signing certificate %s" % (profile.get("Name"), cert_sha1))


def main(argv):
    if len(argv) not in (6, 8):
        sys.exit(__doc__)
    source, xcconfig, team, bundle_id, out = argv[1:6]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        fail("team %r is not a 10-character Team ID" % team)
    values = read_xcconfig(xcconfig)
    values["AppIdentifierPrefix"] = team + "."
    values["TeamIdentifierPrefix"] = team + "."
    with open(source, "rb") as f:
        ents = resolve_all(plistlib.load(f), values)
    ents["application-identifier"] = "%s.%s" % (team, bundle_id)
    ents["com.apple.developer.team-identifier"] = team
    ents["get-task-allow"] = False
    if len(argv) == 8:
        with open(argv[6], "rb") as f:
            profile = plistlib.load(f)
        check_profile(profile, team, bundle_id, argv[7])
        allowed = profile["Entitlements"]
        if allowed.get("beta-reports-active") is True:
            ents["beta-reports-active"] = True
        for key, value in ents.items():
            if key not in allowed or not granted(value, allowed[key]):
                fail("%s: entitlement %s=%r is not granted by profile %r" % (bundle_id, key, value, profile.get("Name")))
    with open(out, "wb") as f:
        plistlib.dump(ents, f, sort_keys=True)


if __name__ == "__main__":
    main(sys.argv)
