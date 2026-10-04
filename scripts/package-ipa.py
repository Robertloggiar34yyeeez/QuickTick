"""Package only an actually compiled arm64 iOS app; this does not sign it."""
import sys,plistlib,zipfile,subprocess
from pathlib import Path
root=Path(sys.argv[1]); output=Path(sys.argv[2])
app=root/'Payload/QuicktickNative.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.quicktick.QuicktickNative'
assert info['CFBundleSupportedPlatforms']==['iPhoneOS']
assert 'arm64' in subprocess.check_output(['lipo','-archs',str(app/info['CFBundleExecutable'])],text=True)
output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
    for file in sorted(root.rglob('*')):
        if file.is_file(): z.write(file,file.relative_to(root).as_posix())
with zipfile.ZipFile(output) as z:
    assert z.testzip() is None
    assert 'Payload/QuicktickNative.app/QuicktickNative' in z.namelist()
print(f'Packaged real unsigned iPhoneOS arm64 app: {output}')
