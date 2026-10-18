#!/usr/bin/env node
/**
 * dsh-chat — a tiny ACP client for DeepSeek Harness.
 *
 * The point is discoverability: another coding agent only needs `dsh-chat
 * --help`, not the raw JSON-RPC method table. One process per command; the
 * session itself is persisted by DSH and reused through ACP `session/resume`.
 *
 * Cross-platform: macOS keeps the original behaviour; Windows uses the
 * `dsh.cmd` launcher shipped with the desktop app (`%LOCALAPPDATA%\Programs\
 * DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`) or `%DSH_BIN%`.
 */

import { spawn } from 'node:child_process'
import {
  chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync
} from 'node:fs'
import { createInterface } from 'node:readline'
import { homedir } from 'node:os'
import { delimiter, dirname, isAbsolute, join } from 'node:path'

const VERSION = '0.1.0'
const IS_WIN = process.platform === 'win32'
const HOME = homedir()

const DSH_HOME_DIR = process.env.DSH_HOME || join(HOME, '.dsh')
const SIDECAR_DIR = join(DSH_HOME_DIR, 'run-bubble', 'sessions')

// Surface values declared by the wrapper. `dsh-chat` always drives the ACP
// profile, but wrappers built on top of it may pass --surface headless/sdk.
const SURFACES = ['acp', 'headless', 'sdk', 'desktop']
const DEFAULT_SURFACE = 'acp'
const DEFAULT_HEARTBEAT_MS = 15000

const HELP = `dsh-chat ${VERSION} — talk to DeepSeek Harness over ACP

Usage:
  dsh-chat ask   [options] <text>        create a session, prompt once, close
  dsh-chat send  [options] --session <id> <text>
                                          resume a session and prompt once
  dsh-chat new   [options]                create a session and print its id
  dsh-chat list  [options]                list persisted sessions
  dsh-chat close [options] --session <id> close a persisted session
  dsh-chat --help | --version

Options:
  --cwd <dir>        working directory for a new session (default: cwd)
  --model <p/m>      provider/model, e.g. deepseek-account/deepseek-flash
  --source <name>    session source, e.g. codex, claude-code, cursor, terminal
  --title <text>     short task title for the session sidecar
  --session <id>     session id for send/close
  --json             emit newline-delimited JSON events instead of text
  --timeout <sec>    per-request timeout (default: 120)
  --quiet            suppress tool/progress lines on stderr
  --verbose          keep ACP stderr
  --surface <kind>   sidecar "surface": acp|headless|sdk|desktop (default: acp)
  --heartbeat <sec>  refresh sidecar heartbeat while a prompt runs
                     (default: 15; 0 disables)
  --print-sidecar    print the sidecar JSON that would be written, then exit
                     (does not start dsh; for testing/diagnostics)

Environment:
  DSH_BIN            path to the dsh launcher (default: desktop app bundle)
  DSH_HOME           session store (default: ~/.dsh); sidecars live in
                     $DSH_HOME/run-bubble/sessions/<sessionId>.json
  DSH_RUN_BUBBLE_SOURCE     default --source when the flag is omitted
  DSH_RUN_BUBBLE_SURFACE    default --surface when the flag is omitted
  DSH_RUN_BUBBLE_HEARTBEAT  default heartbeat interval in seconds

Windows:
  %DSH_HOME%\\run-bubble\\sessions\\<sessionId>.json
  dsh-chat.cmd ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"
  pwsh -NoProfile -File dsh-chat.ps1 --help
  node dsh-chat.mjs --help

Examples:
  dsh-chat ask "Reply with exactly: HELLO"
  dsh-chat ask --source codex --title "Smoke test" "Reply with exactly: HELLO"
  dsh-chat new --cwd .
  dsh-chat send --session <id> "Continue the task"
  dsh-chat list
  dsh-chat send --session <id> --json "status?"
  dsh-chat --print-sidecar --source codex --title "Smoke test" ask "hello"

Protocol (for implementers):
  transport: newline-delimited JSON-RPC 2.0 over stdin/stdout
  initialize -> session/new | session/list | session/resume
  -> session/set_config_option -> session/prompt
  <- session/update (agent_message_chunk, tool_call, ...)
  -> session/close

The raw ACP contract is the standard Agent Client Protocol; DSH adds
session/list, session/resume and session/close. Full reference:
https://agentclientprotocol.com
`

