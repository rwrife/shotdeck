#!/usr/bin/env python3
"""Runnable synthetic release contract checks; no Apple/ASC completion claims."""
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import release


# Exercise a real subprocess boundary; never publish its synthetic secret output.
CHILD = "import sys; print(sys.argv[1]); print(sys.argv[1], file=sys.stderr); sys.exit(1)"


def rejects(action):
    try:
        action()
    except ValueError:
        return
    raise AssertionError("invalid fixture accepted")


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    key = root / "synthetic.p8"
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key)], check=True, capture_output=True)
    token = release.jwt(key, "SYNTHETIC", "synthetic-issuer")
    signature = base64.urlsafe_b64decode(token.split(".")[2] + "==")
    assert len(signature) == 64
    header = json.loads(base64.urlsafe_b64decode(token.split(".")[0] + "=="))
    assert header["alg"] == "ES256"
    rejects(lambda: release.raw_signature(b"invalid"))
    rejects(lambda: release.raw_signature(b"\x30\x06\x02\x01\x00\x02\x01\x01"))
    app = root / "ShotDeck.app"
    app.mkdir()
    valid = {"CFBundleIdentifier": release.BUNDLE, "UIDeviceFamily": [1], "CFBundleVersion": "3.2", "CFBundleShortVersionString": "0.1.0"}
    for name in ("PrivacyInfo.xcprivacy", "Assets.car", "AppIcon60x60@2x.png"):
        (app / name).write_bytes(b"synthetic artifact")
    plist = app / "Info.plist"
    plist.write_bytes(plistlib.dumps(valid))
    assert release.verify_archive(app, "3.2")["device_family"] == [1]
    for field, wrong in (("UIDeviceFamily", [1, 2]), ("CFBundleIdentifier", "com.other.app"), ("CFBundleVersion", "3.1"), ("CFBundleShortVersionString", "1.0")):
        plist.write_bytes(plistlib.dumps(dict(valid, **{field: wrong})))
        rejects(lambda: release.verify_archive(app, "3.2"))
    plist.write_bytes(plistlib.dumps(valid))
    (app / "AppIcon60x60@2x.png").unlink()
    rejects(lambda: release.verify_archive(app, "3.2"))
    raw, evidence = root / "raw", root / "evidence"
    raw.mkdir()
    evidence.mkdir()
    sentinel = "PRIVATE-PARTIAL-KEY-SECRET"
    rejects(lambda: release.command([sys.executable, "-c", CHILD, "error: certificate " + sentinel], "synthetic", raw, evidence))
    assert sentinel in (raw / "synthetic.log").read_text()
    assert sentinel in (raw / "synthetic-stderr.log").read_text()
    assert sentinel not in (evidence / "synthetic-summary.json").read_text()
    assert all(isinstance(count, int) for count in release.categories("error: certificate " + sentinel).values())
    # Failure summaries carry fixed diagnostic codes; raw log text never leaves ephemeral storage.
    curated = json.loads((evidence / "synthetic-summary.json").read_text())
    assert curated["exit_code"] == 1
    assert curated["diagnostics"] == []
    assert "certificate " + sentinel not in json.dumps(curated)
    # Known Xcode/Apple signing failures map to fixed codes, case-insensitively.
    assert release.diagnostics("xcodebuild: error: No profiles for 'com.infinityball.shotdeck' were found.") == ["no-provisioning-profile"]
    assert release.diagnostics("Your account has reached the maximum number of certificates.\nChoose a certificate to revoke.") == sorted(
        ["certificate-limit", "certificate-revocation-required"])
    assert release.diagnostics("Missing package product ''") == ["missing-package-product"]
    assert release.diagnostics("Unable to find module dependency: 'ShotDeckStore'") == ["missing-module-dependency"]
    assert release.diagnostics("iOS 26.0 is not installed. Please download and install") == ["missing-ios-platform"]
    assert release.diagnostics("all good") == []
    assert release.diagnostics("authentication failed") == ["authentication-failed"]
    # A real failing subprocess publishes only fixed codes, never the raw message.
    noisy = "xcodebuild: error: No profiles for 'com.infinityball.shotdeck' were found " + sentinel
    rejects(lambda: release.command([sys.executable, "-c", "import sys; print(sys.argv[1]); sys.exit(65)", noisy], "profilefail", raw, evidence))
    profilefail = json.loads((evidence / "profilefail-summary.json").read_text())
    assert profilefail["exit_code"] == 65
    assert profilefail["diagnostics"] == ["no-provisioning-profile"]
    assert sentinel not in json.dumps(profilefail)
    assert "No profiles for" not in json.dumps(profilefail)

settings = [{"target": "ShotDeck", "buildSettings": {"PRODUCT_BUNDLE_IDENTIFIER": release.BUNDLE, "TARGETED_DEVICE_FAMILY": "1", "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"}}]
release.verify_settings(settings)
for name, wrong in (("PRODUCT_BUNDLE_IDENTIFIER", "com.other.app"), ("TARGETED_DEVICE_FAMILY", "1,2"), ("IPHONEOS_DEPLOYMENT_TARGET", "25.0")):
    changed = json.loads(json.dumps(settings))
    changed[0]["buildSettings"][name] = wrong
    rejects(lambda: release.verify_settings(changed))
rejects(lambda: release.verify_settings([]))
rejects(lambda: release.verify_settings(settings + settings))
started = datetime(2026, 1, 1, tzinfo=timezone.utc)
build = {"id": "synthetic-build-id", "attributes": {"version": "3.2", "uploadedDate": "2026-01-01T00:00:01Z", "processingState": "VALID"}}
assert release.processed_build([build], "3.2", started)["build_id"] == build["id"]
assert release.processed_build([build], "3.1", started) is None
for state in ("PROCESSING", "INVALID", "FAILED", "COMPLETE", "UNKNOWN"):
    changed = json.loads(json.dumps(build))
    changed["attributes"]["processingState"] = state
    if state == "PROCESSING":
        assert release.processed_build([changed], "3.2", started) is None
    else:
        rejects(lambda: release.processed_build([changed], "3.2", started))
old = json.loads(json.dumps(build))
old["attributes"]["uploadedDate"] = "2025-12-31T23:59:59Z"
assert release.processed_build([old], "3.2", started) is None
print("Release helper contracts: PASS (synthetic only; no archive/upload evidence)")
