#!/bin/bash
# Phase 2: install the fix. Run AFTER `make` has produced both modules.
#   sudo arch-7.1.9/02-install.sh   &&   sudo reboot
#
# Installs:
#   1. four TAS2783 firmware alias symlinks (kernel 7.1.9 asks for 8EB4-1-D.bin,
#      linux-firmware ships 8EB4-1-0xD.bin.zst) -- mirrors the 8EF6-X-9 alias
#      pattern linux-firmware already uses for other boards
#   2. patched soundwire-intel.ko (ACTMCTL DOAIS/DOAISE2 DMI quirk, patch 0002)
#   3. patched snd-soc-sdca.ko (SmartAmp function-type fallback, patch 0001)
#   4. TAS2783 UCM profile so PipeWire offers HiFi Speaker instead of pro-audio
#   5. patched snd-soc-tas2783-sdw.ko (system resume no longer waits for the
#      amplifiers, ../resume/) -- only when fetch-src.sh + make built it
#
# Rollback: sudo arch-7.1.9/99-uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

KVER=$(uname -r)
SRC=$(dirname "$(readlink -f "$0")")
FW=/usr/lib/firmware
DST=/lib/modules/$KVER/updates
U=/usr/share/alsa/ucm2
REPO=$(dirname "$SRC")

for ko in "$SRC/build-sdw-intel/soundwire-intel.ko" "$SRC/build-sdca/snd-soc-sdca.ko"; do
  [ -f "$ko" ] || { echo "ERROR: $ko not built. Run: make -C "$SRC""; exit 1; }
done

echo "== 1. firmware alias symlinks =="
for pair in "1-A:1-0xA" "1-D:1-0xD" "2-9:2-0x9" "2-C:2-0xC"; do
  want=8EB4-${pair%%:*}.bin.zst
  have=ti/audio/tas2783/8EB4-${pair##*:}.bin.zst
  [ -e "$FW/$have" ] || { echo "ERROR: missing $FW/$have (is linux-firmware-other installed?)"; exit 1; }
  ln -sfn "$have" "$FW/$want"
  echo "   $want -> $have"
done

echo "== 2/3. module overrides =="
install -d "$DST"
install -m644 "$SRC/build-sdw-intel/soundwire-intel.ko" "$DST/soundwire-intel.ko"
install -m644 "$SRC/build-sdca/snd-soc-sdca.ko"        "$DST/snd-soc-sdca.ko"
depmod -a "$KVER"
echo "   soundwire_intel -> $(modinfo -n soundwire_intel)"
echo "   snd_soc_sdca    -> $(modinfo -n snd_soc_sdca)"
modinfo -n soundwire_intel | grep -q '/updates/' || { echo "ERROR: override not taking precedence"; exit 1; }
modinfo -n snd_soc_sdca    | grep -q '/updates/' || { echo "ERROR: override not taking precedence"; exit 1; }

echo "== 5. resume override =="
TAS="$SRC/build-tas2783/snd-soc-tas2783-sdw.ko"
if [ -f "$TAS" ]; then
  install -m644 "$TAS" "$DST/snd-soc-tas2783-sdw.ko"
  depmod -a "$KVER"
  echo "   snd_soc_tas2783_sdw -> $(modinfo -n snd_soc_tas2783_sdw)"
  modinfo -n snd_soc_tas2783_sdw | grep -q '/updates/' || { echo "ERROR: override not taking precedence"; exit 1; }
else
  # a stale override from another build must not outlive the modules it matched
  rm -fv "$DST/snd-soc-tas2783-sdw.ko"
  depmod -a "$KVER"
  echo "   not built for this kernel; stock snd_soc_tas2783_sdw stays"
fi

echo "== 4. UCM profile =="
install -Dm644 "$REPO/ucm/sof-soundwire/tas2783.conf" "$U/sof-soundwire/tas2783.conf"
install -Dm644 "$REPO/ucm/codecs/tas2783/init.conf"   "$U/codecs/tas2783/init.conf"
if ! grep -q '|tas2783|' "$U/sof-soundwire/sof-soundwire.conf"; then
  cp -n "$U/sof-soundwire/sof-soundwire.conf" "$U/sof-soundwire/sof-soundwire.conf.orig-pre-tas2783"
  sed -i 's/(${var:MultiCodecRegex}|rt1318|/(${var:MultiCodecRegex}|tas2783|rt1318|/' "$U/sof-soundwire/sof-soundwire.conf"
fi
grep -q '|tas2783|' "$U/sof-soundwire/sof-soundwire.conf" && echo "   sof-soundwire.conf now matches tas2783"

echo
echo "Installed. Reboot now:  sudo reboot"
