#!/usr/bin/env python3
"""Turn Open Iconic's PNGs into the 32-bit TGAs Ka0s Mythic Meters draws its header controls from.

Adapted from ../PanelMaster/tools/artwork/artwork_cleaner.py, which does the right KIND of work
and the wrong amount of it: that tool exists for full-panel backdrops and letterboxes onto a
1024x1024 canvas, which would swallow a 64px glyph. What survives from it is the pipeline's shape
and two stages that matter at any size; what goes is the upscaler and the background keying.

    icon_cleaner.py --fetch      download the sources into tools/artwork/.cache/ (needs `gh`)
    icon_cleaner.py --build      convert the cache into media/textures/icons/*.tga
    icon_cleaner.py              both, in that order

WHY THIS TOOL EXISTS AT ALL, rather than a checked-in binary somebody once made:

    The provenance question is the whole point. An icon in a repo with no record of where it came
    from cannot be relicensed, cannot be regenerated at a different size, and cannot be replaced
    when it turns out to be wrong. This file IS the record -- the upstream repo, the licence, the
    exact file names and every transformation applied, in the one place that cannot drift from the
    art because it is what produces it.

WHAT IT DOES TO EACH ICON, in order:

    recolour   black -> white, alpha untouched
    solidify   push opaque colour outward under the transparent pixels
    fit        centre on a square power-of-two canvas, never crop
    normalize  force every fully-transparent pixel to (0,0,0,0)
    save       32-bit RLE TGA

Requires Pillow and numpy. No network beyond `gh api`, and no upscaler.
"""

import argparse
import base64
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))
CACHE = os.path.join(HERE, ".cache")
OUT = os.path.join(ROOT, "media", "textures", "icons")

# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------
#
# Open Iconic, MIT, 223 marks designed to stay legible down to 8px -- which is the property that
# matters here, because these are drawn at 18.
#
# CHOSEN BECAUSE IT SHIPS RASTER. Every other set considered (Feather, Lucide, Tabler, Bootstrap,
# Phosphor, Font Awesome) ships SVG only, and this machine has no rasteriser: no ImageMagick, no
# Inkscape, no rsvg, no cairosvg. A set that needs converting before it can be converted is not a
# set we can use.
REPO = "iconic/open-iconic"

# THE SIZE SUFFIX IS NOT THE PIXEL COUNT. The base icon is 8px, so `-8x` is the 64px render, not a
# 8px one. Getting this wrong is a 404 rather than a wrong-sized icon, which is at least loud.
SUFFIX = "-8x"

# What each control draws. The KEY is this addon's name for the control, so a later decision to
# swap which upstream glyph a control uses is one line here and nothing else anywhere.
GLYPHS = {
    "close":     "x",
    "minimise":  "minus",
    "expand":    "plus",
    "lock":      "lock-locked",
    "unlock":    "lock-unlocked",
    "settings":  "cog",
    "segment":   "menu",
    "reset":     "reload",
    "export":    "data-transfer-download",
    "sort-up":   "caret-top",
    "sort-down": "caret-bottom",
}

LICENSE_SRC = "ICON-LICENSE"
LICENSE_DST = "LICENSE-open-iconic.txt"

# ---------------------------------------------------------------------------
# The output
# ---------------------------------------------------------------------------

# Power of two, because WoW cannot wrap a non-power-of-two texture. 64 is the source's own size, so
# nothing is resampled in the common case -- and it leaves room to draw at 18 with the client
# downscaling, which looks better than upscaling a 16px source would.
SIZE = 64

# What a fully-transparent pixel's RGB becomes. Black, so an additive or alpha-keyed blend cannot
# find a colour hiding under a pixel nothing was supposed to draw.
TRANSPARENT = (0, 0, 0, 0)

# How far to push opaque colour outward under the transparent region. Three is plenty at this size;
# the stage exists for the downscale, not for an upscaler.
SOLIDIFY_ITERS = 3


def _say(text):
    print(text, flush=True)


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

def _gh_file(path):
    """One file out of the repo, through `gh api`.

    NOT raw.githubusercontent.com, which times out from here often enough to be useless in a
    script. The contents API returns base64 in a JSON envelope and `gh` carries the auth, so it
    is both faster and not rate-limited into uselessness.
    """
    out = subprocess.run(
        ["gh", "api", "repos/%s/contents/%s" % (REPO, path)],
        capture_output=True, text=True, timeout=120,
    )
    if out.returncode != 0:
        raise RuntimeError("gh api failed for %s: %s" % (path, out.stderr.strip()[:200]))
    return base64.b64decode(json.loads(out.stdout)["content"])


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    for name, upstream in sorted(GLYPHS.items()):
        dst = os.path.join(CACHE, "%s.png" % upstream)
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            _say("  cached  %s (%s)" % (upstream, name))
            continue
        data = _gh_file("png/%s%s.png" % (upstream, SUFFIX))
        with open(dst, "wb") as fh:
            fh.write(data)
        _say("  fetched %s (%s) %d bytes" % (upstream, name, len(data)))

    lic = os.path.join(CACHE, LICENSE_DST)
    if not os.path.exists(lic):
        with open(lic, "wb") as fh:
            fh.write(_gh_file(LICENSE_SRC))
        _say("  fetched %s" % LICENSE_DST)


