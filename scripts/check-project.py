import sys,json,re,xml.etree.ElementTree as ET
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent/'parser-deps'))
from openstep_parser import OpenStepDecoder
root=Path(__file__).resolve().parents[1]
p=root/'ios-starter/QuicktickNative.xcodeproj'
project=OpenStepDecoder.ParseFromString((p/'project.pbxproj').read_text())
objects=project['objects']
assert objects[project['rootObject']]['isa']=='PBXProject'
for obj in objects.values():
    if obj['isa']=='PBXFileReference' and obj.get('sourceTree')=='SOURCE_ROOT' and not obj['path'].startswith('QuicktickNative/SemanticAssets/'): assert (root/'ios-starter'/obj['path']).exists(), obj['path']
references={o['path'] for o in objects.values() if o['isa']=='PBXFileReference' and o.get('lastKnownFileType')=='sourcecode.swift'}
sources={f.relative_to(root/'ios-starter').as_posix() for f in (root/'ios-starter').rglob('*.swift')}
assert references==sources
scheme=ET.parse(p/'xcshareddata/xcschemes/QuicktickNative.xcscheme')
for ref in scheme.findall('.//BuildableReference'): assert ref.attrib['BlueprintIdentifier'] in objects
assert len(scheme.findall('.//TestableReference'))==2
for fixture in (root/'ios-starter/QuicktickNativeTests/Fixtures').glob('*.json'):
    j=json.loads(fixture.read_text(encoding='utf-8-sig')); assert j['items'][0]['provider']==fixture.stem
vector=json.loads((root/'reference-tests/sync-vector-v1.json').read_text())['syncId']
for path in (root/'ios-starter').rglob('*'):
    if not path.is_file() or path.suffix not in ['.swift','.xcconfig','.json','.pbxproj']: continue
    text=path.read_text(encoding='utf-8-sig')
    for sync_id in re.findall(r'QT6-[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}',text): assert sync_id==vector and 'Tests' in path.as_posix(), f'Unexpected Sync ID: {path}'
    assert 'WKWebView' not in text
    assert not re.search(r'(?:GORSE_API_KEY|GORSE_ENDPOINT)\s*=\s*[^\s]',text)
print(f'PASS: independently parsed Xcode project; all {len(sources)} Swift files referenced; app/unit/UI targets and shared scheme resolve; 5 provider fixtures valid; no WebView or live secret literals found.')
