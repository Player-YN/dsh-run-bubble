#!/usr/bin/env node
/**
 * dsh-run-bubble daemon — standalone status collector.
 *
 * Runs independently of the DeepSeek Harness desktop app. It watches the
 * shared session store, folds externally driven sessions into a small JSON
 * document, and writes it atomically for the native overlay.
 *
 * Cross-platform since the Windows port:
 *   - decode: darwin uses the `zstd` CLI; win32 uses `node:zlib` with a manual
 *     concatenated-frame walk (see src/win/zstd.mjs),
 *   - liveness: darwin uses `session.lock` + `lsof`; win32 uses DSH's named
 *     kernel write leases (`DshLeaseProbe.exe`, see src/win/liveness.mjs) and
 *     only falls back to sidecar/mtime heuristics when the probe is unavailable.
 *     `RUN_BUBBLE_INCLUDE_AMBIGUOUS` (default on) applies to the fallback path.
 *   - process table: darwin shells out to `ps`; win32 uses one cached CIM query
 *     (src/win/process-table.mjs).
 *
 * No npm dependencies, no network requests.
 */

import { execFile } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

import {
  canonicalSource,
  defaultSourceLabel,
  desktopHostPids,
  getProcessTable,
  inferSource as inferSourceFromTable,
  parentChain,
  sourceFromCommand
} from './src/win/process-table.mjs'
import {
  DEFAULT_LIVE_MS,
  DEFAULT_STALE_MS,
  externalCliPids,
  isZombie,
  judgmentMode,
  leaseHash,
  openTurnFromState,
  scanLeases,
  sidecarPid,
  sidecarSource,
  windowsLive,
  windowsOwnership
} from './src/win/liveness.mjs'
import { readZstdText } from './src/win/zstd.mjs'

const execFileAsync = promisify(execFile)
const PLATFORM = process.platform
const IS_WIN = PLATFORM === 'win32'

// `HOME` is usually empty on Windows; the profile directory is the source of
// truth there. On macOS keep the historical $HOME precedence.
const HOME = IS_WIN ? homedir() : (process.env.HOME || homedir())
const DSH_HOME = process.env.DSH_HOME || join(HOME, '.dsh')
const SESSION_ROOT = join(DSH_HOME, 'sessions')
const STATUS_DIR = process.env.RUN_BUBBLE_STATUS_DIR || join(DSH_HOME, 'run-bubble')
const STATUS_FILE = join(STATUS_DIR, 'status.json')
const STATE_FILE = join(STATUS_DIR, 'daemon.json')
const SIDECAR_DIR = join(DSH_HOME, 'run-bubble', 'sessions')
const GROK_HOME = process.env.GROK_HOME || join(HOME, '.grok')
const GROK_ACTIVE_FILE = join(GROK_HOME, 'active_sessions.json')
const GROK_SESSIONS = join(GROK_HOME, 'sessions')
const LOG_DIR = process.env.RUN_BUBBLE_LOG_DIR || (IS_WIN
  ? join(process.env.LOCALAPPDATA || join(HOME, 'AppData', 'Local'), 'dsh-run-bubble', 'logs')
  : join(HOME, 'Library', 'Logs', 'dsh-run-bubble'))
const LOG_FILE = join(LOG_DIR, 'daemon.log')
const TICK_MS = 1500
const RECENT_WINDOW_MS = 6 * 60 * 60 * 1000
const SOURCE_INFER_TTL_MS = 5000
const TASK_PREVIEW_LIMIT = 120
const MAX_COMPRESSED_BYTES = 64 * 1024 * 1024
const MAX_DECOMPRESSED_BYTES = 100 * 1024 * 1024
const TIMING = process.env.RUN_BUBBLE_TIMING === '1'
const CACHE_LIMIT = 64

function envMs(name, fallback) {
  const value = Number(process.env[name])
  return Number.isFinite(value) && value > 0 ? value : fallback
}

/** Boolean env flag; 0/false/no/off disable, anything else enables. */
function envFlag(name, fallback) {
  const raw = process.env[name]
  if (raw === undefined || raw === null || raw.trim() === '') return fallback
  return !['0', 'false', 'no', 'off'].includes(raw.trim().toLowerCase())
}

/** Like envFlag but undefined/empty stays null (tri-state for diagnostics). */
function envFlagOptional(name) {
  const raw = process.env[name]
  if (raw === undefined || raw === null || raw.trim() === '') return null
  return !['0', 'false', 'no', 'off'].includes(raw.trim().toLowerCase())
}

const LIVE_MS = envMs('RUN_BUBBLE_LIVE_MS', DEFAULT_LIVE_MS)
const STALE_MS = envMs('RUN_BUBBLE_STALE_MS', DEFAULT_STALE_MS)
// Show the desktop app's own sessions too. Resolution order:
// RUN_BUBBLE_INCLUDE_DESKTOP (when set) > config.json `includeDesktop` > false.
// The overlay's monitor button writes config.json, so the GUI toggle needs no env.
const CONFIG_FILE = join(STATUS_DIR, 'config.json')
let configCacheKey = ''
let configCacheValue = null

/** `$DSH_HOME/run-bubble/config.json`, re-read only when size/mtime change. */
function readRuntimeConfig() {
  try {
    const stat = statSync(CONFIG_FILE)
    const key = `${stat.size}:${stat.mtimeMs}`
    if (key === configCacheKey) return configCacheValue
    const parsed = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'))
    const value = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
    configCacheKey = key
    configCacheValue = value
    return value
  } catch {
    configCacheKey = ''
    configCacheValue = null
    return null
  }
}

