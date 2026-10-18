/**
 * Windows process table for the run-bubble daemon.
 *
 * Windows has no `ps`; the cheapest cross-version source is one
 * `Get-CimInstance Win32_Process` query piped through `ConvertTo-Json`. The
 * whole table is cached for four seconds, so a refresh tick usually answers all
 * questions (desktop-host detection, parent chains, source inference) from one
 * in-memory snapshot.
 *
 * A `null` result means "the table is unavailable" (no PowerShell, timeout,
 * unparsable output). It is never treated as "no processes": callers must fail
 * open instead of concluding that nothing is running.
 *
 * No npm dependencies, no network, read-only.
 */

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

const PLATFORM = process.platform
const CACHE_MS = 4000
const QUERY_TIMEOUT_MS = 2500
const MAX_BUFFER = 32 * 1024 * 1024
const MAX_CHAIN_DEPTH = 8

/**
 * `[pscustomobject]@{ rows = @(...) }` keeps the output valid JSON even for an
 * empty process list, which `ConvertTo-Json` alone would render as "".
 */
const POWERSHELL_COMMAND = [
  '[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)',
  '[pscustomobject]@{ rows = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine) } | ConvertTo-Json -Compress -Depth 3'
].join('; ')

const POWERSHELL_CANDIDATES = ['pwsh', 'powershell']

let cache = { at: 0, value: null, hasValue: false }
let inFlight = null
let preferredShell = 0
let lastTable = null

export function supportsProcessTable() {
  return PLATFORM === 'win32'
}

function readU32(buffer, offset) {
  return (buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24)) >>> 0
}

/** Normalise a Windows command line so path matching is separator-agnostic. */
export function normalizeCommandLine(value) {
  return String(value || '').replace(/\\/g, '/').toLowerCase()
}

/** Parse the JSON emitted by POWERSHELL_COMMAND into Map<pid, row>. */
export function parseProcessTableOutput(stdout) {
  const text = typeof stdout === 'string' ? stdout.trim() : ''
  if (!text) return null
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    return null
  }
  const rows = Array.isArray(parsed)
    ? parsed
    : parsed && Array.isArray(parsed.rows)
      ? parsed.rows
      : parsed
        ? [parsed]
        : []
  const table = new Map()
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue
    const pid = Number(row.ProcessId ?? row.processId)
    if (!Number.isFinite(pid) || pid <= 0) continue
    table.set(pid, {
      pid,
      ppid: Number(row.ParentProcessId ?? row.parentProcessId) || 0,
      // Name/CommandLine are null for many protected system processes.
      name: typeof row.Name === 'string' ? row.Name : '',
      cmdline: typeof row.CommandLine === 'string' ? row.CommandLine : ''
    })
  }
  return table
}

async function queryTable() {
  for (let index = preferredShell; index < POWERSHELL_CANDIDATES.length; index += 1) {
    const shell = POWERSHELL_CANDIDATES[index]
    try {
      const { stdout } = await execFileAsync(shell, ['-NoProfile', '-NonInteractive', '-Command', POWERSHELL_COMMAND], {
        timeout: QUERY_TIMEOUT_MS,
        maxBuffer: MAX_BUFFER,
        windowsHide: true,
        encoding: 'utf8'
      })
      const table = parseProcessTableOutput(stdout)
      if (table) {
        preferredShell = index
        return table
      }
      return null
    } catch (error) {
      // Only a missing shell is worth retrying with the other candidate; a
      // timeout or a failed query is reported as unavailable.
      if (error?.code === 'ENOENT') continue
      return null
    }
  }
  return null
}

/**
 * One CIM query per cache window (4000ms), shared by every caller.
 * Returns Map<pid, { pid, ppid, name, cmdline }> or null when unavailable.
 *
 * After the first successful query the call never blocks: an expired cache is
 * returned immediately while the next query runs in the background. That keeps
 * a refresh tick off the ~600ms PowerShell startup cost; the table is at most
 * one cache window stale, which is fine for desktop detection and pid liveness.
 * `force: true` awaits a fresh query (used by tests/diagnostics).
 */
export async function getProcessTable({ force = false } = {}) {
  if (!supportsProcessTable()) return null
  const now = Date.now()
  if (!force && cache.hasValue) {
    if (now - cache.at >= CACHE_MS) void refreshTable()
    return cache.value
  }
  return refreshTable()
}

function refreshTable() {
  if (inFlight) return inFlight
  inFlight = queryTable()
    .then((value) => {
      cache = { at: Date.now(), value, hasValue: true }
      if (value instanceof Map) lastTable = value
      return value
    })
    .catch(() => {
      cache = { at: Date.now(), value: null, hasValue: true }
      return null
    })
    .finally(() => {
      inFlight = null
    })
  return inFlight
}

/** Most recent successfully parsed table (kept for the standalone helpers). */
export function lastProcessTable() {
  return lastTable
}

/**
 * Walk the parent chain from `pid` in memory, starting with the pid itself.
 * Returns [] when the pid is unknown, null when the table is unavailable.
 */
