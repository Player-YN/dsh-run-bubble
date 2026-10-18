/**
 * Windows liveness and desktop-attribution for the run-bubble daemon.
 *
 * Windows does have a cross-process session lock — just not a file one. DSH
 * (win32) holds a named kernel semaphore per open session:
 *
 *   Local\dsh-session-lock-<sha256(lower(resolve(<sessionDir>\session.lock)))>
 *
 * The object exists iff a live process holds the write lease, is destroyed when
 * the last handle closes or the holder dies, and never leaves a file behind.
 * That is semantically the macOS `flock`, so the primary chain is:
 *
 *   leaseHolders(sessionDir) -> null (probe unavailable) | [] (dead) | pids
 *
 * The holder PIDs come from the native `DshLeaseProbe.exe` (handle-table scan,
 * ~67ms); `scanLeases()` caches one scan per tick. When the probe is missing or
 * broken, the daemon degrades to the T4 heuristics kept below:
 *
 *   1. an explicit sidecar written by the ACP interop layer (`surface`, `pid`,
 *      `heartbeatAt`/`updatedAt`),
 *   2. a live external `dsh` CLI process (source evidence only),
 *   3. log `mtime` freshness within RUN_BUBBLE_LIVE_MS.
 *
 * Desktop ownership: the desktop app's own host is
 * `dsh-desktop-host/lib/index.js` and its whole subtree (never its shell/system
 * ancestors) is the desktop side. In lease mode a session is desktop-owned when
 * its holder PID belongs to that set (RUN_BUBBLE_INCLUDE_DESKTOP=1 includes it).
 *
 * The module is pure apart from the probe spawn: process-table lookups are
 * passed in as callbacks/sets and the probe output parser is exported so the
 * judgement can be unit-tested without spawning anything.
 */

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { normalizeCommandLine } from './process-table.mjs'

export const DEFAULT_LIVE_MS = 120_000
export const DEFAULT_STALE_MS = 900_000

const DESKTOP_SURFACE = 'desktop'
const EXTERNAL_PROFILE_PATTERN = /--profile(?:=|\s+)(acp|headless|sdk|web)\b/
const EXTERNAL_BIN_ENTRY = '@deepseek-ai/dsh/lib/bin.js'

// The native lease probe ships next to the daemon (dev: repo root; installed:
// %LOCALAPPDATA%\dsh-run-bubble). Never hard-code its absolute path.
const MODULE_DIR = dirname(fileURLToPath(import.meta.url))
const INSTALL_DIR = resolve(MODULE_DIR, '..', '..')
const LEASE_NAME_PREFIX = 'Local\\dsh-session-lock-'
const LEASE_PROBE_TIMEOUT_MS = 4000
const LEASE_CACHE_MS = 1500
const LEASE_ERROR_INTERVAL_MS = 60_000

let leaseCache = { at: 0, value: null }
let leaseInFlight = null
const leaseErrorAt = new Map()

function envFlag(name, fallback) {
  const raw = process.env[name]
  if (raw === undefined || raw === null || raw.trim() === '') return fallback
  return !['0', 'false', 'no', 'off'].includes(raw.trim().toLowerCase())
}

function reportOnce(key, message, onError) {
  if (typeof onError !== 'function') return
  const now = Date.now()
  const last = leaseErrorAt.get(key) || 0
  if (now - last < LEASE_ERROR_INTERVAL_MS) return
  leaseErrorAt.set(key, now)
  if (leaseErrorAt.size > 64) {
    const ordered = [...leaseErrorAt.entries()].sort((a, b) => a[1] - b[1])
    for (const [id] of ordered.slice(0, leaseErrorAt.size - 64)) leaseErrorAt.delete(id)
  }
  try {
    onError(message)
  } catch {}
}

/**
 * Kernel object name of a session's write lease. DSH (win32) creates
 * `Local\dsh-session-lock-<sha256(lower(resolve(<dir>\session.lock)))>`; there
 * is never a `session.lock` file on disk, so never stat it.
 */
export function leaseName(sessionDir) {
  const lockPath = resolve(join(sessionDir, 'session.lock'))
  const hash = createHash('sha256').update(lockPath.toLowerCase()).digest('hex')
  return `${LEASE_NAME_PREFIX}${hash}`
}

