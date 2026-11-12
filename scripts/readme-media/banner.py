#!/usr/bin/env python3
"""Generates docs/media/banner.svg — an animated (SMIL) README banner.

The notch silhouette uses the same curve as Sources/PRAG/UI/NotchShape.swift, so the
banner morphs exactly like the app: notch → shelf with tiles → back into the notch.
"""
import os

W, H = 1200, 430
CX = W / 2
CYCLE = 7.0  # seconds


def notch_path(body_w, body_h, ear, bottom):
    """Same command structure for every state so SMIL can morph between them."""
    w = body_w + 2 * ear
    x0 = CX - w / 2
    e, b, h = ear, bottom, body_h
    p = lambda x, y: f"{x0 + x:.2f},{y:.2f}"
    return (f"M{p(0, 0)} Q{p(e, 0)} {p(e, e)} L{p(e, h - b)} "
            f"C{p(e, h - b * 0.45)} {p(e + b * 0.45, h)} {p(e + b, h)} "
            f"L{p(w - e - b, h)} C{p(w - e - b * 0.45, h)} {p(w - e, h - b * 0.45)} {p(w - e, h - b)} "
            f"L{p(w - e, e)} Q{p(w - e, 0)} {p(w, 0)} Z")


COLLAPSED = notch_path(200, 32, 6, 11)
EXPANDED = notch_path(640, 200, 18, 30)

# Timeline (seconds): hold notch → open → hold → close → hold notch
T_OPEN, T_OPENED, T_CLOSE, T_CLOSED = 0.7, 1.25, 5.4, 5.9
kt = lambda *ts: ";".join(f"{t / CYCLE:.4f}" for t in ts)
SHAPE_TIMES = kt(0, T_OPEN, T_OPENED, T_CLOSE, T_CLOSED, CYCLE)
SHAPE_SPLINES = "0 0 1 1;0.22 0.9 0.32 1;0 0 1 1;0.45 0 0.2 1;0 0 1 1"


def morph(attr="d"):
    return (f'<animate attributeName="{attr}" dur="{CYCLE}s" repeatCount="indefinite" calcMode="spline" '
            f'keyTimes="{SHAPE_TIMES}" keySplines="{SHAPE_SPLINES}" '
            f'values="{COLLAPSED};{COLLAPSED};{EXPANDED};{EXPANDED};{COLLAPSED};{COLLAPSED}"/>')


def fade(t_in, t_out, dur_in=0.3, dur_out=0.15):
    """Opacity 0 → 1 at t_in, 1 → 0 at t_out."""
    times = [0, t_in, t_in + dur_in, t_out, t_out + dur_out, CYCLE]
    return (f'<animate attributeName="opacity" dur="{CYCLE}s" repeatCount="indefinite" '
            f'keyTimes="{kt(*times)}" values="0;0;1;1;0;0"/>')


def rise(t_in, dy=10, dur=0.35):
    times = [0, t_in, t_in + dur, CYCLE]
    return (f'<animateTransform attributeName="transform" type="translate" dur="{CYCLE}s" repeatCount="indefinite" '
            f'calcMode="spline" keyTimes="{kt(*times)}" keySplines="0 0 1 1;0.2 0.9 0.3 1;0 0 1 1" '
            f'values="0 {dy};0 {dy};0 0;0 0"/>')


FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Inter, Helvetica, Arial, sans-serif"

# Tiles inside the open shelf
tile_w, tile_h, gap = 92, 92, 26
tiles_x0 = CX - (4 * tile_w + 3 * gap) / 2
tile_y = 78
tile_fills = ["url(#t1)", "url(#t2)", "url(#t3)", "url(#t4)"]
tile_names = ["Sunset Ridge.jpg", "Brand Mockup.png", "IMG_4821.HEIC", "Pitch Deck.pdf"]

tiles = []
for i in range(4):
    x = tiles_x0 + i * (tile_w + gap)
    t_in = 1.35 + i * 0.12
    tiles.append(f'''
    <g opacity="0">{fade(t_in, T_CLOSE - 0.05)}
      <g>{rise(t_in)}
        <rect x="{x:.1f}" y="{tile_y}" width="{tile_w}" height="{tile_h}" rx="18" fill="{tile_fills[i]}"/>
        <rect x="{x:.1f}" y="{tile_y}" width="{tile_w}" height="{tile_h}" rx="18" fill="none" stroke="#fff" stroke-opacity=".12"/>
        <text x="{x + tile_w / 2:.1f}" y="{tile_y + tile_h + 22}" text-anchor="middle" font-family="{FONT}" font-size="12.5" font-weight="600" fill="#fff" fill-opacity=".9">{tile_names[i]}</text>
      </g>
    </g>''')

