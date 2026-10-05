# HP OmniBook Ultra 14 (8EB4): speakers silent on Linux — fixed with a SoundWire ACTMCTL DMI quirk

## Summary

The HP OmniBook Ultra 14 (board `8EB4`, BIOS F.06, Intel Panther Lake, Core Ultra
X9 388H, `sof-audio-pci-intel-ptl`) has four TI TAS2783 smart amplifiers, two on SoundWire link 1 and two
on link 2, plus an RT712 jack codec on link 3. On Linux (tested 7.2.2) the amps
enumerate, then three of the four drop off the bus ~100–250 ms after attaching,
firmware download fails on them, and there is no speaker output. Headphones work.

Root cause: the static DSDT declares `intel-sdw-doais = 1` / `intel-sdw-doaise2 = 1`
for every link, but `SNDW._INI` runs `DCFG()` on each `LNKn` package and overwrites
those entries from NVS bytes; the driver reads `doais = 3` / `doaise2 = 0` for the amp
links and the amps cannot follow that ACTMCTL drive timing. (`hardware/acpi/DSDT.dsl`;
Windows drives all four amps on the same firmware.)
Bisecting the ACTMCTL fields at runtime showed DOAIS=1 + DOAISE2=1 is necessary
and sufficient; DODS/CLDS/CLDE are irrelevant; DOAISE2 gates DOAIS so neither
alone helps.

Fix: two small kernel patches, no module parameters, no user configuration.

1. `drivers/soundwire/intel_auxdevice.c` — DMI-keyed override that forces
   DOAIS=1 / DOAISE2=1 on links 1 and 2 of this board.
2. `sound/soc/sdca/sdca_functions.c` — prerequisite: the BIOS declares the SDCA
   Function Topology control (0x05) for the TAS2783 nodes with access mode 0x03 and
   no DC value (`hardware/acpi/SSDT35.dsl`), so `snd-soc-sdca` refuses the function
   (same defect as thesofproject/linux#5760, fixed by BIOS on the EliteBook X; still
   present in 8EB4 BIOS F.06); fall back to SmartAmp for TI 0x0102:0x0000.

Result (boot-tested 2026-08-29 on 7.2.2: unmodified `intel_auxdevice.c` + patch 2,
unmodified `sdca_functions.c` + patch 1, stock `soundwire-bus` and
`snd-soc-tas2783-sdw`): all four amps attach and stay attached (device numbers 1/2
on each link), firmware loads first try, zero parity errors at boot and after
streaming, and all four speakers play (verified by playing a tone through one amp
at a time).

`dmesg` when the quirk fires:

```
soundwire sdw-master-0-1: ACTMCTL quirk: doais 0x3 -> 0x1, doaise2 0x0 -> 0x1
soundwire sdw-master-0-2: ACTMCTL quirk: doais 0x3 -> 0x1, doaise2 0x0 -> 0x1
```

## Applying

Against v7.2.2 (should apply to nearby versions):

```
git am upstream/0001-ASoC-SDCA-fall-back-to-SmartAmp-function-type-for-TI.patch \
       upstream/0002-soundwire-intel-override-ACTMCTL-DOAIS-DOAISE2-on-HP.patch
```

Rebuild `soundwire-intel` and `snd-soc-sdca` (CachyOS/clang kernels need `LLVM=1`),
install, reboot. Check `cat /sys/bus/soundwire/devices/sdw:*/status` shows all
five slaves `Attached` and `dmesg | grep -c PARITY` is ~0.

The TAS2783 calibration blobs now ship in `linux-firmware` (verified in
`linux-firmware-other 20260810-2`); extracting them from the Windows driver is
no longer necessary. On kernels that request them without the `0x` filename
prefix, alias symlinks are needed — see `arch-7.1.9/`.

Userspace: PipeWire needs a UCM `Speaker` device for `hw:0,2` — `ucm/` in this
repo, `sudo ucm/install.sh`. Note the 7.2.2 machine driver names the mute
controls `Left Spk Switch`, `Right Spk Switch`, `Left Spk2 Switch`,
`Right Spk2 Switch` (with the `Switch` suffix); a UCM that csets `Left Spk` fails
to load the HiFi verb.

## How this was found

28 numbered single-change experiments on the machine, most of them a full
instrumented reboot with a captured boot log, over two days. Everything was done
with AI assistance (Claude Code, model `claude-fable-5`) driving the
hypothesis/experiment loop; both patches carry an `Assisted-by:` trailer per the
kernel's `Documentation/process/coding-assistants.rst`, and all of it was
reviewed and boot-tested by a human. Condensed index (one reboot per row unless
noted):