/** Tri-state env wins when present; otherwise the GUI/config value; default off. */
function resolveIncludeDesktop() {
  const fromEnv = envFlagOptional('RUN_BUBBLE_INCLUDE_DESKTOP')
  if (fromEnv !== null) return fromEnv
  const config = readRuntimeConfig()
  return config && typeof config.includeDesktop === 'boolean' ? config.includeDesktop : false
}
// Force the T4 mtime/sidecar fallback even if a probe is present (tests/CI).
const DISABLE_LEASE_PROBE = envFlag('RUN_BUBBLE_DISABLE_LEASE_PROBE', false)
// Tri-state: only the *fallback* path consults it. In fallback mode ambiguous
// sessions are included by default (Windows has no other evidence); in lease
// mode the holder PID is precise and this flag is irrelevant. darwin's lock
// holders decide, so it never reaches the ambiguous branch there.
const INCLUDE_AMBIGUOUS_ENV = envFlagOptional('RUN_BUBBLE_INCLUDE_AMBIGUOUS')

// darwin: external CLI; win32: in-process node:zlib decoder.
const ZSTD = IS_WIN
  ? 'node:zlib'
  : ([
      process.env.DSH_ZSTD,
      '/opt/homebrew/bin/zstd',
      '/usr/local/bin/zstd',
      '/usr/bin/zstd'
    ].find((candidate) => candidate && existsSync(candidate)) || 'zstd')

const emptyTokens = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 })

