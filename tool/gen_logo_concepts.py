#!/usr/bin/env python3
"""Generate glickr logo concepts as SVG.

Geometry is computed rather than hand-written, because every one of these
shapes is an interlocking construction (aperture blades against a hexagonal
opening, a letterform bowl against a lens) where a hand-tweaked coordinate
tears the shape at the seams.

Run:  python3 tool/gen_logo_concepts.py && ./tool/raster_concepts.sh
"""
import math
import os

INK = "#1B1017"        # surface / darkroom plum
ROSE = "#E28FA0"       # primary
PERI = "#A9A8C8"       # secondary
CHAMP = "#E3CBA6"      # tertiary
CREAM = "#F8EEEA"      # onSurface

OUT = "brand/concepts"
C = 512.0              # canvas centre on a 1024 grid


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


# --------------------------------------------------------------------------
# A - "Iris". A six-blade aperture whose opening is a hexagon.
#
# The camera reference is the loud one; the hexagon is a git object id, and the
# alternating blade colours are flickr's two dots rotated into a shutter.
# Blades are FILLED wedges rather than strokes - a stroked aperture collapses
# into a plain ring below about 64px, which is what killed the earlier attempt.
# The angular skew between a blade's inner and outer edge is what makes it read
# as a shutter mid-rotation rather than a pie chart.
# --------------------------------------------------------------------------
def concept_iris(r_open=176, r_out=430, ring=52, skew=26, gap=3.0,
                 colors=(ROSE, PERI), hex_fill=None):
    r_in = r_out - ring
    parts = []

    # Outer ring, drawn as an even-odd annulus so it stays a single path.
    parts.append(
        f'<path fill-rule="evenodd" fill="{ROSE}" d="'
        f'M {f(C - r_out)},{f(C)} a {f(r_out)},{f(r_out)} 0 1,0 {f(2 * r_out)},0 '
        f'a {f(r_out)},{f(r_out)} 0 1,0 {f(-2 * r_out)},0 Z '
        f'M {f(C - r_in)},{f(C)} a {f(r_in)},{f(r_in)} 0 1,0 {f(2 * r_in)},0 '
        f'a {f(r_in)},{f(r_in)} 0 1,0 {f(-2 * r_in)},0 Z"/>'
    )

    # Six blades. Inner edge = one edge of the hexagonal opening; outer edge =
    # an arc on the inner ring, rotated by `skew` to create the swirl.
    for k in range(6):
        a0 = -90 + 60 * k
        a1 = a0 + 60
        v0 = pol(C, C, r_open, a0)
        v1 = pol(C, C, r_open, a1)
        o0 = pol(C, C, r_in, a0 + skew + gap)
        o1 = pol(C, C, r_in, a1 + skew - gap)
        parts.append(
            f'<path fill="{colors[k % len(colors)]}" d="'
            f'M {f(v0[0])},{f(v0[1])} L {f(v1[0])},{f(v1[1])} '
            f'L {f(o1[0])},{f(o1[1])} '
            f'A {f(r_in)},{f(r_in)} 0 0,0 {f(o0[0])},{f(o0[1])} Z"/>'
        )

    if hex_fill:
        pts = " ".join(
            f"{f(x)},{f(y)}"
            for x, y in (pol(C, C, r_open, -90 + 60 * k) for k in range(6))
        )
        parts.append(f'<polygon points="{pts}" fill="{hex_fill}"/>')
    return "\n".join(parts)


# --------------------------------------------------------------------------
# B - "Commit". flickr's two overlapping dots ARE two commits on a branch.
#
# The only concept where a single shape is honestly both parents at once: read
# it as two translucent dots and it is flickr, read it as nodes on a line with
# a branch and it is git. Risk is the stroke weight at small sizes, so the
# spine is deliberately heavy.
# --------------------------------------------------------------------------
def concept_commit(r=132, spine=46, node_r=62):
    top = (C - 96, C - 150)
    bot = (C - 96, C + 150)
    branch_end = (C + 168, C - 26)
    parts = [
        # spine
        f'<path stroke="{CHAMP}" stroke-width="{spine}" stroke-linecap="round" '
        f'fill="none" d="M {f(top[0])},{f(top[1])} L {f(bot[0])},{f(bot[1])}"/>',
        # branch out to the right, then up
        f'<path stroke="{CHAMP}" stroke-width="{spine}" stroke-linecap="round" '
        f'stroke-linejoin="round" fill="none" d="'
        f'M {f(top[0])},{f(C + 40)} '
        f'C {f(top[0] + 150)},{f(C + 40)} {f(branch_end[0])},{f(C + 40)} '
        f'{f(branch_end[0])},{f(branch_end[1] + 70)} '
        f'L {f(branch_end[0])},{f(branch_end[1])}"/>',
        # the two big flickr dots, overlapping, sitting ON the spine
        f'<circle cx="{f(top[0])}" cy="{f(top[1])}" r="{f(r)}" fill="{ROSE}"/>',
        f'<circle cx="{f(bot[0])}" cy="{f(bot[1])}" r="{f(r)}" fill="{PERI}" '
        f'fill-opacity="0.92"/>',
        # branch tip node
        f'<circle cx="{f(branch_end[0])}" cy="{f(branch_end[1])}" '
        f'r="{f(node_r)}" fill="{CHAMP}"/>',
    ]
    return "\n".join(parts)


