import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const source = readFileSync(new URL('../Sources/WeappContainer/Session.swift', import.meta.url), 'utf8')

function bodyAfter(text, marker) {
  const start = text.indexOf(marker)
  assert.notEqual(start, -1, `Missing ${marker}`)
  const open = text.indexOf('{', start)
  let depth = 1
  for (let end = open + 1; end < text.length; end++) {
    if (text[end] === '{') depth++
    else if (text[end] === '}' && --depth === 0) return text.slice(open + 1, end)
  }
  assert.fail(`Unclosed ${marker}`)
}

test('journal queries cannot create a native owner or invalidate presentation', () => {
  const execute = bodyAfter(source, 'public func executeCommand(')
  const queryMarker = 'if name == "queryDevPackAttempt"'
  const query = bodyAfter(execute, queryMarker)
  assert.ok(execute.indexOf(queryMarker) < execute.indexOf('if native == nil'))
  assert.match(query, /guard let native/)
  assert.match(query, /await acquireGate\(\)/)
  assert.match(query, /defer \{ releaseGate\(\) \}/)
  assert.match(query, /try ensureOpen\(\)/)
  assert.match(query, /try Task\.checkCancellation\(\)/)
  assert.match(query, /return try native.command\(name, \.object\(payload\)\)/)
  for (const sideEffect of ['prepareView(', 'invalidate(', 'isLoaded =', 'attach(', 'drain(', 'drainEvents(', 'takeEvents', 'enqueue(', 'report(']) {
    assert.ok(!query.includes(sideEffect), `Passive query contains ${sideEffect}`)
  }
})

test('bounded native measurement can read journal metadata without waiting for a GPU gate', () => {
  const query = bodyAfter(source, 'public func queryDevPackAttemptForLayout(')
  assert.match(query, /try ensureOpen\(\)/)
  assert.match(query, /guard let native/)
  assert.match(query, /try native.command\("queryDevPackAttempt",/)
  assert.match(query, /try native.command\("state", \.object\(\[:\]\)\)/)
  assert.match(query, /return \.object\(\["receipt": receipt, "state": state\]\)/)
  assert.match(query, /"ownerId": \.string\(ownerId\)/)
  assert.match(query, /"attemptId": \.string\(attemptId\)/)
  for (const sideEffect of ['await ', 'acquireGate(', 'prepareView(', 'invalidate(', 'isLoaded =', 'attach(', 'drain(', 'drainEvents(', 'takeEvents', 'enqueue(', 'report(']) {
    assert.ok(!query.includes(sideEffect), `Passive metadata accessor contains ${sideEffect}`)
  }
})
