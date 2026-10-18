#!/usr/bin/env node
/**
 * dsh-run-bubble daemon — standalone status collector.
 *
 * Runs independently of the DeepSeek Harness desktop app. It watches the
 * shared session store, folds externally driven sessions into a small JSON
 * document, and writes it atomically for the native overlay.
 *
 * No npm dependencies: Node built-ins plus the `zstd` CLI (Homebrew or
 * /usr/bin/zstd). The DSH sessions are append-only JSONL frames compressed
 * with zstd; the daemon decodes a log only when its size/mtime changes.
 */

import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync, appendFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const HOME = process.env.HOME || homedir()
const DSH_HOME = process.env.DSH_HOME || join(HOME, '.dsh')
const SESSION_ROOT = join(DSH_HOME, 'sessions')
const STATUS_DIR = process.env.RUN_BUBBLE_STATUS_DIR || join(DSH_HOME, 'run-bubble')
const STATUS_FILE = join(STATUS_DIR, 'status.json')
const STATE_FILE = join(STATUS_DIR, 'daemon.json')
const LOG_DIR = join(HOME, 'Library', 'Logs', 'dsh-run-bubble')
const LOG_FILE = join(LOG_DIR, 'daemon.log')
const TICK_MS = 1500
const RECENT_WINDOW_MS = 6 * 60 * 60 * 1000
const SIDECAR_DIR = join(DSH_HOME, 'run-bubble', 'sessions')
const SOURCE_INFER_TTL_MS = 5000
const TASK_PREVIEW_LIMIT = 120

const ZSTD = [
  process.env.DSH_ZSTD,
  '/opt/homebrew/bin/zstd',
  '/usr/local/bin/zstd',
  '/usr/bin/zstd'
].find((candidate) => candidate && existsSync(candidate)) || 'zstd'

const emptyTokens = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 })