export function parentChain(pid, depth = MAX_CHAIN_DEPTH, table = lastTable) {
  if (!(table instanceof Map)) return null
  const start = Number(pid)
  if (!Number.isFinite(start) || start <= 0) return []
  const max = Number.isFinite(depth) && depth > 0 ? Math.min(Math.floor(depth), 64) : MAX_CHAIN_DEPTH
  const chain = []
  const seen = new Set()
  let current = start
  while (chain.length < max && current > 0 && !seen.has(current)) {
    const row = table.get(current)
    if (!row) break
    seen.add(current)
    chain.push(row)
    current = row.ppid
  }
  return chain
}

/**
 * True for a row that is the DSH desktop host.
 *
 * Both the desktop host and the externally driven `dsh` CLI run as
 * `DeepSeek Harness.exe`, so the executable name must never decide this: only
 * the JS entry point does. `dsh-desktop-host\lib\index.js` is the app's host,
 * `dsh-desktop-host\lib\cli.js` is the external ACP/headless CLI.
 *
 * The separator normalisation is essential on Windows: the real command line
 * contains `dsh-desktop-host\lib\index.js`, so a raw "lib/index.js" check would
 * never match.
 */
export function isDesktopHostRow(row) {
  if (!row || typeof row !== 'object') return false
  const command = normalizeCommandLine(row.cmdline)
  if (!command.includes('dsh-desktop-host')) return false
  return command.includes('dsh-desktop-host/lib/index.js')
}

/**
 * PIDs that belong to the desktop side: the `dsh-desktop-host/lib/index.js`
 * host process itself plus its descendants (Electron gpu/renderer/utility
 * subprocesses and their tool children).
 *
 * Upward we allow exactly one level, and only when the direct parent is another
 * `DeepSeek Harness` process (the Electron main). We must never walk further:
 * an interactive terminal/agent is normally descended from explorer.exe, so
 * adding general ancestors (explorer/svchost/services) would misclassify nearly
 * every real user session as desktop-side.
 *
 * Returns a Set, or null when the table is unavailable.
 */
export function desktopHostPids(table = lastTable) {
  if (!(table instanceof Map)) return null
  const hosts = []
  for (const row of table.values()) {
    if (isDesktopHostRow(row)) hosts.push(row)
  }
  const result = new Set()
  if (hosts.length === 0) return result

  const children = new Map()
  for (const row of table.values()) {
    if (row.ppid <= 0) continue
    let list = children.get(row.ppid)
    if (!list) children.set(row.ppid, (list = []))
    list.push(row.pid)
  }

  for (const host of hosts) {
    result.add(host.pid)
    // One level up only, and only for the same app binary. Anything else is a
    // shell/system ancestor and must not taint the desktop set.
    const parent = host.ppid > 0 ? table.get(host.ppid) : null
    if (parent && /deepseek harness/i.test(parent.name)) result.add(parent.pid)
  }

  const queue = hosts.map((row) => row.pid)
  while (queue.length > 0) {
    const pid = queue.pop()
    for (const child of children.get(pid) || []) {
      if (result.has(child)) continue
      result.add(child)
      queue.push(child)
    }
  }
  return result
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

/** Shells are weak evidence: keep walking towards a real agent executable. */
const TERMINAL_PATTERN = /(?:^|[^a-z0-9])(?:pwsh|powershell|cmd|conhost|windowsterminal|wt|bash|wsl|zsh|fish|iterm[0-9]*|terminal)(?:[^a-z0-9]|$)/

export function sourceKey(value) {
  return String(value || '').trim().toLowerCase().replace(/[\s_]+/g, '-')
}

export function canonicalSource(value) {
  const key = sourceKey(value)
  return SOURCE_ALIASES[key] || key || 'unknown'
}

export function defaultSourceLabel(source) {
  const key = sourceKey(source)
  if (SOURCE_LABELS[key]) return SOURCE_LABELS[key]
  if (!key) return 'Unknown'
  return key.split('-').filter(Boolean).map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')
}

/** Map a process name/command line to an external agent or a terminal. */
export function sourceFromCommand(command) {
  const value = String(command || '').toLowerCase()
  if (!value) return null
  if (value.includes('codex') || value.includes('chatgpt')) return { source: 'codex', sourceLabel: 'Codex' }
  if (value.includes('claude')) return { source: 'claude-code', sourceLabel: 'Claude Code' }
  if (value.includes('cursor')) return { source: 'cursor', sourceLabel: 'Cursor' }
  if (value.includes('dsh-chat') || value.includes('dsh_chat')) return { source: 'dsh-chat', sourceLabel: 'DSH Chat' }
  if (TERMINAL_PATTERN.test(value)) return { source: 'terminal', sourceLabel: 'Terminal' }
  return null
}

/**
 * Infer the launching agent by walking the parent chain of `pid` in memory.
 * Agent evidence wins over a shell found earlier in the chain.
 */
export function inferSource(pid, table = lastTable) {
  const chain = parentChain(pid, MAX_CHAIN_DEPTH, table)
  if (!chain) return null
  let terminal = null
  for (const row of chain) {
    const match = sourceFromCommand(`${row.name} ${row.cmdline}`)
    if (!match) continue
    if (match.source === 'terminal') {
      terminal = terminal || match
      continue
    }
    return match
  }
  return terminal
}
