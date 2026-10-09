#!/usr/bin/env python3
"""Local build and installation tools; standard library only, no shell evaluation."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "Remote Dictate Helper"
BUNDLE_ID = "systems.elyrix.RemoteDictateHelper"
LOCAL_IDENTITY = "Remote Dictate Helper Local Code Signing"


class ToolError(Exception):
    pass


def invoke(arguments, *, capture=False, environment=None):
    """Never include command arguments in errors: some tools accept passwords."""
    command = [str(part) for part in arguments]
    result = subprocess.run(command, cwd=ROOT, env=environment, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise ToolError(f"{Path(command[0]).name} failed (exit {result.returncode}).")
    return result.stdout.strip() if capture else ""


def selected_identity():
    if "REMOTE_DICTATE_CODESIGN_IDENTITY" in os.environ:
        return os.environ["REMOTE_DICTATE_CODESIGN_IDENTITY"]
    # A maintainer can retain an existing local certificate across rebuilds.
    # This private checkout preference is never packaged or committed.
    preference = ROOT / ".local-audit/signing-identity.txt"
    if preference.exists():
        identity = preference.read_text(encoding="utf-8").strip()
        if not identity or identity == "-" or "\n" in identity:
            raise ToolError("Local signing preference must name one certificate; select ad-hoc signing explicitly in the environment.")
        return identity
    return LOCAL_IDENTITY


def identity_hash(name):
    keychain = os.environ.get("REMOTE_DICTATE_KEYCHAIN")
    command = ["/usr/bin/security", "find-identity", "-p", "codesigning", "-v"]
    if keychain:
        command.append(keychain)
    inventory = invoke(command, capture=True)
    for record in inventory.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*', record)
        if match and match[2] == name:
            return match[1]
    return None


def sign(bundle, identifier):
    name = selected_identity()
    distribution = os.environ.get("REMOTE_DICTATE_DISTRIBUTION") == "1"
    if distribution and not name.startswith("Developer ID Application: "):
        raise ToolError("Distribution requires a Developer ID Application identity.")
    fingerprint = None if name == "-" else identity_hash(name)
    if not fingerprint and name != "-":
        raise ToolError("Signing identity unavailable. Run make setup-local-signing for a local build.")
    arguments = ["/usr/bin/codesign", "--force", "--identifier", identifier,
                 "--sign", fingerprint or "-"]
    if fingerprint and os.environ.get("REMOTE_DICTATE_KEYCHAIN"):
        arguments += ["--keychain", os.environ["REMOTE_DICTATE_KEYCHAIN"]]
    if distribution:
        arguments += ["--options", "runtime", "--timestamp"]
    invoke(arguments + [bundle])
    invoke(["/usr/bin/codesign", "--verify", "--strict", "--deep", bundle])
    if not fingerprint:
        print("Ad-hoc preview: Accessibility may need approval again after an update.", file=sys.stderr)


def prepare_identity():
    name = selected_identity()
    keychain = os.environ.get("REMOTE_DICTATE_KEYCHAIN")
    keychain_option = ["-k", keychain] if keychain else []
    if name == "-":
        print("Explicit ad-hoc signing selected; no certificate will be created.")
        return
    if identity_hash(name):
        print("The selected local signing identity is ready.")
        return
    if name.startswith("Developer ID") or not re.fullmatch(r"[A-Za-z0-9 ._()-]{1,100}", name):
        raise ToolError("Choose a local certificate name; this tool cannot issue Apple certificates.")
    existing = subprocess.run(["/usr/bin/security", "find-certificate", "-c", name] + ([keychain] if keychain else []),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if existing.returncode == 0:
        raise ToolError("A certificate with that name exists but cannot sign. Review its private key and code-signing trust in Keychain Access.")
    with tempfile.TemporaryDirectory(prefix="rdh-identity-") as directory:
        temporary = Path(directory)
        config = temporary / "request.cnf"
        config.write_text("\n".join([
            "[req]", "prompt = no", "distinguished_name = subject", "x509_extensions = usage",
            "[subject]", f"CN = {name}", "O = Remote Dictate Helper",
            "[usage]", "basicConstraints = critical,CA:FALSE",
            "keyUsage = critical,digitalSignature", "extendedKeyUsage = codeSigning", "",
        ]))
        private_key, certificate, export = (temporary / file for file in ("signing.key", "certificate.crt", "identity.p12"))
        invoke(["/usr/bin/openssl", "req", "-newkey", "rsa:3072", "-nodes", "-x509", "-sha256",
                "-days", "3650", "-config", config, "-keyout", private_key, "-out", certificate], capture=True)
        password = os.urandom(32).hex()
        environment = dict(os.environ, RDH_EXPORT_PASSWORD=password)
        invoke(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", private_key, "-in", certificate,
                "-out", export, "-name", name, "-passout", "env:RDH_EXPORT_PASSWORD"],
               capture=True, environment=environment)
        private_key.chmod(0o600)
        export.chmod(0o600)
        print("macOS may ask you to allow the local signing key and its code-signing trust.")
        invoke(["/usr/bin/security", "import", export, "-P", password, "-T", "/usr/bin/codesign"] + keychain_option, capture=True)
        invoke(["/usr/bin/security", "add-trusted-cert", "-p", "codeSign", "-r", "trustRoot"] + keychain_option + [certificate], capture=True)
    if not identity_hash(name):
        raise ToolError("Certificate setup is incomplete. Check code-signing trust in Keychain Access.")
    print("Local signing setup complete. The private key stays in your keychain.")


def bundle_metadata(version, build_number, diagnostics="0", diagnostic_text="0"):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ToolError("Version must be MAJOR.MINOR.PATCH.")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build_number):
        raise ToolError("Build number must contain only numeric components.")
    if diagnostics not in {"0", "1"}:
        raise ToolError("Diagnostics must be explicitly 0 or 1.")
    if diagnostic_text not in {"0", "1"} or (diagnostic_text == "1" and diagnostics != "1"):
        raise ToolError("Diagnostic text must be explicitly 0 or 1 and requires diagnostics.")
    metadata = {
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleName": PRODUCT,
        "CFBundleDisplayName": PRODUCT, "CFBundleExecutable": PRODUCT,
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en",
        "CFBundleShortVersionString": version, "CFBundleVersion": build_number,
        "CFBundleIconFile": "RemoteDictateHelper", "CFBundleIconName": "RemoteDictateHelper",
        "LSMinimumSystemVersion": "26.0", "LSUIElement": True,
    }
    if diagnostics == "1":
        metadata["RDDiagnosticLogging"] = True
    if diagnostic_text == "1":
        metadata["RDDiagnosticTextLogging"] = True
    return metadata


def build(output=None):
    version = os.environ.get("REMOTE_DICTATE_VERSION", (ROOT / "VERSION").read_text().strip())
    number = os.environ.get("REMOTE_DICTATE_BUILD_NUMBER")
    if number is None:
        try:
            number = invoke(["git", "rev-list", "--count", "HEAD"], capture=True)
        except ToolError:
            number = "1"
    metadata = bundle_metadata(version, number, os.environ.get("REMOTE_DICTATE_DIAGNOSTICS", "0"),
                              os.environ.get("REMOTE_DICTATE_DIAGNOSTIC_TEXT", "0"))
    configuration = os.environ.get("REMOTE_DICTATE_CONFIGURATION", "release")
    if configuration not in {"debug", "release"}:
        raise ToolError("Build configuration must be debug or release.")
    if os.environ.get("REMOTE_DICTATE_ARCHS", "arm64") != "arm64":
        raise ToolError("Only Apple silicon (arm64) builds are supported.")
    swift = ["/usr/bin/xcrun", "swift", "build", "--configuration", configuration,
             "--arch", "arm64", "--product", "remote-dictate-helper"]
    invoke(swift)
    binaries = Path(invoke(swift + ["--show-bin-path"], capture=True))
    output = Path(output or ROOT / ".build/apps").resolve()
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"{PRODUCT}.app"
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise ToolError("Build destination must be an ordinary application directory.")
    with tempfile.TemporaryDirectory(prefix=".rdh-build-", dir=output) as directory:
        staging = Path(directory) / destination.name
        contents = staging / "Contents"
        executable = contents / "MacOS" / PRODUCT
        executable.parent.mkdir(parents=True)
        shutil.copy2(binaries / "remote-dictate-helper", executable)
        executable.chmod(0o755)
        if configuration == "release":
            invoke(["/usr/bin/xcrun", "strip", "-S", executable])
        invoke(["/usr/bin/lipo", executable, "-verify_arch", "arm64"])
        resources = contents / "Resources"
        resources.mkdir()
        shutil.copy2(ROOT / "assets/RemoteDictateHelper.icns", resources)
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata, sort_keys=True))
        sign(staging, BUNDLE_ID)
        previous = Path(directory) / "previous.app"
        if destination.exists():
            destination.rename(previous)
        try:
            staging.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise
    print(destination)
    return destination


def ensure_stopped():
    for executable in (PRODUCT, "remote-dictate-helper"):
        result = subprocess.run(["/usr/bin/pgrep", "-x", executable], stdout=subprocess.DEVNULL)
        if result.returncode == 0:
            raise ToolError("Quit Remote Dictate Helper normally before installing.")
        if result.returncode != 1:
            raise ToolError("Cannot verify whether the helper is running; installation stopped.")


def install(*, setup=False):
    ensure_stopped()
    if setup:
        prepare_identity()
    source = build()
    folder = Path(os.environ.get("REMOTE_DICTATE_INSTALL_DIR", Path.home() / "Applications")).expanduser()
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / source.name
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise ToolError("Installation target is not an ordinary application directory.")
    (ROOT / ".local-audit").mkdir(mode=0o700, exist_ok=True)
    backups = ROOT / ".local-audit/install-backups"
    backups.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rdh-update-", dir=folder) as directory:
        staged = Path(directory) / source.name
        shutil.copytree(source, staged, symlinks=True)
        invoke(["/usr/bin/codesign", "--verify", "--strict", "--deep", staged])
        ensure_stopped()
        previous = Path(directory) / "previous.app"
        if target.exists():
            archive = Path(tempfile.mkdtemp(prefix="version-", dir=backups)) / source.name
            shutil.copytree(target, archive, symlinks=True)
            print(f"Previous version saved: {archive}")
            target.rename(previous)
        try:
            staged.rename(target)
        except OSError:
            if previous.exists():
                previous.rename(target)
            raise
    print(f"Installed: {target}")
    if os.environ.get("REMOTE_DICTATE_RESTART_AFTER_INSTALL", "1") == "1":
        invoke(["/usr/bin/open", target])


def icon(destination):
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rdh-icon-") as directory:
        work = Path(directory)
        renderer = work / "render"
        invoke(["/usr/bin/xcrun", "swiftc", ROOT / "Sources/RemoteDictateHelper/BrandIcon.swift",
                ROOT / "scripts/render-app-icon.swift", "-o", renderer])
        iconset = work / "App.iconset"
        invoke([renderer, iconset])
        invoke(["/usr/bin/iconutil", "-c", "icns", "-o", destination, iconset])
    print(destination)


def main():
    # Shipping app files must be readable by other Mac accounts. Signing material
    # is created only inside a private TemporaryDirectory with explicit modes.
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("build").add_argument("output", nargs="?")
    signer = commands.add_parser("sign")
    signer.add_argument("bundle", type=Path)
    signer.add_argument("identifier")
    commands.add_parser("setup-signing")
    commands.add_parser("install")
    commands.add_parser("install-local")
    commands.add_parser("icon").add_argument("destination")
    args = parser.parse_args()
    try:
        if sys.platform != "darwin":
            raise ToolError("These tools require macOS with Apple Command Line Tools.")
        if args.operation == "build": build(args.output)
        elif args.operation == "sign": sign(args.bundle, args.identifier)
        elif args.operation == "setup-signing": prepare_identity()
        elif args.operation == "install": install(setup=True)
        elif args.operation == "install-local": install()
        elif args.operation == "icon": icon(args.destination)
    except (ToolError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
