#!/usr/bin/env python3
"""Render the lens-g mark and a swatch strip in several candidate palettes.

The point of the exercise: a photo app's chrome should get out of the way of
the photographs. Heavily tinted surfaces fight the content - which is why
Lightroom, VSCO, Apple Photos and Flickr itself all sit on near-neutral greys.
Every option here therefore keeps surfaces neutral and spends its colour on a
single accent pair.
"""
import math
import os

OUT = "brand/palettes"
C = 512.0


def pol(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def f(x):
    return f"{x:.2f}"


PALETTES = {
    # Flickr's own pink and blue, desaturated just enough not to buzz, on a
    # neutral near-black. Most on-concept: the two dots are the brand.
    "p1_darkroom": {
        "label": "Darkroom",
        "ink": "#131417",
        "surface2": "#1C1E22",
        "primary": "#FF3D77",
        "secondary": "#3D8BFF",
        "accent": "#E8EAF0",
        "cream": "#F2F3F7",
        "light_bg": "#FFFFFF",
        "light_surface": "#F4F5F8",
        "light_primary": "#D01B57",
    },
    # Greyscale plus one blue. The most "professional photo tool" of the set -
    # nothing competes with an image.
    "p2_ink": {
        "label": "Ink",
        "ink": "#0E0F11",
        "surface2": "#191B1F",
        "primary": "#4C8DFF",
        "secondary": "#8E9AAE",
        "accent": "#E6E9EF",
        "cream": "#F0F2F6",
        "light_bg": "#FFFFFF",
        "light_surface": "#F3F4F7",
        "light_primary": "#1F63D6",
    },
    # Warm neutral with amber. Warmth without the maroon cast.
    "p3_amber": {
        "label": "Amber",
        "ink": "#14151A",
        "surface2": "#1E2027",
        "primary": "#FFB454",
        "secondary": "#6FB3C9",
        "accent": "#EDE8E1",
        "cream": "#F5F2ED",
        "light_bg": "#FFFDFA",
        "light_surface": "#F4F1EB",
        "light_primary": "#A66600",
    },
    # Near-black with a cool mint/teal. Clean and modern, reads "utility".
    "p4_mint": {
        "label": "Mint",
        "ink": "#101314",
        "surface2": "#1A1E20",
        "primary": "#3FD9A4",
        "secondary": "#7FA6FF",
        "accent": "#E4EBE9",
        "cream": "#EFF4F2",
        "light_bg": "#FFFFFF",
        "light_surface": "#F1F5F3",
        "light_primary": "#00795A",
    },
}


def iris(cx, cy, r_open, r_outer, blades, opening, glint=None,
         skew=26, gap=3.5):
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


def mark(p, bg=None, ring=None, blades=None):
    bowl_r, stroke, r_open = 250, 84, 86
    bx, by = C - 26, C - 74
    mid = bowl_r - stroke / 2
    inner = bowl_r - stroke
    ring = ring or p["primary"]
    blades = blades or (p["secondary"], p["accent"])
    x = bx + mid
    body = [
        f'<circle cx="{f(bx)}" cy="{f(by)}" r="{f(mid)}" fill="none" '
        f'stroke="{ring}" stroke-width="{f(stroke)}"/>',
        f'<path fill="none" stroke="{ring}" stroke-width="{f(stroke)}" '
        f'stroke-linecap="round" stroke-linejoin="round" d="'
        f'M {f(x)},{f(by)} L {f(x)},{f(by + 268)} '
        f'C {f(x)},{f(by + 392)} {f(bx - 66)},{f(by + 412)} '
        f'{f(bx - 176)},{f(by + 334)}"/>',
        iris(bx, by, r_open, inner - 22, blades, bg or p["ink"],
             glint=p["cream"]),
    ]
    rect = f'<rect width="1024" height="1024" fill="{bg or p["ink"]}"/>'
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        f'width="1024" height="1024">\n{rect}\n' + "\n".join(body) + "\n</svg>\n"
    )


def swatches(p):
    """A strip showing what the app's surfaces and accents actually look like."""
    order = [
        ("surface", p["ink"]),
        ("card", p["surface2"]),
        ("primary", p["primary"]),
        ("secondary", p["secondary"]),
        ("text", p["cream"]),
        ("light bg", p["light_bg"]),
        ("light card", p["light_surface"]),
        ("light primary", p["light_primary"]),
    ]
    w, h = 1024, 200
    cw = w / len(order)
    parts = [f'<rect width="{w}" height="{h}" fill="{p["ink"]}"/>']
    for i, (_, colour) in enumerate(order):
        parts.append(
            f'<rect x="{f(i * cw)}" y="0" width="{f(cw)}" height="{h}" '
            f'fill="{colour}"/>'
        )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'width="{w}" height="{h}">\n' + "\n".join(parts) + "\n</svg>\n"
    )


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for key, p in PALETTES.items():
        with open(f"{OUT}/{key}_dark.svg", "w") as fh:
            fh.write(mark(p))
        with open(f"{OUT}/{key}_light.svg", "w") as fh:
            fh.write(mark(p, bg=p["light_bg"], ring=p["light_primary"]))
        with open(f"{OUT}/{key}_swatch.svg", "w") as fh:
            fh.write(swatches(p))
        print(key, p["label"])
