#!/usr/bin/env python3
"""Signed ShotDeck release. Raw tool output stays ephemeral; publish curated evidence only."""
import base64
from collections import Counter
from datetime import datetime, timezone
import glob
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE = "com.infinityball.shotdeck"
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def raw_signature(der):
    # P-256 signatures fit short-form DER lengths; reject all other shapes.
    require(len(der) >= 6 and der[0] == 0x30 and der[1] == len(der) - 2, "Invalid ES256 signature")
    position, values = 2, []
    for _ in range(2):
        require(position + 2 <= len(der) and der[position] == 2, "Invalid ES256 integer")
        length = der[position + 1]
        position += 2
        value = der[position:position + length]
        require(len(value) == length and 1 <= length <= 33 and value[0] < 128, "Invalid ES256 integer")
        require(length == 1 or value[0] != 0 or value[1] >= 128, "Noncanonical ES256 integer")
        number = int.from_bytes(value, "big")
        require(0 < number < 2**256, "Invalid ES256 width")
        values.append(number.to_bytes(32, "big"))
        position += length
    require(position == len(der), "Trailing ES256 data")
    return b"".join(values)


def jwt(key_path, key_id, issuer):
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": issuer, "aud": "appstoreconnect-v1", "iat": now, "exp": now + 600}).encode())
    payload = f"{header}.{claims}"
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                            input=payload.encode(), capture_output=True, check=False)
    require(result.returncode == 0, "ASC signing failed")
    return f"{payload}.{b64(raw_signature(result.stdout))}"


