#!/usr/bin/env python3
"""Generate glickr's brand SVGs.

The mark is a single-storey lowercase `g` whose bowl is a camera shutter.
glickr is always set lowercase, so the `g` is already brand furniture; making
its bowl an aperture means the letterform and the subject are one shape rather
than two pieces of clip art placed next to each other. The hexagonal opening is
the git nod - an object id - and it is the only GitHub reference in the mark,
deliberately: the Octocat is a registered trademark and GitHub's brand policy
forbids using it in another product's logo.

Everything is computed geometry. Nothing depends on a font being installed, so
the icons rasterise identically on any machine.

Run:  python3 tool/gen_brand.py && ./tool/raster_brand.sh
"""
import math
import os

# Matches lib/core/theme/app_theme.dart. Keep in sync.
INK = "#0E0F11"        # dark surface
PRIMARY = "#4C8DFF"    # dark primary
SECONDARY = "#8E9AAE"  # dark secondary
LIGHT_BLADE = "#E6E9EF"
CREAM = "#F0F2F6"      # onSurface

OUT = "brand"
C = 512.0

# Bowl geometry. Held here rather than inline because the stem, the descender
# and the shutter are all positioned off these three numbers.
BOWL_R, STROKE, R_OPEN = 250.0, 84.0, 86.0
BX, BY = C - 26, C - 74

# Adaptive-icon safe zone: the launcher may crop everything outside the central
# 66dp of a 108dp canvas, i.e. a radius of 1024*66/108/2 = 312.9px. The mark's
# bounding radius at full size is ~424px, so 0.72 leaves real margin.
FG_SCALE = 0.72


def pol(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def f(x):
    return f"{x:.2f}"


def shutter(cx, cy, r_open, r_outer, blades, opening, glint=None,
            skew=26.0, gap=3.5):
    """Six blades around a hexagonal opening.

    Blades are FILLED wedges, not strokes. A stroked aperture degrades into a
    plain ring below about 64px, which is exactly the size that matters most.
    The angular skew between a blade's inner and outer edge is what makes it
    read as a shutter caught mid-rotation instead of a pie chart.
    """
    parts = []
    for k in range(6):
        a0 = -90 + 60 * k
        a1 = a0 + 60
        v0 = pol(cx, cy, r_open, a0)
        v1 = pol(cx, cy, r_open, a1)
        o0 = pol(cx, cy, r_outer, a0 + skew + gap)
        o1 = pol(cx, cy, r_outer, a1 + skew - gap)
        parts.append(
            f'<path fill="{blades[k % len(blades)]}" d="'
            f'M {f(v0[0])},{f(v0[1])} L {f(v1[0])},{f(v1[1])} '
            f'L {f(o1[0])},{f(o1[1])} '
            f'A {f(r_outer)},{f(r_outer)} 0 0,0 {f(o0[0])},{f(o0[1])} Z"/>'
        )
    pts = " ".join(
        f"{f(x)},{f(y)}"
        for x, y in (pol(cx, cy, r_open, -90 + 60 * k) for k in range(6))
    )
    parts.append(f'<polygon points="{pts}" fill="{opening}"/>')
    if glint:
        # One specular arc. A single highlight is the difference between
        # "a circle with shapes in it" and "a piece of glass".
        gr = (r_open + r_outer) / 2
        p0 = pol(cx, cy, gr, 168)
        p1 = pol(cx, cy, gr, 214)
        parts.append(
            f'<path fill="none" stroke="{glint}" stroke-width="14" '
            f'stroke-linecap="round" opacity="0.5" d="'
            f'M {f(p0[0])},{f(p0[1])} A {f(gr)},{f(gr)} 0 0,0 '
            f'{f(p1[0])},{f(p1[1])}"/>'
        )
    return "\n".join(parts)


def letter_g(ring, blades, opening, glint):
    mid = BOWL_R - STROKE / 2
    x = BX + mid
    return "\n".join([
        f'<circle cx="{f(BX)}" cy="{f(BY)}" r="{f(mid)}" fill="none" '
        f'stroke="{ring}" stroke-width="{f(STROKE)}"/>',
        # Stem down the bowl's right flank, then a descender hooking left to a
        # cut terminal. A round cap trailing into empty space reads unfinished.
        f'<path fill="none" stroke="{ring}" stroke-width="{f(STROKE)}" '
        f'stroke-linecap="round" stroke-linejoin="round" d="'
        f'M {f(x)},{f(BY)} L {f(x)},{f(BY + 268)} '
        f'C {f(x)},{f(BY + 392)} {f(BX - 66)},{f(BY + 412)} '
        f'{f(BX - 176)},{f(BY + 334)}"/>',
        shutter(BX, BY, R_OPEN, BOWL_R - STROKE - 22, blades, opening,
                glint=glint),
    ])


def doc(body, bg=None, defs=""):
    rect = f'<rect width="1024" height="1024" fill="{bg}"/>' if bg else ""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        f'width="1024" height="1024">\n{defs}{rect}\n{body}\n</svg>\n'
    )