# Web Ready on tile 2: ring spins, then a green savings badge lands.
bx = tiles_x0 + 1 * (tile_w + gap) + tile_w / 2
ring_r = 15
badge = f'''
    <g opacity="0">{fade(2.05, 2.75, 0.15, 0.1)}
      <circle cx="{bx}" cy="{tile_y + tile_h / 2}" r="{ring_r + 10}" fill="#000" fill-opacity=".55"/>
      <circle cx="{bx}" cy="{tile_y + tile_h / 2}" r="{ring_r}" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3.5"/>
      <circle cx="{bx}" cy="{tile_y + tile_h / 2}" r="{ring_r}" fill="none" stroke="#0A84FF" stroke-width="3.5" stroke-linecap="round"
              stroke-dasharray="{2 * 3.1416 * ring_r:.1f}" stroke-dashoffset="{2 * 3.1416 * ring_r:.1f}" transform="rotate(-90 {bx} {tile_y + tile_h / 2})">
        <animate attributeName="stroke-dashoffset" dur="{CYCLE}s" repeatCount="indefinite"
                 keyTimes="{kt(0, 2.05, 2.7, CYCLE)}" values="{2 * 3.1416 * ring_r:.1f};{2 * 3.1416 * ring_r:.1f};0;0"/>
      </circle>
    </g>
    <g opacity="0">{fade(2.75, T_CLOSE - 0.05, 0.2)}
      <g>{rise(2.75, 6, 0.3)}
        <rect x="{bx - 34}" y="{tile_y + tile_h - 12}" width="68" height="24" rx="12" fill="#06140b" stroke="#30D158" stroke-opacity=".6"/>
        <text x="{bx}" y="{tile_y + tile_h + 4.5}" text-anchor="middle" font-family="{FONT}" font-size="12.5" font-weight="800" fill="#30D158">↓ −99%</text>
      </g>
    </g>'''

header = f'''
    <g opacity="0">{fade(1.2, T_CLOSE - 0.1, 0.25, 0.12)}
      <text x="{CX - 300}" y="25" font-family="{FONT}" font-size="14" font-weight="800" letter-spacing=".6" fill="#fff">PRAG</text>
      <text x="{CX - 252}" y="25" font-family="{FONT}" font-size="12.5" font-weight="500" fill="#fff" fill-opacity=".5">4 · 34.1 MB</text>
      <rect x="{CX + 190}" y="12" width="110" height="20" rx="10" fill="#fff" fill-opacity=".1"/>
      <text x="{CX + 245}" y="26" text-anchor="middle" font-family="{FONT}" font-size="11.5" font-weight="600" fill="#fff" fill-opacity=".75">Web Ready</text>
    </g>'''

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="PRAG — the notch becomes a drag-and-drop shelf">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#14161f"/><stop offset="1" stop-color="#07080c"/>
    </linearGradient>
    <radialGradient id="glow" cx=".5" cy="0" r=".75">
      <stop offset="0" stop-color="#5b6cff" stop-opacity=".38"/>
      <stop offset=".45" stop-color="#c2508f" stop-opacity=".12"/>
      <stop offset="1" stop-color="#000" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="shelf" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#000"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".35" stop-color="#fff" stop-opacity=".14"/>
    </linearGradient>
    <linearGradient id="t1" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6d7dff"/><stop offset=".45" stop-color="#f06a6a"/><stop offset="1" stop-color="#b9ee4a"/></linearGradient>
    <linearGradient id="t2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#d9b8ff"/><stop offset=".5" stop-color="#7b3cff"/><stop offset="1" stop-color="#8fe0c8"/></linearGradient>
    <linearGradient id="t3" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0d2233"/><stop offset=".55" stop-color="#9fd3ec"/><stop offset="1" stop-color="#173246"/></linearGradient>
    <linearGradient id="t4" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#eef0f6"/><stop offset="1" stop-color="#9aa3c4"/></linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="160%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".55"/>
    </filter>
    <clipPath id="shape"><path d="{COLLAPSED}">{morph()}</path></clipPath>
  </defs>

  <rect width="{W}" height="{H}" rx="28" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" rx="28" fill="url(#glow)"/>
  <!-- the top edge of the screen -->
  <rect x="0" y="0" width="{W}" height="1.5" fill="#fff" fill-opacity=".08"/>

  <g filter="url(#shadow)">
    <path d="{COLLAPSED}" fill="url(#shelf)">{morph()}</path>
  </g>
  <path d="{COLLAPSED}" fill="none" stroke="url(#rim)" stroke-width="1.5">{morph()}</path>
  <!-- camera -->
  <circle cx="{CX}" cy="15" r="4.5" fill="#1b1d26"/><circle cx="{CX}" cy="15" r="2" fill="#2b3a5c"/>

  <g clip-path="url(#shape)">{header}{''.join(tiles)}{badge}
  </g>

  <text x="{CX}" y="{H - 122}" text-anchor="middle" font-family="{FONT}" font-size="72" font-weight="800" letter-spacing="10" fill="#fff">PRAG</text>
  <text x="{CX}" y="{H - 80}" text-anchor="middle" font-family="{FONT}" font-size="19" font-weight="600" letter-spacing="5" fill="#fff" fill-opacity=".62">PARK  ·  RETRIEVE  ·  ACT  ·  GO</text>
  <text x="{CX}" y="{H - 44}" text-anchor="middle" font-family="{FONT}" font-size="16.5" font-weight="500" fill="#fff" fill-opacity=".42">Your MacBook notch, turned into a drag-and-drop workbench.</text>
</svg>
'''

out = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "media", "banner.svg")
with open(out, "w") as f:
    f.write(svg)
print(os.path.abspath(out), len(svg), "bytes")
