/**
 * zstd decoding for the run-bubble daemon on Windows.
 *
 * Windows has no `zstd` CLI; Node 24 ships `zlib.zstdDecompressSync`. That
 * one-shot API decodes exactly **one** frame and silently ignores everything
 * after it, which is useless for DSH logs: each append writes another frame, so
 * a real log is a concatenation of hundreds of frames (and the file is being
 * appended to while we read it).
 *
 * This module therefore walks the zstd frame structure itself (magic, frame
 * header, block headers) and decompresses one frame at a time. A half-written
 * trailing frame is dropped but everything before it is kept; only a failure at
 * the very first frame (or a corrupt stream / size limit) returns null so the
 * daemon can keep its previous cached state.
 *
 * Error logging is throttled per file (60s) to keep a busy append from
 * flooding daemon.log.
 */

import { readFileSync } from 'node:fs'
import { zstdDecompressSync } from 'node:zlib'

const ZSTD_FRAME_MAGIC = 0xfd2fb528
const SKIPPABLE_MAGIC_MIN = 0x184d2a50
const SKIPPABLE_MAGIC_MAX = 0x184d2a5f

/** Decompressed logs above this size are rejected instead of decoded. */
export const DEFAULT_MAX_OUTPUT_BYTES = 100 * 1024 * 1024
const ERROR_LOG_INTERVAL_MS = 60_000

const errorLogAt = new Map()

function readU32(buffer, offset) {
  return (buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24)) >>> 0
}

function reportError(key, message, onError) {
  if (typeof onError !== 'function') return
  const now = Date.now()
  const last = errorLogAt.get(key) || 0
  if (now - last < ERROR_LOG_INTERVAL_MS) return
  errorLogAt.set(key, now)
  if (errorLogAt.size > 128) {
    const ordered = [...errorLogAt.entries()].sort((a, b) => a[1] - b[1])
    for (const [id] of ordered.slice(0, errorLogAt.size - 128)) errorLogAt.delete(id)
  }
  try {
    onError(message)
  } catch {}
}

/**
 * Byte length of the zstd frame (or skippable frame) starting at `offset`.
 * Returns -1 when the frame is incomplete (file still being appended / cut) or
 * structurally invalid, which is the signal to keep the decoded prefix.
 */
export function frameLength(buffer, offset = 0) {
  if (!buffer || typeof buffer.length !== 'number') return -1
  const available = buffer.length - offset
  if (available < 8) return -1

  const magic = readU32(buffer, offset)
  if (magic >= SKIPPABLE_MAGIC_MIN && magic <= SKIPPABLE_MAGIC_MAX) {
    const size = readU32(buffer, offset + 4)
    if (available < 8 + size) return -1
    return 8 + size
  }
  if (magic !== ZSTD_FRAME_MAGIC) return -1

  let p = offset + 4
  const descriptor = buffer[p]
  p += 1
  const contentSizeFlag = descriptor >> 6
  const singleSegment = (descriptor >> 5) & 1
  const hasChecksum = (descriptor >> 2) & 1
  const dictionaryFlag = descriptor & 3

  if (!singleSegment) p += 1 // Window_Descriptor
  p += dictionaryFlag === 0 ? 0 : dictionaryFlag === 1 ? 1 : dictionaryFlag === 2 ? 2 : 4
  p += contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : contentSizeFlag === 1 ? 2 : contentSizeFlag === 2 ? 4 : 8
  if (p > buffer.length) return -1

  for (;;) {
    if (p + 3 > buffer.length) return -1
    const header = buffer[p] | (buffer[p + 1] << 8) | (buffer[p + 2] << 16)
    p += 3
    const lastBlock = header & 1
    const blockType = (header >> 1) & 3
    const blockSize = header >>> 3
    if (blockType === 3) return -1 // reserved
    const payload = blockType === 1 ? 1 : blockSize // RLE block stores one byte
    if (p + payload > buffer.length) return -1
    p += payload
    if (lastBlock) break
  }

  if (hasChecksum) {
    if (p + 4 > buffer.length) return -1
    p += 4
  }
  return p - offset
}

/**
 * Decode a concatenated zstd stream into UTF-8 text.
 *
 * Returns { text, frames, truncated, bytes }. `truncated` means the final frame
 * was incomplete and has been dropped; earlier frames are always kept.
 * Throws only when nothing could be decoded (corrupt stream, size limit).
 */
export function decodeZstdBuffer(buffer, { maxOutputBytes = DEFAULT_MAX_OUTPUT_BYTES } = {}) {
  const source = buffer instanceof Uint8Array ? buffer : Buffer.from(buffer || '')
  if (source.length === 0) return { text: '', frames: 0, truncated: false, bytes: 0 }

  const limit = Number.isFinite(maxOutputBytes) && maxOutputBytes > 0 ? maxOutputBytes : DEFAULT_MAX_OUTPUT_BYTES
  const parts = []
  let offset = 0
  let frames = 0
  let total = 0
  let truncated = false

  while (offset < source.length) {
    const length = frameLength(source, offset)
    if (length < 0) {
      // Incomplete or corrupt trailing frame: keep what we already decoded.
      if (frames === 0) throw new Error(`zstd: incomplete or invalid frame at byte ${offset}`)
      truncated = true
      break
    }
    const remaining = limit - total
    if (remaining <= 0) throw new Error(`zstd: decompressed size exceeds ${limit} bytes`)
    let output
    try {
      output = zstdDecompressSync(source.subarray(offset, offset + length), { maxOutputLength: Math.max(1, remaining) })
    } catch (error) {
      if (error?.code === 'ERR_BUFFER_TOO_LARGE') throw new Error(`zstd: decompressed size exceeds ${limit} bytes`)
      if (frames === 0) throw error
      truncated = true
      break
    }
    total += output.length
    if (total > limit) throw new Error(`zstd: decompressed size exceeds ${limit} bytes`)
    parts.push(output)
    frames += 1
    offset += length
  }

  return { text: Buffer.concat(parts, total).toString('utf8'), frames, truncated, bytes: total }
}

/**
 * Read one append-only zstd log and return its text, or null when decoding is
 * impossible (the caller keeps its previous cache entry). Errors are logged at
 * most once per file per 60s via `onError`.
 */
export function readZstdText(filePath, { maxOutputBytes = DEFAULT_MAX_OUTPUT_BYTES, onError } = {}) {
  let buffer
  try {
    buffer = readFileSync(filePath)
  } catch (error) {
    reportError(filePath, `cannot read ${filePath}: ${error?.message || error}`, onError)
    return null
  }
  try {
    return decodeZstdBuffer(buffer, { maxOutputBytes }).text
  } catch (error) {
    reportError(filePath, `cannot decode ${filePath}: ${error?.message || error}`, onError)
    return null
  }
}
