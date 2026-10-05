# Arch / Omarchy port (kernel 7.1.9-arch1-2)

The two patches in `../upstream/` were developed and boot-tested on CachyOS
7.2.2. Applying them to Arch's 7.1.9-arch1-2 works, but **two additional
defects show up on 7.1.9 that do not exist on 7.2.2**, and neither is fixed by
the kernel patches. Both are recorded here.

Verified working on: HP OmniBook Ultra Laptop 14-kd0xxx, board 8EB4, BIOS F.06,
Arch kernel 7.1.9-arch1-2, alsa-ucm-conf 1.2.16.1, PipeWire 1.6.8,
WirePlumber 0.5.15.

## The three defects

### 1. Firmware filename mismatch (7.1.9 only, not in the upstream patches)

The 7.1.9 `snd-soc-tas2783-sdw` driver requests the calibration blobs as
`8EB4-1-A.bin`, `8EB4-1-D.bin`, `8EB4-2-9.bin`, `8EB4-2-C.bin`:

```
slave-tas2783 sdw:0:1:0102:0000:01:d: Direct firmware load for 8EB4-1-D.bin failed with error -2
```

`linux-firmware-other 20260810-2` ships them as `8EB4-1-0xA.bin.zst`,
`8EB4-1-0xD.bin.zst`, `8EB4-2-0x9.bin.zst`, `8EB4-2-0xC.bin.zst` — with a `0x`
prefix. All four loads fail with `-2` (ENOENT).

Note these blobs are now **shipped upstream in linux-firmware**; extracting them
from the Windows driver (see `../windows/`) is no longer necessary.

`linux-firmware` already carries alias symlinks in the un-prefixed naming for
other boards (`8EF6-X-9.bin.zst -> 8EF6-2-0x9.bin.zst`, `8EXX-X-D.bin.zst`),
just not for `8EB4`. `02-install.sh` adds the four missing aliases.

### 2. SDCA function refused — fixed by `../upstream/0001-*`

```
acpi device:20: function type only supported as DisCo constant
acpi device:22: function type only supported as DisCo constant
acpi device:24: function type only supported as DisCo constant
acpi device:26: function type only supported as DisCo constant
```

Still present on 7.1.9; patch 0001 applies cleanly.

### 3. Amps dropping off the bus — fixed by `../upstream/0002-*`

Before the quirk, 2 of 4 amps sit `UNATTACHED` (`sdw:0:1:…:a`, `sdw:0:2:…:9`).
Patch 0002 applies with a −3 line offset, no fuzz. Parity errors were already 0
here, consistent with experiment 0026 finding the 4.8 MHz clock cap unnecessary.

### 4. UCM never includes the speaker (7.1.9 only, userspace)

With all three above fixed, `device 2: Speaker` appears in `aplay -l` and all
five SoundWire slaves attach — but PipeWire still shows only `auto_null`.

`sof-soundwire.conf` derives the speaker codec by regex-matching a `spk:` tag in
the card components string. On 7.1.9 that string is:

```
HDA:80862822,80860101,00100000  cfg-amp:4 iec61937-pcm:7,6,5 hs:rt712 mic:rt712
```

There is no `spk:` tag at all — only `cfg-amp:4`. So `SpeakerCodecFile` stays
empty, and both

* `sof-soundwire.conf` → `Include /codecs/${var:SpeakerCodecFile}/init.conf`
* `HiFi.conf:11-16`    → `Include /sof-soundwire/${var:SpeakerCodecFile}.conf`

are skipped. The `ucm/` files install correctly and are simply never read. With
no Speaker port, every remaining output port is "not available" (nothing plugged
into headphone or HDMI), ALSA marks the whole HiFi profile `available: no`,
PipeWire selects profile `off`, and the only sink is `auto_null`.

`04-fix-ucm-spk-tag.sh` adds a board-gated compat block that derives the codec
name, placed next to the existing `If.old_multi_spk` block — which exists for
exactly this class of older-kernel components-string difference.