function log(line) {
  try {
    mkdirSync(LOG_DIR, { recursive: true })
    appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${line}\n`)
  } catch {}
}

function addTokens(target, usage) {
  if (!usage || typeof usage !== 'object') return
  const input = Number(usage.inputTokens) || 0
  const output = Number(usage.outputTokens) || 0
  const cacheRead = Number(usage.cacheReadTokens) || 0
  const cacheWrite = Number(usage.cacheWriteTokens) || 0
  const total = Number(usage.totalTokens) || input + output + cacheRead + cacheWrite
  target.input += input
  target.output += output
  target.cacheRead += cacheRead
  target.cacheWrite += cacheWrite
  target.total += total
}

function sumTokens(items) {
  const out = emptyTokens()
  for (const item of items) {
    const t = item?.tokens
    if (!t) continue
    out.input += t.input
    out.output += t.output
    out.cacheRead += t.cacheRead
    out.cacheWrite += t.cacheWrite
    out.total += t.total
  }
  return out
}

function fallbackTitle(header, shortId) {
  const cwd = typeof header?.cwd === 'string' ? header.cwd.replace(/\/+$/, '') : ''
  const base = cwd.split('/').filter(Boolean).pop()
  return base || `Session ${shortId}`
}

function collapseWhitespace(value) {
  return String(value || '').replace(/\s+/g, ' ').trim()
}

/** Collapse a preview to one short line; about 120 chars is what the bubble shows. */
function clampPreview(value) {
  return collapseWhitespace(value).slice(0, TASK_PREVIEW_LIMIT)
}

/** Text of a user/message event; only text parts are interesting for a preview. */
function userMessageText(data) {
  const content = data?.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const part of content) {
    if (typeof part?.text === 'string') parts.push(part.text)
  }
  return parts.join('\n')
}

/** Locate the newest canonical log in one session directory. */
function newestLog(dir) {
  let best = null
  let bestVersion = -1
  for (const name of readdirSync(dir)) {
    const match = /^session(?:\.v(\d+))?\.jsonl(?:\.zstd)?$/.exec(name)
    if (!match) continue
    const version = match[1] === undefined ? 0 : Number(match[1])
    if (version <= bestVersion) continue
    bestVersion = version
    best = join(dir, name)
  }
  return best
}

/** Enumerate the shared session store without relying on DSH packages. */
function listLogs() {
  const out = []
  try {
    for (const project of readdirSync(SESSION_ROOT, { withFileTypes: true })) {
      if (!project.isDirectory()) continue
      const projectDir = join(SESSION_ROOT, project.name)
      for (const session of readdirSync(projectDir, { withFileTypes: true })) {
        if (!session.isDirectory()) continue
        const dir = join(projectDir, session.name)
        const logPath = newestLog(dir)
        if (logPath) out.push({ id: session.name, dir, logPath })
      }
    }
  } catch {}
  return out
}

/** Decode one JSONL (optionally zstd) log into header + events. */
async function readLog(entry) {
  const stat = statSync(entry.logPath)
  const key = `${stat.size}:${stat.mtimeMs}`
  const cached = cache.get(entry.id)
  if (cached && cached.key === key) return cached

  let text
  if (entry.logPath.endsWith('.zstd')) {
    const { stdout } = await execFileAsync(ZSTD, ['-d', '-c', entry.logPath], {
      maxBuffer: 128 * 1024 * 1024,
      timeout: 15000
    })
    text = stdout
  } else {
    text = readFileSync(entry.logPath, 'utf8')
  }

  let header = null
  const state = {
    lastStart: null,
    lastEnd: null,
    title: '',
    model: '',
    reasoningEffort: '',
    label: '',
    firstPrompt: '',
    turn: 0,
    lastEventAt: 0,
    tokens: emptyTokens(),
    turnTokens: emptyTokens()
  }

  // Fold in one pass and retain only the summary: long external runs must not
  // grow the daemon's memory with a full event array.
  for (const line of text.split('\n')) {
    if (!line || line[0] !== '{') continue
    let value
    try {
      value = JSON.parse(line)
    } catch {
      continue
    }
    if (value.type === 'session') {
      header = value
      continue
    }
    const time = Number(value.time) || 0
    if (time > state.lastEventAt) state.lastEventAt = time
    switch (value.type) {
      case 'turn/start':
        state.lastStart = value
        state.lastEnd = null
        state.turn = Number(value.data?.turn) || state.turn + 1
        state.turnTokens = emptyTokens()
        break
      case 'turn/end':
        state.lastEnd = value
        break
      case 'session/title':
        if (typeof value.data?.title === 'string' && value.data.title.trim()) state.title = value.data.title.trim()
        break
      case 'request/header': {
        const config = value.data?.header?.config
        if (config) {
          if (typeof config.model === 'string') state.model = config.model
          if (typeof config.reasoningEffort === 'string') state.reasoningEffort = config.reasoningEffort
        }
        break
      }
      case 'model/selection':
        if (typeof value.data?.model === 'string') state.model = value.data.model
        if (typeof value.data?.reasoningEffort === 'string') state.reasoningEffort = value.data.reasoningEffort
        break
      case 'subagent/descriptor':
        if (typeof value.data?.label === 'string' && value.data.label.trim()) state.label = value.data.label.trim()
        if (typeof value.data?.agentModel === 'string') state.model = value.data.agentModel
        if (typeof value.data?.agentReasoningEffort === 'string') state.reasoningEffort = value.data.agentReasoningEffort
        break
      case 'user/message': {
        // The runtime-context and system-reminder messages are injected by the
        // harness; the first real user prompt is the useful preview.
        if (state.firstPrompt) break
        const text = collapseWhitespace(userMessageText(value.data))
        if (!text || text.startsWith('Current runtime context') || text.startsWith('<system-reminder>')) break
        state.firstPrompt = text.slice(0, TASK_PREVIEW_LIMIT)
        break
      }
      case 'assistant/message':
        addTokens(state.tokens, value.data?.usage)
        if (state.lastStart) addTokens(state.turnTokens, value.data?.usage)
        break
      default:
        break
    }
  }

  const result = { key, header, state }
  cache.set(entry.id, result)
  return result
}

/** PIDs of the running desktop host; their sessions are the app's own. */
async function desktopPids() {
  const now = Date.now()
  if (now - desktopPidsCache.at < 5000) return desktopPidsCache.value
  let value = new Set()
  try {
    const { stdout } = await execFileAsync('ps', ['-axo', 'pid=,command='], { timeout: 2000 })
    for (const line of stdout.split('\n')) {
      if (!line.includes('dsh-desktop-host/lib/index.js')) continue
      const match = /^\s*(\d+)\s+/.exec(line)
      if (match) value.add(Number(match[1]))
    }
  } catch {}
  desktopPidsCache = { at: now, value }
  return value
}

/** Holder PIDs for a session lock; `null` means the check was unavailable. */
async function lockHolders(lockPath) {
  const now = Date.now()
  const cached = holderCache.get(lockPath)
  if (cached && now - cached.at < 4000) return cached.value
  let value = null
  if (process.platform === 'darwin') {
    try {
      const { stdout } = await execFileAsync('lsof', ['-t', lockPath], { timeout: 1500 })
      value = stdout.trim().split(/\s+/).filter(Boolean).map(Number)
    } catch (error) {
      value = error?.code === 1 ? [] : null
    }
  }
  holderCache.set(lockPath, { at: now, value })
  return value
}

const SOURCE_LABELS = {
  codex: 'Codex',
  'claude-code': 'Claude Code',
  cursor: 'Cursor',
  'dsh-chat': 'DSH Chat',
  terminal: 'Terminal',
  unknown: 'Unknown'
}

const SOURCE_ALIASES = {
  codex: 'codex',
  chatgpt: 'codex',
  claude: 'claude-code',
  'claude-code': 'claude-code',
  cursor: 'cursor',
  'dsh-chat': 'dsh-chat',
  terminal: 'terminal',
  unknown: 'unknown'
}

function sourceKey(value) {
  return String(value || '').trim().toLowerCase().replace(/[\s_]+/g, '-')
}

function canonicalSource(value) {
  const key = sourceKey(value)
  return SOURCE_ALIASES[key] || key || 'unknown'
}

function defaultSourceLabel(source) {
  const key = sourceKey(source)
  if (SOURCE_LABELS[key]) return SOURCE_LABELS[key]
  if (!key) return 'Unknown'
  return key.split('-').filter(Boolean).map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')
}

/** Map one `ps` comm value (lowercased path included) to a launching agent. */
function sourceFromCommand(command) {
  const value = String(command || '').toLowerCase()
  if (!value) return null
  if (value.includes('codex') || value.includes('chatgpt')) return { source: 'codex', sourceLabel: 'Codex' }
  if (value.includes('claude')) return { source: 'claude-code', sourceLabel: 'Claude Code' }
  if (value.includes('cursor')) return { source: 'cursor', sourceLabel: 'Cursor' }
  if (value.includes('dsh-chat')) return { source: 'dsh-chat', sourceLabel: 'DSH Chat' }
  if (value.includes('iterm') || value.includes('terminal') || value.includes('zsh') || value.includes('bash') || value.includes('fish')) {
    return { source: 'terminal', sourceLabel: 'Terminal' }
  }
  return null
}

/** Per-session metadata sidecars; a missing or malformed file is simply ignored. */
function readSidecar(id) {
  try {
    const value = JSON.parse(readFileSync(join(SIDECAR_DIR, `${id}.json`), 'utf8'))
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null
  } catch {
    return null
  }
}

function explicitSourceValue(sidecar) {
  return typeof sidecar?.source === 'string' ? sidecar.source.trim() : ''
}

/** One `ps` row from the parent walk; only comm/ppid are read (no env/secrets). */
async function psRow(pid) {
  const { stdout } = await execFileAsync('ps', ['-o', 'ppid=,comm=', '-p', String(pid)], { timeout: 1000 })
  const line = stdout.trim()
  if (!line) return null
  const match = /^\s*(\d+)\s+(.+)$/.exec(line)
  if (!match) return null
  return { ppid: Number(match[1]), comm: match[2].trim() }
}

/** Infer the launching agent by walking the lock holder's parent chain. */
async function inferSource(pid) {
  if (!Number.isFinite(pid) || pid <= 0) return null
  const now = Date.now()
  const cached = sourceCache.get(pid)
  if (cached && now - cached.at < SOURCE_INFER_TTL_MS) return cached.value
  let value = null
  let terminal = null
  try {
    let current = pid
    for (let depth = 0; depth <= 8 && current > 0; depth += 1) {
      const row = await psRow(current)
      if (!row) break
      const match = sourceFromCommand(row.comm)
      if (match) {
        // A shell in the middle of the chain is weaker evidence than a known
        // agent executable higher up (Codex/Claude/Cursor). Keep walking.
        if (match.source === 'terminal') terminal = terminal || match
        else {
          value = match
          break
        }
      }
      current = row.ppid
    }
    if (!value) value = terminal
  } catch {}
  sourceCache.set(pid, { at: now, value })
  if (sourceCache.size > 64) {
    const ordered = [...sourceCache.entries()].sort((a, b) => a[1].at - b[1].at)
    for (const [id] of ordered.slice(0, sourceCache.size - 64)) sourceCache.delete(id)
  }
  return value
}

/** Explicit sidecar beats parent-chain inference; no signal means unknown. */
function resolveSource(sidecar, inferred) {
  const explicit = explicitSourceValue(sidecar)
  if (explicit) {
    const source = canonicalSource(explicit)
    const label = typeof sidecar?.sourceLabel === 'string' && sidecar.sourceLabel.trim()
      ? sidecar.sourceLabel.trim()
      : defaultSourceLabel(source)
    return { source, sourceLabel: label, sourceConfidence: 'explicit' }
  }
  if (inferred) return { ...inferred, sourceConfidence: 'inferred' }
  return { source: 'unknown', sourceLabel: 'Unknown', sourceConfidence: 'unknown' }
}

/** Stable 0..5 color assignment so a session keeps the same accent across ticks. */
function colorKeyFor(id) {
  let hash = 0
  for (let index = 0; index < id.length; index += 1) hash = (hash * 31 + id.charCodeAt(index)) >>> 0
  return hash % 6
}

function buildInfo(header, state, now, meta = {}) {
  const id = String(header.id)
  const active = state.lastStart !== null && (state.lastEnd === null || (Number(state.lastEnd.time) || 0) < (Number(state.lastStart.time) || 0))
  const startedAt = Number(state.lastStart?.time) || Number(header.createdAt) || now
  const elapsedMs = active
    ? Math.max(0, now - startedAt)
    : state.lastStart && state.lastEnd
      ? Math.max(0, (Number(state.lastEnd.time) || 0) - (Number(state.lastStart.time) || 0))
      : 0
  const shortId = id.slice(0, 8)
  const sidecar = meta.sidecar || null
  const explicitTitle = typeof sidecar?.title === 'string' ? sidecar.title.trim() : ''
  const sidecarTask = typeof sidecar?.task === 'string' ? clampPreview(sidecar.task) : ''
  const source = resolveSource(sidecar, meta.inferred)

  return {
    id,
    shortId,
    colorKey: colorKeyFor(id),
    parentSession: typeof header.parentSession === 'string' ? header.parentSession : null,
    depth: Number(header.delegationDepth) || 0,
    title: explicitTitle || state.title || state.label || fallbackTitle(header, shortId),
    titleSource: explicitTitle ? 'explicit' : 'fallback',
    source: source.source,
    sourceLabel: source.sourceLabel,
    sourceConfidence: source.sourceConfidence,
    taskPreview: sidecarTask || state.firstPrompt,
    cwd: typeof header.cwd === 'string' ? header.cwd : '',
    startedAt,
    elapsedMs,
    active,
    turn: state.turn,
    model: state.model,
    reasoningEffort: state.reasoningEffort,
    label: state.label,
    tokens: state.tokens,
    turnTokens: state.turnTokens,
    lastEventAt: state.lastEventAt,
    children: []
  }
}

function publicInfo(info) {
  return {
    id: info.id,
    shortId: info.shortId,
    colorKey: info.colorKey,
    parentSession: info.parentSession,
    depth: info.depth,
    title: info.title,
    titleSource: info.titleSource,
    source: info.source,
    sourceLabel: info.sourceLabel,
    sourceConfidence: info.sourceConfidence,
    taskPreview: info.taskPreview,
    cwd: info.cwd,
    startedAt: info.startedAt,
    elapsedMs: info.elapsedMs,
    active: info.active,
    turn: info.turn,
    model: info.model,
    reasoningEffort: info.reasoningEffort,
    label: info.label,
    tokens: info.tokens,
    turnTokens: info.turnTokens,
    children: info.children.map(publicInfo)
  }
}

let cache = new Map()
let holderCache = new Map()
let sourceCache = new Map()
let desktopPidsCache = { at: 0, value: new Set() }
let refreshing = false
let lastSnapshot = { schemaVersion: 2, updatedAt: 0, roots: [], totals: { sessions: 0, children: 0, activeChildren: 0, tokens: emptyTokens() }, daemonPid: process.pid }

async function refresh() {
  if (refreshing) return
  refreshing = true
  try {
    const now = Date.now()
    const desktops = await desktopPids()
    const entries = listLogs()
    const infos = []

    for (const entry of entries) {
      const lockPath = join(entry.dir, 'session.lock')
      const holders = await lockHolders(lockPath)
      // No holder means the run is gone; do not decode its log at all.
      if (holders && holders.length === 0) continue
      // Skip sessions owned by this machine's desktop host; the daemon is for
      // terminal-driven runs. When no desktop is running, all sessions count.
      if (holders && holders.some((pid) => desktops.has(pid))) continue

      let record
      try {
        record = await readLog(entry)
      } catch (error) {
        log(`read ${entry.id}: ${String(error)}`)
        continue
      }
      const header = record.header
      if (!header?.id) continue
      const depth = Number(header.delegationDepth) || 0
      if (depth > 1) continue
      const createdAt = Number(header.createdAt) || 0
      if (createdAt > 0 && now - createdAt > RECENT_WINDOW_MS) continue

      // Sidecar metadata is tiny and explicit; only fall back to the parent
      // chain when the launcher did not identify itself.
      const sidecar = readSidecar(entry.id)
      const inferred = !explicitSourceValue(sidecar) && holders && holders.length > 0
        ? await inferSource(holders[0])
        : null
      infos.push(buildInfo(header, record.state, now, { sidecar, inferred }))
    }

    const byId = new Map(infos.map((info) => [info.id, info]))
    const roots = []
    for (const info of infos) {
      if (!info.parentSession) {
        roots.push(info)
        continue
      }
      const parent = byId.get(info.parentSession)
      if (parent) parent.children.push(info)
    }

    const activeRoots = roots.filter((root) => root.active || root.children.some((child) => child.active))
    for (const root of activeRoots) {
      root.children.sort((a, b) => a.startedAt - b.startedAt)
      root.childCount = root.children.length
      root.activeChildCount = root.children.filter((child) => child.active).length
    }
    activeRoots.sort((a, b) => b.startedAt - a.startedAt)

    lastSnapshot = {
      schemaVersion: 2,
      updatedAt: now,
      daemonPid: process.pid,
      roots: activeRoots.map(publicInfo),
      totals: {
        sessions: activeRoots.length,
        children: activeRoots.reduce((count, root) => count + root.children.length, 0),
        activeChildren: activeRoots.reduce((count, root) => count + root.activeChildCount, 0),
        tokens: sumTokens(activeRoots.flatMap((root) => [root, ...root.children]))
      }
    }

    mkdirSync(STATUS_DIR, { recursive: true })
    const temp = `${STATUS_FILE}.tmp-${process.pid}`
    writeFileSync(temp, JSON.stringify(lastSnapshot), { mode: 0o600 })
    renameSync(temp, STATUS_FILE)
    writeFileSync(STATE_FILE, JSON.stringify({ pid: process.pid, startedAt: processStart, zstd: ZSTD }), { mode: 0o600 })

    if (cache.size > 64) {
      const ordered = [...cache.entries()].sort((a, b) => (a[1].key > b[1].key ? 1 : -1))
      for (const [id] of ordered.slice(0, cache.size - 64)) cache.delete(id)
    }
  } catch (error) {
    log(`refresh: ${String(error)}`)
  } finally {
    refreshing = false
  }
}

const processStart = Date.now()
log(`daemon start pid=${process.pid} zstd=${ZSTD} home=${DSH_HOME}`)
await refresh()
setInterval(() => { void refresh() }, TICK_MS)

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    try {
      writeFileSync(STATUS_FILE, JSON.stringify({ schemaVersion: 2, updatedAt: Date.now(), daemonPid: process.pid, roots: [], totals: { sessions: 0, children: 0, activeChildren: 0, tokens: emptyTokens() } }), { mode: 0o600 })
    } catch {}
    process.exit(0)
  })
}
