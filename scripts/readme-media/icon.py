#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns: a macOS-style squircle with the PRAG shelf growing
out of a notch, three tiles and a savings badge. Renders the SVG with headless Chrome,
then builds the iconset with sips + iconutil.

    python3 scripts/readme-media/icon.py
"""
import os, shutil, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Apple's 1024 grid: 824 pt body, 100 pt margin, continuous corner ≈ 185.
S, M, B = 1024, 100, 824
cx = S / 2


def shelf_path(x0, w, h, ear, bottom):
    e, b = ear, bottom
    p = lambda x, y: f"{x0 + x:.1f},{y:.1f}"
    top = M
    return (f"M{p(0, top)} Q{p(e, top)} {p(e, top + e)} L{p(e, top + h - b)} "
            f"C{p(e, top + h - b * .45)} {p(e + b * .45, top + h)} {p(e + b, top + h)} "
            f"L{p(w - e - b, top + h)} C{p(w - e - b * .45, top + h)} {p(w - e, top + h - b * .45)} {p(w - e, top + h - b)} "
            f"L{p(w - e, top + e)} Q{p(w - e, top)} {p(w, top)} Z")


shelf_w, shelf_h = 640, 330
shelf = shelf_path(cx - shelf_w / 2, shelf_w, shelf_h, 34, 64)

tile, gap = 150, 34
tx0 = cx - (3 * tile + 2 * gap) / 2
ty = M + 118
tiles = "".join(
    f'<rect x="{tx0 + i * (tile + gap):.1f}" y="{ty}" width="{tile}" height="{tile}" rx="36" fill="url(#t{i})"/>'
    f'<rect x="{tx0 + i * (tile + gap):.1f}" y="{ty}" width="{tile}" height="{tile}" rx="36" fill="none" stroke="#fff" stroke-opacity=".16" stroke-width="3"/>'
    for i in range(3))
bx = tx0 + 2 * (tile + gap) + tile / 2

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">
  <defs>
    <clipPath id="sq"><rect x="{M}" y="{M}" width="{B}" height="{B}" rx="185"/></clipPath>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5865f2"/><stop offset=".55" stop-color="#d4567d"/><stop offset="1" stop-color="#f29a5c"/>
    </linearGradient>
    <linearGradient id="hill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2e7a35"/><stop offset=".12" stop-color="#5fae3f"/><stop offset=".3" stop-color="#c3ec55"/>
    </linearGradient>
    <linearGradient id="t0" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7486ff"/><stop offset=".5" stop-color="#f06a6a"/><stop offset="1" stop-color="#b9ee4a"/></linearGradient>
    <linearGradient id="t1" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e2c6ff"/><stop offset=".5" stop-color="#7b3cff"/><stop offset="1" stop-color="#8fe0c8"/></linearGradient>
    <linearGradient id="t2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0f2638"/><stop offset=".55" stop-color="#a6d8ef"/><stop offset="1" stop-color="#1a3a52"/></linearGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="22" stdDeviation="26" flood-opacity=".5"/></filter>
    <filter id="outer" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-opacity=".35"/></filter>
  </defs>
  <g filter="url(#outer)">
    <g clip-path="url(#sq)">
      <rect x="{M}" y="{M}" width="{B}" height="{B}" fill="url(#bg)"/>
      <ellipse cx="{M + 150}" cy="{M + B + 170}" rx="760" ry="360" fill="url(#hill)" transform="rotate(-14 {M + 150} {M + B})"/>
      <g filter="url(#sh)"><path d="{shelf}" fill="#050506"/></g>
      <path d="{shelf}" fill="none" stroke="#fff" stroke-opacity=".12" stroke-width="3"/>
      {tiles}
      <rect x="{bx - 74}" y="{ty + tile - 26}" width="148" height="56" rx="28" fill="#04120a" stroke="#30D158" stroke-opacity=".7" stroke-width="4"/>
      <path d="M{bx - 46},{ty + tile - 2} l14,16 l14,-16 M{bx - 32},{ty + tile + 14} v-30" stroke="#30D158" stroke-width="7" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
      <rect x="{bx - 6}" y="{ty + tile - 6}" width="56" height="9" rx="4.5" fill="#30D158"/>
      <rect x="{bx - 6}" y="{ty + tile + 9}" width="40" height="9" rx="4.5" fill="#30D158" fill-opacity=".7"/>
      <rect x="{M}" y="{M}" width="{B}" height="{B / 2}" fill="url(#gloss)" opacity=".5"/>
    </g>
    <rect x="{M + 1.5}" y="{M + 1.5}" width="{B - 3}" height="{B - 3}" rx="184" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3"/>
  </g>
</svg>'''


def main():
    tmp = tempfile.mkdtemp()
    html = os.path.join(tmp, "icon.html")
    with open(html, "w") as f:
        f.write(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
    png = os.path.join(tmp, "icon_1024.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--default-background-color=00000000", f"--screenshot={png}",
                    f"--window-size={S},{S}", "file://" + html],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), png, "--out", os.path.join(iconset, name)],
                           check=True, stdout=subprocess.DEVNULL)
    os.makedirs(os.path.join(ROOT, "Resources"), exist_ok=True)
    out = os.path.join(ROOT, "Resources", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.copy(png, os.path.join(ROOT, "docs", "media", "icon.png"))
    shutil.rmtree(tmp)
    print(out)


if __name__ == "__main__":
    main()
