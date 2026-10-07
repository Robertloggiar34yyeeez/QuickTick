import json,sys
from pathlib import Path
root=Path.cwd(); entries=[]
for directory in ['ios-starter','reference-tests','.github']:
    for file in sorted((root/directory).rglob('*')):
        if file.is_file(): entries.append({'path':file.relative_to(root).as_posix(),'mode':'100644','type':'blob','content':file.read_text(encoding='utf-8-sig')})
for file in sorted((root/'scripts').glob('*.py')):
    entries.append({'path':file.relative_to(root).as_posix(),'mode':'100644','type':'blob','content':file.read_text(encoding='utf-8-sig')})
for name in ['.gitignore','ARCHITECTURE.md','DOWNLOADS.md','GORSE-HYBRID-IOS.md','PROVIDER-CONTRACT-0.6.24.md','SYNC-COMPATIBILITY.md','CODEX-MASTER-PROMPT.md','IOS-PORT-STATUS.md','GITHUB-BUILD-STATUS.md']:
    entries.append({'path':name,'mode':'100644','type':'blob','content':(root/name).read_text(encoding='utf-8-sig')})
entries.append({'path':'README.md','mode':'100644','type':'blob','content':(root/'NATIVE-README.md').read_text(encoding='utf-8-sig')})
start = int(sys.argv[1]) if len(sys.argv) > 1 else 0
end = int(sys.argv[2]) if len(sys.argv) > 2 else len(entries)
print(json.dumps(entries[start:end]))