def scaled(body, scale):
    return (
        f'<g transform="translate({f(C)},{f(C)}) scale({scale}) '
        f'translate({f(-C)},{f(-C)})">\n{body}\n</g>'
    )


FULL = letter_g(PRIMARY, (SECONDARY, LIGHT_BLADE), INK, CREAM)

# The in-app mark needs a transparent shutter opening so it sits on the login
# screen's gradient instead of stamping a flat INK hexagon onto it.
MASK = (
    '<defs>\n'
    '  <mask id="lens" maskUnits="userSpaceOnUse" x="0" y="0" '
    'width="1024" height="1024">\n'
    '    <rect width="1024" height="1024" fill="#FFFFFF"/>\n'
    f'    <polygon points="'
    + " ".join(
        f"{f(x)},{f(y)}"
        for x, y in (pol(BX, BY, R_OPEN, -90 + 60 * k) for k in range(6))
    )
    + '" fill="#000000"/>\n'
    '  </mask>\n'
    '</defs>\n'
)

FILES = {
    # Full-bleed launcher icon.
    "glickr_icon.svg": doc(FULL, bg=INK),
    # Adaptive foreground: transparent, inset into the safe zone. The
    # background layer is the flat colour INK, declared in pubspec.yaml rather
    # than shipped as a 1024px PNG of one colour.
    "glickr_foreground.svg": doc(scaled(FULL, FG_SCALE)),
    # In-app mark on a transparent ground, opening punched through.
    "glickr_mark.svg": doc(
        f'<g mask="url(#lens)">\n'
        + letter_g(PRIMARY, (SECONDARY, LIGHT_BLADE), INK, CREAM)
        + "\n</g>",
        defs=MASK,
    ),
}

# Android 13+ themed icon: recoloured wholesale, so only the ALPHA channel is
# read. The shutter opening must therefore be genuinely transparent - painting
# it black would leave it opaque and the lens would fill in.
MONO_MASK = (
    '<defs>\n'
    '  <mask id="mono" maskUnits="userSpaceOnUse" x="0" y="0" '
    'width="1024" height="1024">\n'
    '    <rect width="1024" height="1024" fill="#000000"/>\n'
    f'    {scaled(letter_g("#FFFFFF", ("#FFFFFF", "#FFFFFF"), "#000000", None), FG_SCALE)}\n'
    '  </mask>\n'
    '</defs>\n'
)
FILES["glickr_monochrome.svg"] = doc(
    '<rect width="1024" height="1024" fill="#FFFFFF" mask="url(#mono)"/>',
    defs=MONO_MASK,
)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, body in FILES.items():
        with open(os.path.join(OUT, name), "w") as fh:
            fh.write(body)
        print(f"{OUT}/{name}")
