#!/usr/bin/env python3
"""Generate a small, deterministic Xcode project without third-party tooling."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'Gremma'
PROJECT = ROOT / 'Gremma.xcodeproj'
PROJECT.mkdir(exist_ok=True)

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value))

objects = []
def obj(name, value):
    objects.append(f'{ident(name)} = {{ {value} }};')
    return ident(name)

sources, resources, file_refs = [], [], []
for path in sorted(APP.rglob('*')):
    if any(parent.suffix == '.xcassets' for parent in path.parents):
        continue
    if path.suffix != '.xcassets' and (not path.is_file() or path.suffix not in ('.swift', '.json', '.entitlements')):
        continue
    rel = str(path.relative_to(APP))
    kind = {'.swift': 'sourcecode.swift', '.xcassets': 'folder.assetcatalog',
            '.json': 'text.json', '.entitlements': 'text.plist.entitlements'}[path.suffix]
    ref = obj('file:' + rel, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(rel)}; sourceTree = "<group>";')
    file_refs.append(ref)
    if path.suffix == '.entitlements':
        continue  # Signing input, not an app resource.
    build = obj('build:' + rel, f'isa = PBXBuildFile; fileRef = {ref};')
    (sources if path.suffix == '.swift' else resources).append(build)

app_ref = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Gremma.app; sourceTree = BUILT_PRODUCTS_DIR;')
group = obj('appgroup', 'isa = PBXGroup; children = (' + ','.join(file_refs) + '); path = Gremma; sourceTree = "<group>";')
products = obj('products', f'isa = PBXGroup; children = ({app_ref}); name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({group},{products}); sourceTree = "<group>";')
package = obj('package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/google-ai-edge/LiteRT-LM"; requirement = { kind = exactVersion; version = 0.18.1; };')
dependency = obj('dependency', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = LiteRTLM;')
framework = obj('framework', f'isa = PBXBuildFile; productRef = {dependency};')
source_phase = obj('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(sources) + '); runOnlyForDeploymentPostprocessing = 0;')
resource_phase = obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(resources) + '); runOnlyForDeploymentPostprocessing = 0;')
framework_phase = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework}); runOnlyForDeploymentPostprocessing = 0;')

def settings(values):
    return ' '.join(f'{key} = {quoted(value)};' for key, value in values.items())

project_settings = dict(ARCHS='arm64', CLANG_ENABLE_MODULES='YES', IPHONEOS_DEPLOYMENT_TARGET='18.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', SWIFT_STRICT_CONCURRENCY='targeted', ENABLE_USER_SCRIPT_SANDBOXING='YES')
target_settings = dict(PRODUCT_BUNDLE_IDENTIFIER='com.ajjkumar.aster2026', PRODUCT_NAME='$(TARGET_NAME)', INFOPLIST_FILE='Gremma/Info.plist', GENERATE_INFOPLIST_FILE='NO', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM='M82M5Y4R79', CODE_SIGN_IDENTITY='Apple Development', LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', ENABLE_PREVIEWS='YES')
# Keep the existing phone's app identity by default so a rename preserves its data.
# Other developers can supply their own signing identity without editing this script.
target_settings['DEVELOPMENT_TEAM'] = os.environ.get('GREMMA_DEVELOPMENT_TEAM', target_settings['DEVELOPMENT_TEAM'])
target_settings['PRODUCT_BUNDLE_IDENTIFIER'] = os.environ.get('GREMMA_BUNDLE_ID', target_settings['PRODUCT_BUNDLE_IDENTIFIER'])
target_settings['CODE_SIGN_ENTITLEMENTS'] = 'Gremma/Gremma.entitlements'
if (APP / 'Assets.xcassets' / 'AppIcon.appiconset').exists():
    target_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
for scope, base in [('project', project_settings), ('target', target_settings)]:
    configs=[]
    for mode in ['Debug', 'Release']:
        vals=base.copy()
        vals['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
        vals['DEBUG_INFORMATION_FORMAT']='dwarf' if mode=='Debug' else 'dwarf-with-dsym'
        if mode=='Debug': vals['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
        configs.append(obj(scope+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {settings(vals)} }}; name = {mode};'))
    obj(scope+'configs', 'isa = XCConfigurationList; buildConfigurations = (' + ','.join(configs) + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("targetconfigs")}; buildPhases = ({source_phase},{framework_phase},{resource_phase}); buildRules = (); dependencies = (); name = Gremma; packageProductDependencies = ({dependency}); productName = Gremma; productReference = {app_ref}; productType = "com.apple.product-type.application";')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 27.1; ProvisioningStyle = Automatic; }}; }}; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; packageReferences = ({package}); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target});')
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")}; }}\n')
scheme=PROJECT/'xcshareddata'/'xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
(scheme/'Gremma.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Gremma.app" BlueprintName="Gremma" ReferencedContainer="container:Gremma.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Gremma.app" BlueprintName="Gremma" ReferencedContainer="container:Gremma.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated {PROJECT}: {len(sources)} Swift files, {len(resources)} resources')
