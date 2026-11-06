#!/usr/bin/env node
import { distributionOptions } from './distribution-identity.mjs';
import { verifySourceInventory } from './source-inventory.mjs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { copyVerifiedTree, option, readNative, readNotices, requireNativeRoot, sourceProvenance, nativeIdentity, SDK_VERSION } from './native-input.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const reviewedSource = verifySourceInventory(root);
const args = process.argv.slice(2);
const expectedDistribution = distributionOptions(args);
if (process.platform !== 'darwin') throw new Error('XCFramework assembly requires macOS and Xcode');
const native = requireNativeRoot(args);
const licenses = resolve(option(args, '--licenses-root', resolve(native, '../licenses')));
const out = resolve(option(args, '--out', resolve(root, 'artifacts/ios')));
const targets = ['aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios'];
const inputs = targets.map(target => ({ ...readNative(native, target, ['libweapp_container_sdk.a'], expectedDistribution), ...readNotices(native, licenses, target) }));
const packageRoot = resolve(out, 'WeappContainer');
const work = resolve(out, `.packaging-${process.pid}`);
if (existsSync(work)) throw new Error(`Packaging directory already exists: ${work}`);
mkdirSync(work, { recursive: true });
const commandEvidence=[];
function run(command, argv) {
  const result = spawnSync(command, argv, { cwd: root, stdio: 'inherit' });
  commandEvidence.push({command,args:argv,exitCode:result.status,error:result.error?.message});
  writeFileSync(resolve(out,'packaging-commands.json'),`${JSON.stringify(commandEvidence,null,2)}\n`);
  if (result.error || result.status !== 0) throw new Error(`${command} failed: ${result.error?.message || result.status}`);
}
const receipt = {
  schemaVersion: 1, sdkVersion: SDK_VERSION, ...expectedDistribution, status: 'building', profile: 'release',
  ...sourceProvenance(root), sourceInventorySha256: reviewedSource.inventorySha256, minimumIOS: '16.0',
  startedAt: new Date().toISOString(), targets, native: inputs.map(input => nativeIdentity(input.receipt)), artifacts: [],
};
const save = () => writeFileSync(resolve(out, 'build.json'), `${JSON.stringify(receipt, null, 2)}\n`);
save();
try {
  const headers = resolve(work, 'Headers'); mkdirSync(headers);
  cpSync(resolve(root, 'include/weapp_container_sdk.h'), resolve(headers, 'weapp_container_sdk.h'));
  writeFileSync(resolve(headers, 'module.modulemap'), 'module WeappContainerNative {\n  header "weapp_container_sdk.h"\n  export *\n}\n');
  const simulator = resolve(work, 'libweapp_container_sdk.a');
  run('xcrun', ['lipo', '-create', ...inputs.slice(1).map(input => resolve(input.directory, 'libweapp_container_sdk.a')), '-output', simulator]);
  const staged = resolve(work, 'WeappContainer'); mkdirSync(resolve(staged, 'Frameworks'), { recursive: true });
  run('xcodebuild', ['-create-xcframework', '-library', resolve(inputs[0].directory, 'libweapp_container_sdk.a'), '-headers', headers, '-library', simulator, '-headers', headers, '-output', resolve(staged, 'Frameworks/WeappContainerNative.xcframework')]);
  for (const name of ['Package.swift', 'WeappContainer.podspec', 'README.md', 'README.en.md', 'Sources', 'docs', 'LICENSE', 'CONTRACT.md', 'ORIGIN.json']) copyVerifiedTree(resolve(root, name), resolve(staged, name));
  cpSync(inputs[0].runtimeLicense, resolve(staged, 'RUNTIME-LICENSE'));
  for (let index = 0; index < targets.length; index++) copyVerifiedTree(inputs[index].notices, resolve(staged, 'licenses', targets[index]));
  const hashes = path => readdirSync(path, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? hashes(resolve(path, entry.name)) : [{ file: relative(staged, resolve(path, entry.name)), sha256: createHash('sha256').update(readFileSync(resolve(path, entry.name))).digest('hex') }]);
  receipt.artifacts = hashes(staged); receipt.status = 'built'; receipt.finishedAt = new Date().toISOString();
  writeFileSync(resolve(staged, 'build.json'), `${JSON.stringify(receipt, null, 2)}\n`);
  const backup = resolve(out, `.previous-${process.pid}`);
  if (existsSync(backup)) throw new Error('Previous-output backup already exists');
  if (existsSync(packageRoot)) renameSync(packageRoot, backup);
  try { renameSync(staged, packageRoot); }
  catch (error) { if (existsSync(backup)) renameSync(backup, packageRoot); throw error; }
  rmSync(backup, { recursive: true, force: true });
  if (args.includes('--install-framework')) {
    const destination = resolve(root, 'Frameworks');
    const temporary = resolve(root, `.Frameworks-${process.pid}`);
    const previous = resolve(root, `.Frameworks-previous-${process.pid}`);
    if (existsSync(temporary) || existsSync(previous)) throw new Error('Framework installation staging already exists');
    copyVerifiedTree(resolve(packageRoot, 'Frameworks'), temporary);
    if (existsSync(destination)) renameSync(destination, previous);
    try { renameSync(temporary, destination); }
    catch (error) { if (existsSync(previous)) renameSync(previous, destination); throw error; }
    rmSync(previous, { recursive: true, force: true });
  }
  save();
  console.log(JSON.stringify({ status: receipt.status, package: packageRoot, receipt: resolve(out, 'build.json') }, null, 2));
} catch (error) {
  receipt.status = 'failed'; receipt.error = error.message; receipt.finishedAt = new Date().toISOString(); save(); throw error;
} finally { rmSync(work, { recursive: true, force: true }); }
