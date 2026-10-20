"""Build-time pinned WD Tagger v3 -> int8 Core ML, with numerical parity gates."""
from pathlib import Path
import csv,json,time,subprocess,shutil
import torch,numpy as np,timm,coremltools as ct
from timm.layers import set_fused_attn
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights

REPO='SmilingWolf/wd-vit-tagger-v3'
REV='7f6b584d0bd3f55c4531f14ba3d4761b2bccdc0f'
OUT=Path('ios-starter/QuicktickNative/SemanticAssets'); OUT.mkdir(parents=True,exist_ok=True)
BUILD=Path('build/wd-model'); BUILD.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(1); torch.set_num_interop_threads(1); set_fused_attn(False)
base=timm.create_model('vit_base_patch16_224',pretrained=False,img_size=448,num_classes=10861,
    class_token=False,global_pool='avg',fc_norm=False,act_layer='gelu_tanh').eval()
base.load_state_dict(load_file(hf_hub_download(REPO,'model.safetensors',revision=REV)),strict=True)
class Tagger(torch.nn.Module):
    def __init__(self): super().__init__(); self.base=base
    def forward(self,image): return torch.sigmoid(self.base(image))
wrapper=Tagger().eval()
torch.manual_seed(17); example=torch.rand(1,3,448,448)*2-1
traced=torch.jit.trace(wrapper,example,strict=False)
# Compute references before Core ML loads its native runtime. Intel macOS can
# crash in PyTorch's threading bridge when it runs after Core ML proxy creation.
fixtures=[]
for fixture in [example,torch.zeros_like(example)]:
    with torch.inference_mode(): reference=wrapper(fixture).numpy().reshape(-1).copy()
    fixtures.append((fixture.numpy().copy(),reference))
model=ct.convert(traced,inputs=[ct.TensorType(name='image',shape=(1,3,448,448),dtype=np.float32)],
    outputs=[ct.TensorType(name='probabilities',dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY)
# Preserve the patch projection and final tag classifier: their errors directly
# alter color evidence and confidence thresholds. Compress transformer weights.
protected={op.name:None for op in model._mil_program.functions['main'].operations
    if op.op_type=='conv' or (op.op_type=='linear' and not
        (op.weight.shape[0]==4*op.weight.shape[1] or op.weight.shape[1]==4*op.weight.shape[0]))}
compressed=linear_quantize_weights(model,OptimizationConfig(global_config=OpLinearQuantizerConfig(
    mode='linear_symmetric',dtype='int8',granularity='per_channel',weight_threshold=512),op_name_configs=protected))
compressed.author='SmilingWolf / QuickTick Core ML conversion'; compressed.license='Apache-2.0'
compressed.short_description='WD ViT Tagger v3; pinned weights; BGR normalized to [-1,1], white square letterbox, 448px.'
package=BUILD/'WDTaggerV3.mlpackage'; compressed.save(str(package))
compressed=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY)
report={'repo':REPO,'revision':REV,'precision':'int8 MLP weights; float16 attention/patch/classifier and compute','protectedOperations':list(protected),'input':'BGR NCHW [-1,1], white letterbox, 448x448','fixtures':[]}
for fixture,reference in fixtures:
    start=time.perf_counter(); result=compressed.predict({'image':fixture})['probabilities'].reshape(-1)
    error=float(np.max(np.abs(reference-result)))
    top=set(np.argsort(reference)[-64:]); overlap=len(top.intersection(np.argsort(result)[-64:]))/64
    uncompressed=model.predict({'image':fixture})['probabilities'].reshape(-1)
    print(json.dumps({'maxAbsoluteError':error,'top64Overlap':overlap,'uncompressedFloat16Error':float(np.max(np.abs(reference-uncompressed)))}),flush=True)
    assert np.isfinite(result).all() and error<0.06 and overlap>=0.85,(error,overlap)
    report['fixtures'].append({'maxAbsoluteError':error,'top64Overlap':overlap,'macCPUInferenceMs':(time.perf_counter()-start)*1000})
subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(OUT)],check=True)
labels=list(csv.DictReader(open(hf_hub_download(REPO,'selected_tags.csv',revision=REV),encoding='utf-8')))
assert len(labels)==10861
(OUT/'wd-v3-labels.json').write_text(json.dumps([{'name':x['name'],'category':int(x['category'])} for x in labels]),encoding='utf-8')
shutil.copy2(hf_hub_download(REPO,'README.md',revision=REV),OUT/'wd-v3-model-card.md')
report['compiledBytes']=sum(p.stat().st_size for p in (OUT/'WDTaggerV3.mlmodelc').rglob('*') if p.is_file())
assert report['compiledBytes']<150*1024*1024
report['devicePerformance']='Not measured on physical iPhone/iPad; synthetic conversion parity is not tag accuracy validation.'
Path('logs/wd-model-benchmark.json').write_text(json.dumps(report,indent=2)); print(json.dumps(report))
