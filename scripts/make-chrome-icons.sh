#!/bin/sh
# make-chrome-icons.sh - derive the install's hicolor set from the white
# master, with the light-background outline.
#
# Licence: AGPLv3 (njuggle).
#
# Provenance: ~/development/docs/projects/njuggle/njuggle_white_large.png
# (1254x1254 RGBA, white on transparent) is the master and lives in the docs
# repo. This script writes images/njuggle/{32,64,128,256,512}.png, which are
# the install step's hicolor set and the gresource's chrome_icons.
#
# Why the outline: the master is white on transparent. On a dark panel that
# reads; on a light menu it washes out to a faint grey, which is what the
# owner's build-5 acceptance reported. A dark 1px-at-64px rim drawn under the
# silhouette fixes the light case and is invisible against dark, so one file
# serves both backgrounds - no second asset, no theme branching.
#
# Sizes are cut from the outlined 1254px master, so every size is a resample
# of one image and they cannot drift apart.
#
# usage (from the repo root):
#   sh scripts/make-chrome-icons.sh <master.png>
set -eu

MASTER="${1:-$HOME/development/docs/projects/njuggle/njuggle_white_large.png}"
OUT="images/njuggle"
# Rim thickness in MASTER pixels. The master is 1254px wide; 12 master
# pixels is ~1px at 64 and ~0.3px at 32, which is where the rim stays a
# crisp keyline instead of a halo.
RIM=12
# Rim colour. Deliberately the artwork's own dark grey, not black: a black
# rim reads as a sticker on light backgrounds.
RIM_COLOUR="#2b2b2b"

[ -f "$MASTER" ] || { echo "no such master: $MASTER" >&2; exit 2; }

# A cut-out cannot be made from an image with no alpha channel.
[ "$(convert "$MASTER" -format '%A' info:)" = "Blend" ] || {
    echo "master must have an alpha channel (got: $(convert "$MASTER" -format '%A' info:))" >&2
    exit 2
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. Silhouette: everything the master draws.
convert "$MASTER" -alpha extract -threshold 50% "$TMP/mask.png"

# 2. Rim: the ring between the mask and itself dilated by RIM.
convert "$TMP/mask.png" -morphology Dilate "Diamond:$RIM" "$TMP/dilated.png"
convert "$TMP/dilated.png" "$TMP/mask.png" -compose Difference -composite "$TMP/ring.png"

# 3. Rim in the artwork's grey, fully opaque where the ring is.
convert -size "$(identify -format '%wx%h' "$MASTER")" "xc:$RIM_COLOUR" \
    "$TMP/ring.png" -compose CopyOpacity -composite "$TMP/rim.png"

# 4. Rim under the artwork.
convert "$TMP/rim.png" "$MASTER" -compose Over -composite "$TMP/outlined.png"

mkdir -p "$OUT"
for s in 512 256 128 64 32; do
    convert "$TMP/outlined.png" -resize "${s}x${s}" -strip "$OUT/$s.png"
    printf '%s %sx%s %s\n' "$s" "$s" "$s" "$(sha256sum "$OUT/$s.png" | cut -d' ' -f1)"
done
