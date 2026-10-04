"""Deliver an exact GitHub revision plus a verified GitHub-built unsigned IPA."""
import sys,json,hashlib,zipfile,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
metadata=json.loads((ROOT/'logs/github-final.json').read_text(encoding='utf-8'))
entries=json.loads((ROOT/'logs/final-source-tree.json').read_text(encoding='utf-8'))
local=ROOT/'deliverables'/metadata['revision']
drive=Path('E:/Meine Ablage/QuickTick iOS Revisions')/metadata['revision']
assert Path('E:/').exists(), 'Required Google Drive mount unavailable'
local.mkdir(parents=True,exist_ok=False)
source=local/'source'
for entry in entries:
    file=source/entry['path']; file.parent.mkdir(parents=True,exist_ok=True)
    file.write_bytes(entry['content'].encode('utf-8'))
archive=local/(metadata['revision']+'-source.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for file in sorted(source.rglob('*')):
        if file.is_file(): z.write(file,'source/'+file.relative_to(source).as_posix())
export=Path(metadata['exportDirectory'])
for name in ['QuickTick-0.6.24-unsigned.ipa','SHA256SUMS.txt','INSTALLATION.txt']: shutil.copy2(export/name,local/name)
logs=local/'logs'; logs.mkdir()
for name in ['github-xcode-version.txt','github-xcodebuild-test.txt','github-xcodebuild-archive.txt','native-test-results.zip','ipa-verification.json','provider-live-probes.json','project-audit.txt','swift-syntax.txt','sync-vector.txt']:
    file=ROOT/'logs'/name
    if file.exists(): shutil.copy2(file,logs/name)
for name in ['IOS-PORT-STATUS.md','GITHUB-BUILD-STATUS.md','CODEX-MASTER-PROMPT.md']: shutil.copy2(ROOT/name,local/name)
def sha(file): return hashlib.sha256(file.read_bytes()).hexdigest()
assert sha(local/'QuickTick-0.6.24-unsigned.ipa')==metadata['ipaSHA256']
manifest={**metadata,'drivePath':str(drive),'sourceZipSHA256':sha(archive),'files':[]}
for file in sorted(local.rglob('*')):
    if file.is_file(): manifest['files'].append({'path':file.relative_to(local).as_posix(),'bytes':file.stat().st_size,'sha256':sha(file)})
(local/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
assert not drive.exists(), 'Refusing to overwrite an existing revision'
drive.parent.mkdir(parents=True,exist_ok=True); shutil.copytree(local,drive)
files=[f for f in local.rglob('*') if f.is_file()]
for file in files:
    destination=drive/file.relative_to(local)
    assert destination.exists() and destination.stat().st_size==file.stat().st_size and sha(destination)==sha(file), str(destination)
verification={'result':'PASS','drivePath':str(drive),'localPath':str(local),'commitSHA':metadata['commitSHA'],'buildCommitSHA':metadata['buildCommitSHA'],'filesVerified':len(files),'ipaSHA256':sha(drive/'QuickTick-0.6.24-unsigned.ipa'),'ipaBytes':(drive/'QuickTick-0.6.24-unsigned.ipa').stat().st_size,'sourceZipSHA256':sha(drive/archive.name),'cloudSynchronization':'not observed; mounted-folder copy verified'}
report=json.dumps(verification,indent=2)
for file in [local/'DELIVERY-VERIFICATION.json',drive/'DELIVERY-VERIFICATION.json',ROOT/'logs/ipa-drive-delivery.json']: file.write_text(report,encoding='utf-8')
assert sha(local/'DELIVERY-VERIFICATION.json')==sha(drive/'DELIVERY-VERIFICATION.json')
print(report)

