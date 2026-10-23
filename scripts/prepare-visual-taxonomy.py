"""Build a compact offline artist/character lookup. Never runs on the device."""
from pathlib import Path
import csv,hashlib,json,urllib.request,heapq

REV='dd58c53'
SHA='d08bbc883c8b038d03c5f8a05a672baabeef70fd6662ebeb006c02fdfce8c9ec'
URL=f'https://huggingface.co/datasets/deepghs/site_tags/resolve/{REV}/rule34.xxx/tags.csv'
source=Path('build/visual-taxonomy/tags.csv');source.parent.mkdir(parents=True,exist_ok=True)
if not source.exists() or hashlib.sha256(source.read_bytes()).hexdigest()!=SHA:
    with urllib.request.urlopen(URL,timeout=90) as response,source.open('wb') as output:
        while chunk:=response.read(1024*1024): output.write(chunk)
assert hashlib.sha256(source.read_bytes()).hexdigest()==SHA
groups={'0':[],'1':[],'4':[]}
with source.open(encoding='utf-8-sig',newline='') as data:
    for row in csv.DictReader(data):
        kind=row['type']; name=row['name'].strip().lower().replace(' ','_')
        if kind in groups and name not in {'unknown_artist','anonymous_artist','unknown_character'} and row.get('ambiguous','').lower()!='true':
            count=int(row['count'])
            if count>=5: groups[kind].append((count,name))
general=sorted({name for _,name in heapq.nlargest(30000,groups['0'])})
artists=sorted({name for _,name in heapq.nlargest(20000,groups['1'])})
characters=sorted({name for _,name in heapq.nlargest(40000,groups['4'])})
assert 'palcomix' in artists and 'chun-li' in characters
out=Path('ios-starter/QuicktickNative/SemanticAssets');out.mkdir(parents=True,exist_ok=True)
payload=json.dumps({'version':'rule34-tags-dd58c53-v2','artists':artists,'characters':characters,'general':general},separators=(',',':'))
assert len(payload.encode())<=7*1024*1024
(out/'visual-tag-taxonomy.json').write_text(payload,encoding='utf-8')
(out/'visual-tag-attribution.txt').write_text(f'DeepGHS site_tags, Rule34 snapshot, revision {REV}.\nSource: {URL}\nSHA256: {SHA}\nCC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nModified: nonambiguous tag names with >=5 posts; top 30,000 general, 20,000 artists and 40,000 characters. Snapshot may omit newer or uncommon identities. No images or user data included.\n',encoding='utf-8')
print(json.dumps({'taxonomyBytes':len(payload.encode()),'artists':len(artists),'characters':len(characters),'general':len(general),'revision':REV}))
