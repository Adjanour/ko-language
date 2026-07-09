#!/usr/bin/env bash
# Regenerate PNGs from SVGs in this directory.
# Requires: rsvg-convert (librsvg)

set -euo pipefail

cd "$(dirname "$0")"

for svg in *.svg; do
    png="${svg%.svg}.png"
    echo "Rendering $svg -> $png"
    rsvg-convert "$svg" -o "$png"
done

echo "Done."