/** Just the 64-hex digest part of `leaseName()` (the probe reports this). */
export function leaseHash(sessionDir) {
  const lockPath = resolve(join(sessionDir, 'session.lock'))
  return createHash('sha256').update(lockPath.toLowerCase()).digest('hex')
}

/**
 * Parse `DshLeaseProbe.exe` stdout into Map<hash, pid[]>.
 *
 * Contract:
 *   { ok: true, scanMs, handles, semaphores, leases: [{ pid, hash, name }] }
 * Anything malformed returns null (probe considered unavailable).
 */
export function parseProbeOutput(stdout) {
  const text = typeof stdout === 'string' ? stdout.trim() : ''
  if (!text) return null
  let parsed = null
  // Tolerate extra/warning lines: use the last valid JSON object line.
  for (const line of text.split(/\r?\n/)) {
    const candidate = line.trim()
    if (!candidate.startsWith('{')) continue
    try {
      parsed = JSON.parse(candidate)
    } catch {}
  }
  if (!parsed || parsed.ok !== true) return null
  const leases = Array.isArray(parsed.leases) ? parsed.leases : []
  const map = new Map()
  for (const lease of leases) {
    if (!lease || typeof lease !== 'object') continue
    let hash = typeof lease.hash === 'string' ? lease.hash.trim().toLowerCase() : ''
    if (!hash && typeof lease.name === 'string') {
      const index = lease.name.lastIndexOf(LEASE_NAME_PREFIX)
      if (index >= 0) hash = lease.name.slice(index + LEASE_NAME_PREFIX.length).trim().toLowerCase()
    }
    if (!/^[0-9a-f]{64}$/.test(hash)) continue
    const pid = Number(lease.pid)
    if (!Number.isFinite(pid) || pid <= 0) continue
    let list = map.get(hash)
    if (!list) map.set(hash, (list = []))
    if (!list.includes(pid)) list.push(pid)
  }
  return map
}

/**
 * Resolve the native probe path:
 *   RUN_BUBBLE_LEASE_PROBE -> <install>/DshLeaseProbe.exe ->
 *   <install>/../dist/DshLeaseProbe.exe -> <install>/dist/DshLeaseProbe.exe
 * An explicit env override that does not exist means "unavailable" (no silent
 * fallback to another copy); all other misses also return null.
 */
export function resolveLeaseProbe() {
  const override = process.env.RUN_BUBBLE_LEASE_PROBE
  if (override && override.trim()) {
    const candidate = override.trim()
    return existsSync(candidate) ? candidate : null
  }
  const candidates = [
    join(INSTALL_DIR, 'DshLeaseProbe.exe'),
    resolve(INSTALL_DIR, '..', 'dist', 'DshLeaseProbe.exe'),
    join(INSTALL_DIR, 'dist', 'DshLeaseProbe.exe')
  ]
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  return null
}

/**
 * One handle-table scan, cached for 1500ms (at most one spawn per tick).
 * Returns Map<hash, pid[]> or null ("probe unavailable" — never an empty Map,
 * which would declare every session dead).
 */
export async function scanLeases({ force = false, onError } = {}) {
  if (envFlag('RUN_BUBBLE_DISABLE_LEASE_PROBE', false)) return null
  const now = Date.now()
  if (!force && now - leaseCache.at < LEASE_CACHE_MS) return leaseCache.value
  if (leaseInFlight) return leaseInFlight
  leaseInFlight = scanLeasesUncached(onError)
    .then((value) => {
      leaseCache = { at: Date.now(), value }
      return value
    })
    .catch((error) => {
      reportOnce('scan', `lease probe failed: ${error?.message || error}`, onError)
      leaseCache = { at: Date.now(), value: null }
      return null
    })
    .finally(() => {
      leaseInFlight = null
    })
  return leaseInFlight
}

function scanLeasesUncached(onError) {
  const probe = resolveLeaseProbe()
  if (!probe) {
    reportOnce('missing', 'lease probe not found; falling back to mtime/sidecar heuristics', onError)
    return Promise.resolve(null)
  }
  return new Promise((resolvePromise) => {
    execFile(probe, [], {
      timeout: LEASE_PROBE_TIMEOUT_MS,
      windowsHide: true,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024
    }, (error, stdout) => {
      if (error) {
        reportOnce(`exec:${probe}`, `lease probe failed: ${error.message}`, onError)
        resolvePromise(null)
        return
      }
      const map = parseProbeOutput(stdout)
      if (!map) {
        reportOnce(`parse:${probe}`, 'lease probe returned unparsable output', onError)
        resolvePromise(null)
        return
      }
      resolvePromise(map)
    })
  })
}

