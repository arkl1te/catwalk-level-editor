## Windows' sound output for the sound previews (music.nim): 16-bit stereo
## PCM through winmm's waveOut, a few chunk-sized buffers deep. On Linux the
## same chunks go to pw-cat, paplay or aplay through a pipe instead.

import std/[atomics, os, times, volatile]

type
  HWaveOut = pointer
  WaveFormatEx {.packed.} = object
    formatTag, channels: uint16
    samplesPerSec, avgBytesPerSec: uint32
    blockAlign, bitsPerSample, cbSize: uint16
  WaveHdr = object
    data: pointer
    bufferLength, bytesRecorded: uint32
    user: uint
    flags, loops: uint32
    next: pointer
    reserved: uint

  WaveOut* = object
    h: HWaveOut
    hdrs: seq[WaveHdr]          ## fixed addresses: waveOut holds them while queued
    bufs: seq[seq[int16]]
    prepared: seq[bool]

const
  WaveMapper = 0xFFFFFFFF'u32
  WaveFormatPcm = 1'u16
  CallbackNull = 0'u32
  WhdrDone = 0x1'u32

proc waveOutGetNumDevs(): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutOpen(h: ptr HWaveOut, device: uint32, fmt: ptr WaveFormatEx,
  callback, instance: uint, flags: uint32): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutPrepareHeader(h: HWaveOut, hdr: ptr WaveHdr, size: uint32): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutUnprepareHeader(h: HWaveOut, hdr: ptr WaveHdr, size: uint32): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutWrite(h: HWaveOut, hdr: ptr WaveHdr, size: uint32): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutReset(h: HWaveOut): uint32 {.stdcall, importc, dynlib: "winmm".}
proc waveOutClose(h: HWaveOut): uint32 {.stdcall, importc, dynlib: "winmm".}

proc haveWaveOut*(): bool = waveOutGetNumDevs() > 0

proc openWaveOut*(rate, chunkSamples, buffers: int): WaveOut =
  ## Opens the default output for rate Hz 16-bit stereo, with buffers
  ## buffers of chunkSamples samples (both channels) each; raises IOError.
  var fmt = WaveFormatEx(formatTag: WaveFormatPcm, channels: 2, samplesPerSec: rate.uint32,
    avgBytesPerSec: uint32(rate * 4), blockAlign: 4, bitsPerSample: 16)
  if waveOutOpen(result.h.addr, WaveMapper, fmt.addr, 0, 0, CallbackNull) != 0:
    raise newException(IOError, "no sound output")
  result.hdrs = newSeq[WaveHdr](buffers)
  result.prepared = newSeq[bool](buffers)
  for i in 0 ..< buffers: result.bufs.add newSeq[int16](chunkSamples)

proc busy(o: WaveOut, i: int): bool =
  ## Still queued: the driver sets WHDR_DONE from its own thread.
  o.prepared[i] and (volatileLoad(o.hdrs[i].flags.unsafeAddr) and WhdrDone) == 0

proc write*(o: var WaveOut, buf: seq[int16], stop: ptr Atomic[int]): bool =
  ## Queues a chunk (at most chunkSamples), waiting for a free buffer; false
  ## once stop is set or the device fails.
  while true:
    if stop[].load != 0: return false
    for i in 0 ..< o.hdrs.len:
      if o.busy(i): continue
      if o.prepared[i]:
        discard waveOutUnprepareHeader(o.h, o.hdrs[i].addr, sizeof(WaveHdr).uint32)
        o.prepared[i] = false
      let n = min(buf.len, o.bufs[i].len)
      if n > 0: copyMem(o.bufs[i][0].addr, buf[0].unsafeAddr, n * 2)
      o.hdrs[i] = WaveHdr(data: o.bufs[i][0].addr, bufferLength: uint32(n * 2))
      if waveOutPrepareHeader(o.h, o.hdrs[i].addr, sizeof(WaveHdr).uint32) != 0: return false
      o.prepared[i] = true
      return waveOutWrite(o.h, o.hdrs[i].addr, sizeof(WaveHdr).uint32) == 0
    sleep(5)

proc drain*(o: var WaveOut, stop: ptr Atomic[int], seconds: float) =
  ## Waits until what was queued has played, stop is set or seconds pass.
  let deadline = epochTime() + seconds
  while stop[].load == 0 and epochTime() < deadline:
    var queued = false
    for i in 0 ..< o.hdrs.len:
      if o.busy(i): queued = true
    if not queued: return
    sleep(10)

proc close*(o: var WaveOut) =
  ## Stops at once and closes the device.
  if o.h == nil: return
  discard waveOutReset(o.h)  # hands back every queued buffer, marked done
  for i in 0 ..< o.hdrs.len:
    if o.prepared[i]:
      discard waveOutUnprepareHeader(o.h, o.hdrs[i].addr, sizeof(WaveHdr).uint32)
  discard waveOutClose(o.h)
  o.h = nil