function log(line) {
  try {
    mkdirSync(LOG_DIR, { recursive: true })
    appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${line}\n`)
  } catch {}
}

const throttleAt = new Map()
/** Log a repeated failure at most once per `intervalMs` per key. */
function logThrottled(key, line, intervalMs = 60_000) {
  const now = Date.now()
  const last = throttleAt.get(key) || 0
  if (now - last < intervalMs) return
  throttleAt.set(key, now)
  if (throttleAt.size > 256) {
    const ordered = [...throttleAt.entries()].sort((a, b) => a[1] - b[1])
    for (const [id] of ordered.slice(0, throttleAt.size - 256)) throttleAt.delete(id)
  }
  log(line)
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

/** `session-<uuid>` and bare `<uuid>` are both valid session ids. */
function normalizeSessionId(value) {
  const id = String(value ?? '')
  return id.startsWith('session-') ? id.slice('session-'.length) : id
}

function shortIdFor(value) {
  return normalizeSessionId(value).slice(0, 8)
}

/** Last path segment of the cwd, tolerant of Windows separators and drive roots. */
function fallbackTitle(header, shortId) {
  const cwd = typeof header?.cwd === 'string' ? header.cwd.replace(/[\\/]+$/, '') : ''
  const base = cwd.split(/[\\/]+/).filter(Boolean).pop() || ''
  if (!base || /^[a-z]:$/i.test(base)) return `Session ${shortId}`
  return base
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

const PROMPT_PREFIXES = ['Current runtime context', '<system-reminder>']

function isInjectablePrompt(text) {
  return PROMPT_PREFIXES.some((prefix) => text.startsWith(prefix))
}

/**
 * The first real user prompt, used for taskPreview (and as a last-resort title).
 * This build of DSH delivers prompts through `agent/inbox/spliced`, older ones
 * through `user/message`; both are folded here.
 */
function collectFirstPrompt(state, data, { spliced = false } = {}) {
  if (state.firstPrompt) return
  if (spliced) {
    const inserted = Array.isArray(data?.inserted) ? data.inserted : []
    for (const item of inserted) {
      if (!item || item.role !== 'user') continue
      const kind = item.source && typeof item.source === 'object' ? item.source.kind : undefined
      // Approval prompts and other injected user-role items are not tasks.
      if (typeof kind === 'string' && kind && kind !== 'user') continue
      const text = collapseWhitespace(userMessageText(item))
      if (!text || isInjectablePrompt(text)) continue
      state.firstPrompt = text.slice(0, TASK_PREVIEW_LIMIT)
      return
    }
    return
  }
  const text = collapseWhitespace(userMessageText(data))
  if (!text || isInjectablePrompt(text)) return
  state.firstPrompt = text.slice(0, TASK_PREVIEW_LIMIT)
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
  let projects
  try {
    projects = readdirSync(SESSION_ROOT, { withFileTypes: true })
  } catch {
    return out
  }
  for (const project of projects) {
    if (!project.isDirectory()) continue
    const projectDir = join(SESSION_ROOT, project.name)
    let sessions
    try {
      sessions = readdirSync(projectDir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const session of sessions) {
      if (!session.isDirectory()) continue
      const dir = join(projectDir, session.name)
      try {
        const logPath = newestLog(dir)
        if (logPath) out.push({ id: session.name, project: project.name, dir, logPath })
      } catch {}
    }
  }
  return out
}

/**
 * Decode one JSONL (optionally zstd) log into header + folded state.
 * Returns null when the bytes cannot be decoded; the caller keeps the previous
 * cache entry (the file is append-only, so the cached subset stays valid).
 */
async function readLog(entry, stat) {
  const key = `${stat.size}:${stat.mtimeMs}`
  const cached = cache.get(entry.id)
  if (cached && cached.key === key) return cached

  let text
  if (entry.logPath.endsWith('.zstd')) {
    if (IS_WIN) {
      if (stat.size > MAX_COMPRESSED_BYTES) {
        logThrottled(`large:${entry.id}`, `skip ${entry.id}: compressed log is ${stat.size} bytes`)
        return null
      }
      text = readZstdText(entry.logPath, {
        maxOutputBytes: MAX_DECOMPRESSED_BYTES,
        onError: (message) => logThrottled(`zstd:${entry.id}`, `read ${entry.id}: ${message}`)
      })
      if (text === null) return null
    } else {
      const { stdout } = await execFileAsync(ZSTD, ['-d', '-c', entry.logPath], {
        maxBuffer: 128 * 1024 * 1024,
        timeout: 15000
      })
      text = stdout
    }
  } else {
    if (stat.size > MAX_DECOMPRESSED_BYTES) {
      logThrottled(`large:${entry.id}`, `skip ${entry.id}: log is ${stat.size} bytes`)
      return null
    }
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
    catalogs: new Map(),
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
      case 'subagent/catalog': {
        // Announced in the *parent* log; label is attributed to the child id
        // after every kept log has been folded.
        const childId = typeof value.data?.childId === 'string' ? value.data.childId.trim() : ''
        const label = typeof value.data?.label === 'string' ? value.data.label.trim() : ''
        if (childId && label) state.catalogs.set(childId, label)
        break
      }
      case 'agent/inbox/spliced':
        collectFirstPrompt(state, value.data, { spliced: true })
        break
      case 'user/message':
        // Kept for other DSH versions; this build uses agent/inbox/spliced.
        collectFirstPrompt(state, value.data)
        break
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

/** PIDs of the running desktop host (darwin `ps`; Windows uses the CIM table). */
async function desktopPids() {
  const now = Date.now()
  if (now - desktopPidsCache.at < 5000) return desktopPidsCache.value
  let value = new Set()
  try {
    const { stdout } = await execFileAsync('ps', ['-axo', 'pid=,command='], {
      timeout: 2000,
      // A busy desktop can push the process table over execFile's 1 MB default;
      // silently getting no rows disables the desktop filter (and source labels).
      maxBuffer: 8 * 1024 * 1024
    })
    for (const line of stdout.split('\n')) {
      if (!line.includes('dsh-desktop-host/lib/index.js')) continue
      const match = /^\s*(\d+)\s+/.exec(line)
      if (match) value.add(Number(match[1]))
    }
  } catch {}
  desktopPidsCache = { at: now, value }
  return value
}

/**
 * Grok Build keeps its open TUI sessions in `~/.grok/active_sessions.json`:
 * [{ session_id, pid, pid_start, cwd, opened_at }]. Session metadata lives in
 * `~/.grok/sessions/<encoded-cwd>/<session_id>/{summary,signals,usage}.json`.
 * Treat this as a read-only second provider; no prompts or credentials are read.
 */
function readJsonFile(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return null
  }
}

function grokSessionIndex() {
  const out = new Map()
  try {
    for (const project of readdirSync(GROK_SESSIONS, { withFileTypes: true })) {
      if (!project.isDirectory()) continue
      const projectDir = join(GROK_SESSIONS, project.name)
      let sessions
      try {
        sessions = readdirSync(projectDir, { withFileTypes: true })
      } catch {
        continue
      }
      for (const session of sessions) {
        if (!session.isDirectory()) continue
        const dir = join(projectDir, session.name)
        if (existsSync(join(dir, 'summary.json'))) out.set(session.name, dir)
      }
    }
  } catch {}
  return out
}

function grokPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

function isoMs(value) {
  const ms = Date.parse(String(value || ''))
  return Number.isFinite(ms) ? ms : 0
}

function grokTokens(usage) {
  const session = usage?.session || usage || {}
  const input = Number(session.inputTokens) || 0
  const output = Number(session.outputTokens) || 0
  const cacheRead = Number(session.cachedReadTokens) || 0
  const total = Number(session.totalTokens) || (input + output + cacheRead)
  return { input, output, cacheRead, write: 0, total }
}

function grokSessionSummary(dir) {
  return dir ? readJsonFile(join(dir, 'summary.json')) : null
}

function grokChildInfo(childId, meta, index, now) {
  const dir = index.get(childId) || ''
  const summary = grokSessionSummary(dir)
  const usage = dir ? readJsonFile(join(dir, 'usage.json')) : null
  const label = String(meta?.description || summary?.generated_title || summary?.session_summary || `subagent ${childId.slice(0, 8)}`)
  const startedAt = isoMs(meta?.started_at) || isoMs(summary?.created_at) || now
  const status = String(meta?.status || '')
  const active = status === 'running' || (!status && !meta?.completed_at)
  const completed = isoMs(meta?.completed_at)
  const elapsedMs = active
    ? Math.max(0, now - startedAt)
    : Number(meta?.duration_ms) || (completed ? Math.max(0, completed - startedAt) : 0)
  return {
    id: `grok:${childId}`,
    shortId: childId.slice(0, 8),
    colorKey: colorKeyFor(`grok:${childId}`),
    parentSession: String(meta?.parent_session_id || ''),
    depth: 1,
    title: label,
    titleSource: 'explicit',
    source: 'grok',
    sourceLabel: 'Grok Build',
    sourceConfidence: 'explicit',
    taskPreview: String(meta?.prompt || '').split('\n')[0],
    cwd: String(meta?.child_cwd || summary?.info?.cwd || ''),
    startedAt,
    elapsedMs,
    active,
    turn: Number(meta?.turns) || Number(summary?.next_trace_turn) || 0,
    model: String(meta?.effective_model_id || summary?.current_model_id || ''),
    reasoningEffort: String(summary?.reasoning_effort || ''),
    label,
    tokens: grokTokens(usage),
    turnTokens: emptyTokens(),
    lastEventAt: isoMs(summary?.last_active_at) || completed || startedAt,
    children: [],
    activeChildCount: 0,
    childCount: 0
  }
}

function grokChildrenFor(parentDir, parentId, index, now) {
  if (!parentDir) return []
  const out = []
  let entries = []
  try {
    entries = readdirSync(join(parentDir, 'subagents'), { withFileTypes: true })
  } catch {
    return out
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    const meta = readJsonFile(join(parentDir, 'subagents', entry.name, 'meta.json'))
    if (!meta) continue
    const childId = String(meta.child_session_id || meta.subagent_id || entry.name)
    out.push(grokChildInfo(childId, meta, index, now))
  }
  out.sort((a, b) => a.startedAt - b.startedAt)
  return out
}

function grokRootForSession(id, dir, now, options = {}, index = new Map()) {
  const summary = grokSessionSummary(dir)
  const usage = dir ? readJsonFile(join(dir, 'usage.json')) : null
  const signals = dir ? readJsonFile(join(dir, 'signals.json')) : null
  const cwd = String(summary?.info?.cwd || options.cwd || '')
  const title = String(
    summary?.generated_title ||
    summary?.session_summary ||
    (cwd ? cwd.split('/').filter(Boolean).pop() : '') ||
    'Grok Build'
  )
  const taskPreview = String(summary?.session_summary || summary?.last_turn_summary || '')
  const startedAt = isoMs(options.openedAt) || isoMs(summary?.created_at) || now
  const lastEventAt = isoMs(summary?.last_active_at) || isoMs(summary?.updated_at) || startedAt
  const children = grokChildrenFor(dir, id, index, now)
  return {
    id: `grok:${id}`,
    shortId: id.slice(0, 8),
    colorKey: colorKeyFor(`grok:${id}`),
    parentSession: null,
    depth: 0,
    title,
    titleSource: 'explicit',
    source: 'grok',
    sourceLabel: 'Grok Build',
    sourceConfidence: 'explicit',
    taskPreview,
    cwd,
    startedAt,
    elapsedMs: Math.max(0, now - startedAt),
    active: true,
    turn: Number(signals?.turnCount) || Number(summary?.next_trace_turn) || 0,
    model: String(summary?.current_model_id || ''),
    reasoningEffort: String(summary?.reasoning_effort || ''),
    label: '',
    tokens: grokTokens(usage),
    turnTokens: emptyTokens(),
    lastEventAt,
    children,
    activeChildCount: children.filter((child) => child.active).length,
    childCount: children.length
  }
}

/**
 * Headless `grok -p` / `grok agent` processes do not appear in
 * active_sessions.json, but they keep their session's events/terminal files
 * open. One bulk lsof maps those PIDs to session directories. TUI PIDs are
 * excluded so the same session is not counted twice.
 */
async function grokHeadlessSessions(excludePids) {
  const now = Date.now()
  const key = [...excludePids].sort((a, b) => a - b).join(',')
  if (grokHeadlessCache.value && grokHeadlessCache.key === key && now - grokHeadlessCache.at < 2500) {
    return grokHeadlessCache.value
  }
  let value = []
  try {
    const { stdout: psOut } = await execFileAsync('ps', ['-axo', 'pid=,command='], {
      timeout: 2000,
      maxBuffer: 8 * 1024 * 1024
    })
    const candidates = []
    for (const line of psOut.split('\n')) {
      const match = /^\s*(\d+)\s+(.+)$/.exec(line)
      if (!match) continue
      const pid = Number(match[1])
      const command = match[2]
      if (excludePids.has(pid)) continue
      // Only headless forms; a TUI with an initial prompt must not be mistaken
      // for a headless run.
      if (!command.includes('.grok/bin/grok')) continue
      if (!/(?:\s-p\s|--single|--prompt-file|--prompt-json|--output-format|\sagent\s)/.test(command)) continue
      candidates.push(pid)
    }
    if (candidates.length === 0) {
      grokHeadlessCache = { at: now, key, value }
      return value
    }
    let lsofOut = ''
    try {
      ({ stdout: lsofOut } = await execFileAsync('lsof', ['-p', candidates.join(','), '-F', 'pn'], {
        timeout: 5000,
        maxBuffer: 8 * 1024 * 1024
      }))
    } catch (error) {
      lsofOut = typeof error?.stdout === 'string' ? error.stdout : ''
      if (!lsofOut) {
        grokHeadlessCache = { at: now, key, value }
        return value
      }
    }
    const seen = new Set()
    let currentPid = 0
    for (const line of lsofOut.split('\n')) {
      if (!line) continue
      if (line[0] === 'p') {
        currentPid = Number(line.slice(1)) || 0
        continue
      }
      if (line[0] !== 'n' || !currentPid) continue
      const path = line.slice(1)
      if (!path.startsWith(GROK_SESSIONS + '/')) continue
      const rel = path.slice(GROK_SESSIONS.length + 1)
      const parts = rel.split('/')
      if (parts.length < 2) continue
      const id = parts[1]
      const dir = join(GROK_SESSIONS, parts[0], id)
      if (seen.has(id) || !existsSync(join(dir, 'summary.json'))) continue
      seen.add(id)
      value.push({ id, dir })
    }
  } catch {}
  grokHeadlessCache = { at: now, key, value }
  return value
}

async function collectGrokRoots(now, includeTui) {
  const active = readJsonFile(GROK_ACTIVE_FILE)
  const entries = Array.isArray(active) ? active : []
  const index = grokSessionIndex()
  const bySession = new Map()
  const tuiPids = new Set()
  for (const entry of entries) {
    const pid = Number(entry?.pid) || 0
    if (pid > 0) tuiPids.add(pid)
  }

  if (includeTui) {
    for (const entry of entries) {
      try {
        const id = typeof entry?.session_id === 'string' ? entry.session_id : ''
        const pid = Number(entry?.pid) || 0
        if (!id || !grokPidAlive(pid)) continue
        const dir = index.get(id) || ''
        if (!dir) continue
        if (grokSessionSummary(dir)?.session_kind === 'subagent') continue
        bySession.set(id, grokRootForSession(id, dir, now, { cwd: entry.cwd, openedAt: entry.opened_at }, index))
      } catch {}
    }
  }

  // Headless runs are always visible; the monitor toggle only affects TUI
  // sessions (and DSH desktop sessions).
  for (const item of await grokHeadlessSessions(tuiPids)) {
    if (bySession.has(item.id)) continue
    if (grokSessionSummary(item.dir)?.session_kind === 'subagent') continue
    bySession.set(item.id, grokRootForSession(item.id, item.dir, now, {}, index))
  }
  return [...bySession.values()]
}

/**
 * Holder PIDs for every session lock in one lsof pass (darwin).
 *
 * `lsof` startup costs ~0.3s on this machine. Spawning it once per session
 * (80+ sessions => 20s+) blocks the refresh loop, makes status.json stale, and
 * the overlay's stale guard then flips to idle. One bulk call keeps each
 * refresh under ~1s; `null` remains the "check unavailable" fallback.
 *
 * Windows has no cross-process session lock; the lease probe / heuristics in
 * src/win/liveness.mjs replace this path.
 */
async function lockHoldersFor(entries) {
  if (IS_WIN) return null
  const now = Date.now()
  const paths = entries
    .map((entry) => join(entry.dir, 'session.lock'))
    .filter((lockPath) => existsSync(lockPath))
  const key = paths.join('\0')
  if (bulkHolderCache.value !== null && bulkHolderCache.key === key && now - bulkHolderCache.at < 3000) {
    return bulkHolderCache.value
  }

  let value = null
  if (paths.length === 0) {
    value = new Map()
  } else if (process.platform === 'darwin') {
    let stdout = ''
    let unavailable = false
    try {
      ({ stdout } = await execFileAsync('lsof', ['-F', 'pn', '--', ...paths], {
        timeout: 10000,
        maxBuffer: 8 * 1024 * 1024
      }))
    } catch (error) {
      // lsof exits 1 when *some* requested paths have no match, while still
      // printing the paths that do have holders. Keep that stdout; only treat
      // it as unavailable when the error produced neither output nor exit 1.
      stdout = typeof error?.stdout === 'string' ? error.stdout : ''
      if (!stdout && error?.code !== 1) unavailable = true
    }
    if (unavailable) {
      // Never fail open on macOS: decoding every session because lsof timed out
      // resurrects old logs and can make the bubble show a dozen dead roots.
      // Reuse the last good holder map, or an empty map on cold start.
      value = bulkHolderCache.value instanceof Map ? bulkHolderCache.value : new Map()
      logThrottled('lsof', 'lsof unavailable; using cached/empty holder map')
    } else {
      value = new Map(paths.map((lockPath) => [lockPath, []]))
      let currentPid = null
      for (const line of stdout.split('\n')) {
        if (!line) continue
        if (line[0] === 'p') {
          currentPid = Number(line.slice(1)) || null
        } else if (line[0] === 'n' && currentPid) {
          const lockPath = line.slice(1)
          if (value.has(lockPath)) value.get(lockPath).push(currentPid)
        }
      }
    }
  }

  bulkHolderCache = { at: now, key, value }
  return value
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

/** Infer the launching agent by walking the lock holder's parent chain (darwin). */
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
  if (sourceCache.size > CACHE_LIMIT) {
    const ordered = [...sourceCache.entries()].sort((a, b) => a[1].at - b[1].at)
    for (const [id] of ordered.slice(0, sourceCache.size - CACHE_LIMIT)) sourceCache.delete(id)
  }
  return value
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
  return sidecarSource(sidecar)
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
  if (inferred) return { ...inferred, sourceConfidence: inferred.sourceConfidence || 'inferred' }
  return { source: 'unknown', sourceLabel: 'Unknown', sourceConfidence: 'unknown' }
}

/**
 * The lock/lease holder is the desktop host itself: ownership is exact, so the
 * source is "Desktop" rather than an unknown launcher.
 */
function desktopSource(desktops, holders) {
  if (!desktops || !Array.isArray(holders)) return null
  return holders.some((pid) => desktops.has(pid))
    ? { source: 'desktop', sourceLabel: 'Desktop', sourceConfidence: 'explicit' }
    : null
}

/** Stable 0..5 color assignment so a session keeps the same accent across ticks. */
function colorKeyFor(id) {
  let hash = 0
  for (let index = 0; index < id.length; index += 1) hash = (hash * 31 + id.charCodeAt(index)) >>> 0
  return hash % 6
}

function buildInfo(header, state, now, meta = {}) {
  const id = String(header.id)
  const normalizedId = normalizeSessionId(id)
  const shortId = normalizedId.slice(0, 8)
  const active = openTurnFromState(state)
  const startedAt = Number(state.lastStart?.time) || Number(header.createdAt) || now
  const elapsedMs = active
    ? Math.max(0, now - startedAt)
    : state.lastStart && state.lastEnd
      ? Math.max(0, (Number(state.lastEnd.time) || 0) - (Number(state.lastStart.time) || 0))
      : 0
  const sidecar = meta.sidecar || null
  const explicitTitle = typeof sidecar?.title === 'string' ? sidecar.title.trim() : ''
  const sidecarTask = typeof sidecar?.task === 'string' ? clampPreview(sidecar.task) : ''
  const source = resolveSource(sidecar, meta.inferred)
  // Child labels are announced by the parent log (subagent/catalog); older
  // builds put them in the child log (subagent/descriptor).
  const label = state.label || (typeof meta.catalogLabel === 'string' ? meta.catalogLabel : '') || ''

  return {
    id,
    shortId,
    colorKey: colorKeyFor(normalizedId),
    parentSession: typeof header.parentSession === 'string' ? header.parentSession : null,
    depth: Number(header.delegationDepth) || 0,
    title: explicitTitle || state.title || label || state.firstPrompt || fallbackTitle(header, shortId),
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
    label,
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
let bulkHolderCache = { at: 0, key: '', value: null }
let sourceCache = new Map()
let grokHeadlessCache = { at: 0, key: '', value: null }
let desktopPidsCache = { at: 0, value: new Set() }
let refreshing = false
let mode = judgmentMode({ platform: PLATFORM })
let lastSnapshot = {
  schemaVersion: 2,
  updatedAt: 0,
  roots: [],
  totals: { sessions: 0, children: 0, activeChildren: 0, tokens: emptyTokens() },
  daemonPid: process.pid
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * Write the status document atomically. On Windows `renameSync` replaces the
 * target, but the overlay may hold it open for a moment (EPERM/EBUSY), so retry
 * three times and finally fall back to an in-place write.
 */
async function writeAtomic(filePath, data) {
  const temp = `${filePath}.tmp-${process.pid}`
  writeFileSync(temp, data, { mode: 0o600 })
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      renameSync(temp, filePath)
      return true
    } catch (error) {
      const retriable = error?.code === 'EPERM' || error?.code === 'EACCES' || error?.code === 'EBUSY'
      if (!retriable) break
      await sleep(20)
    }
  }
  writeFileSync(filePath, data, { mode: 0o600 })
  try {
    rmSync(temp, { force: true })
  } catch {}
  return false
}

/** Serialize status writes so a heartbeat can never clobber a newer refresh. */
let statusWriteChain = Promise.resolve()
function writeStatusSnapshot(snapshot) {
  const data = JSON.stringify(snapshot)
  statusWriteChain = statusWriteChain
    .then(() => writeAtomic(STATUS_FILE, data))
    .catch((error) => {
      logThrottled('status-write', `status.json: ${String(error?.message || error)}`)
    })
  return statusWriteChain
}

async function refresh() {
  if (refreshing) return
  refreshing = true
  const startHr = performance.now()
  let kept = 0
  let rootCount = 0
  let leaseProbeState = 'unavailable'
  let sourceProbe = 'none'
  let leaseUsed = false
  let includeAmbiguous = false
  let includeDesktop = false
  try {
    const now = Date.now()

    // One CIM query per cache window on Windows; `null` means "unavailable",
    // never "nothing running", so decisions fail open below.
    let table = null
    let desktops = null
    let leaseScan = null
    if (IS_WIN) {
      table = await getProcessTable()
      desktops = table ? desktopHostPids(table) : null
      if (!table) {
        logThrottled('process-table', 'process table unavailable; source inference degraded')
      }
      // Primary liveness signal: DSH's kernel write leases. One handle-table
      // scan per refresh (cached 1500ms); null = probe unavailable -> T4.
      if (!DISABLE_LEASE_PROBE) {
        leaseScan = await scanLeases({ onError: (message) => logThrottled('lease-probe', message) })
      }
    } else {
      desktops = await desktopPids()
    }
    const desktopPresent = Boolean(desktops && desktops.size > 0)
    const external = IS_WIN ? externalCliPids(table) : null
    const pidChain = table ? (pid) => parentChain(pid, 8, table) : null
    const pidAlive = table ? (pid) => table.has(pid) : null
    const entries = listLogs()
    // One bulk lsof for all lock files, not one process per session.
    const holdersByPath = IS_WIN ? null : await lockHoldersFor(entries)

    // Guard: a probe that reports no lease for ANY session of this store is not
    // describing this store (synthetic/temporary DSH_HOME in tests, or a store
    // where every session is currently dead). Either way the precise signal is
    // unusable here - fall back instead of declaring every session dead.
    if (leaseScan) {
      const anyMatch = entries.some((entry) => leaseScan.has(leaseHash(entry.dir)))
      if (!anyMatch) {
        logThrottled('lease-mismatch', 'lease probe reports no lease for this session store; falling back to mtime/sidecar')
        leaseScan = null
      }
    }
    leaseUsed = leaseScan !== null
    leaseProbeState = leaseUsed ? 'ok' : 'unavailable'
    // Holder PIDs are precise in lease mode, so ambiguity never arises there.
    // Only the fallback path needs the (default-on) ambiguous inclusion.
    includeAmbiguous = INCLUDE_AMBIGUOUS_ENV === null ? true : INCLUDE_AMBIGUOUS_ENV
    // Re-read every tick: the overlay's monitor button flips this at runtime.
    includeDesktop = resolveIncludeDesktop()
    let sidecarInfluenced = false
    const noteSourceProbe = (value) => {
      if (value === 'cim' || (value === 'sidecar' && sourceProbe === 'none')) sourceProbe = value
    }

    // Pass 1: attribution + liveness from cheap signals only (stat, sidecar,
    // process table). Kept candidates get their log decoded below; ambiguous
    // ones stay undecoded unless they can inherit attribution from a parent.
    const candidates = []
    for (const entry of entries) {
      try {
        const stat = statSync(entry.logPath)
        const sidecar = readSidecar(entry.id)
        const candidate = {
          entry,
          stat,
          sidecar,
          keep: false,
          ambiguous: false,
          leased: false,
          holders: null,
          sidecarInfluenced: false
        }
        if (IS_WIN) {
          if (leaseUsed) {
            // mac-equivalent chain: the lease holder decides live + ownership.
            const holders = leaseScan.get(leaseHash(entry.dir)) || []
            // No holder = the session is dead; do not decode its log at all.
            if (holders.length === 0) continue
            // Sessions owned by the desktop host subtree are the app's own.
            if (!includeDesktop && desktops && holders.some((pid) => desktops.has(pid))) continue
            candidate.keep = true
            candidate.holders = holders
            candidate.leased = true
          } else {
            // T4 fallback: attribution first, then mtime/sidecar liveness.
            const ownership = windowsOwnership({
              sidecar,
              desktopPresent,
              includeAmbiguous,
              includeDesktop,
              desktopPids: desktops,
              pidChain
            })
            candidate.ambiguous = ownership.ambiguous
            if (ownership.keep) {
              const liveCheck = windowsLive({
                now,
                mtimeMs: stat.mtimeMs,
                sidecar,
                liveMs: LIVE_MS,
                pidAlive,
                externalCliPids: external
              })
              candidate.keep = liveCheck.live
              candidate.sidecarInfluenced = ownership.via === 'sidecar' || liveCheck.via === 'sidecar'
            }
          }
        } else {
          const lockPath = join(entry.dir, 'session.lock')
          const holders = holdersByPath ? (holdersByPath.get(lockPath) ?? []) : null
          candidate.holders = holders
          // No holder means the run is gone; do not decode its log at all.
          if (holders && holders.length === 0) continue
          // Skip sessions owned by this machine's desktop host unless the
          // panel's monitor toggle (config.json includeDesktop) asks for them.
          if (!includeDesktop && holders && holders.some((pid) => desktops.has(pid))) continue
          candidate.keep = true
        }
        candidates.push(candidate)
      } catch (error) {
        logThrottled(`entry:${entry.id}`, `read ${entry.id}: ${String(error?.message || error)}`)
      }
    }

    const collected = []
    // Decode + apply the per-session filters that need the folded log state.
    const acceptRecord = async (candidate) => {
      const record = await readLog(candidate.entry, candidate.stat)
      if (!record?.header?.id) return null
      const header = record.header
      const depth = Number(header.delegationDepth) || 0
      if (depth > 1) return null
      const createdAt = Number(header.createdAt) || 0
      const openTurn = openTurnFromState(record.state)
      // Long-lived conversations (especially the desktop app's own session) can
      // be days old while still actively streaming. The age window is only for
      // avoiding dead legacy logs; an open turn wins.
      if (createdAt > 0 && now - createdAt > RECENT_WINDOW_MS && !openTurn) return null
      if (IS_WIN && !candidate.leased) {
        // Zombie filter only matters when mtime/sidecar decide liveness; a held
        // lease already proves a live writer.
        if (isZombie({ openTurn, lastEventAt: record.state.lastEventAt, now, staleMs: STALE_MS })) return null
      }
      let inferred = null
      if (IS_WIN) {
        // Lease holders are the authoritative source signal; sidecar.pid is the
        // degraded-path fallback.
        const holderPid = candidate.leased
          ? candidate.holders?.[0]
          : sidecarPid(candidate.sidecar)
        if (candidate.leased) inferred = desktopSource(desktops, candidate.holders)
        if (!inferred && holderPid && table) inferred = inferSourceFromTable(holderPid, table)
        if (inferred) noteSourceProbe('cim')
        else if (explicitSourceValue(candidate.sidecar)) noteSourceProbe('sidecar')
      } else if (!explicitSourceValue(candidate.sidecar) && candidate.holders && candidate.holders.length > 0) {
        inferred = desktopSource(desktops, candidate.holders) || await inferSource(candidate.holders[0])
      }
      if (candidate.sidecarInfluenced) sidecarInfluenced = true
      return { header, state: record.state, sidecar: candidate.sidecar, inferred, project: candidate.entry.project }
    }

    for (const candidate of candidates) {
      if (!candidate.keep) continue
      try {
        const item = await acceptRecord(candidate)
        if (item) collected.push(item)
      } catch (error) {
        logThrottled(`entry:${candidate.entry.id}`, `read ${candidate.entry.id}: ${String(error?.message || error)}`)
      }
    }

    // Pass 2 (win32): subagent sessions of an externally driven run carry no
    // sidecar of their own. When their parent session is proven external, the
    // child inherits that attribution and must not be hidden.
    if (IS_WIN && collected.length > 0) {
      const keptIds = new Set()
      const projectsWithKept = new Set()
      const noteKept = (item) => {
        keptIds.add(String(item.header.id))
        keptIds.add(normalizeSessionId(item.header.id))
        if (item.project) projectsWithKept.add(item.project)
      }
      for (const item of collected) noteKept(item)
      let added = true
      let rounds = 0
      while (added && rounds < 3) {
        added = false
        rounds += 1
        for (const candidate of candidates) {
          if (candidate.keep || !candidate.ambiguous) continue
          // Parent and child sessions always share one project directory.
          if (!projectsWithKept.has(candidate.entry.project)) continue
          try {
            const record = await readLog(candidate.entry, candidate.stat)
            const parentId = typeof record?.header?.parentSession === 'string' ? record.header.parentSession : ''
            if (!parentId) continue
            if (!keptIds.has(parentId) && !keptIds.has(normalizeSessionId(parentId))) continue
            const item = await acceptRecord(candidate)
            if (!item) continue
            candidate.keep = true // never re-add the same session in a later round
            noteKept(item)
            collected.push(item)
            added = true
          } catch (error) {
            logThrottled(`entry:${candidate.entry.id}`, `read ${candidate.entry.id}: ${String(error?.message || error)}`)
          }
        }
      }
    }

    // subagent/catalog labels are announced in the parent's log; resolve them
    // once all kept logs have been folded.
    const catalogs = new Map()
    for (const item of collected) {
      for (const [childId, label] of item.state.catalogs) {
        if (!catalogs.has(childId)) catalogs.set(childId, label)
        const normalized = normalizeSessionId(childId)
        if (!catalogs.has(normalized)) catalogs.set(normalized, label)
      }
    }

    const infos = collected.map((item) => buildInfo(item.header, item.state, now, {
      sidecar: item.sidecar,
      inferred: item.inferred,
      catalogLabel: catalogs.get(String(item.header.id)) || catalogs.get(normalizeSessionId(item.header.id)) || ''
    }))

    const byId = new Map()
    const byNormalized = new Map()
    for (const info of infos) {
      byId.set(info.id, info)
      const normalized = normalizeSessionId(info.id)
      if (!byNormalized.has(normalized)) byNormalized.set(normalized, info)
    }
    const roots = []
    for (const info of infos) {
      if (!info.parentSession) {
        roots.push(info)
        continue
      }
      // Parent and child ids use different formats across DSH versions; keep
      // the full id as the map key and fall back to the normalised form.
      const parent = byId.get(info.parentSession) || byNormalized.get(normalizeSessionId(info.parentSession))
      if (parent && parent !== info) parent.children.push(info)
    }

    const activeRoots = roots.filter((root) => root.active || root.children.some((child) => child.active))
    for (const root of activeRoots) {
      root.children.sort((a, b) => a.startedAt - b.startedAt)
      root.childCount = root.children.length
      root.activeChildCount = root.children.filter((child) => child.active).length
    }
    // Second provider: open Grok Build TUI sessions. They share the same root
    // shape and are sorted with DSH roots.
    const grokRoots = await collectGrokRoots(now, includeDesktop)
    for (const root of grokRoots) activeRoots.push(root)
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
    mode = judgmentMode({ platform: PLATFORM, lease: leaseUsed, sidecarInfluenced })
    kept = collected.length
    rootCount = activeRoots.length
  } catch (error) {
    // A failed tick must keep the previous (valid) document in place.
    logThrottled('refresh', `refresh: ${String(error?.stack || error)}`)
  } finally {
    refreshing = false
  }

  const elapsed = performance.now() - startHr
  if (TIMING) {
    process.stderr.write(`[refresh] ${elapsed.toFixed(1)}ms kept=${kept} roots=${rootCount} mode=${mode} leaseProbe=${leaseProbeState} sourceProbe=${IS_WIN ? sourceProbe : 'none'}\n`)
  } else if (elapsed > 2000) {
    log(`slow refresh ${elapsed.toFixed(0)}ms kept=${kept} roots=${rootCount} mode=${mode}`)
  }

  try {
    mkdirSync(STATUS_DIR, { recursive: true })
    await writeStatusSnapshot(lastSnapshot)
  } catch (error) {
    logThrottled('status-write', `status.json: ${String(error?.message || error)}`)
  }
  try {
    writeFileSync(STATE_FILE, JSON.stringify({
      pid: process.pid,
      startedAt: processStart,
      zstd: ZSTD,
      platform: PLATFORM,
      mode,
      // Diagnostics (status.json v2 schema is untouched).
      leaseProbe: leaseProbeState,
      sourceProbe: IS_WIN ? sourceProbe : 'none',
      includeAmbiguous: IS_WIN ? (!leaseUsed && includeAmbiguous) : false,
      includeDesktop
    }))
  } catch (error) {
    logThrottled('state-write', `daemon.json: ${String(error?.message || error)}`)
  }

  if (cache.size > CACHE_LIMIT) {
    const ordered = [...cache.entries()].sort((a, b) => (a[1].key > b[1].key ? 1 : -1))
    for (const [id] of ordered.slice(0, cache.size - CACHE_LIMIT)) cache.delete(id)
  }
}

const processStart = Date.now()
log(`daemon start pid=${process.pid} platform=${PLATFORM} zstd=${ZSTD} home=${DSH_HOME} status=${STATUS_FILE} mode=${mode}`)
await refresh()
setInterval(() => {
  void refresh()
}, TICK_MS)

// Keep status.json fresh even if a busy refresh is slow. The overlay treats a
// status file older than a few seconds as stale and would otherwise flash back
// to idle while the daemon is still collecting data.
setInterval(() => {
  if (lastSnapshot.roots.length === 0) return
  const now = Date.now()
  if (now - lastSnapshot.updatedAt < 800) return
  lastSnapshot.updatedAt = now
  void writeStatusSnapshot(lastSnapshot)
}, 1000)

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    try {
      const empty = {
        schemaVersion: 2,
        updatedAt: Date.now(),
        daemonPid: process.pid,
        roots: [],
        totals: { sessions: 0, children: 0, activeChildren: 0, tokens: emptyTokens() }
      }
      mkdirSync(STATUS_DIR, { recursive: true })
      writeFileSync(STATUS_FILE, JSON.stringify(empty), { mode: 0o600 })
    } catch {}
    process.exit(0)
  })
}
