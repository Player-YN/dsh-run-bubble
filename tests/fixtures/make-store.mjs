#!/usr/bin/env node
/**
 * Synthetic DSH session store generator for the smoke test.
 *
 * Mirrors what the Windows build of DSH actually writes:
 *   - one zstd *frame per event* appended to the same file (multi-frame),
 *   - `agent/inbox/spliced` as the carrier of the first real user prompt,
 *   - `assistant/message.data.usage` with the *Tokens field names,
 *   - `subagent/catalog` announcements for child agents,
 *   - a deliberately truncated trailing frame to prove partial writes are safe.
 *
 * A single-frame fixture would hide the concatenated-frame decoding bug, so the
 * frame-per-event layout is load-bearing: do not collapse it.
 */

import { zstdCompressSync } from 'node:zlib'
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'

const now = Date.now()

function frames(events, { partialTail = false } = {}) {
  const buffers = events.map((event) => zstdCompressSync(Buffer.from(`${JSON.stringify(event)}\n`, 'utf8')))
  if (partialTail) {
    // A half-written append: frame magic followed by a cut-off header. Decoding
    // it must fail locally without discarding the frames before it.
    buffers.push(Buffer.concat([Buffer.from([0x28, 0xb5, 0x2f, 0xfd]), Buffer.from([0x04, 0x00])]))
  }
  return Buffer.concat(buffers)
}

export function buildStore(root) {
  rmSync(root, { recursive: true, force: true })

  const project = join(root, 'sessions', '--C-Users-test-project--')
  const write = (sessionId, events, options) => {
    const dir = join(project, sessionId)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'session.v4.jsonl.zstd'), frames(events, options))
    return dir
  }

  const rootId = 'session-11111111-aaaa-4bbb-8ccc-dddddddddddd'
  const childId = '22222222-bbbb-4ccc-8ddd-eeeeeeeeeeee'
  const doneId = 'session-33333333-cccc-4ddd-8eee-ffffffffffff'
  const createdAt = now - 120_000

  write(
    rootId,
    [
      { type: 'session', version: 4, id: rootId, createdAt, cwd: 'C:\\Users\\test\\project', isSeeded: false, delegationDepth: 0, agentPreset: 'standard' },
      {
        type: 'agent/inbox/spliced',
        time: now - 119_000,
        data: { target: 'next-turn', start: 0, inserted: [{ role: 'user', content: [{ type: 'text', text: 'Current runtime context. ignore me' }], source: { kind: 'user' } }] }
      },
      {
        type: 'agent/inbox/spliced',
        time: now - 118_000,
        data: { target: 'next-turn', start: 0, inserted: [{ role: 'user', content: [{ type: 'text', text: 'Port the bubble to Windows' }], source: { kind: 'user' } }] }
      },
      { type: 'request/header', time: now - 117_000, data: { header: { config: { provider: 'deepseek-account', model: 'deepseek-flash', reasoningEffort: 'high', maxTokens: 256000 } } } },
      { type: 'session/title', time: now - 116_500, data: { title: 'Port the bubble to Windows', source: { kind: 'provider' } } },
      { type: 'turn/start', time: now - 116_000, data: { turn: 1 } },
      { type: 'assistant/message', time: now - 115_000, data: { turn: 1, step: 1, usage: { inputTokens: 1200, outputTokens: 90, cacheReadTokens: 4000, cacheWriteTokens: 0, totalTokens: 5290 } } },
      { type: 'turn/end', time: now - 114_000, data: { turn: 1, reason: { kind: 'completed' } } },
      { type: 'turn/start', time: now - 60_000, data: { turn: 2 } },
      { type: 'assistant/message', time: now - 59_000, data: { turn: 2, step: 1, usage: { inputTokens: 300, outputTokens: 10, cacheReadTokens: 100, cacheWriteTokens: 0, totalTokens: 410 } } },
      { type: 'subagent/catalog', time: now - 58_000, data: { version: 0, childId, childCreatedAt: now - 58_100, mode: 'continuable', label: 'render worker' } },
      // Trailing event whose frame is truncated: proves a half-written append is
      // dropped without losing the events before it (including the catalog).
      { type: 'job/registered', time: now - 57_500, data: { jobId: 'pwsh-deadbeef', kind: 'process', owner: rootId } }
    ],
    { partialTail: true }
  )

  write(childId, [
    { type: 'session', version: 4, id: childId, createdAt: now - 58_000, cwd: 'C:\\Users\\test\\project', parentSession: rootId, origin: 'subagent', isSeeded: false, delegationDepth: 1, agentPreset: 'standard' },
    { type: 'turn/start', time: now - 56_000, data: { turn: 1 } },
    { type: 'assistant/message', time: now - 55_000, data: { turn: 1, step: 1, usage: { inputTokens: 200, outputTokens: 20, cacheReadTokens: 50, cacheWriteTokens: 0, totalTokens: 270 } } }
  ])

  // Closed session: no dangling turn, therefore not active.
  write(doneId, [
    { type: 'session', version: 4, id: doneId, createdAt: now - 600_000, cwd: 'C:\\Users\\test\\old', isSeeded: false, delegationDepth: 0, agentPreset: 'standard' },
    { type: 'turn/start', time: now - 590_000, data: { turn: 1 } },
    { type: 'assistant/message', time: now - 580_000, data: { turn: 1, step: 1, usage: { inputTokens: 10, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 11 } } },
    { type: 'turn/end', time: now - 570_000, data: { turn: 1, reason: { kind: 'completed' } } }
  ])

  return { rootId, childId, doneId, project }
}
