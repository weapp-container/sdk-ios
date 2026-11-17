import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assetEntry, cleanSource, readRelease, releaseUrl, run, writeRelease, publishRelease } from '../tools/public-release.mjs';
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'weapp-finalize-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeFileSync(join(root, '.gitignore'), 'artifacts/\n');
  writeFileSync(join(root, 'package.json'), JSON.stringify({ version: '0.1.0-preview.7.0' }));
  mkdirSync(join(root, 'tools'));
  for (const name of ['package-release.mjs', 'public-release.mjs']) cpSync(fileURLToPath(new URL(`../tools/${name}`, import.meta.url)), join(root, 'tools', name));
  run('git', ['init', '-q'], root);
  commit(root);
  return root;
}
function commit(root) {
  run('git', ['add', '.'], root);
  run('git', ['-c', 'user.name=Publication Test', '-c', 'user.email=publication@example.invalid', 'commit', '-qm', 'Reviewed source'], root);
}

test('iOS finalization preserves the tested archive bytes across the reviewed pin commit', async t => {
  const root = fixture(t), out = join(root, 'artifacts'); mkdirSync(out);
  const producer = cleanSource(root);
  writeFileSync(join(out, 'native.zip'), 'inert native archive');
  writeFileSync(join(out, 'sdk.zip'), 'inert SDK archive');
  const assets = [assetEntry(out, 'native.zip', { component: 'swiftpm-native' }), assetEntry(out, 'sdk.zip', { component: 'cocoapods-sdk' })];
  const release = writeRelease(root, out, 'weapp-container/sdk-ios', assets);
  writeFileSync(join(root, 'release-assets.json'), JSON.stringify(release));
  writeFileSync(join(root, 'Package.swift'), `.binaryTarget(name: "WeappContainerNative", url: "${releaseUrl(release, assets[0])}", checksum: "${assets[0].sha256}")`);
  writeFileSync(join(root, 'WeappContainer.podspec'), `s.source = { :http => '${releaseUrl(release, assets[1])}', :sha256 => '${assets[1].sha256}', :flatten => true }`);
  commit(root);
  run(process.execPath, ['tools/package-release.mjs', '--out', out, '--finalize'], root);
  const finalized = readRelease(join(out, 'release.json'), release.repository, release.sdkVersion, true);
  assert.deepEqual(finalized.assets, assets);
  assert.equal(finalized.packagingSourceCommit, producer);
  assert.equal(finalized.sourceCommit, cleanSource(root));
  assert.equal((await publishRelease(root, join(out, 'release.json'))).published, false);
  writeFileSync(join(root, 'Package.swift'), 'incorrect public checksum');
  commit(root);
  assert.throws(() => run(process.execPath, ['tools/package-release.mjs', '--out', out, '--finalize'], root), /Install metadata differs/);
});
