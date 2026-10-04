import json, urllib.request, urllib.error, concurrent.futures
from pathlib import Path
base='https://quick-tick-webb.vercel.app'
def probe(provider):
    path='/api/'+provider+'?page=1'
    try:
        with urllib.request.urlopen(base+path,timeout=25) as response:
            data=response.read(); result=json.loads(data)
            return {'provider':provider,'http':response.status,'items':len(result.get('items',[])),'hasMore':result.get('hasMore'),'bytes':len(data)}
    except urllib.error.HTTPError as error:
        try: message=json.loads(error.read()).get('error','')
        except Exception: message='Non-JSON response'
        return {'provider':provider,'http':error.code,'error':message[:400]}
    except Exception as error: return {'provider':provider,'error':str(error)}
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool: results=list(pool.map(probe,['rule34','redgifs','pornhub','eporner','hanime']))
text=json.dumps(results,indent=2)
(Path(__file__).resolve().parents[1]/'logs/provider-live-probes.json').write_text(text)
print(text)
