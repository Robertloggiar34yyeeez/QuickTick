import json, base64, hashlib, re
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
root=Path(__file__).resolve().parents[1]
v=json.loads((root/'reference-tests/sync-vector-v1.json').read_text())
def dec(s): return base64.urlsafe_b64decode(s+'='*((-len(s))%4))
def enc(b): return base64.urlsafe_b64encode(b).decode().rstrip('=')
secret=dec(v['secretBase64Url'])
key=hashlib.sha256(b'quicktick-sync-encryption-v1:'+secret).digest()
assert key.hex()==v['expectedEncryptionKeyHex']
assert enc(hashlib.sha256(b'quicktick-sync-verifier-v1:'+secret).digest())==v['expectedVerifier']
plain=AESGCM(key).decrypt(dec(v['envelope']['iv']),dec(v['envelope']['data']),v['aad'].encode())
snapshot=json.loads(plain)
assert snapshot['version']==1
assert snapshot['exclusions']['tags']==['example_excluded']
assert enc(AESGCM(key).encrypt(dec(v['envelope']['iv']),plain,v['aad'].encode()))==v['envelope']['data']
swift=(root/'ios-starter/QuicktickNativeTests/SyncCryptoTests.swift').read_text()
assert re.search(r'static let dataVector = "([^"]+)"',swift).group(1)==v['envelope']['data']
print('PASS: independent AES-256-GCM web vector decrypt, exact re-encrypt, key/verifier and Swift fixture match (Swift tests not executed).')
