#!/usr/bin/env node
/**
 * End-to-end smoke test for the daemon on a synthetic session store.
 *
 *   node tests/smoke.mjs
 *
 * Exits non-zero with a readable report when the contract drifts. Runs on
 * macOS and Windows; on Windows it also exercises the no-lock liveness path.
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildStore } from './fixtures/make-store.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const repo = dirname(here)
const home = mkdtempSync(join(tmpdir(), 'dsh-run-bubble-smoke-'))
const store = buildStore(home)
const statusPath = join(home, 'run-bubble', 'status.json')

const failures = []
const check = (name, actual, expected) => {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures.push(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`)
}

const child = spawn(process.execPath, [join(repo, 'daemon.mjs')], {
  cwd: repo,
  env: {
    ...process.env,
    DSH_HOME: home,
    RUN_BUBBLE_LOG_DIR: join(home, 'logs'),
    RUN_BUBBLE_INCLUDE_AMBIGUOUS: '1',
    RUN_BUBBLE_LIVE_MS: '600000',
    RUN_BUBBLE_STALE_MS: '900000'
  },
  stdio: ['ignore', 'pipe', 'pipe']
})

let stderr = ''
child.stderr.on('data', (chunk) => { stderr += chunk.toString() })
child.stdout.on('data', (chunk) => { process.stdout.write(`[daemon] ${chunk}`) })

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function waitForStatus(timeoutMs = 15_000) {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    if (existsSync(statusPath)) {
      try {
        const doc = JSON.parse(readFileSync(statusPath, 'utf8'))
        if (doc && Array.isArray(doc.roots) && doc.updatedAt > 0) return doc
      } catch {}
    }
    await sleep(200)
  }
  return null
}

try {
  const doc = await waitForStatus()
  if (!doc) {
    console.error('\nstatus.json was never written')
    if (stderr) console.error(stderr)
    process.exit(1)
  }

  check('schemaVersion', doc.schemaVersion, 2)
  check('daemonPid is number', typeof doc.daemonPid, 'number')
  check('roots count', doc.roots.length, 1)

  const root = doc.roots[0] || {}
  check('root id', root.id, store.rootId)
  check('root shortId strips prefix', root.shortId, '11111111')
  check('root title from first real prompt', root.title, 'Port the bubble to Windows')
  check('root model', root.model, 'deepseek-flash')
  check('root effort', root.reasoningEffort, 'high')
  check('root active', root.active, true)
  check('root turn', root.turn, 2)
  check('root childCount', root.children.length, 1)
  check('child id', root.children[0]?.id, store.childId)
  check('child label from descriptor', root.children[0]?.label, 'render worker')
  check('child active', root.children[0]?.active, true)
  check('root token total', root.tokens.total, 5700)
  check('child token total', root.children[0]?.tokens.total, 270)
  check('totals.sessions', doc.totals.sessions, 1)
  check('totals.children', doc.totals.children, 1)
  check('totals.activeChildren', doc.totals.activeChildren, 1)
  check('totals.tokens', doc.totals.tokens.total, 5970)
  check('finished session excluded', doc.roots.some((item) => item.id === store.doneId), false)

  const daemonState = JSON.parse(readFileSync(join(home, 'run-bubble', 'daemon.json'), 'utf8'))
  check('daemon.json has pid', typeof daemonState.pid, 'number')
  check('daemon.json has mode', typeof daemonState.mode, 'string')
} catch (error) {
  failures.push(`unexpected error: ${error?.stack || error}`)
} finally {
  child.kill()
  await sleep(250)
  rmSync(home, { recursive: true, force: true })
}

if (failures.length > 0) {
  console.error(`\n${failures.length} failure(s):`)
  for (const line of failures) console.error(`  - ${line}`)
  if (stderr) console.error(`\ndaemon stderr:\n${stderr}`)
  process.exit(1)
}
console.log('\nall checks passed')