def api(path, parameters, key_path, credentials):
    url = "https://api.appstoreconnect.apple.com/v1/" + path + "?" + urllib.parse.urlencode(parameters)
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + jwt(key_path, credentials["ASC_KEY_ID"], credentials["ASC_ISSUER_ID"])})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise ValueError(f"ASC HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        raise ValueError("ASC transport or response failure") from None


def processed_build(builds, wanted, started):
    for build in builds:
        attributes = build["attributes"]
        if attributes.get("version") != wanted:
            continue
        uploaded = datetime.fromisoformat(attributes["uploadedDate"].replace("Z", "+00:00"))
        require(uploaded.tzinfo is not None, "ASC upload date missing timezone")
        if uploaded < started:
            continue
        state = attributes.get("processingState")
        require(state in ("PROCESSING", "VALID", "INVALID", "FAILED"), "Unexpected ASC processing state")
        require(state not in ("INVALID", "FAILED"), "ASC processing rejected build")
        if state == "VALID":
            require(bool(re.fullmatch(r"[A-Za-z0-9-]+", build["id"])), "Invalid ASC build ID")
            return {"build_id": build["id"], "build_number": wanted, "processing_state": state,
                    "uploaded_date": attributes["uploadedDate"]}
    return None


def verify_settings(settings):
    apps = [entry["buildSettings"] for entry in settings if entry.get("target") == "ShotDeck"]
    require(len(apps) == 1, "Release app settings missing or ambiguous")
    app = apps[0]
    require(app.get("PRODUCT_BUNDLE_IDENTIFIER") == BUNDLE, "Wrong release bundle identifier")
    require(app.get("TARGETED_DEVICE_FAMILY") == "1", "Release is not iPhone-only")
    require(app.get("IPHONEOS_DEPLOYMENT_TARGET") == "26.0", "Wrong deployment target")
    require(app.get("ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon", "AppIcon not configured")


def verify_archive(app, build_number):
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == BUNDLE, "Archive bundle identifier mismatch")
    require(info.get("UIDeviceFamily") == [1], "Archive is not iPhone-only")
    require(info.get("CFBundleVersion") == build_number, "Archive build version mismatch")
    require(info.get("CFBundleShortVersionString") == "0.1.0", "Archive marketing version mismatch")
    require((app / "PrivacyInfo.xcprivacy").is_file(), "Archive privacy manifest missing")
    require((app / "Assets.car").is_file() and bool(list(app.glob("AppIcon*.png"))), "Archive compiled AppIcon missing")
    return {"bundle_identifier": BUNDLE, "device_family": [1], "build_number": build_number,
            "marketing_version": info["CFBundleShortVersionString"], "privacy_manifest": True, "compiled_icon": True}


def categories(text):
    patterns = {"provisioning": r"profile|provision", "signing-certificate": r"certificate|codesign|code sign",
                "appstore-auth": r"unauthorized|authentication|unauthenticated", "app-identity": r"bundle identifier|app icon|appicon",
                "compiler-or-build": r"error:|build failed|archive failed|export failed"}
    counts = Counter()
    for line in text.splitlines():
        for name, pattern in patterns.items():
            if re.search(pattern, line, re.IGNORECASE):
                counts[name] += 1
    return dict(counts) or {"unclassified": 1}


def diagnostics(text):
    """Fixed codes for specific Xcode messages; never return any source text."""
    patterns = {
        "certificate-limit": r"reached the maximum number of certificates",
        "certificate-revocation-required": r"choose a certificate to revoke",
        "no-provisioning-profile": r"No profiles for .+ were found",
        "authentication-failed": r"authentication failed|unable to authenticate|unauthorized",
        "agreement-required": r"agreement.+(?:expired|must be accepted|needs to be accepted)",
        "missing-package-product": r"Missing package product",
        "missing-module-dependency": r"Unable to find module dependency",
        "missing-ios-platform": r"iOS 26\.0 is not installed",
    }
    return sorted(code for code, pattern in patterns.items() if re.search(pattern, text, re.IGNORECASE))


def command(args, name, raw, evidence, timeout=1200):
    log = raw / f"{name}.log"
    errors = raw / f"{name}-stderr.log"
    with log.open("wb") as output, errors.open("wb") as stderr:
        try:
            result = subprocess.run(args, stdout=output, stderr=stderr, timeout=timeout, check=False)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    text = log.read_text(errors="replace") + errors.read_text(errors="replace")
    summary = {"phase": name, "exit_code": code, "categories": categories(text)}
    if code != 0:
        # Fixed diagnostic codes only; raw tool text never becomes published evidence.
        summary["diagnostics"] = diagnostics(text)
    (evidence / f"{name}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{name}: exit {code}", flush=True)
    require(code == 0, f"Release phase {name} failed; see curated evidence")
    return log


def select_xcode(pin):
    matches = []
    for app in sorted(glob.glob("/Applications/Xcode*.app")):
        dev = str(Path(app) / "Contents/Developer")
        env = dict(os.environ, DEVELOPER_DIR=dev)
        result = subprocess.run(["xcodebuild", "-version"], env=env, capture_output=True, timeout=30, check=False)
        if result.returncode or result.stdout.decode().strip().splitlines() != [f"Xcode {pin['xcode_version']}", f"Build version {pin['xcode_build']}"]:
            continue
        sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env=env, capture_output=True, timeout=30, check=False)
        if sdk.returncode == 0 and sdk.stdout.decode().strip() == pin["iphoneos_sdk"]:
            matches.append(dev)
    require(bool(matches), "ACCEPTANCE BLOCKER: exact Xcode 26.0.1 / 17A400 / SDK 26.0 unavailable")
    os.environ["DEVELOPER_DIR"] = matches[-1]