/** A plain readable file, used to probe launcher candidates. */
function isFile(candidate) {
  try {
    return statSync(candidate).isFile()
  } catch {
    return false
  }
}

/** Cross-platform `which`: scan PATH instead of spawning which/where. */
function findOnPath(names) {
  const pathValue = process.env.PATH || process.env.Path || ''
  const directories = pathValue.split(delimiter).filter(Boolean)
  const found = []
  for (const directory of directories) {
    for (const name of names) {
      const candidate = join(directory, name)
      if (isFile(candidate)) found.push(candidate)
    }
  }
  return found
}

/** dsh launcher candidates, platform first; DSH_BIN always wins. */
function launcherCandidates() {
  const explicit = process.env.DSH_BIN ? [process.env.DSH_BIN] : []
  if (IS_WIN) {
    const localAppData = process.env.LOCALAPPDATA || join(HOME, 'AppData', 'Local')
    const appData = process.env.APPDATA || join(HOME, 'AppData', 'Roaming')
    const programFiles = process.env.ProgramFiles || process.env.PROGRAMFILES || 'C:\\Program Files'
    const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)'
    return [
      ...explicit,
      join(localAppData, 'Programs', 'DeepSeek Harness', 'resources', 'runtime', 'cli', 'bin', 'dsh.cmd'),
      join(programFiles, 'DeepSeek Harness', 'resources', 'runtime', 'cli', 'bin', 'dsh.cmd'),
      join(programFilesX86, 'DeepSeek Harness', 'resources', 'runtime', 'cli', 'bin', 'dsh.cmd'),
      join(HOME, '.local', 'bin', 'dsh.cmd'),
      join(appData, 'npm', 'dsh.cmd'),
      ...findOnPath(['dsh.cmd', 'dsh.exe'])
    ]
  }
  // macOS (original order preserved) and generic POSIX.
  return [
    ...explicit,
    '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh',
    join(HOME, '.local', 'bin', 'dsh'),
    '/opt/homebrew/bin/dsh',
    '/usr/local/bin/dsh',
    ...findOnPath(['dsh'])
  ]
}

/** Resolve a bare launcher name through PATH before deciding how to spawn it. */
function resolveLauncher() {
  const candidate = launcherCandidates().find(isFile)
  if (candidate) return candidate
  const requested = process.env.DSH_BIN || 'dsh'
  if (IS_WIN && !isAbsolute(requested) && !/[\\/]/.test(requested)) {
    const resolved = findOnPath([`${requested}.cmd`, `${requested}.exe`, requested])
    if (resolved.length) return resolved[0]
  }
  return requested
}

const DSH_BIN = resolveLauncher()