The cleaner long-term fix is kernel-side: have `sof_sdw` emit `spk:tas2783` in
the components string. That needs a third patch and a `snd_soc_sof_sdw` rebuild.
Since stock `alsa-ucm-conf` ships no `tas2783.conf` regardless, the UCM files in
`../ucm/` are required either way.

## Differences from the CachyOS build

* **Arch's kernel is GCC-built.** The original Makefile forces `LLVM=1` for
  CachyOS's clang kernel; that must not be set here or the modules will not load.
* Sources are fetched at **v7.1.9**. The `soundwire-intel` and `snd-soc-sdca`
  object lists are identical between 7.1.9 and 7.2.2, and Arch's config matches
  CachyOS on `SND_SOC_SDCA_HID/IRQ/FDL` (all `=y`).
* The `/etc/modprobe.d/` debug and knob confs are **not** installed —
  experiments 0027/0028 established the DMI quirk alone is the whole fix.

## Omarchy's kernel (linux-omarchy)

The directory is named for where it started; the same scripts build for
`linux-omarchy` (verified on 7.2.5-3-omarchy), with one difference that matters.

**linux-omarchy is not the plain stable tag.** Its PKGBUILD applies about 90
patches, and `0510-sound-updates.patch` alone rewrites enough of SDCA that plain
v7.2.5 `sdca_functions.c` does not compile against `linux-omarchy-headers`
(`sdca_parse_function()` has a different signature). On an `-omarchy` kernel
`fetch-src.sh` therefore finds the `omacom/omarchy-pkgs` commit that built the
running `pkgver-pkgrel`, downloads that commit's patches, and applies whatever
they do to the files being built before applying ours. It needs `jq` and
network access to GitHub. Check: the sources it produces for `soundwire-intel`
and `snd-soc-sdca` are byte-identical to the ones the installed modules were
built from, and the rebuilt modules have the same `srcversion`.

Kernel headers there come from `linux-omarchy-headers`, not `linux-headers`
(`01-prereqs.sh` installs the latter).

On this kernel a third module is built as well: `snd-soc-tas2783-sdw` with the
`../resume/` series, which stops every resume from suspend freezing for 10–13 s
while the kernel waits for the amplifiers. It is independent of the speaker fix
and is skipped on kernels it does not apply to (including 7.1.9). See
`../resume/README.md` — built, not yet resume-tested.

## Usage

```sh
sudo ./01-prereqs.sh          # linux-headers matching the running kernel
./fetch-src.sh                # kernel sources (+ distro patches) + our patches
make                          # build the modules (GCC, no LLVM=1)
sudo ./02-install.sh          # fw symlinks + module overrides + UCM
sudo reboot
sudo ./04-fix-ucm-spk-tag.sh  # UCM speaker-codec compat block
systemctl --user restart wireplumber pipewire pipewire-pulse
./03-verify.sh                # ten-point check, plus resume timing
```

Rollback: `sudo ./99-uninstall.sh` (also reverts the `04` change), then reboot.

`02-install.sh` refuses to install if `modinfo -n` does not resolve to
`/updates/` after `depmod` — that is the failure mode that would otherwise
silently leave you booting stock modules.

## Result

```
soundwire sdw-master-0-1: ACTMCTL quirk: doais 0x3 -> 0x1, doaise2 0x0 -> 0x1
soundwire sdw-master-0-2: ACTMCTL quirk: doais 0x3 -> 0x1, doaise2 0x0 -> 0x1
slave-tas2783 sdw:0:1:0102:0000:01:a: Found Smart Amp function at index 0
slave-tas2783 sdw:0:1:0102:0000:01:d: Found Smart Amp function at index 0
slave-tas2783 sdw:0:2:0102:0000:01:9: Found Smart Amp function at index 0
slave-tas2783 sdw:0:2:0102:0000:01:c: Found Smart Amp function at index 0
```

All five slaves `Attached`, 0 parity errors, `HiFi` profile active and
available, default sink `alsa_output.…sof_sdw.HiFi__Speaker__sink`.
