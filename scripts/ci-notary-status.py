#!/usr/bin/env python3
"""Read notarization status on a protected hosted runner without uploading code."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from uuid import UUID, uuid4


class StatusError(Exception):
    pass


def identifier(value):
    """Normalize a UUID without reflecting invalid input in errors."""
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise StatusError("Submission ID must be a UUID.") from None


def timestamp(value):
    """Require an explicit timezone and normalize the timestamp to UTC."""
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            raise ValueError()
        return result.astimezone(timezone.utc)
    except (ValueError, TypeError, AttributeError):
        raise StatusError("Expected an ISO 8601 timestamp with a timezone.") from None


def summarize(payload, requested_id=None, since=None):
    """Expose only bounded status metadata, never filenames or raw API responses."""
    if not isinstance(payload, dict):
        raise StatusError("Unexpected notarization response.")
    records = [payload] if requested_id else payload.get("history")
    if not isinstance(records, list):
        raise StatusError("Unexpected notarization history response.")
    result = []
    for record in records:
        if not isinstance(record, dict):
            raise StatusError("Unexpected notarization history entry.")
        if not requested_id:
            name = record.get("name", "")
            if not isinstance(name, str) or not (name == "app.zip" or name.startswith("Remote-Dictate-Helper-")):
                continue
        item_id = identifier(record.get("id"))
        if requested_id and item_id != requested_id:
            raise StatusError("Notarization response has an unexpected submission ID.")
        created = timestamp(record.get("createdDate"))
        if not requested_id and since and created < since:
            continue
        status = record.get("status")
        if status not in {"Accepted", "In Progress", "Invalid", "Rejected"}:
            raise StatusError("Unexpected notarization status.")
        result.append({"id": item_id, "createdDate": created.isoformat(), "status": status})
    result.sort(key=lambda item: item["createdDate"], reverse=True)
    return {"submissions": result[:20], "truncated": len(result) > 20}


def command(arguments):
    """Keep credentials out of errors, including subprocess timeout messages."""
    try:
        result = subprocess.run([str(arg) for arg in arguments], capture_output=True,
                                text=True, timeout=90)
    except subprocess.TimeoutExpired:
        raise StatusError(f"{Path(arguments[0]).name} timed out.") from None
    if result.returncode:
        raise StatusError(f"{Path(arguments[0]).name} failed (exit {result.returncode}).")
    return result.stdout


def main():
    """Use a disposable credential profile; neither sign nor submit any package."""
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("GITHUB_REPOSITORY") != "elyrix-systems/remote-dictate-helper"
            or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or not os.environ.get("RUNNER_TEMP")):
        raise StatusError("This command requires the protected main workflow on GitHub Actions.")
    requested = os.environ.get("NOTARY_SUBMISSION_ID", "").strip()
    requested = identifier(requested) if requested else None
    since = os.environ.get("NOTARY_SINCE_UTC", "").strip()
    since = timestamp(since) if since else datetime.now(timezone.utc) - timedelta(days=1)
    for name in ("APPLE_ID", "APPLE_APP_PASSWORD", "APPLE_TEAM_ID"):
        if not os.environ.get(name):
            raise StatusError(f"Missing {name}.")
    with tempfile.TemporaryDirectory(prefix="rdh-notary-status-", dir=os.environ["RUNNER_TEMP"]) as directory:
        keychain = Path(directory) / "status.keychain-db"
        password = str(uuid4())
        try:
            command(["/usr/bin/security", "create-keychain", "-p", password, keychain])
            command(["/usr/bin/security", "set-keychain-settings", "-lut", "300", keychain])
            command(["/usr/bin/security", "unlock-keychain", "-p", password, keychain])
            command(["/usr/bin/xcrun", "notarytool", "store-credentials", "rdh-status",
                     "--keychain", keychain, "--apple-id", os.environ["APPLE_ID"],
                     "--team-id", os.environ["APPLE_TEAM_ID"],
                     "--password", os.environ["APPLE_APP_PASSWORD"]])
            operation = ["info", requested] if requested else ["history"]
            raw = command(["/usr/bin/xcrun", "notarytool", *operation,
                           "--keychain-profile", "rdh-status", "--keychain", keychain,
                           "--output-format", "json"])
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                raise StatusError("Unexpected notarization JSON response.") from None
            print(json.dumps(summarize(payload, requested, since), indent=2))
        finally:
            try:
                command(["/usr/bin/security", "delete-keychain", keychain])
            except StatusError:
                print("Warning: keychain removal failed; the hosted runner is disposable.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except StatusError as error:
        raise SystemExit(str(error)) from None