def run(upload):
    pin = json.loads((ROOT / "toolchain.json").read_text())
    require((pin["xcode_version"], pin["xcode_build"], pin["iphoneos_sdk"], pin["bundle_identifier"]) ==
            ("26.0.1", "17A400", "26.0", BUNDLE), "Release pin violates platform contract")
    number = f"{os.environ['GITHUB_RUN_NUMBER']}.{os.environ['GITHUB_RUN_ATTEMPT']}"
    require(bool(re.fullmatch(r"[1-9][0-9]*\.[1-9][0-9]*", number)), "Invalid attempt build number")
    evidence = ROOT / "build/release-evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    raw = Path(os.environ["RUNNER_TEMP"]) / "shotdeck-release-private"
    raw.mkdir(mode=0o700, exist_ok=True)
    raw.chmod(0o700)
    credentials = {name: os.environ.get(name, "") for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "ASC_TEAM_ID")}
    require(all(credentials.values()), "Missing ASC secret; required names: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_TEAM_ID")
    key = raw / "AuthKey.p8"
    try:
        key.write_text(credentials["ASC_KEY_P8"].replace("\\n", "\n"))
        key.chmod(0o600)
        # Validate credentials without publishing token or key text.
        jwt(key, credentials["ASC_KEY_ID"], credentials["ASC_ISSUER_ID"])
        select_xcode(pin)
        result = {"source_sha": os.environ["GITHUB_SHA"], "run_id": os.environ["GITHUB_RUN_ID"],
                  "attempt": os.environ["GITHUB_RUN_ATTEMPT"], "build_number": number, "upload_requested": upload,
                  "xcode_version": pin["xcode_version"], "xcode_build": pin["xcode_build"], "iphoneos_sdk": pin["iphoneos_sdk"]}
        (evidence / "provenance.json").write_text(json.dumps(result, indent=2) + "\n")
        base = ["xcodebuild", "-project", "ShotDeck.xcodeproj", "-scheme", "ShotDeck", "-configuration", "Release"]
        settings = command(base + ["-showBuildSettings", "-json", "-destination", "generic/platform=iOS"], "settings", raw, evidence)
        verify_settings(json.loads(settings.read_text()))
        auth = ["-allowProvisioningUpdates", "-authenticationKeyPath", str(key),
                "-authenticationKeyID", credentials["ASC_KEY_ID"], "-authenticationKeyIssuerID", credentials["ASC_ISSUER_ID"]]
        archive = ROOT / "build/ShotDeck.xcarchive"
        command(base + ["archive", "-destination", "generic/platform=iOS", "-archivePath", str(archive)] + auth +
                [f"DEVELOPMENT_TEAM={credentials['ASC_TEAM_ID']}", "CODE_SIGN_STYLE=Automatic", f"CURRENT_PROJECT_VERSION={number}"],
                "archive", raw, evidence)
        app = archive / "Products/Applications/ShotDeck.app"
        metadata = verify_archive(app, number)
        command(["codesign", "--verify", "--deep", "--strict", str(app)], "signature", raw, evidence, timeout=60)
        metadata["signature_verified"] = True
        (evidence / "archive-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        options = {"method": "app-store-connect", "signingStyle": "automatic", "teamID": credentials["ASC_TEAM_ID"],
                   "manageAppVersionAndBuildNumber": False, "uploadSymbols": True, "destination": "upload" if upload else "export"}
        if upload:
            options["uploadMethod"] = "app-store-connect"
        options_path = raw / "ExportOptions.plist"
        options_path.write_bytes(plistlib.dumps(options))
        started = datetime.now(timezone.utc)
        command(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(ROOT / "build/export"),
                 "-exportOptionsPlist", str(options_path)] + auth, "export-upload" if upload else "export-only", raw, evidence)
        if upload:
            apps = api("apps", {"filter[bundleId]": BUNDLE}, key, credentials)["data"]
            require(len(apps) == 1 and bool(re.fullmatch(r"[0-9]+", apps[0]["id"])), "ASC app record missing or ambiguous")
            app_id = apps[0]["id"]
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                builds = api("builds", {"filter[app]": app_id, "filter[version]": number, "sort": "-uploadedDate", "limit": 100}, key, credentials)["data"]
                processed = processed_build(builds, number, started)
                if processed:
                    processed.update(app_id=app_id, source_sha=result["source_sha"], run_id=result["run_id"])
                    (evidence / "processed-build.json").write_text(json.dumps(processed, indent=2) + "\n")
                    print(f"Processed ASC build: {processed['build_id']} (VALID)", flush=True)
                    break
                time.sleep(30)
            else:
                raise ValueError("Timed out waiting for exact attempt build to become VALID")
        else:
            require(bool(list((ROOT / "build/export").glob("*.ipa"))), "Dry-run IPA missing")
        print("Release acceptance: PASS" if upload else "Signed archive/export: PASS; upload and processing NOT exercised", flush=True)
    finally:
        # Raw tool output and signing material never become Actions artifacts.
        for path in raw.iterdir():
            if path.is_file():
                path.unlink()
        raw.rmdir()


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("upload", "dry-run"), "Usage: release.py upload|dry-run")
        os.chdir(ROOT)
        run(sys.argv[1] == "upload")
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        # Never print exception text: OS/Xcode errors can contain credentials.
        print("Release blocked. Inspect curated evidence (categories + fixed diagnostic codes) and the runbook; raw signing output is not published.", file=sys.stderr)
        sys.exit(1)