/** Quote one argv token for `cmd.exe /d /s /c` (only the launcher args are dynamic). */
function quoteCmdArgument(value) {
  const text = String(value)
  if (!text) return '""'
  if (!/[\s"&|<>^()]/.test(text)) return text
  return `"${text.replace(/"/g, '""')}"`
}

/**
 * Windows cannot CreateProcess a .cmd/.bat directly, so those go through
 * `cmd.exe /d /s /c "<launcher>" <args>` with the whole command line quoted
 * (the /s form strips exactly the outer pair). Everything else spawns directly.
 */
function spawnSpec(extraArgs) {
  const launcher = DSH_BIN
  if (IS_WIN) {
    if (/\.(cmd|bat)$/i.test(launcher)) {
      const comspec = process.env.ComSpec || process.env.COMSPEC || 'cmd.exe'
      const inner = `"${launcher}" ${extraArgs.map(quoteCmdArgument).join(' ')}`
      return {
        command: comspec,
        args: ['/d', '/s', '/c', `"${inner}"`],
        windowsVerbatimArguments: true,
        viaCmd: true
      }
    }
    if (/\.(c|m)?js$/i.test(launcher)) {
      // A raw CLI entry point: run it with the current Node instead of a shim.
      return { command: process.execPath, args: [launcher, ...extraArgs], windowsVerbatimArguments: false, viaCmd: false }
    }
  }
  return { command: launcher, args: extraArgs, windowsVerbatimArguments: false, viaCmd: false }
}

function parseArgs(argv) {
  const args = { _: [] }
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    if (token === '--help' || token === '-h') args.help = true
    else if (token === '--version' || token === '-V') args.version = true
    else if (token === '--json') args.json = true
    else if (token === '--quiet') args.quiet = true
    else if (token === '--verbose') args.verbose = true
    else if (token === '--print-sidecar') args.printSidecar = true
    else if (token === '--cwd') args.cwd = argv[++i]
    else if (token.startsWith('--cwd=')) args.cwd = token.slice(6)
    else if (token === '--model') args.model = argv[++i]
    else if (token.startsWith('--model=')) args.model = token.slice(8)
    else if (token === '--source') args.source = argv[++i]
    else if (token.startsWith('--source=')) args.source = token.slice(9)
    else if (token === '--title') args.title = argv[++i]
    else if (token.startsWith('--title=')) args.title = token.slice(8)
    else if (token === '--session') args.session = argv[++i]
    else if (token.startsWith('--session=')) args.session = token.slice(10)
    else if (token === '--surface') args.surface = argv[++i]
    else if (token.startsWith('--surface=')) args.surface = token.slice(10)
    else if (token === '--heartbeat') args.heartbeat = argv[++i]
    else if (token.startsWith('--heartbeat=')) args.heartbeat = token.slice(12)
    else if (token === '--timeout') args.timeout = Number(argv[++i])
    else if (token.startsWith('--timeout=')) args.timeout = Number(token.slice(10))
    else args._.push(token)
  }
  return args
}

class AcpError extends Error {
  constructor(message, data) {
    super(message)
    this.name = 'AcpError'
    this.data = data
  }
}

function firstLine(text) {
  return String(text || '').split(/\r?\n/).find((line) => line.trim()) || ''
}

class AcpClient {
  constructor({ timeoutMs, verbose, quiet, json }) {
    this.timeoutMs = timeoutMs
    this.verbose = verbose
    this.quiet = quiet
    this.json = json
    this.nextId = 1
    this.pending = new Map()
    this.child = null
    this.rl = null
    this.notification = null
    this.exited = false
    this.stopped = false
    this.stderrTail = ''
    this.spec = null
  }

  async start() {
    const spec = spawnSpec(['--profile', 'acp'])
    this.spec = spec
    const options = {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, DSH_ACP_QUIET: '1' },
      windowsVerbatimArguments: spec.windowsVerbatimArguments
    }
    if (IS_WIN) options.windowsHide = true
    this.child = spawn(spec.command, spec.args, options)
    this.child.on('error', (error) => {
      const hint = error?.code === 'ENOENT'
        ? ` (dsh launcher not found: ${DSH_BIN}; set DSH_BIN or install DeepSeek Harness)`
        : ''
      this.failAll(new AcpError(`${error?.message || error}${hint}`))
    })
    this.child.on('exit', (code, signal) => {
      this.exited = true
      let message = `ACP exited (${code ?? signal})`
      const tail = firstLine(this.stderrTail)
      if (code && tail && /is not recognized|不是内部或外部命令|cannot find|not found/i.test(tail)) {
        message += ` — the dsh launcher failed to start: ${tail.slice(0, 300)} (check DSH_BIN)`
      }
      this.failAll(new AcpError(message))
    })
    this.child.stdin.on('error', () => {})
    this.rl = createInterface({ input: this.child.stdout, crlfDelay: Infinity })
    this.rl.on('line', (line) => this.onLine(line))
    this.child.stderr.on('data', (chunk) => {
      if (this.verbose) process.stderr.write(chunk)
      else this.stderrTail = (this.stderrTail + chunk).slice(-8192)
    })
  }

  failAll(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer)
      reject(error)
    }
    this.pending.clear()
  }

  onLine(line) {
    if (!line.trim()) return
    let message
    try {
      message = JSON.parse(line)
    } catch {
      if (this.verbose) process.stderr.write(`[acp] ${line}\n`)
      return
    }
    if (message.id !== undefined && this.pending.has(message.id)) {
      const entry = this.pending.get(message.id)
      this.pending.delete(message.id)
      clearTimeout(entry.timer)
      if (message.error) {
        const data = message.error.data
        const detail = typeof data === 'string' ? data : data?.details || data?.message
        entry.reject(new AcpError(detail || message.error.message || 'ACP error', data))
      } else {
        entry.resolve(message.result)
      }
      return
    }
    if (message.method && this.notification) this.notification(message)
  }

  request(method, params = {}) {
    if (this.exited) return Promise.reject(new AcpError('ACP is not running'))
    const id = this.nextId++
    const payload = { jsonrpc: '2.0', id, method, params }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new AcpError(`${method} timed out after ${this.timeoutMs}ms`))
      }, this.timeoutMs)
      this.pending.set(id, { resolve, reject, timer })
      try {
        this.child.stdin.write(`${JSON.stringify(payload)}\n`)
      } catch (error) {
        clearTimeout(timer)
        this.pending.delete(id)
        reject(new AcpError(`${method} write failed: ${error?.message || error}`))
      }
    })
  }

  /** `cmd.exe` shells do not die with their child, so Windows kills the tree. */
  killTree() {
    const pid = this.child?.pid
    if (!pid) return
    if (IS_WIN) {
      try {
        const killer = spawn('taskkill', ['/pid', String(pid), '/t', '/f'], {
          stdio: 'ignore',
          windowsHide: true
        })
        killer.on('error', () => {})
        killer.unref()
      } catch {}
    } else {
      try { this.child.kill('SIGTERM') } catch {}
    }
  }

  async stop() {
    if (this.stopped) return
    this.stopped = true
    try { this.rl?.close() } catch {}
    if (!this.child || this.exited) return
    try { this.child.stdin.end() } catch {}
    await new Promise((resolve) => {
      const timer = setTimeout(() => { this.killTree(); resolve() }, 800)
      this.child.once('exit', () => { clearTimeout(timer); resolve() })
    })
  }
}

