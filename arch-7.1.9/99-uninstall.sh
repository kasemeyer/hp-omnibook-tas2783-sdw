#!/bin/bash
# Full rollback of 02-install.sh. Reboot afterwards.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
KVER=$(uname -r)
U=/usr/share/alsa/ucm2
rm -fv /lib/modules/"$KVER"/updates/soundwire-intel.ko /lib/modules/"$KVER"/updates/snd-soc-sdca.ko \
       /lib/modules/"$KVER"/updates/snd-soc-tas2783-sdw.ko
rm -fv /usr/lib/firmware/8EB4-1-A.bin.zst /usr/lib/firmware/8EB4-1-D.bin.zst \
       /usr/lib/firmware/8EB4-2-9.bin.zst /usr/lib/firmware/8EB4-2-C.bin.zst
rm -fv "$U/sof-soundwire/tas2783.conf" "$U/codecs/tas2783/init.conf"
[ -f "$U/sof-soundwire/sof-soundwire.conf.orig-pre-tas2783" ] && \
  mv -v "$U/sof-soundwire/sof-soundwire.conf.orig-pre-tas2783" "$U/sof-soundwire/sof-soundwire.conf"
depmod -a "$KVER"
echo "Rolled back. Reboot to return to stock."
