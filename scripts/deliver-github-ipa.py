"""Package a verified CI IPA and optionally export it to a configured directory.

Set QUICKTICK_REVISION_EXPORT_DIR to opt into an external copy. No personal
storage path is embedded in this public repository.
"""
import base64
import hashlib
import json
import os
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
metadata = json.loads((ROOT / "logs/github-final.json").read_text(encoding="utf-8"))
entries = json.loads((ROOT / "logs/final-source-tree.json").read_text(encoding="utf-8"))
local = ROOT / "deliverables" / metadata["revision"]
export_root = os.environ.get("QUICKTICK_REVISION_EXPORT_DIR")
destination = Path(export_root).expanduser() / metadata["revision"] if export_root else None
local.mkdir(parents=True, exist_ok=False)
source = local / "source"

for entry in entries:
    file = source / entry["path"]
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_bytes(
        base64.b64decode(entry["content"])
        if entry.get("encoding") == "base64"
        else entry["content"].encode("utf-8")
    )

archive = local / (metadata["revision"] + "-source.zip")
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
    for file in sorted(source.rglob("*")):
        if file.is_file():
            output.write(file, "source/" + file.relative_to(source).as_posix())

build_export = Path(metadata["exportDirectory"])
ipas = sorted(build_export.glob("*.ipa"))
if len(ipas) != 1:
    raise RuntimeError(f"Expected exactly one IPA in {build_export}, found {len(ipas)}")
ipa = local / ipas[0].name
shutil.copy2(ipas[0], ipa)
for name in ("SHA256SUMS.txt", "INSTALLATION.txt"):
    file = build_export / name
    if file.is_file():
        shutil.copy2(file, local / name)

logs = local / "logs"
logs.mkdir()
for name in (
    "github-xcode-version.txt", "github-xcodebuild-test.txt",
    "github-xcodebuild-archive.txt", "native-test-results.zip",
    "ipa-verification.json", "provider-live-probes.json",
    "project-audit.txt", "swift-syntax.txt", "sync-vector.txt",
    "sync-live-roundtrip.json"
):
    file = ROOT / "logs" / name
    if file.is_file():
        shutil.copy2(file, logs / name)
screenshots = ROOT / "logs/immersive-native-tests/screenshots"
if screenshots.is_dir():
    shutil.copytree(screenshots, logs / "screenshots")
for name in (
    "IOS-PORT-STATUS.md", "GITHUB-BUILD-STATUS.md",
    "IMMERSIVE-RELEASE-NOTES.md", "CODEX-MASTER-PROMPT.md"
):
    file = ROOT / name
    if file.is_file():
        shutil.copy2(file, local / name)

def sha(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

if sha(ipa) != metadata["ipaSHA256"]:
    raise RuntimeError("IPA checksum does not match the CI manifest")

manifest = {
    **metadata,
    "exportPath": str(destination) if destination else None,
    "sourceZipSHA256": sha(archive),
    "files": []
}
for file in sorted(local.rglob("*")):
    if file.is_file():
        manifest["files"].append({
            "path": file.relative_to(local).as_posix(),
            "bytes": file.stat().st_size,
            "sha256": sha(file)
        })
(local / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

files = [file for file in local.rglob("*") if file.is_file()]
if destination:
    if destination.exists():
        raise RuntimeError("Refusing to overwrite an existing export")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(local, destination)
    for file in files:
        copied = destination / file.relative_to(local)
        if not copied.is_file() or sha(copied) != sha(file):
            raise RuntimeError(f"Export verification failed: {file.relative_to(local)}")

verification = {
    "result": "PASS" if destination else "LOCAL_ONLY",
    "exportPath": str(destination) if destination else None,
    "localPath": str(local),
    "commitSHA": metadata["commitSHA"],
    "buildCommitSHA": metadata["buildCommitSHA"],
    "filesVerified": len(files) if destination else 0,
    "ipaSHA256": sha(ipa),
    "ipaBytes": ipa.stat().st_size,
    "sourceZipSHA256": sha(archive)
}
report = json.dumps(verification, indent=2)
(local / "DELIVERY-VERIFICATION.json").write_text(report, encoding="utf-8")
if destination:
    (destination / "DELIVERY-VERIFICATION.json").write_text(report, encoding="utf-8")
(ROOT / "logs/ipa-export-verification.json").write_text(report, encoding="utf-8")
print(report)