# ---------------------------------------------------------------------------
# Convert
# ---------------------------------------------------------------------------

def recolour_white(im):
    """Black art -> white art, alpha untouched.

    THE STAGE THAT DECIDES WHETHER THE ICONS OBEY THE PLAYER'S COLOUR SETTING. Every glyph the
    header draws today is tinted at draw time to the header's text colour, and a texture is tinted
    by MULTIPLYING -- so a white source becomes any colour asked for and a black one stays black
    whatever it is asked for. Open Iconic ships black.

    Only the RGB is touched. The antialiased edge lives entirely in the alpha channel, so writing
    a flat white under it preserves the shape exactly.
    """
    a = np.asarray(im.convert("RGBA")).copy()
    a[..., :3] = 255
    return Image.fromarray(a, "RGBA")


def _box_sum(arr):
    """Sum of each pixel's 3x3 neighbourhood, edges clamped."""
    p = np.pad(arr, ((1, 1), (1, 1), (0, 0)), mode="edge")
    return (p[:-2, :-2] + p[:-2, 1:-1] + p[:-2, 2:] +
            p[1:-1, :-2] + p[1:-1, 1:-1] + p[1:-1, 2:] +
            p[2:, :-2] + p[2:, 1:-1] + p[2:, 2:])


def solidify(im, iters=SOLIDIFY_ITERS):
    """Edge-extend opaque RGB outward into the transparent region.

    Kept from PanelMaster's tool, and kept for the same reason stated there: nothing renders the
    RGB under a transparent pixel, so nothing complains when it is arbitrary -- until a resample
    samples it. The client downscales these from 64 to 18, and its kernel reads the neighbours of
    every edge pixel including the transparent ones.

    After `recolour_white` the under-alpha RGB is already white, so this is close to a no-op today.
    It stays because the invariant it protects is "whatever is under the alpha continues the art",
    and that stops being free the moment a coloured icon is added.
    """
    a = np.asarray(im.convert("RGBA"), dtype=np.float32)
    rgb, alpha = a[..., :3], a[..., 3]
    known = (alpha > 0).astype(np.float32)[..., None]
    cur = rgb * known
    for _ in range(iters):
        if known.min() >= 1.0:
            break
        num, den = _box_sum(cur), _box_sum(known)
        newly = ((den > 0) & (known == 0))
        cur = np.where(newly, num / np.maximum(den, 1e-6), cur)
        known = ((newly | (known > 0)).astype(np.float32))
    out = np.concatenate([np.clip(cur, 0, 255), alpha[..., None]], axis=2)
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def fit_square(im, size=SIZE):
    """Centre on a square power-of-two canvas. Never crop.

    A source already at `size` passes through untouched, which is the case every glyph currently
    takes -- the branch exists so a differently-sized replacement does not silently get cropped.
    """
    if im.size == (size, size):
        return im
    scale = min(size / im.width, size / im.height)
    w, h = max(1, round(im.width * scale)), max(1, round(im.height * scale))
    art = im.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), TRANSPARENT)
    canvas.paste(art, ((size - w) // 2, (size - h) // 2), art)
    return canvas


def normalize_transparent(im):
    """Force every fully-transparent pixel to one defined RGB.

    Must run LAST. LANCZOS premultiplies and a paste carries its canvas colour in, so normalising
    any earlier is simply undone by the next stage.
    """
    a = np.asarray(im.convert("RGBA")).copy()
    a[a[..., 3] == 0] = TRANSPARENT
    return Image.fromarray(a, "RGBA")


def convert_one(src, dst):
    im = Image.open(src)
    im = im.convert("RGBA") if im.mode != "RGBA" else im.copy()
    im = normalize_transparent(fit_square(solidify(recolour_white(im))))
    # RLE, matching media/textures/Default.tga -- the texture this client is already known to load.
    im.save(dst, compression="tga_rle")
    return im.size


def build():
    os.makedirs(OUT, exist_ok=True)
    missing = []
    for name, upstream in sorted(GLYPHS.items()):
        src = os.path.join(CACHE, "%s.png" % upstream)
        if not os.path.exists(src):
            missing.append(upstream)
            continue
        dst = os.path.join(OUT, "%s.tga" % name)
        size = convert_one(src, dst)
        _say("  %-10s <- %-24s %dx%d  %d bytes"
             % (name, upstream, size[0], size[1], os.path.getsize(dst)))

    lic = os.path.join(CACHE, LICENSE_DST)
    if os.path.exists(lic):
        with open(lic, "rb") as fh:
            body = fh.read()
        with open(os.path.join(OUT, LICENSE_DST), "wb") as fh:
            fh.write(body)
        _say("  %s" % LICENSE_DST)

    if missing:
        _say("\nmissing sources (run --fetch): %s" % ", ".join(missing))
        return 1
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fetch", action="store_true", help="download sources into the cache")
    ap.add_argument("--build", action="store_true", help="convert the cache into TGAs")
    args = ap.parse_args(argv)

    both = not (args.fetch or args.build)
    if args.fetch or both:
        _say("fetching from %s ..." % REPO)
        fetch()
    if args.build or both:
        _say("building into media/textures/icons/ ...")
        return build()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