/**
 * Holders of one session's write lease. `null` = probe unavailable, `[]` = no
 * holder (session is dead). This is the Windows equivalent of `lockHolders()`.
 */
export async function leaseHolders(sessionDir, options = {}) {
  const map = await scanLeases(options)
  if (map === null) return null
  const holders = map.get(leaseHash(sessionDir))
  return holders ? [...holders] : []
}

/**
 * PIDs of externally driven `dsh` sessions — used only as *source* evidence
 * (never for desktop attribution).
 *
 * `dsh-desktop-host/lib/cli.js` is deliberately NOT matched: it is the desktop
 * runtime's wrapper for running `dsh` commands, not an external ACP/headless
 * process (see docs/dsh-internals-windows.md §9.2).
 */
export function externalCliPids(table) {
  if (!(table instanceof Map)) return null
  const pids = new Set()
  for (const row of table.values()) {
    const command = normalizeCommandLine(row.cmdline)
    if (EXTERNAL_PROFILE_PATTERN.test(command) || command.includes(EXTERNAL_BIN_ENTRY)) {
      pids.add(row.pid)
    }
  }
  return pids
}

export function normalizeSidecar(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null
}

/** Explicit surface declaration from the interop sidecar (`acp`/`headless`/`desktop`). */
export function sidecarSurface(sidecar) {
  if (typeof sidecar?.surface !== 'string') return ''
  return sidecar.surface.trim().toLowerCase()
}

/** Explicit source declaration from the interop sidecar. */
export function sidecarSource(sidecar) {
  return typeof sidecar?.source === 'string' ? sidecar.source.trim() : ''
}

/** Pid declared by the sidecar (interop may use `pid`, `agentPid` or `processId`). */
export function sidecarPid(sidecar) {
  for (const key of ['pid', 'agentPid', 'processId', 'processPid']) {
    const value = Number(sidecar?.[key])
    if (Number.isFinite(value) && value > 0) return value
  }
  return null
}

export function sidecarSessionId(sidecar) {
  if (typeof sidecar?.sessionId === 'string' && sidecar.sessionId.trim()) return sidecar.sessionId.trim()
  if (typeof sidecar?.id === 'string' && sidecar.id.trim()) return sidecar.id.trim()
  return ''
}

/** Accepts epoch milliseconds, epoch seconds or an ISO timestamp. */
export function parseTimestampMs(value) {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    return value < 1e12 ? Math.round(value * 1000) : Math.round(value)
  }
  if (typeof value === 'string' && value.trim()) {
    const parsed = Date.parse(value)
    if (Number.isFinite(parsed) && parsed > 0) return parsed
    const numeric = Number(value)
    if (Number.isFinite(numeric) && numeric > 0) return numeric < 1e12 ? Math.round(numeric * 1000) : Math.round(numeric)
  }
  return 0
}

/** Newest sidecar heartbeat, falling back to `updatedAt` from the interop. */
export function sidecarHeartbeatAt(sidecar) {
  let newest = 0
  for (const key of ['heartbeatAt', 'heartbeat', 'updatedAt', 'touchedAt']) {
    const value = parseTimestampMs(sidecar?.[key])
    if (value > newest) newest = value
  }
  return newest
}

/** True when the sidecar declares a surface or a pid (contract §4 "declared"). */
export function sidecarDeclared(sidecar) {
  return Boolean(sidecarSurface(sidecar) || sidecarPid(sidecar))
}

/** `openTurn` from folded log state: a turn start without a later turn end. */
export function openTurnFromState(state) {
  if (!state || state.lastStart === null || state.lastStart === undefined) return false
  if (state.lastEnd === null || state.lastEnd === undefined) return true
  return (Number(state.lastEnd.time) || 0) < (Number(state.lastStart.time) || 0)
}

/** A dangling turn that stopped writing events a long time ago is a zombie. */
export function isZombie({ openTurn, lastEventAt, now, staleMs = DEFAULT_STALE_MS }) {
  if (!openTurn) return false
  const last = Number(lastEventAt) || 0
  if (last <= 0) return false
  return now - last > staleMs
}

