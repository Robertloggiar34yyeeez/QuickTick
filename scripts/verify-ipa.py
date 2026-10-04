"""Validate a GitHub-built unsigned IPA before mounted Drive delivery."""
import sys,zipfile,plistlib,hashlib,struct,json
from pathlib import Path
ipa=Path(sys.argv[1]); checksum=Path(sys.argv[2]).read_text().split()[0].lower()
actual=hashlib.sha256(ipa.read_bytes()).hexdigest()
assert actual==checksum, 'Downloaded IPA does not match runner checksum'
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None
    info=plistlib.loads(z.read('Payload/QuicktickNative.app/Info.plist'))
    assert info['CFBundleSupportedPlatforms']==['iPhoneOS']
    assert info['CFBundleIdentifier']=='com.quicktick.QuicktickNative'
    assert info['QUICKTICK_API_BASE_URL']=='https://quick-tick-webb.vercel.app'
    executable=z.read('Payload/QuicktickNative.app/'+info['CFBundleExecutable'])
    magic=executable[:4]
    if magic==b'\xcf\xfa\xed\xfe': cpu=struct.unpack('<I',executable[4:8])[0]; assert cpu==0x0100000c
    elif magic in [b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf']:
        n=struct.unpack('>I',executable[4:8])[0]; stride=20 if magic==b'\xca\xfe\xba\xbe' else 32
        assert any(struct.unpack('>I',executable[8+i*stride:12+i*stride])[0]==0x0100000c for i in range(n))
    else: raise AssertionError('Not a supported arm64 Mach-O executable')
print(json.dumps({'result':'PASS','ipa':str(ipa),'bytes':ipa.stat().st_size,'sha256':actual,'platform':'iPhoneOS','cpu':'arm64','bundleIdentifier':info['CFBundleIdentifier'],'signing':'unsigned; user-requested AltStore/Sideloadly re-signing required'},indent=2))

