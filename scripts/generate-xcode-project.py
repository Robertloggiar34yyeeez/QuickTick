"""Generate the native Xcode project deterministically on Windows or macOS."""
import hashlib, plistlib
from pathlib import Path
from xml.sax.saxutils import escape
ROOT=Path(__file__).resolve().parents[1]/'ios-starter'
objects={}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_key,isa,**values):
    key=uid(object_key); objects[key]={'isa':isa,**values}; return key
def serialize(value, level=0):
    if isinstance(value,dict): return '{\n'+''.join('\t'*(level+1)+serialize(k)+' = '+serialize(v,level+1)+';\n' for k,v in value.items())+'\t'*level+'}'
    if isinstance(value,list): return '(\n'+''.join('\t'*(level+1)+serialize(v,level+1)+',\n' for v in value)+'\t'*level+')'
    return '"'+str(value).replace('\\','\\\\').replace('"','\\"')+'"'
refs=[]; source_ids={}; resource_ids={}
for path in sorted(ROOT.rglob('*')):
    if not path.is_file() or path.suffix not in ('.swift','.json','.xcconfig','.plist'): continue
    rel=path.relative_to(ROOT).as_posix()
    if not rel.startswith(('QuicktickNative/','QuicktickNativeTests/','QuicktickNativeUITests/','Config/')): continue
    ref=add('file:'+rel,'PBXFileReference',lastKnownFileType={'.swift':'sourcecode.swift','.json':'text.json','.xcconfig':'text.xcconfig','.plist':'text.plist.xml'}[path.suffix],path=rel,sourceTree='SOURCE_ROOT')
    refs.append(ref)
    if path.suffix=='.swift': source_ids[rel]=add('build:'+rel,'PBXBuildFile',fileRef=ref)
    if path.suffix=='.json': resource_ids[rel]=add('build:'+rel,'PBXBuildFile',fileRef=ref)
products=[]; targets=[]
for name,kind in [('QuicktickNative','application'),('QuicktickNativeTests','bundle.unit-test'),('QuicktickNativeUITests','bundle.ui-testing')]:
    if not (ROOT/name).exists(): continue
    app=kind=='application'
    product=add('product:'+name,'PBXFileReference',explicitFileType='wrapper.application' if app else 'wrapper.cfbundle',includeInIndex='0',path=name+('.app' if app else '.xctest'),sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    sources=add('sources:'+name,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=[v for k,v in source_ids.items() if k.startswith(name+'/')],runOnlyForDeploymentPostprocessing='0')
    resources=add('resources:'+name,'PBXResourcesBuildPhase',buildActionMask='2147483647',files=[v for k,v in resource_ids.items() if k.startswith(name+'/')],runOnlyForDeploymentPostprocessing='0')
    frameworks=add('frameworks:'+name,'PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0')
    configs=[]
    for config in ('Debug','Release'):
        settings={'PRODUCT_BUNDLE_IDENTIFIER':'com.quicktick.'+name,'PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','SWIFT_VERSION':'6.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','SWIFT_EMIT_LOC_STRINGS':'YES'}
        extra={}
        if app:
            settings.update({'MARKETING_VERSION':'0.6.24','CURRENT_PROJECT_VERSION':'2','INFOPLIST_KEY_QUICKTICK_API_BASE_URL':'$(QUICKTICK_API_BASE_URL)','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','INFOPLIST_KEY_CFBundleDisplayName':'Quicktick','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
            extra['baseConfigurationReference']=uid('file:Config/'+config+'.xcconfig')
            settings['GENERATE_INFOPLIST_FILE']='NO'
            settings['INFOPLIST_FILE']='Config/Info.plist'
        elif kind=='bundle.unit-test': settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/QuicktickNative.app/QuicktickNative','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
        else: settings['TEST_TARGET_NAME']='QuicktickNative'
        configs.append(add('config:'+name+config,'XCBuildConfiguration',buildSettings=settings,name=config,**extra))
    cfg=add('configs:'+name,'XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
    deps=[]
    if not app:
        proxy=add('proxy:'+name,'PBXContainerItemProxy',containerPortal=uid('project'),proxyType='1',remoteGlobalIDString=uid('target:QuicktickNative'),remoteInfo='QuicktickNative')
        deps=[add('dep:'+name,'PBXTargetDependency',target=uid('target:QuicktickNative'),targetProxy=proxy)]
    targets.append(add('target:'+name,'PBXNativeTarget',buildConfigurationList=cfg,buildPhases=[sources,frameworks,resources],buildRules=[],dependencies=deps,name=name,productName=name,productReference=product,productType='com.apple.product-type.'+kind))
products_group=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main_group=add('main','PBXGroup',children=refs+[products_group],sourceTree='<group>')
project_configs=[]
for config in ('Debug','Release'):
    settings={'SDKROOT':'iphoneos','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_VERSION':'6.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym'}
    if config=='Debug':
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)'
        settings['ENABLE_TESTABILITY']='YES'
        settings['ONLY_ACTIVE_ARCH']='YES'
        settings['COPY_PHASE_STRIP']='NO'
    project_configs.append(add('projectconfig:'+config,'XCBuildConfiguration',buildSettings=settings,name=config))
config_list=add('projectconfigs','XCConfigurationList',buildConfigurations=project_configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'1600'},buildConfigurationList=config_list,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main_group,productRefGroup=products_group,projectDirPath='',projectRoot='',targets=targets)
folder=ROOT/'QuicktickNative.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n',encoding='utf-8')
scheme_dir=folder/'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True,exist_ok=True)
def reference(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:"+name)}" BuildableName="{name}{".app" if name=="QuicktickNative" else ".xctest"}" BlueprintName="{name}" ReferencedContainer="container:QuicktickNative.xcodeproj"/>'
app_ref=reference('QuicktickNative')
tests=[name for name in ('QuicktickNativeTests','QuicktickNativeUITests') if (ROOT/name).exists()]
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
{''.join('<TestableReference skipped="NO">'+reference(n)+'</TestableReference>' for n in tests)}
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_dir/'QuicktickNative.xcscheme').write_text(scheme,encoding='utf-8')
print(f'Generated {folder}: {len(source_ids)} Swift sources, {len(resource_ids)} fixtures, {len(targets)} targets.')