function modelValue(value) {
  const slash = value.indexOf('/')
  if (slash <= 0 || slash === value.length - 1) return JSON.stringify([value])
  return JSON.stringify([value.slice(0, slash), value.slice(slash + 1)])
}

function chooseModelValue(configOptions, requested) {
  if (requested) return modelValue(requested)
  const modelOption = Array.isArray(configOptions)
    ? configOptions.find((option) => option?.id === 'model')
    : undefined
  const groups = Array.isArray(modelOption?.options) ? modelOption.options : []
  const account = groups.find((group) => group?.group === 'deepseek-account')
  const flash = account?.options?.find((option) => String(option?.name || '').toLowerCase().includes('flash'))
  return flash?.value || null
}

function emitJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`)
}

const SOURCE_LABELS = {
  codex: 'Codex',
  claude: 'Claude Code',
  'claude-code': 'Claude Code',
  cursor: 'Cursor',
  'dsh-chat': 'DSH Chat',
  terminal: 'Terminal'
}

function sourceLabelOf(source) {
  return SOURCE_LABELS[source] || source
}

function resolveSource(args) {
  return args.source || process.env.DSH_RUN_BUBBLE_SOURCE || 'terminal'
}

function resolveSurface(args) {
  const raw = args.surface ?? process.env.DSH_RUN_BUBBLE_SURFACE ?? DEFAULT_SURFACE
  const value = String(raw).trim().toLowerCase()
  if (SURFACES.includes(value)) return value
  warn(`ignoring surface "${raw}" (expected ${SURFACES.join('|')}); using ${DEFAULT_SURFACE}`)
  return DEFAULT_SURFACE
}

function heartbeatMs(args) {
  let raw = args.heartbeat
  if (raw === undefined || raw === null || raw === '') raw = process.env.DSH_RUN_BUBBLE_HEARTBEAT
  if (raw === undefined || raw === null || String(raw).trim() === '') return DEFAULT_HEARTBEAT_MS
  const seconds = Number(raw)
  if (!Number.isFinite(seconds) || seconds < 0) {
    warn(`ignoring heartbeat interval "${raw}" (expected seconds >= 0)`)
    return DEFAULT_HEARTBEAT_MS
  }
  return Math.min(seconds, 3600) * 1000
}

function titleFromText(text, fallback) {
  const collapsed = String(text ?? '').replace(/\s+/g, ' ').trim()
  const title = collapsed.slice(0, 50).trim()
  return title || fallback
}

function warn(message) {
  process.stderr.write(`dsh-chat: warning: ${message}\n`)
}

function sidecarFile(sessionId) {
  return join(SIDECAR_DIR, `${sessionId}.json`)
}

function readSidecar(sessionId) {
  try {
    const parsed = JSON.parse(readFileSync(sidecarFile(sessionId), 'utf8'))
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
  } catch {
    return null
  }
}

let tmpCounter = 0

function spinWait(ms) {
  const end = Date.now() + ms
  while (Date.now() < end) { /* bounded synchronous retry for Windows AV locks */ }
}

/** Windows answers EPERM/EBUSY while a scanner holds the destination open. */
function renameWithRetry(from, to) {
  let lastError
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      renameSync(from, to)
      return
    } catch (error) {
      lastError = error
      if (!['EPERM', 'EACCES', 'EBUSY', 'EEXIST'].includes(error?.code)) break
      spinWait(10 * (attempt + 1))
    }
  }
  throw lastError
}

/**
 * Write JSON atomically (unique tmp file + rename). 0600 on POSIX; Windows has
 * no POSIX mode bits, so the user-profile ACL is relied on instead.
 */
function atomicWriteJson(file, value) {
  mkdirSync(dirname(file), { recursive: true })
  const data = `${JSON.stringify(value, null, 2)}\n`
  const tmp = `${file}.tmp-${process.pid}-${++tmpCounter}`
  try {
    writeFileSync(tmp, data, { encoding: 'utf8', mode: 0o600 })
    if (!IS_WIN) chmodSync(tmp, 0o600)
    renameWithRetry(tmp, file)
  } catch (error) {
    try { rmSync(tmp, { force: true }) } catch {}
    throw error
  }
  if (!IS_WIN) {
    try { chmodSync(file, 0o600) } catch {}
  }
}

/**
 * Sidecar record: legacy fields stay byte-for-byte compatible, plus the
 * Windows liveness fields the daemon reads (pid / surface / heartbeatAt).
 * `sessionId` is included only because the wrapper always knows it.
 */
function buildRecord(command, args, sessionId, text, existing = {}, surface = resolveSurface(args)) {
  const fallbackSource = resolveSource(args)
  let source = fallbackSource
  let title
  let task
  if (command === 'ask') {
    title = args.title || titleFromText(text, 'New session')
    task = text
  } else if (command === 'new') {
    title = args.title || 'New session'
    task = ''
  } else {
    // send: keep existing metadata unless the caller explicitly updates it
    const update = Boolean(args.title || args.source)
    source = args.source || (typeof existing.source === 'string' && existing.source) || fallbackSource
    const existingTitle = typeof existing.title === 'string' ? existing.title.trim() : ''
    const usableTitle = existingTitle && existingTitle !== 'New session' ? existingTitle : ''
    title = args.title || usableTitle || titleFromText(text, 'New session')
    task = !update && typeof existing.task === 'string' && existing.task.trim() ? existing.task : text
  }
  const now = new Date().toISOString()
  return {
    ...existing,
    sessionId,
    source,
    sourceLabel: sourceLabelOf(source),
    title,
    task,
    pid: process.pid,
    surface,
    heartbeatAt: now,
    updatedAt: now
  }
}

/** Sidecar failures must never break the prompt itself: warn and move on. */
function writeSidecar(command, args, sessionId, text, surface = resolveSurface(args)) {
  try {
    const existing = readSidecar(sessionId) || {}
    const record = buildRecord(command, args, sessionId, text, existing, surface)
    atomicWriteJson(sidecarFile(sessionId), record)
    return record
  } catch (error) {
    warn(`could not write session metadata: ${error?.message || error}`)
    return null
  }
}

let heartbeatTimer = null
let heartbeatFailed = false

function stopHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  heartbeatTimer = null
}

/**
 * Long prompts refresh heartbeatAt so the bubble can tell a live run from a
 * crashed one. The timer is unref'd: it never keeps dsh-chat alive.
 */
function startHeartbeat(sessionId, args, surface) {
  stopHeartbeat()
  const ms = heartbeatMs(args)
  if (!Number.isFinite(ms) || ms <= 0) return
  heartbeatFailed = false
  heartbeatTimer = setInterval(() => {
    try {
      const existing = readSidecar(sessionId)
      // The sidecar was removed (session closed): do not resurrect it.
      if (!existing) {
        stopHeartbeat()
        return
      }
      const now = new Date().toISOString()
      atomicWriteJson(sidecarFile(sessionId), {
        ...existing,
        sessionId,
        pid: process.pid,
        surface,
        heartbeatAt: now,
        updatedAt: now
      })
      heartbeatFailed = false
    } catch (error) {
      if (!heartbeatFailed) {
        warn(`could not refresh session metadata: ${error?.message || error}`)
        heartbeatFailed = true
      }
    }
  }, ms)
  heartbeatTimer.unref?.()
}

function removeSidecar(sessionId) {
  stopHeartbeat()
  try {
    rmSync(sidecarFile(sessionId), { force: true })
  } catch {}
}

function installSignalHandlers(client) {
  const handler = async (signal) => {
    stopHeartbeat()
    try { await client.stop() } catch {}
    process.exit(signal === 'SIGINT' ? 130 : 143)
  }
  process.once('SIGINT', handler)
  process.once('SIGTERM', handler)
  return () => {
    process.off('SIGINT', handler)
    process.off('SIGTERM', handler)
  }
}

async function withClient(args, fn) {
  const client = new AcpClient({
    timeoutMs: (Number(args.timeout) || 120) * 1000,
    verbose: Boolean(args.verbose),
    quiet: Boolean(args.quiet),
    json: Boolean(args.json)
  })
  const removeSignalHandlers = installSignalHandlers(client)
  await client.start()
  try {
    await client.request('initialize', { protocolVersion: 1, clientCapabilities: {} })
    return await fn(client)
  } finally {
    stopHeartbeat()
    removeSignalHandlers()
    await client.stop()
  }
}

async function applyModel(client, sessionId, configOptions, requested, args) {
  const value = chooseModelValue(configOptions, requested)
  if (!value) return
  try {
    const result = await client.request('session/set_config_option', {
      sessionId,
      configId: 'model',
      value
    })
    if (!args.json) return result
    return result
  } catch (error) {
    if (requested) throw error
  }
}

function textOf(update) {
  if (!update || update.sessionUpdate !== 'agent_message_chunk') return ''
  const content = update.content
  if (content?.type === 'text') return content.text || ''
  return ''
}

async function promptOnce(client, sessionId, text, args) {
  let answer = ''
  client.notification = (message) => {
    if (message.method !== 'session/update') return
    const update = message.params?.update
    if (!update) return
    if (update.sessionUpdate === 'agent_message_chunk') {
      const chunk = textOf(update)
      if (!chunk) return
      answer += chunk
      if (args.json) emitJson({ type: 'text', text: chunk })
      else process.stdout.write(chunk)
    } else if (update.sessionUpdate === 'tool_call' || update.sessionUpdate === 'tool_call_update') {
      if (args.json) emitJson({ type: 'update', update })
      else if (!args.quiet) {
        const title = update.title || update.kind || update.toolCallId || 'tool'
        process.stderr.write(`[tool] ${title}\n`)
      }
    } else if (args.json) {
      emitJson({ type: 'update', update })
    }
  }
  const result = await client.request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text }]
  })
  client.notification = null
  if (args.json) emitJson({ type: 'done', stopReason: result?.stopReason ?? null })
  else process.stdout.write('\n')
  return { answer, stopReason: result?.stopReason }
}

async function closeSession(client, sessionId, cwd) {
  stopHeartbeat()
  try {
    await client.request('session/close', { sessionId })
  } catch {
    await client.request('session/resume', { sessionId, cwd, mcpServers: [] })
    await client.request('session/close', { sessionId })
  }
  removeSidecar(sessionId)
}

async function cmdAsk(args) {
  const text = args._.join(' ').trim()
  if (!text) throw new Error('ask needs a prompt')
  const cwd = args.cwd ? args.cwd : process.cwd()
  return withClient(args, async (client) => {
    const session = await client.request('session/new', { cwd, mcpServers: [] })
    const sessionId = session.sessionId
    await applyModel(client, sessionId, session.configOptions, args.model, args)
    const surface = resolveSurface(args)
    writeSidecar('ask', args, sessionId, text, surface)
    startHeartbeat(sessionId, args, surface)
    if (args.json) emitJson({ type: 'session', sessionId })
    await promptOnce(client, sessionId, text, args)
    stopHeartbeat()
    try { await closeSession(client, sessionId, cwd) } catch {}
    return 0
  })
}

async function cmdSend(args) {
  if (!args.session) throw new Error('send needs --session <id>')
  const text = args._.join(' ').trim()
  if (!text) throw new Error('send needs a prompt')
  const cwd = args.cwd ? args.cwd : process.cwd()
  return withClient(args, async (client) => {
    const resumed = await client.request('session/resume', { sessionId: args.session, cwd, mcpServers: [] })
    await applyModel(client, args.session, resumed.configOptions, args.model, args)
    const surface = resolveSurface(args)
    writeSidecar('send', args, args.session, text, surface)
    startHeartbeat(args.session, args, surface)
    if (args.json) emitJson({ type: 'session', sessionId: args.session })
    await promptOnce(client, args.session, text, args)
    stopHeartbeat()
    return 0
  })
}

async function cmdNew(args) {
  const cwd = args.cwd ? args.cwd : process.cwd()
  return withClient(args, async (client) => {
    const session = await client.request('session/new', { cwd, mcpServers: [] })
    await applyModel(client, session.sessionId, session.configOptions, args.model, args)
    writeSidecar('new', args, session.sessionId, '', resolveSurface(args))
    if (args.json) emitJson({ type: 'session', sessionId: session.sessionId, cwd })
    else process.stdout.write(`${session.sessionId}\n`)
    return 0
  })
}

async function cmdList(args) {
  return withClient(args, async (client) => {
    const result = await client.request('session/list', {})
    if (args.json) emitJson({ type: 'sessions', sessions: result.sessions })
    else for (const session of result.sessions || []) process.stdout.write(`${session.sessionId}\t${session.cwd || ''}\n`)
    return 0
  })
}

async function cmdClose(args) {
  if (!args.session) throw new Error('close needs --session <id>')
  return withClient(args, async (client) => {
    const cwd = args.cwd ? args.cwd : process.cwd()
    await closeSession(client, args.session, cwd)
    if (args.json) emitJson({ type: 'closed', sessionId: args.session })
    else process.stdout.write(`closed ${args.session}\n`)
    return 0
  })
}

/** Test/diagnostic mode: show exactly what would land in the sidecar. */
function cmdPrintSidecar(args) {
  const rest = [...args._]
  const command = rest.shift() || 'ask'
  const text = rest.join(' ').trim()
  if (!['ask', 'new', 'send'].includes(command)) {
    throw new Error('--print-sidecar supports ask, new or send')
  }
  if (command === 'send' && !args.session) throw new Error('--print-sidecar send needs --session <id>')
  const sessionId = args.session || 'preview-session'
  const record = buildRecord(command, args, sessionId, text, readSidecar(sessionId) || {})
  process.stdout.write(`${JSON.stringify(record, null, 2)}\n`)
  if (!args.quiet) process.stderr.write(`dsh-chat: sidecar path: ${sidecarFile(sessionId)}\n`)
  return 0
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) { process.stdout.write(HELP); return 0 }
  if (args.version) { process.stdout.write(`${VERSION}\n`); return 0 }
  if (args.printSidecar) return cmdPrintSidecar(args)
  const command = args._.shift() || 'help'
  switch (command) {
    case 'ask': return cmdAsk(args)
    case 'send': return cmdSend(args)
    case 'new': return cmdNew(args)
    case 'list': return cmdList(args)
    case 'close': return cmdClose(args)
    case 'help': process.stdout.write(HELP); return 0
    default: throw new Error(`unknown command: ${command}`)
  }
}

main().then((code) => {
  process.exitCode = code
}).catch((error) => {
  process.stderr.write(`dsh-chat: ${error?.message || error}\n`)
  if (error?.data) process.stderr.write(`${JSON.stringify(error.data)}\n`)
  process.exitCode = 1
})
