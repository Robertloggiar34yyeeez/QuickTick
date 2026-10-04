"""Seal a native source revision and verify its mounted Google Drive copy."""
import hashlib,json,shutil,zipfile
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
ROOT=Path(__file__).resolve().parents[1]
revision='QuickTick-iOS-0.6.24-REV-'+datetime.now(ZoneInfo('Europe/Berlin')).strftime('%Y%m%d-%H%M%S')
local=ROOT/'deliverables'/revision
source=local/'source'
source.mkdir(parents=True,exist_ok=False)
def ignored(directory,names): return {n for n in names if n in {'.git','parser-deps','__pycache__','xcuserdata','DerivedData','node_modules','.env'} or n.startswith('.env.') and n!='.env.example'}
for name in ['ios-starter','reference-tests','reference-web','scripts','.github']:
    shutil.copytree(ROOT/name,source/name,ignore=ignored)
for file in ROOT.iterdir():
    if file.is_file() and file.name!='IOS-PORT-STATUS.md' and (file.suffix=='.md' or file.name=='.gitignore'): shutil.copy2(file,source/file.name)
shutil.copytree(ROOT/'logs',local/'logs')
shutil.copy2(ROOT/'CODEX-MASTER-PROMPT.md',local/'CODEX-MASTER-PROMPT.md')
archive=local/(revision+'-source.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for file in sorted(source.rglob('*')):
        if file.is_file(): z.write(file,'source/'+file.relative_to(source).as_posix())
def sha(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda:stream.read(1048576),b''): h.update(block)
    return h.hexdigest()
archive_hash=sha(archive)
mount=Path('E:/Meine Ablage/QuickTick iOS Revisions')
if not Path('E:/').exists(): destination=None
else:
    mount.mkdir(parents=True,exist_ok=True)
    destination=mount/revision
    if destination.exists(): raise RuntimeError('Unique destination already exists; refusing to overwrite')
report=(ROOT/'IOS-PORT-STATUS.md').read_text(encoding='utf-8-sig')
report+='\n## Sealed revision artifacts\n'
report+=f'- Local revision: `{local}`\n- Source ZIP: `{archive.name}`\n- Source ZIP SHA-256: `{archive_hash}`\n- Source ZIP size: {archive.stat().st_size} bytes.\n'
report+=f'- Drive destination: `{destination}`\n- Delivery verification: all file sizes and SHA-256 values are compared against the local revision; the script fails if any mismatch occurs. The successful result is recorded in DELIVERY-VERIFICATION.json.\n' if destination else '- Drive destination unavailable; no copy occurred.\n'
(ROOT/'IOS-PORT-STATUS.md').write_text(report,encoding='utf-8')
(local/'IOS-PORT-STATUS.md').write_text(report,encoding='utf-8')
manifest={'revision':revision,'repository':'https://github.com/Robertloggiar34yyeeez/QuickTick','branch':None,'preReplacementHEAD':None,'gitCommitSHA':None,'pushResult':'blocked: repository authentication/access unavailable','sourceZipSHA256':archive_hash,'files':[]}
for file in sorted(local.rglob('*')):
    if file.is_file(): manifest['files'].append({'path':file.relative_to(local).as_posix(),'bytes':file.stat().st_size,'sha256':sha(file)})
(local/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
if destination:
    shutil.copytree(local,destination)
    files=[p for p in local.rglob('*') if p.is_file()]
    for file in files:
        copy=destination/file.relative_to(local)
        assert copy.exists() and copy.stat().st_size==file.stat().st_size and sha(copy)==sha(file), str(copy)
    assert sha(destination/archive.name)==archive_hash
    assert len([p for p in destination.rglob('*') if p.is_file()])==len(files)
    verified={'result':'PASS','drivePath':str(destination),'localPath':str(local),'filesVerified':len(files),'zipSHA256':archive_hash,'zipBytes':archive.stat().st_size,'verification':'Every copied file exists and matches source bytes and SHA-256. Cloud synchronization not verified.'}
else: verified={'result':'DRIVE_UNAVAILABLE','localPath':str(local),'zipSHA256':archive_hash}
verification=json.dumps(verified,indent=2)
(local/'DELIVERY-VERIFICATION.json').write_text(verification,encoding='utf-8')
if destination:
    shutil.copy2(local/'DELIVERY-VERIFICATION.json',destination/'DELIVERY-VERIFICATION.json')
    assert sha(destination/'DELIVERY-VERIFICATION.json')==sha(local/'DELIVERY-VERIFICATION.json')
(ROOT/'logs/delivery-verification.json').write_text(verification,encoding='utf-8')
print(verification)
