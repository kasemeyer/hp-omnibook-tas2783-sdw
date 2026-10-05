# Resume stall: 10–13 s frozen on the lock screen after every wake

Separate from the speaker fix in `../upstream/`, and only reachable once that
fix works: with all four amplifiers alive, every resume from s2idle holds the
whole machine in the kernel for 10–13 s. The lock screen is drawn and takes no
input until it is over.

**Status: installed on linux-omarchy 7.2.5-3 and measured over one short
suspend/resume cycle (2026-10-05).** Kernel resume time went from 10–13 s to
0.6 s; the lock screen took the password at once and music played right after
unlocking. Not yet tried: a sleep of hours, music playing as the lid closes,
closing the lid again within a few seconds of opening it, and one tone per
speaker after a resume.

```
 +0.00 s  ACPI: EC: interrupt unblocked
 +0.61 s  Restarting tasks: Done
 +3.00 s  slave-tas2783 sdw:0:1:0102:0000:01:d: re-initialised 2512 ms after system resume, ret=0
 +3.00 s  slave-tas2783 sdw:0:2:0102:0000:01:c: re-initialised 2510 ms after system resume, ret=0
 +5.60 s  slave-tas2783 sdw:0:2:0102:0000:01:9: re-initialised 5118 ms after system resume, ret=0
 +5.61 s  slave-tas2783 sdw:0:1:0102:0000:01:a: re-initialised 5122 ms after system resume, ret=0
```

The rest of this file up to "The patches" describes the stock driver.

## What happens

`snd-soc-tas2783-sdw` uses one callback for runtime and system resume, and it
starts by waiting up to 5 s (`TAS2783_PROBE_TIMEOUT`) for the amplifier to be
enumerated and initialised again. For system resume that wait runs before user
space is thawed.

One resume on 7.2.5-3-omarchy, kernel timestamps relative to
`ACPI: EC: interrupt unblocked`:

```
 +0.16 s  nvme nvme0: 16/0/0 default/read/poll queues
 +5.87 s  slave-tas2783 sdw:0:1:0102:0000:01:a: Initialization not complete
          slave-tas2783 sdw:0:1:0102:0000:01:a: PM: failed to resume: error -110
+11.51 s  slave-tas2783 sdw:0:2:0102:0000:01:9: Initialization not complete
          slave-tas2783 sdw:0:2:0102:0000:01:9: PM: failed to resume: error -110
+12.13 s  Restarting tasks: Done
```

| Boot | Kernel | Patched `soundwire-intel` / `snd-soc-sdca` | Kernel time per resume |
|---|---|---|---|
| 2026-09-30 | 7.1.9-arch1-2 | loaded, speakers work | 10 s |
| 2026-10-01 | 7.2.5-3-omarchy | not loaded, no speakers | 0, 0, 0, 1 s |
| 2026-10-02 | 7.2.5-3-omarchy | loaded, speakers work | 12, 12 s |
| 2026-10-03 | 7.2.5-3-omarchy | loaded, speakers work | 10.6, 11.9, 12.1 s |

The two speaker patches are not at fault. The ACTMCTL quirk is re-applied on
resume (`intel_resume()` → link power-up → `intel_shim_vs_init()` reads the
quirked values). Without the patches the amplifiers are not functional devices,
so there is nothing to wait for.

Why the wait cannot be met here — partly measured, partly inferred:

* Measured: `sdw:0:1:…:a` times out on every resume and `sdw:0:2:…:9` on most;
  the other two never do. All four are `Attached` afterwards.
* From the code: after the bus reset, `tas_update_status()` resets each
  amplifier and downloads its firmware again (40 KiB per amplifier), and
  `sdw_handle_slave_status()` initialises the peripherals on a link one after
  the other, completing each one's `initialization_complete` only when its
  driver callback returns.
* Measured with patch 0002, resume no longer blocked: about 2.5 s per
  amplifier, the two links in parallel, so the first amplifier on each link is
  ready 2.5 s after its resume callback and the second 5.1 s after — some
  120 ms past the 5 s limit.
* Not explained: with the stock driver `:9` was still not ready 11.5 s in,
  though unblocked it needs 5.1 s. The first guess here, 5.5 s per amplifier,
  was wrong. Whatever the cause, initialisation ran slower while system resume
  sat waiting for it than it does once resume is allowed to finish.

So `:a` and `:9` being the same two amplifiers that would not attach before the
ACTMCTL quirk is probably coincidence: they are simply second in line.

## The patches

Cut against linux-omarchy 7.2.5-3. They also apply to `sound.git for-next`
(checked 2026-10-04), which still has the same blocking wait.

* `0001-…do-not-block-system-resume-on-peripheral-re-attach` — system resume
  gets its own callback. When the manager reset the bus it returns at once and
  lets `tas_update_status()` bring the amplifier back in the background, which
  it already did in full. When the bus was not reset, and for runtime resume,
  nothing changes.
* `0002-…log-how-long-re-initialisation-takes` — local diagnostic, not for
  upstream. One line per amplifier per resume:
  `re-initialised <N> ms after system resume, ret=0`.

**Dependency.** 0001 is only safe on a driver that has upstream `b627da430357`
("drop stale regcache on uninitialized re-attach", merged for 7.3). linux-omarchy
7.2.5-3 carries it in `0510-sound-updates.patch`; plain v7.2.5 does not. Without
it the register cache that this callback no longer syncs is left stale instead
of dropped. `arch-7.1.9/fetch-src.sh` checks for it and leaves the module out
when it is missing.

## What to expect, and what to test

All four amplifiers are ready about 5 s after wake, and the desktop is usable
while they finish.

1. Wake time — done, see Status. `arch-7.1.9/03-verify.sh` section 11 shows a
   kernel resume under a second, four `re-initialised` lines per resume and no
   `failed to resume`.
2. All four speakers after a resume (one tone per amp, as in the original fix).
3. Sound started in the first ~5 s after wake. A stream opened before an
   amplifier has its firmware gets `-EINVAL` ("error playback without fw
   download") from `hw_params`; whether PipeWire retries cleanly or needs a
   second attempt is the open question. Music started right after a normal
   unlock played, with nothing logged.
4. Music playing when the lid closes: it should pick up again once the
   amplifiers are back, without restarting PipeWire.
5. Closing the lid again within ~5 s of opening it, while the amplifiers are
   still downloading firmware.

If 3 or 4 misbehave, the next step is a bounded wait for the amplifier in
`hw_params` (delaying only the audio client) — not putting the system-wide
wait back.

## What 7.3 changes

`sound.git for-next` adds "ASoC: tas2783-sdw: add firmware download status
check", which skips re-downloading the program blocks to an amplifier that
still has its firmware. If these amplifiers keep theirs across s2idle, that
makes re-initialisation fast enough that the stock wait stops hurting, and this
override can be dropped. The `re-initialised` line is how to tell.

Related: omacom/omarchy#14172 (same stall on an HP EliteBook X Flip G2i).
