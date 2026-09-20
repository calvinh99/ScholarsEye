#!/usr/bin/env python3
"""Prepare and publish an immutable, signed ScholarsEye GitHub release."""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE_BIN = ROOT / "build/dependencies/Sparkle-2.10.0/bin"
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\Z")


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def decode_key(value, lengths, label):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError, TypeError):
        raise ReleaseError(f"{label} must be valid base64.") from None
    require(len(decoded) in lengths, f"{label} has an invalid length.")
    return decoded


def validate_config(config, repository):
    require(isinstance(repository, str) and REPO_RE.fullmatch(repository), "Repository must be OWNER/REPO.")
    require(not repository.endswith(('/.', '/..')), "Invalid repository name.")
    version = config.get("version")
    require(isinstance(version, str) and VERSION_RE.fullmatch(version), "version must be MAJOR.MINOR.PATCH.")
    build = config.get("build")
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build), "build must be a positive integer string.")
    private_repository = config.get("githubRepository", "")
    if private_repository:
        require(private_repository == repository, "githubRepository must match the release destination.")
        feed = f"https://api.github.com/repos/{repository}/releases/latest"
    else:
        feed = f"https://github.com/{repository}/releases/latest/download/appcast.xml"
    require(config.get("updateFeedURL") == feed, f"updateFeedURL must be {feed}")
    decode_key(config.get("publicEDKey", ""), {32}, "publicEDKey")
    return config


def version_tuple(value):
    return tuple(map(int, value.split('.')))


def validate_release_history(config, releases):
    tag = "v" + config["version"]
    require(not any(r.get("tag_name") == tag for r in releases),
            f"Release {tag} already exists. Bump version and build; published assets are never replaced. "
            "If an earlier attempt failed, inspect its draft before deleting that draft and retrying.")
    stable = [r for r in releases if not r.get("draft") and not r.get("prerelease")
              and VERSION_RE.fullmatch(r.get("tag_name", "")[1:]) and r.get("tag_name", "").startswith("v")]
    if not stable:
        return None
    latest = max(stable, key=lambda r: version_tuple(r["tag_name"][1:]))
    require(version_tuple(config["version"]) > version_tuple(latest["tag_name"][1:]),
            "version must be greater than every published stable version.")
    return latest


def validate_build_progress(config, previous_feed):
    try:
        root = ET.fromstring(previous_feed)
        builds = [int(node.text) for node in root.findall(f".//{{{SPARKLE_NS}}}version")]
    except (ET.ParseError, TypeError, ValueError):
        raise ReleaseError("The previous appcast has invalid build numbers.") from None
    require(builds and int(config["build"]) > max(builds), "build must exceed every build in the previous appcast.")


def validate_app(config, app):
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException):
        raise ReleaseError("Packaged app is missing or has an invalid Info.plist. Build and package it first.") from None
    validate_app_info(config, info)


