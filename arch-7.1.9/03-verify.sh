#!/bin/bash
# Post-reboot verification. No sudo needed.  arch-7.1.9/03-verify.sh
echo "=== kernel ==="; uname -r
echo
echo "=== 1. overrides loaded from /updates/? ==="
printf '  soundwire_intel : %s\n' "$(modinfo -n soundwire_intel)"
printf '  snd_soc_sdca    : %s\n' "$(modinfo -n snd_soc_sdca)"
printf '  snd_soc_tas2783_sdw : %s  (resume override; stock path if not built)\n' "$(modinfo -n snd_soc_tas2783_sdw)"
echo
echo "=== 2. did the ACTMCTL quirk fire? (expect 2 lines, links 1 and 2) ==="
journalctl -k -b --no-pager | grep -i 'ACTMCTL quirk' || echo "  !! quirk did NOT fire"
echo
echo "=== 3. SoundWire slave status (expect 5x Attached) ==="
for f in /sys/bus/soundwire/devices/sdw:*/status; do
  printf '  %-46s %s\n' "$(basename $(dirname $f))" "$(cat $f)"
done
echo
echo "=== 4. firmware load (expect no 'failed', 4 amps) ==="
journalctl -k -b --no-pager | grep -i 'tas2783' | tail -10 || echo "  (no tas2783 messages)"
echo
echo "=== 5. SDCA function accepted? (expect SmartAmp, NOT 'DisCo constant') ==="
journalctl -k -b --no-pager | grep -iE 'SDCA function|DisCo constant' | tail -10
echo
echo "=== 6. parity errors (expect 0) ==="
echo "  count: $(journalctl -k -b --no-pager | grep -ci parity)"
echo
echo "=== 7. speaker PCM present? ==="
aplay -l 2>/dev/null | grep -i 'card 0'
echo
echo "=== 8. mixer controls (UCM needs these names) ==="
amixer -c 0 controls 2>/dev/null | grep -i 'spk' || echo "  no Spk controls"
echo
echo "=== 9. PipeWire sink (expect a real sink, NOT auto_null) ==="
pactl list short sinks 2>/dev/null
echo
echo "=== 10. card profile ==="
pactl list cards 2>/dev/null | grep -A2 -iE 'Active Profile' | head -10
echo
echo "=== 11. resume (run after at least one suspend/resume this boot) ==="
echo "  with the override: one 're-initialised N ms' line per amp and resume,"
echo "  no 'failed to resume', and a kernel resume time of about a second"
journalctl -k -b --no-pager -o cat | grep -E 'tas2783.*(failed to resume|re-initialised)' | tail -8
journalctl -k -b --no-pager -o json \
  | jq -r 'select(.MESSAGE|type=="string") | select(.MESSAGE|test("EC: interrupt unblocked|Restarting tasks: Done")) | "\((._SOURCE_MONOTONIC_TIMESTAMP|tonumber)/1e6) \(.MESSAGE)"' 2>/dev/null \
  | awk '/EC: interrupt unblocked/ {t = $1; next} t > 10 {printf "  kernel resume took %.1f s\n", $1 - t; t = 0}' | tail -4
