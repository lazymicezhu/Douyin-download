#!/usr/bin/env python3
"""Generate a small dependency-free Xcode project. No secrets are build inputs."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = sorted((root / "DouyinLite").rglob("*.swift"))
objects = []
references, builds = [], []
for i, path in enumerate(files, 1):
    ref, build = f"A{i:023X}", f"B{i:023X}"
    relative = path.relative_to(root).as_posix()
    references.append(ref)
    builds.append(build)
    objects += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{relative}"; sourceTree = "<group>"; }};',
                f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};']
objects += [
'000000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2640;}; buildConfigurationList = 000000000000000000000010; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; knownRegions = (en, "zh-Hans", Base); mainGroup = 000000000000000000000002; productRefGroup = 000000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (000000000000000000000004); };',
'000000000000000000000002 = {isa = PBXGroup; children = (' + ','.join(references) + ',000000000000000000000008,000000000000000000000003); sourceTree = "<group>"; };',
'000000000000000000000003 = {isa = PBXGroup; children = (000000000000000000000005); name = Products; sourceTree = "<group>"; };',
'000000000000000000000004 = {isa = PBXNativeTarget; buildConfigurationList = 000000000000000000000020; buildPhases = (000000000000000000000006,000000000000000000000007); buildRules = (); dependencies = (); name = DouyinLite; productName = DouyinLite; productReference = 000000000000000000000005; productType = "com.apple.product-type.application"; };',
'000000000000000000000005 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DouyinLite.app; sourceTree = BUILT_PRODUCTS_DIR; };',
'000000000000000000000006 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(builds) + '); runOnlyForDeploymentPostprocessing = 0; };',
'000000000000000000000007 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (000000000000000000000009); runOnlyForDeploymentPostprocessing = 0; };',
'000000000000000000000008 = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = DouyinLite/Resources/Assets.xcassets; sourceTree = "<group>"; };',
'000000000000000000000009 = {isa = PBXBuildFile; fileRef = 000000000000000000000008; };',
'000000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (000000000000000000000011,000000000000000000000012); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };',
'000000000000000000000020 = {isa = XCConfigurationList; buildConfigurations = (000000000000000000000021,000000000000000000000022); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };',
]
common = 'CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0;'
target = 'PRODUCT_BUNDLE_IDENTIFIER = io.lazymice.douyinlite; PRODUCT_NAME = "$(TARGET_NAME)"; INFOPLIST_FILE = DouyinLite/Resources/Info.plist; TARGETED_DEVICE_FAMILY = 1; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGN_STYLE = Automatic; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; GENERATE_INFOPLIST_FILE = NO; ENABLE_PREVIEWS = YES;'
for number, name in [(11, "Debug"), (12, "Release"), (21, "Debug"), (22, "Release")]:
    settings = common if number < 20 else target
    if number < 20:
        settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if name == "Debug" else ' SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
    objects.append(f'0000000000000000000000{number} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};')
project_dir = root / "DouyinLite.xcodeproj"
scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(project_dir / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = 000000000000000000000001; }\n')
scheme = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000000000004" BuildableName="DouyinLite.app" BlueprintName="DouyinLite" ReferencedContainer="container:DouyinLite.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000000000004" BuildableName="DouyinLite.app" BlueprintName="DouyinLite" ReferencedContainer="container:DouyinLite.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(scheme_dir / "DouyinLite.xcscheme").write_text(scheme)
print(f"Generated project with {len(files)} Swift source files; no configuration secrets included.")
