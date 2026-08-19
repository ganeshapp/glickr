#!/usr/bin/env python3
"""Refinements of the lens-g mark, plus one refined photo-stack alternative."""
import math
import os

INK = "#1B1017"
ROSE = "#E28FA0"
PERI = "#A9A8C8"
CHAMP = "#E3CBA6"
CREAM = "#F8EEEA"

OUT = "brand/concepts"
C = 512.0


def pol(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def f(x):
    return f"{x:.2f}"


def svg(body, bg=INK, size=1024):
    rect = f'<rect width="{size}" height="{size}" fill="{bg}"/>' if bg else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
        f'width="{size}" height="{size}">\n{rect}\n{body}\n</svg>\n'
    )


def iris(cx, cy, r_open, r_outer, blade, opening=INK, skew=26, gap=3.5,
         glint=None):
    """A six-blade shutter around a hexagonal opening.

    Blades are filled wedges, not strokes: a stroked aperture degrades into a
    plain ring below roughly 64px. The skew between each blade's inner and
    outer edge is what makes it read as a shutter caught mid-rotation instead
    of a pie chart.
    """
    parts = []
    for k in range(6):
        a0 = -90 + 60 * k
        a1 = a0 + 60
        v0 = pol(cx, cy, r_open, a0)
        v1 = pol(cx, cy, r_open, a1)
        o0 = pol(cx, cy, r_outer, a0 + skew + gap)
        o1 = pol(cx, cy, r_outer, a1 + skew - gap)
        fill = blade[k % len(blade)] if isinstance(blade, tuple) else blade
        parts.append(
            f'<path fill="{fill}" d="'
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
        # A single specular arc. One highlight is the difference between "a
        # circle with shapes in it" and "a piece of glass".
        gr = (r_open + r_outer) / 2
        p0 = pol(cx, cy, gr, 168)
        p1 = pol(cx, cy, gr, 214)
        parts.append(
            f'<path fill="none" stroke="{glint}" stroke-width="14" '
            f'stroke-linecap="round" opacity="0.55" d="'
            f'M {f(p0[0])},{f(p0[1])} A {f(gr)},{f(gr)} 0 0,0 '
            f'{f(p1[0])},{f(p1[1])}"/>'
        )
    return "\n".join(parts)


def lens_g(bowl_r=250, stroke=84, r_open=86, blade=PERI, ring=ROSE,
           glint=CREAM, descender=True):
    """Single-storey lowercase g whose bowl is a camera lens.

    glickr is always set lowercase, so the g is already brand furniture.
    Making its bowl an aperture means the letterform and the subject are one
    shape - which is the move that separates a mark from a clip-art pairing.
    Drawn as geometry, never as type, so rendering does not depend on a font
    being installed on whoever's machine builds the icons.
    """
    bx, by = C - 26, C - 74
    mid = bowl_r - stroke / 2          # centreline radius of the bowl ring
    inner = bowl_r - stroke            # inner edge of the ring

    parts = [
        f'<circle cx="{f(bx)}" cy="{f(by)}" r="{f(mid)}" fill="none" '
        f'stroke="{ring}" stroke-width="{f(stroke)}"/>'
    ]

    if descender:
        # Stem down the bowl's right flank, then a descender that hooks left
        # and stops with a cut terminal. A round cap trailing into space is
        # what made the first pass look unfinished.
        x = bx + mid
        parts.append(
            f'<path fill="none" stroke="{ring}" stroke-width="{f(stroke)}" '
            f'stroke-linecap="round" stroke-linejoin="round" d="'
            f'M {f(x)},{f(by)} L {f(x)},{f(by + 268)} '
            f'C {f(x)},{f(by + 392)} {f(bx - 66)},{f(by + 412)} '
            f'{f(bx - 176)},{f(by + 334)}"/>'
        )

    parts.append(iris(bx, by, r_open, inner - 22, blade, glint=glint))
    return "\n".join(parts)


def stack_branch():
    """Photo cards fanned like a history, threaded by a branch."""
    w, h, rx = 384, 306, 46
    parts = []
    for dx, dy, fill, rot in [
        (-104, 80, CHAMP, -13),
        (-46, 30, PERI, -6.5),
        (26, -28, ROSE, 0),
    ]:
        x, y = C - w / 2 + dx, C - h / 2 + dy
        parts.append(
            f'<g transform="rotate({rot} {f(x + w / 2)} {f(y + h / 2)})">'
            f'<rect x="{f(x)}" y="{f(y)}" width="{w}" height="{h}" rx="{rx}" '
            f'fill="{fill}"/></g>'
        )
    parts.append(
        f'<path fill="none" stroke="{INK}" stroke-width="38" '
        f'stroke-linecap="round" stroke-linejoin="round" d="'
        f'M {f(C - 132)},{f(C + 142)} L {f(C - 132)},{f(C - 22)} '
        f'C {f(C - 132)},{f(C - 108)} {f(C - 40)},{f(C - 108)} '
        f'{f(C + 42)},{f(C - 108)}"/>'
    )
    for cx, cy in [(C - 132, C + 142), (C + 42, C - 108)]:
        parts.append(f'<circle cx="{f(cx)}" cy="{f(cy)}" r="48" fill="{INK}"/>')
    return "\n".join(parts)


VARIANTS = {
    # The favourite: rose g, periwinkle shutter, dark opening.
    "g1_peri": lens_g(),
    # Warmer: champagne shutter reads more "vintage lens".
    "g2_champ": lens_g(blade=CHAMP),
    # Two-tone shutter - the flickr pink/blue pairing living inside the lens.
    "g3_twotone": lens_g(blade=(PERI, CHAMP)),
    # Cream g for a mono/inverse lockup.
    "g4_cream": lens_g(ring=CREAM, blade=ROSE, glint=None),
    # No descender: a pure lens, in case the g reads as too literal.
    "g5_nodesc": lens_g(descender=False),
    "d2_stack": stack_branch(),
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, body in VARIANTS.items():
        with open(f"{OUT}/{name}.svg", "w") as fh:
            fh.write(svg(body))
        print(f"{OUT}/{name}.svg")
