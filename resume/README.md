# Resume stall: 10–13 s frozen on the lock screen after every wake

Separate from the speaker fix in `../upstream/`, and only reachable once that
fix works: with all four amplifiers alive, every resume from s2idle holds the
whole machine in the kernel for 10–13 s. The lock screen is drawn and takes no
input until it is over.

**Status: built and compile-checked against linux-omarchy 7.2.5-3, not yet
run through a suspend/resume cycle.** The numbers below are from the stock
driver; nothing here has been measured with the patch loaded.

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
* Inferred: the timings fit roughly 5.5 s per amplifier, which puts the second
  amplifier on each link at about 11 s — past a 5 s limit no matter what. Patch
  0002 exists to replace this inference with a logged number.

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

The amplifiers are ready at the same moment as before, about 11 s after wake.
The difference is that the desktop is usable while they finish.

1. Wake time: `arch-7.1.9/03-verify.sh` section 11 should show a kernel resume
   of about a second, four `re-initialised` lines per resume and no
   `failed to resume`.
2. All four speakers after a resume (one tone per amp, as in the original fix).
3. Sound started in the first ~10 s after wake. A stream opened before an
   amplifier has its firmware gets `-EINVAL` ("error playback without fw
   download") from `hw_params`; whether PipeWire retries cleanly or needs a
   second attempt is the open question.
4. Music playing when the lid closes: it should pick up again once the
   amplifiers are back, without restarting PipeWire.
5. Closing the lid again within ~10 s of opening it, while the amplifiers are
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
