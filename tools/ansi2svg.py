#!/usr/bin/env python3
"""Render a recorded NanoTax session into the README's SVGs.

    script -qfc "nanotax -y 8" session.typescript
    python3 tools/ansi2svg.py loader    session.typescript docs/assets/loader.svg
    python3 tools/ansi2svg.py dashboard session.typescript docs/assets/dashboard.svg
    python3 tools/ansi2svg.py verdict   session.typescript docs/assets/verdict.svg

`loader` is the banner + inventory screen, `verdict` the last screen, and
`dashboard` an animated SVG that cycles one frame per phase (pure CSS, so it
plays inside a GitHub README). Needs `rich` (pip install rich).
"""

import re
import sys

from rich.console import Console
from rich.text import Text

WIDTH = 92
FRAME_SECONDS = 2.2
CLEAR = re.compile(r"\x1b\[H\x1b\[(?:2)?J(?:\x1b\[3J)?")
NON_SGR = re.compile(r"\x1b\[[0-9;?]*[A-Za-ln-z]|\x1b\][^\x07]*\x07|\r")


def screens(raw):
    """Split a typescript into the screens NanoTax painted, oldest first."""
    raw = re.sub(r"^Script started.*\n", "", raw)
    raw = re.sub(r"\nScript done.*$", "", raw, flags=re.S)
    parts = [p for p in CLEAR.split(raw) if p.strip()]
    return [NON_SGR.sub("", p).rstrip("\n") + "\n" for p in parts]


def svg_of(ansi, title):
    console = Console(record=True, width=WIDTH, force_terminal=True, color_system="256",
                      file=open("/dev/null", "w"))
    console.print(Text.from_ansi(ansi), end="")
    return console.export_svg(title=title)


def strip_header(svg):
    return re.sub(r"^<\?xml[^>]*>\s*", "", svg)


def size_of(svg):
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg)
    return float(m.group(1)), float(m.group(2))


def animate(frames, title):
    svgs = [strip_header(svg_of(f, title)) for f in frames]
    w = max(size_of(s)[0] for s in svgs)
    h = max(size_of(s)[1] for s in svgs)
    n = len(svgs)
    period = n * FRAME_SECONDS
    show = 100.0 / n
    groups = "\n".join(
        f'<g class="nt-f" style="animation-delay:{i * FRAME_SECONDS:.2f}s">{s}</g>'
        for i, s in enumerate(svgs))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.0f} {h:.0f}" width="{w:.0f}" height="{h:.0f}">
<style>
.nt-f {{ opacity: 0; animation: nt-cycle {period:.2f}s step-end infinite; }}
@keyframes nt-cycle {{ 0% {{ opacity: 1; }} {show:.3f}% {{ opacity: 0; }} 100% {{ opacity: 0; }} }}
</style>
{groups}
</svg>
"""


def main():
    mode, src, dst = sys.argv[1:4]
    shots = screens(open(src, encoding="utf-8", errors="replace").read())
    if mode == "loader":
        # the banner and the inventory are one screen, painted before "Press enter"
        first = shots[0].split("Taxing for")[0].rstrip() + "\n"
        out = svg_of(first, "nanotax --loader")
    elif mode == "verdict":
        out = svg_of(shots[-1], "nanotax · verdict")
    elif mode == "dashboard":
        # a frame ~70% into each phase: the meters have settled and the
        # storm workers (timed to the phase) are still running
        by_phase = {}
        for s in shots:
            m = re.search(r"PHASE (\d)", s)
            if m and s.count("core") >= 4 and "HAILO" in s:
                by_phase.setdefault(m.group(1), []).append(s)
        picks = [v[int(len(v) * 0.7)] for _, v in sorted(by_phase.items())]
        out = animate(picks, "nanotax")
    else:
        sys.exit(f"unknown mode {mode}")
    open(dst, "w", encoding="utf-8").write(out)
    print(f"{dst}: {len(out) // 1024} KB")


if __name__ == "__main__":
    main()