# --------------------------------------------------------------------------
# C - "Lens g". The lowercase g of the wordmark, with a lens for a bowl.
#
# glickr is always set lowercase, so the g is already brand furniture; making
# its bowl an aperture means the letterform and the object are the same shape.
# Bold enough to survive as a silhouette at 48px, and nobody else owns it.
# Drawn as geometry, not type, so it does not depend on a font being installed.
# --------------------------------------------------------------------------
def concept_lens_g(bowl_r=232, stroke=76, r_open=92):
    bx, by = C - 34, C - 60          # bowl centre
    inner = bowl_r - stroke / 2
    parts = [
        # bowl: a thick ring
        f'<circle cx="{f(bx)}" cy="{f(by)}" r="{f(bowl_r - stroke / 2)}" '
        f'fill="none" stroke="{ROSE}" stroke-width="{f(stroke)}"/>',
        # stem down the right side, then the descender curling left
        f'<path fill="none" stroke="{ROSE}" stroke-width="{f(stroke)}" '
        f'stroke-linecap="round" d="'
        f'M {f(bx + bowl_r - stroke / 2)},{f(by)} '
        f'L {f(bx + bowl_r - stroke / 2)},{f(by + 250)} '
        f'C {f(bx + bowl_r - stroke / 2)},{f(by + 372)} '
        f'{f(bx - 60)},{f(by + 392)} {f(bx - 150)},{f(by + 330)}"/>',
    ]
    # aperture inside the bowl: three-blade pinwheel around a hex opening
    for k in range(6):
        a0 = -90 + 60 * k
        a1 = a0 + 60
        v0 = pol(bx, by, r_open, a0)
        v1 = pol(bx, by, r_open, a1)
        rr = inner - 26
        o0 = pol(bx, by, rr, a0 + 24 + 3)
        o1 = pol(bx, by, rr, a1 + 24 - 3)
        parts.append(
            f'<path fill="{PERI if k % 2 else CHAMP}" d="'
            f'M {f(v0[0])},{f(v0[1])} L {f(v1[0])},{f(v1[1])} '
            f'L {f(o1[0])},{f(o1[1])} '
            f'A {f(rr)},{f(rr)} 0 0,0 {f(o0[0])},{f(o0[1])} Z"/>'
        )
    return "\n".join(parts)


# --------------------------------------------------------------------------
# D - "Stack". Photo cards fanned like a commit history, threaded by a branch.
#
# Says "successive versions of a set of photos" more literally than the others.
# The weakness is that a fanned stack is a crowded silhouette at icon sizes.
# --------------------------------------------------------------------------
def concept_stack(w=372, h=300, rx=44):
    parts = []
    for i, (dx, dy, fill, rot) in enumerate(
        [(-96, 74, CHAMP, -12), (-40, 26, PERI, -6), (24, -26, ROSE, 0)]
    ):
        x, y = C - w / 2 + dx, C - h / 2 + dy
        parts.append(
            f'<g transform="rotate({rot} {f(x + w / 2)} {f(y + h / 2)})">'
            f'<rect x="{f(x)}" y="{f(y)}" width="{w}" height="{h}" rx="{rx}" '
            f'fill="{fill}"/></g>'
        )
    # branch threading the stack
    parts.append(
        f'<path fill="none" stroke="{INK}" stroke-width="34" '
        f'stroke-linecap="round" stroke-linejoin="round" d="'
        f'M {f(C - 150)},{f(C + 150)} L {f(C - 150)},{f(C - 40)} '
        f'C {f(C - 150)},{f(C - 120)} {f(C - 60)},{f(C - 120)} '
        f'{f(C + 10)},{f(C - 120)}"/>'
    )
    for cx, cy in [(C - 150, C + 150), (C + 10, C - 120)]:
        parts.append(
            f'<circle cx="{f(cx)}" cy="{f(cy)}" r="46" fill="{INK}"/>'
        )
    return "\n".join(parts)


CONCEPTS = {
    "a_iris": concept_iris(),
    "a_iris_mono": concept_iris(colors=(ROSE, ROSE)),
    "a_iris_hex": concept_iris(hex_fill=CREAM),
    "b_commit": concept_commit(),
    "c_lens_g": concept_lens_g(),
    "d_stack": concept_stack(),
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, body in CONCEPTS.items():
        with open(f"{OUT}/{name}.svg", "w") as fh:
            fh.write(svg(body))
        print(f"{OUT}/{name}.svg")