/**
 * Liveness for one Windows session (degraded / T4 path only).
 *
 * `pidAlive` and `externalCliPids` are optional: a missing process table simply
 * removes those signals instead of failing the whole refresh.
 */
export function windowsLive({
  now,
  mtimeMs,
  sidecar,
  liveMs = DEFAULT_LIVE_MS,
  pidAlive = null,
  externalCliPids: external = null
} = {}) {
  const mtime = Number(mtimeMs) || 0
  const freshMtime = mtime > 0 && now - mtime <= liveMs
  const surface = sidecarSurface(sidecar)
  const pid = sidecarPid(sidecar)
  const declared = Boolean(surface || pid)
  const heartbeat = sidecarHeartbeatAt(sidecar)
  const freshHeartbeat = heartbeat > 0 && now - heartbeat <= liveMs
  const externalAlive = Boolean(pid && external instanceof Set && external.has(pid))
  const processAlive = Boolean(pid && typeof pidAlive === 'function' && pidAlive(pid))

  if (freshMtime) {
    return { live: true, via: 'mtime', declared, freshHeartbeat, processAlive, externalAlive, pid }
  }
  if (declared && (freshHeartbeat || externalAlive || processAlive)) {
    return { live: true, via: 'sidecar', declared, freshHeartbeat, processAlive, externalAlive, pid }
  }
  return { live: false, via: null, declared, freshHeartbeat, processAlive, externalAlive, pid }
}

/**
 * Desktop / external attribution for one Windows session (contract §4 step 3).
 *
 * Decision order (degraded path only; lease holders are authoritative):
 *   1. sidecar `surface: "desktop"`          -> skip unless includeDesktop
 *   2. any other explicit sidecar surface    -> keep (explicit external run)
 *   3. explicit sidecar source (interop)     -> keep (the app never writes one)
 *   4. sidecar pid chain touches a desktop host -> skip unless includeDesktop
 *   5. sidecar pid chain resolves in-process -> keep (external launcher)
 *   6. otherwise ambiguous: included by default on Windows (no other evidence);
 *      set includeAmbiguous=false via RUN_BUBBLE_INCLUDE_AMBIGUOUS=0 to restore
 *      the strict macOS-like rule.
 *
 * `externalCliPids` is deliberately NOT consulted here: it is only source
 * evidence / sidecar-pid corroboration, never an ownership signal.
 */
export function windowsOwnership({
  sidecar,
  desktopPresent = false,
  includeAmbiguous = true,
  includeDesktop = false,
  desktopPids = null,
  pidChain = null
} = {}) {
  const surface = sidecarSurface(sidecar)
  const pid = sidecarPid(sidecar)

  if (surface === DESKTOP_SURFACE) {
    return { keep: includeDesktop, reason: includeDesktop ? 'sidecar-desktop-included' : 'sidecar-desktop', via: 'sidecar', ambiguous: false, pid }
  }
  if (surface) return { keep: true, reason: 'sidecar-surface', via: 'sidecar', ambiguous: false, pid }
  if (sidecarSource(sidecar)) return { keep: true, reason: 'sidecar-source', via: 'sidecar', ambiguous: false, pid }

  if (pid) {
    const chain = typeof pidChain === 'function' ? pidChain(pid) : null
    if (chain && chain.length > 0) {
      if (desktopPids instanceof Set && chain.some((row) => desktopPids.has(row.pid))) {
        return { keep: includeDesktop, reason: includeDesktop ? 'pid-desktop-chain-included' : 'pid-desktop-chain', via: 'process', ambiguous: false, pid }
      }
      return { keep: true, reason: 'pid-external-chain', via: 'process', ambiguous: false, pid }
    }
  }

  if (desktopPresent && !includeAmbiguous) {
    return { keep: false, reason: 'ambiguous-desktop', via: 'none', ambiguous: true, pid }
  }
  return { keep: true, reason: desktopPresent ? 'ambiguous-included' : 'no-desktop-host', via: 'none', ambiguous: true, pid }
}

/** `daemon.json.mode`: the judgment chain actually used for this refresh. */
export function judgmentMode({ platform, lease = false, sidecarInfluenced = false }) {
  if (platform === 'darwin') return 'darwin-lock'
  if (lease) return 'win-lease'
  return sidecarInfluenced ? 'win-sidecar' : 'win-mtime'
}
