import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
export function makeProject(directory, bundle, { cocoapods = false } = {}) {
  const project = resolve(directory, 'SDKConsumer.xcodeproj');
  mkdirSync(resolve(project, 'xcshareddata/xcschemes'), { recursive: true });
  const objects = [];
  let count = 0;
  const add = contents => { const id = (++count).toString(16).padStart(24, 'A'); objects.push(`${id} = {${contents}};`); return id; };
  const src = add('isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Consumer.swift; sourceTree = "<group>";');
  const tests = add('isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ConsumerUITests.swift; sourceTree = "<group>";');
  const resource = add('isa = PBXFileReference; lastKnownFileType = folder; path = "portable-pack"; sourceTree = "<group>";');
  const appProduct = add('isa = PBXFileReference; explicitFileType = wrapper.application; path = SDKConsumer.app; sourceTree = BUILT_PRODUCTS_DIR;');
  const testProduct = add('isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = SDKConsumerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;');
  const pkg = add('isa = XCLocalSwiftPackageReference; relativePath = WeappContainer;');
  const dep = add(`isa = XCSwiftPackageProductDependency; package = ${pkg}; productName = WeappContainer;`);
  const sdkBuild = add(`isa = PBXBuildFile; productRef = ${dep};`);
  const build = fileRef => add(`isa = PBXBuildFile; fileRef = ${fileRef};`);
  const sourcePhase = source => add(`isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (${build(source)}); runOnlyForDeploymentPostprocessing = 0;`);
  const framework = files => add(`isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (${files.join(',')}); runOnlyForDeploymentPostprocessing = 0;`);
  const resources = add(`isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (${build(resource)}); runOnlyForDeploymentPostprocessing = 0;`);
  const configList = settings => {
    const debug = add(`isa = XCBuildConfiguration; name = Debug; buildSettings = {${settings}};`);
    const release = add(`isa = XCBuildConfiguration; name = Release; buildSettings = {${settings} SWIFT_OPTIMIZATION_LEVEL = \"-O\"; DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";};`);
    return add(`isa = XCConfigurationList; buildConfigurations = (${debug},${release}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;`);
  };
  const common = 'SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 16.0; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_NAME = "$(TARGET_NAME)";';
  const appConfig = configList(common + `PRODUCT_BUNDLE_IDENTIFIER = "${bundle}"; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";`);
  const testConfig = configList(common + `PRODUCT_BUNDLE_IDENTIFIER = "${bundle}.tests"; SUPPORTED_PLATFORMS = iphonesimulator; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");`);
  const app = add(`isa = PBXNativeTarget; buildConfigurationList = ${appConfig}; buildPhases = (${sourcePhase(src)},${framework(cocoapods ? [] : [sdkBuild])},${resources}); buildRules = (); dependencies = (); name = SDKConsumer; packageProductDependencies = (${cocoapods ? '' : dep}); productName = SDKConsumer; productReference = ${appProduct}; productType = "com.apple.product-type.application";`);
  const test = add(`isa = PBXNativeTarget; buildConfigurationList = ${testConfig}; buildPhases = (${sourcePhase(tests)},${framework([])}); buildRules = (); dependencies = (); name = SDKConsumerTests; productName = SDKConsumerTests; productReference = ${testProduct}; productType = "com.apple.product-type.bundle.ui-testing";`);
  const products = add(`isa = PBXGroup; children = (${appProduct},${testProduct}); name = Products; sourceTree = "<group>";`);
  const group = add(`isa = PBXGroup; children = (${src},${tests},${resource},${products}); sourceTree = "<group>";`);
  const projectConfig = configList('CLANG_ENABLE_MODULES = YES; ENABLE_TESTING_SEARCH_PATHS = YES; SDKROOT = iphoneos;');
  const projectId = add(`isa = PBXProject; attributes = {LastUpgradeCheck = 1600;}; buildConfigurationList = ${projectConfig}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = ${group}; productRefGroup = ${products}; projectDirPath = ""; projectRoot = ""; packageReferences = (${cocoapods ? '' : pkg}); targets = (${app},${test});`);
  writeFileSync(resolve(project, 'project.pbxproj'), `// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={${objects.join('\n')}};rootObject=${projectId};}\n`);
  const ref = (id, name, buildable) => `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id}" BuildableName="${buildable}" BlueprintName="${name}" ReferencedContainer="container:SDKConsumer.xcodeproj"/>`;
  writeFileSync(resolve(project,'xcshareddata/xcschemes/SDKConsumer.xcscheme'), `<?xml version="1.0"?><Scheme version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">${ref(app,'SDKConsumer','SDKConsumer.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">${ref(test,'SDKConsumerTests','SDKConsumerTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug"><BuildableProductRunnable>${ref(app,'SDKConsumer','SDKConsumer.app')}</BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="NO"/></Scheme>`);
  return project;
}
