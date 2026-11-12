#!/usr/bin/env python3
"""Turn a raw PRAG demo recording into a polished clip.

    render.py <scene.mov> <scene.json> <out-basename> [--gif-width 880] [--fps 30]

- Aligns t=0 to the magenta sync flash the demo director emits.
- Replays the director's camera keyframes as an eased zoom/follow (Screen Studio style).
- Places the footage in a rounded window with a soft shadow on a gradient backdrop.
- Writes <out>.mp4 (H.264) and <out>.gif (gifski).

Requires: ffmpeg, gifski, Pillow, numpy.
"""
import argparse, json, math, os, shutil, subprocess, sys, tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Output geometry
OUT_W, OUT_H = 1600, 960          # canvas
PAD_X, PAD_TOP = 72, 64           # window placement on canvas
WIN_W = OUT_W - 2 * PAD_X         # 1456
WIN_H = round(WIN_W * 9 / 16)     # 819
RADIUS = 22
BASE_VIEW_PT = 1200               # points visible across at zoom 1


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height", "-of", "csv=p=0", path]).decode()
    w, h = map(int, out.strip().split(",")[:2])
    return w, h


def find_sync(path, fps=60):
    """Time (s) of the first frame after the magenta flash."""
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={fps},scale=16:10",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    n, seen, frame_bytes = 0, False, 16 * 10 * 3
    while True:
        buf = proc.stdout.read(frame_bytes)
        if len(buf) < frame_bytes:
            break
        a = np.frombuffer(buf, np.uint8).reshape(-1, 3).mean(axis=0)
        magenta = a[0] > 200 and a[1] < 70 and a[2] > 200
        if magenta:
            seen = True
        elif seen:
            proc.kill()
            return n / fps
        n += 1
    proc.kill()
    raise SystemExit("sync flash not found")


def ease(u):
    u = max(0.0, min(1.0, u))
    return 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


class Camera:
    """Piecewise eased camera: each keyframe starts a transition from wherever we are."""

    def __init__(self, keys):
        self.segments = []
        cur = None
        for k in keys:
            if "end" in k:
                continue
            target = (k["x"], k["y"], k["z"])
            if cur is None:
                cur = target
                self.segments.append((k["t"], target, target, 0.0))
                continue
            start_val = self.value(k["t"])
            self.segments.append((k["t"], start_val, target, max(k["d"], 1e-3)))

    def value(self, t):
        if not self.segments:
            return (756.0, 300.0, 1.0)
        val = self.segments[0][1]
        for (ts, frm, to, d) in self.segments:
            if t < ts:
                break
            u = ease((t - ts) / d) if d > 0 else 1.0
            val = tuple(frm[i] + (to[i] - frm[i]) * u for i in range(3))
        return val


def make_backdrop():
    # Deep graphite → midnight gradient with a faint top glow.
    y = np.linspace(0, 1, OUT_H)[:, None]
    x = np.linspace(0, 1, OUT_W)[None, :]
    top = np.array([24, 26, 38], float)
    bot = np.array([8, 9, 14], float)
    base = top * (1 - y[..., None]) + bot * y[..., None]
    glow = np.exp(-(((x - 0.5) / 0.35) ** 2 + ((y - 0.0) / 0.45) ** 2))[..., None] * np.array([60, 70, 120], float) * 0.35
    img = np.clip(base + glow, 0, 255).astype(np.uint8)
    canvas = Image.fromarray(img)
    # Soft shadow under the window.
    shadow = Image.new("L", (OUT_W, OUT_H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([PAD_X, PAD_TOP + 14, PAD_X + WIN_W, PAD_TOP + WIN_H + 14], RADIUS, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), shadow)
    mask = Image.new("L", (WIN_W, WIN_H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, WIN_W - 1, WIN_H - 1], RADIUS, fill=255)
    rim = Image.new("L", (WIN_W, WIN_H), 0)
    ImageDraw.Draw(rim).rounded_rectangle([0, 0, WIN_W - 1, WIN_H - 1], RADIUS, outline=60, width=2)
    return canvas, mask, rim


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mov"); ap.add_argument("log"); ap.add_argument("out")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--gif-width", type=int, default=1000)
    ap.add_argument("--gif-fps", type=int, default=24)
    ap.add_argument("--gif-quality", type=int, default=82)
    ap.add_argument("--tail", type=float, default=0.3)
    a = ap.parse_args()

    log = json.load(open(a.log))
    scale = log["display"]["scale"]
    disp_w, disp_h = log["display"]["w"], log["display"]["h"]
    cam = Camera(log["camera"])
    end_t = max(k["t"] for k in log["camera"]) + a.tail

    src_w, src_h = probe(a.mov)
    t0 = find_sync(a.mov)
    frames = int(end_t * a.fps)
    print(f"sync at {t0:.3f}s, rendering {end_t:.2f}s ({frames} frames)")

    backdrop, mask, rim = make_backdrop()
    dec = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{t0:.4f}", "-i", a.mov, "-t", f"{end_t:.3f}",
                            "-vf", f"fps={a.fps}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{OUT_W}x{OUT_H}", "-r", str(a.fps), "-i", "-",
                            "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
                            "-movflags", "+faststart", a.out + ".mp4"], stdin=subprocess.PIPE)
    fb = src_w * src_h * 3
    px = src_w / disp_w                       # pixels per point in the recording
    for i in range(frames):
        buf = dec.stdout.read(fb)
        if len(buf) < fb:
            break
        frame = Image.frombuffer("RGB", (src_w, src_h), buf, "raw", "RGB", 0, 1)
        cx, cy, z = cam.value(i / a.fps)
        vw = BASE_VIEW_PT / z * px
        vh = vw * 9 / 16
        x0 = min(max(cx * px - vw / 2, 0), src_w - vw)
        y0 = min(max(cy * px - vh / 2, 0), src_h - vh)
        view = frame.resize((WIN_W, WIN_H), Image.Resampling.LANCZOS, box=(x0, y0, x0 + vw, y0 + vh))
        canvas = backdrop.copy()
        canvas.paste(view, (PAD_X, PAD_TOP), mask)
        canvas.paste(Image.new("RGB", (WIN_W, WIN_H), (255, 255, 255)), (PAD_X, PAD_TOP), rim)
        enc.stdin.write(canvas.tobytes())
    enc.stdin.close(); enc.wait(); dec.kill()

    # GIF via gifski for the README.
    tmp = tempfile.mkdtemp()
    subprocess.check_call(["ffmpeg", "-v", "error", "-i", a.out + ".mp4",
                           "-vf", f"fps={a.gif_fps},scale={a.gif_width}:-1:flags=lanczos",
                           os.path.join(tmp, "f%04d.png")])
    pngs = sorted(os.path.join(tmp, f) for f in os.listdir(tmp))
    subprocess.check_call(["gifski", "--quiet", "--fps", str(a.gif_fps), "--quality", str(a.gif_quality),
                           "--width", str(a.gif_width), "-o", a.out + ".gif"] + pngs)
    shutil.rmtree(tmp)
    for ext in ("mp4", "gif"):
        print(f"{a.out}.{ext}: {os.path.getsize(a.out + '.' + ext) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
