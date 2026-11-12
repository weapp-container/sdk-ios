import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assetEntry, cleanSource, readRelease, releaseUrl, run, sha256, validateRelease, versionOf, writeRelease, publishRelease } from './public-release.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const out = resolve(option('--out') ?? join(root, 'artifacts/public'));
const manifest = join(out, 'release.json'), version = versionOf(root);
if (args.includes('--pin')) {
  const release = readRelease(manifest, 'weapp-container/sdk-ios', version, true);
  const native = release.assets.find(asset => asset.component === 'swiftpm-native');
  const sdk = release.assets.find(asset => asset.component === 'cocoapods-sdk');
  if (!native || !sdk) throw Error('Both SwiftPM and CocoaPods archives are required');
  let swift = readFileSync(join(root, 'Package.swift'), 'utf8');
  swift = swift.replace(/\.binaryTarget\(name: "WeappContainerNative", (?:path: "[^"]+"|url: "[^"]+", checksum: "[^"]+")\)/,
    `.binaryTarget(name: "WeappContainerNative", url: "${releaseUrl(release, native)}", checksum: "${native.sha256}")`);
  if (!swift.includes(native.sha256)) throw Error('Cannot locate SwiftPM binary target');
  writeFileSync(join(root, 'Package.swift'), swift);
  let pod = readFileSync(join(root, 'WeappContainer.podspec'), 'utf8');
  pod = pod.replace(/^  s.source = .*$/m, `  s.source = { :http => '${releaseUrl(release, sdk)}', :sha256 => '${sdk.sha256}' }`);
  writeFileSync(join(root, 'WeappContainer.podspec'), pod);
  writeFileSync(join(root, 'release-assets.json'), JSON.stringify(release, null, 2) + '\n');
  console.log('Pinned public assets. Review, refresh the source inventory, commit, then --finalize.');
} else if (args.includes('--finalize')) {
  const release = readRelease(manifest, 'weapp-container/sdk-ios', version, true);
  const pinned = validateRelease(JSON.parse(readFileSync(join(root, 'release-assets.json'))), release.repository, version);
  if (JSON.stringify(pinned.assets) !== JSON.stringify(release.assets)) throw Error('Committed pins differ from the archive set');
  const packagingSourceCommit = release.packagingSourceCommit ?? release.sourceCommit;
  if (pinned.sourceCommit !== packagingSourceCommit) throw Error('Committed pins differ from the packaging source');
  run('git', ['merge-base', '--is-ancestor', packagingSourceCommit, 'HEAD'], root);
  const native = release.assets.find(asset => asset.component === 'swiftpm-native');
  const sdk = release.assets.find(asset => asset.component === 'cocoapods-sdk');
  if (!native || !sdk) throw Error('Both public archives are required');
  const swift = readFileSync(join(root, 'Package.swift'), 'utf8');
  const pod = readFileSync(join(root, 'WeappContainer.podspec'), 'utf8');
  if (!swift.includes(`url: "${releaseUrl(release, native)}", checksum: "${native.sha256}"`) || !pod.includes(`:http => '${releaseUrl(release, sdk)}', :sha256 => '${sdk.sha256}'`)) throw Error('Install metadata differs from the reviewed public assets');
  const next = writeRelease(root, out, release.repository, release.assets);
  next.packagingSourceCommit = packagingSourceCommit;
  writeFileSync(manifest, JSON.stringify(next, null, 2) + '\n');
  // Regenerate the manifest checksum after adding its explicit packaging provenance.
  writeFileSync(join(out, 'SHA256SUMS'), [...next.assets, assetEntry(out, 'release.json')].map(a => `${a.sha256}  ${a.fileName}`).join('\n') + '\n');
} else if (args.includes('--publish') || args.includes('--verify')) {
  console.log(JSON.stringify(await publishRelease(root, manifest, args.includes('--publish')), null, 2));
} else {
  if (process.platform !== 'darwin') throw Error('XCFramework ZIP assembly requires macOS');
  cleanSource(root);
  const input = resolve(option('--sdk') ?? join(root, 'artifacts/ios/WeappContainer'));
  const receipt = JSON.parse(readFileSync(join(input, 'build.json')));
  if (receipt.sdkVersion !== version || receipt.status !== 'built' || receipt.sourceDirty !== false || receipt.sourceCommit !== cleanSource(root) || !receipt.native?.length) throw Error('A successful matching SDK producer is required');
  for (const entry of receipt.artifacts) if (sha256(readFileSync(join(input, entry.file))) !== entry.sha256) throw Error(`SDK member changed: ${entry.file}`);
  mkdirSync(out, { recursive: true });
  const nativeName = `WeappContainerNative-${version}.xcframework.zip`, sdkName = `WeappContainer-${version}.zip`;
  for (const file of [nativeName, sdkName, 'release.json']) if (existsSync(join(out, file))) throw Error('Use a new output directory; release archives are immutable');
  const stage = join(out, '.sdk-stage');
  try {
    cpSync(input, join(stage, 'WeappContainer'), { recursive: true });
    run('ditto', ['-c', '-k', '--keepParent', join(input, 'Frameworks/WeappContainerNative.xcframework'), join(out, nativeName)], root);
    run('ditto', ['-c', '-k', '--keepParent', join(stage, 'WeappContainer'), join(out, sdkName)], root);
    writeRelease(root, out, 'weapp-container/sdk-ios', [assetEntry(out, nativeName, { component: 'swiftpm-native' }), assetEntry(out, sdkName, { component: 'cocoapods-sdk' })]);
  } finally { rmSync(stage, { recursive: true, force: true }); }
}
