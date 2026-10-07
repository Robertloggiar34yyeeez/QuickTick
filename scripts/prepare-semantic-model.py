"""Pinned BGE Micro -> Core ML, with numerical parity and semantic smoke checks.
Build-time only; no Python/MLX/transformers dependency ships in the app.
"""
from pathlib import Path
import json,time,hashlib,subprocess,shutil
import torch,numpy as np,coremltools as ct
from transformers import AutoModel,AutoTokenizer
MODEL="TaylorAI/bge-micro-v2"
REVISION="3edf6d7de0faa426b09780416fe61009f26ae589"
OUT=Path("ios-starter/QuicktickNative/SemanticAssets");OUT.mkdir(parents=True,exist_ok=True)
CACHE=Path("build/semantic-model");CACHE.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(2)
tokenizer=AutoTokenizer.from_pretrained(MODEL,revision=REVISION)
base=AutoModel.from_pretrained(MODEL,revision=REVISION,attn_implementation="eager").eval()
class Embed(torch.nn.Module):
 def __init__(self): super().__init__();self.base=base
 def forward(self,input_ids,attention_mask):
  hidden=self.base(input_ids=input_ids,attention_mask=attention_mask,return_dict=False)[0]
  mask=attention_mask.unsqueeze(-1).to(hidden.dtype)
  pooled=(hidden*mask).sum(1)/mask.sum(1).clamp(min=1)
  return torch.nn.functional.normalize(pooled,dim=1)
def inputs(text):
 t=tokenizer(text,max_length=96,padding="max_length",truncation=True,return_tensors="pt")
 return t["input_ids"],t["attention_mask"]
wrapper=Embed().eval();example=inputs("Formula 1 engineering and aerodynamics")
traced=torch.jit.trace(wrapper,example,strict=False)
model=ct.convert(traced,inputs=[ct.TensorType(name="input_ids",shape=(1,96),dtype=np.int32),ct.TensorType(name="attention_mask",shape=(1,96),dtype=np.int32)],outputs=[ct.TensorType(name="embedding",dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY)
model.author="TaylorAI / QuickTick Core ML conversion"
model.license="MIT"
model.short_description="Pinned bge-micro-v2, 384-dimensional normalized masked mean embeddings; 96 WordPiece tokens."
package=CACHE/"BGEMicro.mlpackage";model.save(str(package))
subprocess.run(["xcrun","coremlcompiler","compile",str(package),str(OUT)],check=True)
from huggingface_hub import hf_hub_download
for remote,dest in [("vocab.txt","bge-vocab.txt"),("LICENSE","bge-license.txt")]: shutil.copy2(hf_hub_download(MODEL,remote,revision=REVISION),OUT/dest)
texts=["F1 aerodynamics McLaren engineering race car suspension","Ground effect downforce in racing cars","Baking chocolate cake","Ocean conservation coral reefs"]
start=time.perf_counter();vectors=[];parity=[];times=[]
for text in texts:
 ids,mask=inputs(text);t=time.perf_counter();v=model.predict({"input_ids":ids.numpy().astype(np.int32),"attention_mask":mask.numpy().astype(np.int32)})["embedding"].reshape(-1);times.append((time.perf_counter()-t)*1000)
 with torch.no_grad(): reference=wrapper(ids,mask).numpy().reshape(-1)
 parity.append(float(np.dot(v,reference)/(np.linalg.norm(v)*np.linalg.norm(reference))));vectors.append(v)
sim=lambda a,b:float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)))
assert min(parity)>.995,parity
assert sim(vectors[0],vectors[1])>sim(vectors[0],vectors[2])+.10
report={"model":MODEL,"revision":REVISION,"dimensions":384,"parameters":sum(p.numel() for p in base.parameters()),"compiledBytes":sum(p.stat().st_size for p in (OUT/"BGEMicro.mlmodelc").rglob("*") if p.is_file()),"macCPUInferenceMs":times,"parityCosine":parity,"relatedCosine":sim(vectors[0],vectors[1]),"unrelatedCosine":sim(vectors[0],vectors[2]),"devicePerformance":"Not measured on a physical iPhone/iPad"}
Path("logs").mkdir(exist_ok=True);Path("logs/semantic-model-benchmark.json").write_text(json.dumps(report,indent=2));print(json.dumps(report))
