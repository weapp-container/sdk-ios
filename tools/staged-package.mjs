import assert from 'node:assert/strict';

// Generated installations consume their own validated XCFramework, while the
// source repository keeps the previous public SwiftPM URL/checksum intact.
export function localSwiftPackage(source) {
  const target = /\.binaryTarget\(name: "WeappContainerNative", (?:path: "[^"]+"|url: "[^"]+", checksum: "[^"]+")\)/g;
  assert.equal([...source.matchAll(target)].length, 1, 'Expected exactly one reviewed native binary target');
  return source.replace(target, '.binaryTarget(name: "WeappContainerNative", path: "Frameworks/WeappContainerNative.xcframework")');
}
