"""Recover the exact public xtool source in the user's Drive ZIP and verify every file.

No private Drive download URL is written into the public repository or CI.
The source manifest was generated from xtool-main.zip, including its ZIP comment
(the upstream commit), and SHA-256 for every source/resource file in that ZIP.
"""
import hashlib, io, json, pathlib, urllib.request, zipfile

root = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'tools/xtool-source-manifest.json').read_text())
commit = manifest['commit']
assert len(commit) == 40 and all(c in '0123456789abcdef' for c in commit)
request = urllib.request.Request(f'https://codeload.github.com/xtool-org/xtool/zip/{commit}', headers={'User-Agent': 'QuickTick-build'})
with urllib.request.urlopen(request, timeout=90) as response:
    data = response.read(20 * 1024 * 1024)
archive = zipfile.ZipFile(io.BytesIO(data))
files = {name.split('/', 1)[1]: name for name in archive.namelist() if not name.endswith('/')}
assert set(files) == set(manifest['files']), 'xtool source differs from the supplied Drive archive'
destination = (root / 'tools/xtool-source').resolve()
for relative, expected in manifest['files'].items():
    target = (destination / relative).resolve()
    assert target.is_relative_to(destination), 'Unsafe archive path'
    payload = archive.read(files[relative])
    assert hashlib.sha256(payload).hexdigest() == expected, f'xtool source mismatch: {relative}'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    target.chmod(0o755 if (archive.getinfo(files[relative]).external_attr >> 16) & 0o111 else 0o644)
proof = {'source': 'user-provided xtool-main.zip', 'driveArchiveSHA256': manifest['archiveSHA256'], 'commit': commit,
         'verifiedFiles': len(files), 'everyFileMatchesDriveArchive': True}
(root / 'logs').mkdir(exist_ok=True)
(root / 'logs/xtool-source-verification.json').write_text(json.dumps(proof, indent=2))
print(json.dumps(proof, indent=2))