| # | Hypothesis | Result |
|---|---|---|
| 0001 | ACPI missing SDCA function type → assume SmartAmp for TI | **Keep.** 4 amps visible, Speaker PCM exists |
| 0002 | Program BUF0 before firmware, like Windows | Ordering irrelevant |
| 0003 | Cap amp links at 4.8 MHz | PARITY 993→0; one amp gets firmware (superseded by 0026) |
| 0004–0005 | Treat clock-base `-ENODATA` as success; retry FW | Second amp per link still ignores SCP |
| 0006 | Serialize FW download; skip DAI without FW | Needed at the time; one amp still `-5` |
| 0007–0008 | Skip device number 2 | Hypothesis wrong — device ignores SCP as 3 too |
| 0009 | Clock-scale `-ENODATA` during prepare = success | Speaker PCM can open with 1 live amp |
| 0010 | 400 ms defer so the 32 KB blob misses ping traffic | Work cancelled by NPRESENT |
| 0011 | Trust ping over sticky UNATTACHED | Bus melted: PARITY 769, reset loop |
| 0012 | Keep firmware in codec across a short blip | Amp survives one blip |
| 0013 | Ignore drop only if ping already attached | Never fired |
| 0014 | Retry ping 3×50 ms | Ping stays 0; last stable single-amp boot |
| 0015 | Debounce UNATTACHED 2 s | Bus melted: Dummy Output |
| 0016 | Proceed io_init while UNATTACHED | Amp dead |
| 0017 | Skip if unattached; retry on next attach | PCM back; global mutex blocked the other link |
| 0018 | Per-link mutex; abort blob on unattach | Clean FW; Speaker `-EINVAL` on dead-amp resume |
| 0019 | Resume returns 0 without FW | Speaker opens, HiFi sink, PARITY 0 — one speaker audible |
| 0020 | Start amp links 2 s after the SOF DSP boot | Marginal amps never attach after the boot |
| 0021 | Sublink power-cycle + register snapshots around DSP boot | No register fingerprint; repower useless |
| 0022 | Runtime knob box: IOCTL / LVSCTL / ACTMCTL / repower (live trials) | **`ACTMCTL=0xd0ef` → all four amps attach + FW, live and at boot** |
| 0023 | Bisect the ACTMCTL fields (live trials) | **DOAIS=1 + DOAISE2=1 necessary and sufficient**; DOAISE2 gates DOAIS |
| 0024 | DMI quirk (this patch) instead of the knob | 4/4 firmware first try, PARITY 0, four tones |
| 0025 | Drop the 2 s late start | Identical — late start unnecessary |
| 0026 | Drop the 4.8 MHz cap (ACPI-default 9.6 MHz) | Identical — clock cap unnecessary |
| 0027 | Stock bus + stock codec, quirk only | Identical — **the quirk is the whole fix** |
| 0028 | Pristine v7.2.2 `intel_auxdevice.c` + quirk patch only | Identical — series boot-tested as written |

## Repository contents

* `upstream/` — the two patches as a `git am`-able series with cover letter
  (`0000-cover-letter.patch`, `0001-…SDCA…`, `0002-…soundwire-intel…`).
  checkpatch `--strict` clean.
* `ucm/` — alsa-ucm-conf files for the `Speaker` device on `hw:0,2` with the
  `… Switch` control names used by the 7.2.2 machine driver, and an installer
  (`sudo ucm/install.sh`, then restart PipeWire/WirePlumber).
* `hardware/acpi/` — decompiled DSDT/SSDTs from this machine.
* `windows/` — what Windows does with the same hardware (registry SoundWire
  enumeration, SetupAPI log excerpt, calibration EFI variable), see
  `windows/NOTES.md`.
* `arch-7.1.9/` — port to Arch Linux's 7.1.9-arch1-2 kernel, with scripts. Two
  further defects appear on 7.1.9 that do not on 7.2.2: the TAS2783 calibration
  blobs are requested without the `0x` filename prefix that `linux-firmware`
  ships them under, and the machine driver emits no `spk:` tag, so UCM never
  includes the speaker. See `arch-7.1.9/README.md`. The same scripts build for
  Omarchy's `linux-omarchy` kernel, which needs its own patches layered on
  first.
* `resume/` — a follow-on problem, not part of the upstream series: once the
  speakers work, every resume from suspend freezes the machine for 10–13 s
  while the kernel waits for the amplifiers. Two patches to
  `snd-soc-tas2783-sdw` and the measurements behind them. Built, not yet
  resume-tested. See `resume/README.md`.

## Status

Submitted as a PR to thesofproject/linux `topic/sof-dev` and reported in
thesofproject/linux#5732; the same series (see `upstream/0000-cover-letter.patch`)
goes to the linux-sound / SoundWire / SDCA maintainers. Until it lands, apply the
patches to your kernel or rebuild `soundwire-intel` and `snd-soc-sdca` out of tree.
