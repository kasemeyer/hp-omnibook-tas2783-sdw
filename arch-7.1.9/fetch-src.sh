#!/bin/bash
# Populate build-sdw-intel/, build-sdca/ and build-tas2783/ with kernel sources
# from git.kernel.org and apply the two upstream patches and the resume series.
# Idempotent: re-run to start over.
#   ./fetch-src.sh [kernel-tag]      (default: the running kernel)
#
# linux-omarchy is NOT the plain stable tag. Its PKGBUILD applies ~90 patches,
# and the sound ones change all three modules and the in-tree headers they are
# built against (plain v7.2.5 sdca sources do not even compile against
# linux-omarchy-headers 7.2.5-3). On an -omarchy kernel the package's own
# patches are therefore layered on first, taken from the omarchy-pkgs commit
# that built the running kernel. That step needs jq.
set -euo pipefail
KREL=$(uname -r)
# 7.1.9-arch1-2 -> v7.1.9, 7.2.5-3-omarchy -> v7.2.5
TAG=${1:-v$(echo "$KREL" | sed -E 's/-(arch[0-9-]*|[0-9]+-omarchy)$//')}
A=$(dirname "$(readlink -f "$0")")
R=$(dirname "$A")
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain"

DISTRO=()   # the distro kernel's own patches, in the order its PKGBUILD applies them
if [[ $KREL == *-omarchy ]]; then
  PKGS=omacom/omarchy-pkgs
  P=pkgbuilds/linux-omarchy
  RAW="https://raw.githubusercontent.com/$PKGS"
  want=${KREL%-omarchy}
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  # newest packaging commit whose PKGBUILD is this pkgver-pkgrel
  sha=
  for s in $(curl -sfL "https://api.github.com/repos/$PKGS/commits?path=$P/PKGBUILD&per_page=100" | jq -r '.[].sha'); do
    curl -sfL -o "$TMP/PKGBUILD" "$RAW/$s/$P/PKGBUILD" || continue
    v=$(awk -F= '/^pkgver=/{v=$2} /^pkgrel=/{r=$2} END{print v"-"r}' "$TMP/PKGBUILD")
    if [ "$v" = "$want" ]; then sha=$s; break; fi
  done
  [ -n "$sha" ] || { echo "no $PKGS commit builds linux-omarchy $want"; exit 1; }
  echo "linux-omarchy $want is $PKGS@${sha:0:12}; fetching its patches"
  for p in $(grep -oE '^ *[0-9]{4}-[A-Za-z0-9._-]+\.patch' "$TMP/PKGBUILD" | tr -d ' '); do
    curl -sfL -o "$TMP/$p" "$RAW/$sha/$P/$p" || { echo "fetch failed: $p"; exit 1; }
    DISTRO+=("$TMP/$p")
  done
fi

# populate <dir> <kernel subdir> <strip> <file>...
# Fetch the files at $TAG into build-<dir>, then apply whatever the distro
# patches do to exactly those files. <strip> turns a/<kernel subdir>/<file>
# into <file>.
populate() {
  local name=$1 sub=$2 strip=$3 f p
  shift 3
  mkdir -p "$A/$name"
  cd "$A/$name"
  rm -f ./*.c ./*.h
  for f in "$@"; do
    curl -sfL -o "$f" "$BASE/$sub/$f?h=$TAG" || { echo "fetch failed: $f"; exit 1; }
  done
  for p in "${DISTRO[@]}"; do
    awk -v pre="a/$sub/" -v want=" $* " '
      /^diff --git / {
        keep = 0
        if (index($3, pre) == 1) {
          f = substr($3, length(pre) + 1)
          keep = index(want, " " f " ") > 0
        }
      }
      keep' "$p" > "$TMP/part.patch"
    [ -s "$TMP/part.patch" ] || continue
    patch -Np"$strip" --fuzz=0 -s < "$TMP/part.patch" \
      || { echo "distro patch does not apply in $name: $(basename "$p")"; exit 1; }
  done
}

echo "fetching sources at $TAG"

populate build-sdw-intel drivers/soundwire 3 \
  intel.c intel_ace2x.c intel_ace2x_debugfs.c intel_auxdevice.c \
  intel_init.c dmi-quirks.c intel_bus_common.c \
  intel.h intel_auxdevice.h bus.h cadence_master.h
patch -p3 -s < "$R"/upstream/0002-soundwire-intel-*.patch

populate build-sdca sound/soc/sdca 4 \
  sdca_asoc.c sdca_device.c sdca_fdl.c sdca_function_device.c \
  sdca_function_device.h sdca_functions.c sdca_hid.c \
  sdca_interrupts.c sdca_jack.c sdca_regmap.c sdca_ump.c
patch -p4 -s < "$R"/upstream/0001-ASoC-SDCA-*.patch

populate build-tas2783 sound/soc/codecs 4 tas2783-sdw.c tas2783.h
# The resume series is cut against linux-omarchy 7.2.5-3, whose tas2783 driver
# already has upstream b627da430357 (drop stale regcache on re-attach), and is
# not safe without it: see resume/README.md. On a tree that lacks that commit
# the module is left out and `make` skips it.
if grep -q regcache_drop_region tas2783-sdw.c; then
  for p in "$R"/resume/0*.patch; do
    patch -p4 -s < "$p" || { echo "resume patch does not apply at $TAG: $(basename "$p")"; exit 1; }
  done
else
  echo "tas2783 at $TAG lacks b627da430357: not building the resume override"
  rm -f ./*.c ./*.h
fi

echo "sources at $TAG populated and patched; now: make"
