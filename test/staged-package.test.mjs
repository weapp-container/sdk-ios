import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { localSwiftPackage } from '../tools/staged-package.mjs';
import { SDK_VERSION } from '../tools/native-input.mjs';

test('iOS candidate package, Pod version and native input are coordinated', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url)));
  const pod = readFileSync(new URL('../WeappContainer.podspec', import.meta.url), 'utf8');
  assert.equal(pkg.version, SDK_VERSION);
  assert.equal(pod.match(/s.version = '([^']+)'/)?.[1], SDK_VERSION);
});

test('generated SwiftPM installation consumes the newly built local XCFramework', () => {
  const source = readFileSync(new URL('../Package.swift', import.meta.url), 'utf8');
  assert.match(source, /url: "https:\/\//);
  const local = localSwiftPackage(source);
  assert.match(local, /path: "Frameworks\/WeappContainerNative.xcframework"/);
  assert.doesNotMatch(local, /url: "https:\/\//);
  assert.equal(localSwiftPackage(local), local);
  assert.throws(() => localSwiftPackage('missing target'));
  assert.throws(() => localSwiftPackage(source + source));
});