def validate_app_info(config, info):
    expected = {"CFBundleIdentifier": "com.scholarseye.app", "CFBundleVersion": config["build"],
                "CFBundleShortVersionString": config["version"], "SUFeedURL": config["updateFeedURL"],
                "SUPublicEDKey": config["publicEDKey"], "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True}
    if config.get("githubRepository"):
        expected["ScholarsEyeGitHubRepository"] = config["githubRepository"]
    else:
        require(info.get("ScholarsEyeGitHubRepository", "") == "",
                "Public updates must not retain ScholarsEyeGitHubRepository; the app would still require private GitHub access.")
    for key, value in expected.items():
        require(info.get(key) == value, f"Packaged app {key} does not match the release configuration.")
    require(not any(k in info for k in ("ScholarsEyeRecordingsPath", "ScholarsEyeAnalysisScript")),
            "Packaged app still contains development-only paths.")


def asset_url(repository, asset_id):
    require(isinstance(asset_id, int) and not isinstance(asset_id, bool) and asset_id > 0,
            "GitHub returned an invalid release asset ID.")
    return f"https://api.github.com/repos/{repository}/releases/assets/{asset_id}"


def validate_appcast(config, repository, feed, archive, *, archive_asset_id=None):
    try:
        root = ET.fromstring(feed.read_bytes())
    except (OSError, ET.ParseError):
        raise ReleaseError("Sparkle did not generate a valid appcast.") from None
    items = root.findall("./channel/item")
    require(len(items) == 1, "The new release must contain exactly one update item.")
    item = items[0]
    require(item.findtext(f"{{{SPARKLE_NS}}}version") == config["build"], "Appcast build mismatch.")
    require(item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") == config["version"], "Appcast version mismatch.")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "Appcast has no download enclosure.")
    url = f"https://github.com/{repository}/releases/download/v{config['version']}/{archive.name}"
    if archive_asset_id is not None:
        require(config.get("githubRepository") == repository, "Authenticated asset URL requires GitHub repository configuration.")
        url = asset_url(repository, archive_asset_id)
    require(enclosure.get("url") == url, "Appcast archive URL must point to the exact release asset.")
    require(enclosure.get("length") == str(archive.stat().st_size), "Appcast archive size mismatch.")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "")
    decode_key(signature, {64}, "Archive signature")
    return signature


def run(arguments, *, private_key=None):
    # Never pass a private key as an argument, retain it in child environments, or echo it.
    environment = {k: v for k, v in os.environ.items() if k != "SPARKLE_PRIVATE_KEY"}
    result = subprocess.run([str(a) for a in arguments], cwd=ROOT, env=environment,
                            input=(private_key + "\n") if private_key else None,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        if private_key:
            detail = detail.replace(private_key, "[redacted]")
        raise ReleaseError(f"{Path(str(arguments[0])).name} failed: {detail}")
    return result.stdout


def preflight(config, repository):
    metadata = json.loads(run(["gh", "api", f"repos/{repository}"]))
    require(not metadata["private"] or config.get("githubRepository") == repository,
            "Private releases require githubRepository and the authenticated GitHub API feed configuration.")
    pages = json.loads(run(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"]))
    releases = [release for page in pages for release in page]
    latest = validate_release_history(config, releases)
    if latest and any(asset["name"] == "appcast.xml" for asset in latest.get("assets", [])):
        with tempfile.TemporaryDirectory(prefix="scholarseye-previous-feed-") as temp:
            path = Path(temp) / "appcast.xml"
            run(["gh", "release", "download", latest["tag_name"], "--repo", repository,
                 "--pattern", "appcast.xml", "--output", path])
            validate_build_progress(config, path.read_bytes())
    return latest


def prepare(config, repository, private_key, output):
    decode_key(private_key, {32, 64, 96}, "SPARKLE_PRIVATE_KEY")
    distribution = ROOT / "build/distribution"
    app = distribution / "ScholarsEye.app"
    validate_app(config, app)
    source = distribution / f"ScholarsEye-{config['version']}-macOS-AppleSilicon.zip"
    require(source.is_file(), "Packaged ZIP is missing. Run zsh scripts/package-macos.sh first.")
    try:
        with zipfile.ZipFile(source) as zipped:
            validate_app_info(config, plistlib.loads(zipped.read("ScholarsEye.app/Contents/Info.plist")))
    except (OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException):
        raise ReleaseError("ZIP is not a valid packaged ScholarsEye app.") from None
    require(not output.exists(), f"Output already exists: {output}. Choose a fresh --output directory.")
    output.mkdir(parents=True)
    archive = output / source.name
    shutil.copy2(source, archive)
    # An isolated directory prevents stale archives or appcasts entering this release.
    run([SPARKLE_BIN / "generate_appcast", "--ed-key-file", "-", "--maximum-deltas", "0",
         "--download-url-prefix", f"https://github.com/{repository}/releases/download/v{config['version']}/",
         "--link", f"https://github.com/{repository}/releases/tag/v{config['version']}",
         "-o", output / "appcast.xml", output], private_key=private_key)
    feed = output / "appcast.xml"
    signature = validate_appcast(config, repository, feed, archive)
    # Independently check against the configured public key, not just the signing key.
    run(["xcrun", "swift", "-module-cache-path", ROOT / "build/module-cache",
         ROOT / "scripts/verify-update-signature.swift", config["publicEDKey"], signature, archive])
    run([SPARKLE_BIN / "sign_update", "--ed-key-file", "-", "--verify", feed], private_key=private_key)
    return archive, feed


def rewrite_private_feed(config, repository, feed, archive, archive_asset_id, private_key):
    # Re-serialization deliberately discards the old embedded signature comment.
    # Sparkle signs the final bytes after the authenticated asset URL is known.
    root = ET.fromstring(feed.read_bytes())
    enclosure = root.find("./channel/item/enclosure")
    require(enclosure is not None, "Generated feed is missing its archive enclosure.")
    enclosure.set("url", asset_url(repository, archive_asset_id))
    ET.register_namespace("sparkle", SPARKLE_NS)
    feed.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))
    run([SPARKLE_BIN / "sign_update", "--ed-key-file", "-", feed], private_key=private_key)
    validate_appcast(config, repository, feed, archive, archive_asset_id=archive_asset_id)
    run([SPARKLE_BIN / "sign_update", "--ed-key-file", "-", "--verify", feed], private_key=private_key)


def draft_metadata(repository, tag):
    # The /releases/tags endpoint only returns published releases. Listing with
    # the write-authorized publishing token includes drafts and their assets.
    pages = json.loads(run(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"]))
    matches = [item for page in pages for item in page if item.get("tag_name") == tag]
    require(len(matches) == 1 and matches[0].get("draft") is True,
            "Expected exactly one unpublished draft for this version.")
    return matches[0]


def uploaded_archive_id(metadata, archive):
    matches = [asset for asset in metadata.get("assets", []) if asset.get("name") == archive.name]
    require(len(matches) == 1 and matches[0].get("state") == "uploaded",
            "GitHub did not finish uploading the release archive.")
    require(matches[0].get("size") == archive.stat().st_size, "Uploaded archive size does not match the signed ZIP.")
    asset_id = matches[0].get("id")
    require(isinstance(asset_id, int) and not isinstance(asset_id, bool) and asset_id > 0,
            "GitHub returned an invalid release archive ID.")
    return asset_id


def publish(config, repository, archive, feed, *, private_key=None):
    tag = "v" + config["version"]
    commit = os.environ.get("GITHUB_SHA") or run(["git", "rev-parse", "HEAD"]).strip()
    authenticated = bool(config.get("githubRepository"))
    require(not authenticated or private_key, "Private releases need the signing key to finalize the feed.")
    # Draft release assets are excluded from /releases/latest. Private archives
    # must be uploaded first so their API asset ID can enter the signed feed.
    initial_assets = [archive] if authenticated else [archive, feed]
    arguments = ["gh", "release", "create", tag, *initial_assets, "--repo", repository,
                 "--draft", "--title", f"ScholarsEye {config['version']}"]
    if repository == os.environ.get("GITHUB_REPOSITORY", repository):
        arguments += ["--target", commit, "--generate-notes"]
    else:
        # The source commit does not exist in a separate binary-only repository.
        arguments += ["--notes", f"ScholarsEye {config['version']} (build {config['build']})."]
    run(arguments)
    if authenticated:
        metadata = draft_metadata(repository, tag)
        require(metadata.get("draft") is True, "Release must remain a draft while preparing its feed.")
        archive_id = uploaded_archive_id(metadata, archive)
        rewrite_private_feed(config, repository, feed, archive, archive_id, private_key)
        run(["gh", "release", "upload", tag, feed, "--repo", repository])
        ready = draft_metadata(repository, tag)
        require(ready.get("draft") is True and uploaded_archive_id(ready, archive) == archive_id,
                "Draft archive changed while preparing its feed.")
        feed_assets = [asset for asset in ready.get("assets", []) if asset.get("name") == feed.name]
        require(len(feed_assets) == 1 and feed_assets[0].get("state") == "uploaded"
                and feed_assets[0].get("size") == feed.stat().st_size,
                "GitHub did not finish uploading the signed feed.")
    run(["gh", "release", "edit", tag, "--repo", repository, "--draft=false", "--latest"])
    print(f"Published https://github.com/{repository}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("SCHOLARSEYE_RELEASE_REPOSITORY") or os.environ.get("GITHUB_REPOSITORY"), help="Release destination OWNER/REPO")
    parser.add_argument("--check", action="store_true", help="Check config and release history without writing anything")
    parser.add_argument("--prepare-only", action="store_true", help="Sign and verify local assets without publishing or calling GitHub")
    parser.add_argument("--output", type=Path, help="Fresh directory for signed release assets")
    args = parser.parse_args()
    try:
        config = validate_config(json.loads((ROOT / "config/release.json").read_text()), args.repo)
        require(not (args.check and args.prepare_only), "Choose either --check or --prepare-only.")
        if not args.prepare_only:
            preflight(config, args.repo)
        if args.check:
            print(f"Release v{config['version']} (build {config['build']}) is ready to build.")
            return
        private_key = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
        require(private_key, "Set SPARKLE_PRIVATE_KEY to the exported Sparkle signing key; never commit it.")
        output = (args.output or ROOT / f"build/releases/v{config['version']}").resolve()
        archive, feed = prepare(config, args.repo, private_key, output)
        if args.prepare_only:
            print(f"Signed and verified {archive} and {feed}. Nothing published.")
            if config.get("githubRepository"):
                print("Private feed is staged only; publishing replaces its enclosure with the assigned GitHub asset ID and re-signs it.")
        else:
            # Recheck immediately before making any external changes.
            preflight(config, args.repo)
            publish(config, args.repo, archive, feed, private_key=private_key)
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
