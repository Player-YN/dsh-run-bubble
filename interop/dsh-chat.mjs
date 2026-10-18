#!/usr/bin/env node
/**
 * dsh-chat — a tiny ACP client for DeepSeek Harness.
 *
 * The point is discoverability: another coding agent only needs `dsh-chat
 * --help`, not the raw JSON-RPC method table. One process per command; the
 * session itself is persisted by DSH and reused through ACP `session/resume`.
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { homedir } from 'node:os'
import { join } from 'node:path'

const VERSION = '0.1.0'
const DEFAULT_DSH = [
  process.env.DSH_BIN,
  '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh',
  join(homedir(), '.local/bin/dsh'),
  '/opt/homebrew/bin/dsh',
  '/usr/local/bin/dsh'
].find((candidate) => candidate && existsSync(candidate)) || 'dsh'

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

Environment:
  DSH_BIN            path to the dsh launcher (default: the Desktop bundle)
  DSH_HOME           session store (default: ~/.dsh); sidecars live in
                     $DSH_HOME/run-bubble/sessions/<sessionId>.json
  DSH_RUN_BUBBLE_SOURCE  default --source when the flag is omitted

Examples:
  dsh-chat ask "Reply with exactly: HELLO"
  dsh-chat ask --source codex --title "Smoke test" "Reply with exactly: HELLO"
  dsh-chat new --cwd .
  dsh-chat send --session <id> "Continue the task"
  dsh-chat list
  dsh-chat send --session <id> --json "status?"

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

function parseArgs(argv) {
  const args = { _: [] }
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    if (token === '--help' || token === '-h') args.help = true
    else if (token === '--version' || token === '-V') args.version = true
    else if (token === '--json') args.json = true
    else if (token === '--quiet') args.quiet = true
    else if (token === '--verbose') args.verbose = true
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

class AcpClient {
  constructor({ bin, timeoutMs, verbose, quiet, json }) {
    this.bin = bin
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
  }

  async start() {
    this.child = spawn(this.bin, ['--profile', 'acp'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, DSH_ACP_QUIET: '1' }
    })
    this.child.on('error', (error) => this.failAll(error))
    this.child.on('exit', (code, signal) => {
      this.exited = true
      this.failAll(new AcpError(`ACP exited (${code ?? signal})`))
    })
    this.rl = createInterface({ input: this.child.stdout, crlfDelay: Infinity })
    this.rl.on('line', (line) => this.onLine(line))
    this.child.stderr.on('data', (chunk) => {
      if (this.verbose) process.stderr.write(chunk)
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
      this.child.stdin.write(`${JSON.stringify(payload)}\n`)
    })
  }

  async stop() {
    try { this.rl?.close() } catch {}
    if (!this.child || this.exited) return
    this.child.stdin.end()
    await new Promise((resolve) => {
      const timer = setTimeout(() => { try { this.child.kill('SIGTERM') } catch {} ; resolve() }, 800)
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

const SIDECAR_DIR = join(
  process.env.DSH_HOME || join(homedir(), '.dsh'),
  'run-bubble',
  'sessions'
)

function sourceLabelOf(source) {
  return SOURCE_LABELS[source] || source
}

function resolveSource(args) {
  return args.source || process.env.DSH_RUN_BUBBLE_SOURCE || 'terminal'
}

function titleFromText(text, fallback) {
  const collapsed = String(text ?? '').replace(/\s+/g, ' ').trim()
  const title = collapsed.slice(0, 50).trim()
  return title || fallback
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

function writeSidecar(command, args, sessionId, text) {
  try {
    const existing = readSidecar(sessionId) || {}
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
    const record = {
      ...existing,
      source,
      sourceLabel: sourceLabelOf(source),
      title,
      task,
      updatedAt: new Date().toISOString()
    }
    mkdirSync(SIDECAR_DIR, { recursive: true })
    writeFileSync(sidecarFile(sessionId), `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 })
  } catch (error) {
    process.stderr.write(`dsh-chat: warning: could not write session metadata: ${error?.message || error}\n`)
  }
}

function removeSidecar(sessionId) {
  try {
    rmSync(sidecarFile(sessionId), { force: true })
  } catch {}
}

async function withClient(args, fn) {
  const client = new AcpClient({
    bin: DEFAULT_DSH,
    timeoutMs: (Number(args.timeout) || 120) * 1000,
    verbose: Boolean(args.verbose),
    quiet: Boolean(args.quiet),
    json: Boolean(args.json)
  })
  await client.start()
  try {
    await client.request('initialize', { protocolVersion: 1, clientCapabilities: {} })
    return await fn(client)
  } finally {
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
    writeSidecar('ask', args, sessionId, text)
    if (args.json) emitJson({ type: 'session', sessionId })
    await promptOnce(client, sessionId, text, args)
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
    writeSidecar('send', args, args.session, text)
    if (args.json) emitJson({ type: 'session', sessionId: args.session })
    await promptOnce(client, args.session, text, args)
    return 0
  })
}

async function cmdNew(args) {
  const cwd = args.cwd ? args.cwd : process.cwd()
  return withClient(args, async (client) => {
    const session = await client.request('session/new', { cwd, mcpServers: [] })
    await applyModel(client, session.sessionId, session.configOptions, args.model, args)
    writeSidecar('new', args, session.sessionId, '')
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

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) { process.stdout.write(HELP); return 0 }
  if (args.version) { process.stdout.write(`${VERSION}\n`); return 0 }
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
