#!/usr/bin/env python3
"""dashboard.py — helpers for the brain-dashboard skill (python3 stdlib only).

Design: specs/2026-10-06-brain-dashboard-design.md.

  dashboard.py theme  <colour>                     print the theme CSS block
  dashboard.py render --title T --colour C [--glyph G] [--subtitle-url U] [--subtitle-text S]
                      [--owner the user] [--placeholder P] [--template F] [-o page.html]
  dashboard.py lookup   <project> [--registry F]   print the dashboard url; exit 1 if absent
  dashboard.py lookup   --all [--registry F]       print every row: project<TAB>url<TAB>colour
  dashboard.py register <project> <url> <colour> [--registry F]   idempotent upsert
  dashboard.py needs  --slugs s1 s2 ... [--docs F] [--now-ms N] (<monitor-line> | --line L)

Colours: `#rgb`, `#rrggbb` (any case) or a CSS named colour from a small set (see
NAMED). Only the input's OKLCH hue is used; near-grey input (chroma < 0.02) gives a
neutral slate theme.

Exit: 0 ok; 1 lookup found nothing; 2 usage/validation error (message on stderr);
needs: exit 3 when there are no writes (it still prints `[]`; skip the batch, since an
ArtifactData batch needs at least one write).
"""

import argparse
import datetime
import html
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEMPLATE = os.path.join(HERE, "..", "assets", "dashboard.template.html")
DEFAULT_REGISTRY = os.path.expanduser("~/Obsidian/vault/dashboards.md")


class UsageError(Exception):
    pass


# ================================================================ colour maths ====
NAMED = {
    "black": "#000000", "white": "#ffffff", "gray": "#808080", "grey": "#808080",
    "slategray": "#708090", "slategrey": "#708090", "silver": "#c0c0c0",
    "red": "#ff0000", "crimson": "#dc143c", "maroon": "#800000", "tomato": "#ff6347",
    "coral": "#ff7f50", "orange": "#ffa500", "darkorange": "#ff8c00", "gold": "#ffd700",
    "goldenrod": "#daa520", "yellow": "#ffff00", "olive": "#808000", "lime": "#00ff00",
    "green": "#008000", "forestgreen": "#228b22", "seagreen": "#2e8b57", "teal": "#008080",
    "darkcyan": "#008b8b", "cyan": "#00ffff", "aqua": "#00ffff", "turquoise": "#40e0d0",
    "steelblue": "#4682b4", "royalblue": "#4169e1", "blue": "#0000ff", "navy": "#000080",
    "indigo": "#4b0082", "slateblue": "#6a5acd", "rebeccapurple": "#663399",
    "purple": "#800080", "violet": "#ee82ee", "magenta": "#ff00ff", "fuchsia": "#ff00ff",
    "orchid": "#da70d6", "pink": "#ffc0cb", "hotpink": "#ff69b4", "deeppink": "#ff1493",
    "brown": "#a52a2a", "sienna": "#a0522d", "chocolate": "#d2691e", "tan": "#d2b48c",
}


def parse_colour(s):
    """'#rgb' | '#rrggbb' | named → (r, g, b) ints. ValueError otherwise."""
    t = (s or "").strip().lower()
    t = NAMED.get(t, t)
    m = re.fullmatch(r"#([0-9a-f]{3}|[0-9a-f]{6})", t)
    if not m:
        raise ValueError(f"not a colour: {s!r} (want #rgb, #rrggbb or a CSS colour name)")
    h = m.group(1)
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def rgb_to_oklch(rgb):
    r, g, b = (_lin(v / 255) for v in rgb)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def _oklch_to_linear(L, C, H):
    a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)


def _in_gamut(lin, eps=1e-4):
    return all(-eps <= v <= 1 + eps for v in lin)


def oklch_to_hex(L, C, H):
    """OKLCH → '#rrggbb'. Out-of-gamut colours lose chroma (hue and lightness kept)."""
    L = min(max(L, 0.0), 1.0)
    if not _in_gamut(_oklch_to_linear(L, C, H)):
        lo, hi = 0.0, C
        for _ in range(40):
            mid = (lo + hi) / 2
            if _in_gamut(_oklch_to_linear(L, mid, H)):
                lo = mid
            else:
                hi = mid
        C = lo
    lin = _oklch_to_linear(L, C, H)
    return "#" + "".join(f"{round(min(max(_gam(min(max(v, 0.0), 1.0)), 0.0), 1.0) * 255):02x}" for v in lin)


def hex_to_oklch(h):
    return rgb_to_oklch(parse_colour(h))


def luminance(h):
    r, g, b = (_lin(v / 255) for v in parse_colour(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


# ======================================================================= theme ====
STATUS = {
    "light": "--ok:#2c7748;--ok-soft:#dcefe2;--run:#2c5f9e;--run-soft:#dde8f6;"
             "--warn:#985a00;--warn-soft:#f8e7cc;--bad:#a3322b;--bad-soft:#f6dcd9",
    "dark": "--ok:#6cc28d;--ok-soft:#1c3326;--run:#7fb0ec;--run-soft:#1c2b3f;"
            "--warn:#e6a648;--warn-soft:#3a2c17;--bad:#ec8a80;--bad-soft:#3c1f1c",
}
# role → (OKLCH lightness, chroma). Neutral roles are tinted with the hue at low chroma;
# accent roles carry it. Calibrated on the hand-made teal pages (Budgebell Control).
ROLES = {
    "light": {
        "bg": (0.955, 0.006), "surface": (0.992, 0.003), "ink": (0.23, 0.018),
        "muted": (0.50, 0.024), "line": (0.88, 0.012), "accent": (0.48, 0.11),
        "accent-soft": (0.925, 0.032), "on-accent": (0.995, 0.004),
        "idle": (0.52, 0.02), "idle-soft": (0.925, 0.01),
    },
    "dark": {
        "bg": (0.20, 0.012), "surface": (0.24, 0.015), "ink": (0.93, 0.01),
        "muted": (0.70, 0.022), "line": (0.33, 0.02), "accent": (0.76, 0.12),
        "accent-soft": (0.30, 0.04), "on-accent": (0.18, 0.02),
        "idle": (0.72, 0.02), "idle-soft": (0.28, 0.014),
    },
}
ACCENT_ROLES = ("accent", "accent-soft")
GREY_CHROMA = 0.02          # input chroma below this → neutral slate
SLATE_HUE = 250.0
SLATE_ACCENT_SCALE = 0.35   # slate accent keeps a hint of colour, no more


def _palette(hue, grey, mode):
    roles = ROLES[mode]
    sign = -1 if mode == "light" else 1     # direction that moves a text colour away from bg

    def mk(role, L=None):
        l0, c = roles[role]
        if grey and role in ACCENT_ROLES:
            c *= SLATE_ACCENT_SCALE
        return oklch_to_hex(l0 if L is None else L, c, hue)

    def fit(role, against, need, step_sign):
        L = roles[role][0]
        col = mk(role, L)
        while any(contrast(col, x) < need for x in against) and 0.0 < L < 1.0:
            L += step_sign * 0.005
            col = mk(role, L)
        return col

    p = {r: mk(r) for r in roles}
    for text in ("ink", "muted"):
        p[text] = fit(text, [p["bg"], p["surface"]], 4.5, sign)
    p["accent"] = fit("accent", [p["bg"], p["surface"], p["on-accent"], p["accent-soft"]], 4.5, sign)
    p["idle"] = fit("idle", [p["idle-soft"]], 4.5, sign)   # chip text on its own soft bg
    return p


def theme_vars(colour):
    """{'light': {role: hex}, 'dark': {role: hex}} for an input colour."""
    _, C, H = rgb_to_oklch(parse_colour(colour))
    grey = C < GREY_CHROMA
    hue = SLATE_HUE if grey else H
    return {m: _palette(hue, grey, m) for m in ("light", "dark")}


ORDER = ["bg", "surface", "ink", "muted", "line", "accent", "accent-soft", "on-accent"]


def _decls(p, mode):
    own = ";".join(f"--{r}:{p[r]}" for r in ORDER)
    return f"{own};{STATUS[mode]};--idle:{p['idle']};--idle-soft:{p['idle-soft']};color-scheme:{mode}"


def theme_css(colour):
    v = theme_vars(colour)
    dark = _decls(v["dark"], "dark")
    return (":root{" + _decls(v["light"], "light") + "}\n"
            '@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){' + dark + "}}\n"
            ':root[data-theme="dark"]{' + dark + "}")


# ====================================================================== render ====
def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "dashboard"


def subtitle_html(text, url):
    if not text and not url:
        return ""
    parts = []
    if text:
        parts.append(html.escape(text))
    if url:
        if not re.fullmatch(r"https://\S+", url):
            raise UsageError(f"--subtitle-url must start with https:// (got {url!r})")
        label = url
        for pre in ("https://github.com/", "https://"):
            if label.startswith(pre):
                label = label[len(pre):]
                break
        label = label.rstrip("/") or url
        parts.append(f'<a href="{html.escape(url)}" target="_blank" rel="noopener">{html.escape(label)}</a>')
    return '<p class="sub">' + " ".join(parts) + "</p>"


def config_json(owner, title):
    raw = json.dumps({"owner": owner, "storageKey": slugify(title) + "-view", "title": title},
                     ensure_ascii=False)
    return raw.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def render(template, values):
    """Fill {{NAME}} holes in one pass; any hole without a value is an error."""
    missing = sorted({m.group(0) for m in re.finditer(r"\{\{[^{}]*\}\}", template)
                      if m.group(0)[2:-2] not in values})
    if missing:
        raise UsageError("unfilled placeholder(s) in template: " + ", ".join(missing))
    return re.sub(r"\{\{([^{}]*)\}\}", lambda m: values[m.group(1)], template)


def cmd_render(a):
    try:
        css = theme_css(a.colour)
    except ValueError as e:
        raise UsageError(str(e))
    values = {
        "TITLE": html.escape(a.title),
        "GLYPH": html.escape(a.glyph),
        "SUBTITLE_HTML": subtitle_html(a.subtitle_text, a.subtitle_url),
        "THEME_CSS": css,
        "PLACEHOLDER": html.escape(a.placeholder),
        "CONFIG_JSON": config_json(a.owner, a.title),
    }
    try:
        with open(a.template, encoding="utf-8") as f:
            tpl = f.read()
    except OSError as e:
        raise UsageError(f"cannot read template {a.template}: {e.strerror}")
    out = render(tpl, values)
    if a.output:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(out)
    else:
        sys.stdout.write(out)
    return 0


# ==================================================================== registry ====
REG_HEADER = "| project | url | colour | created |"
REG_SEP = "|---|---|---|---|"
REG_INTRO = ("# Dashboards\n\n"
             "One manager dashboard (a private claude.ai artifact) per project. Read and written "
             "only by `skills/brain-dashboard/scripts/dashboard.py lookup|register`.\n\n")


REG_COLS = ["project", "url", "colour", "created"]
SEP_CELL = re.compile(r":?-+:?")


def _cells(line):
    """Cells of a markdown table row, or None if the line is not one."""
    s = line.strip()
    if len(s) < 2 or not (s.startswith("|") and s.endswith("|")):
        return None
    return [c.strip() for c in s[1:-1].split("|")]


def _is_sep(cells):
    return cells is not None and all(SEP_CELL.fullmatch(c) for c in cells)


def find_table(lines):
    """(separator index, [(line index, cells)]) of the first table whose header (the row
    right above a `|---|` row) is exactly `project | url | colour | created`; (None, [])."""
    for i in range(1, len(lines)):
        if _is_sep(_cells(lines[i])) and _cells(lines[i - 1]) == REG_COLS:
            rows, j = [], i + 1
            while j < len(lines) and (c := _cells(lines[j])) is not None:
                if len(c) == 4:
                    rows.append((j, c))
                j += 1
            return i, rows
    return None, []


def read_registry(path):
    """(lines, separator index, rows); (None, None, None) when the file is missing."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None, None, None
    sep, rows = find_table(lines)
    return lines, sep, rows


def norm_project(name):
    project = (name or "").strip()
    if not project or re.search(r"[|\n\r]", project):
        raise UsageError(f"bad project name: {name!r}")
    return project


def cmd_lookup(a):
    if not a.all:
        if not a.project:
            raise UsageError("lookup needs a project (or --all)")
        project = norm_project(a.project)
    lines, _, rows = read_registry(a.registry)
    if lines is None:
        print(f"dashboard: no registry at {a.registry}", file=sys.stderr)
        return 1
    if a.all:
        for _, c in rows:
            print(f"{c[0]}\t{c[1]}\t{c[2]}")
        return 0
    for _, c in rows:
        if c[0] == project:
            print(c[1])
            return 0
    print(f"dashboard: no dashboard registered for {project!r} in {a.registry}", file=sys.stderr)
    return 1


def cmd_register(a):
    project = norm_project(a.project)
    if not re.fullmatch(r"https://claude\.ai/[^\s|]+", a.url):
        raise UsageError(f"url must be a https://claude.ai/... artifact link (got {a.url!r})")
    try:
        parse_colour(a.colour)
    except ValueError as e:
        raise UsageError(str(e))
    colour = a.colour.strip().lower()
    lines, sep, rows = read_registry(a.registry)
    if lines is None:
        lines = (REG_INTRO + REG_HEADER + "\n" + REG_SEP).splitlines()
        sep, rows = find_table(lines)
    elif sep is None:
        lines += ["", REG_HEADER, REG_SEP]
        sep, rows = len(lines) - 1, []
    today = datetime.date.today().isoformat()
    for i, c in rows:
        if c[0] == project:
            lines[i] = f"| {project} | {a.url} | {colour} | {c[3] or today} |"
            break
    else:
        at = rows[-1][0] + 1 if rows else sep + 1
        lines.insert(at, f"| {project} | {a.url} | {colour} | {today} |")
    os.makedirs(os.path.dirname(os.path.abspath(a.registry)), exist_ok=True)
    tmp = a.registry + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, a.registry)
    return 0


# ======================================================================= needs ====
LOWER_WAITING = {"unknown", "done", "gone", "question", "review", "blocked", "idle", "stuck"}
CAPS = {"CHECK", "COLLECT", "REVIVE", "ANSWER", "REVIEW", "UNBLOCK", "NUDGE", "INSPECT"}
DELETE = {"__delete__": True}
LINK_KEYS = ("needsYouLink", "needsYouLinkLabel")
NEEDS_KEYS = ("needsYou", "needsYouSince") + LINK_KEYS
LINE_START = re.compile(r"\d{4}-\d\d-\d\dT\S*( |$)")  # a monitor line starts with its ISO ts
SEG_RE = re.compile(r"(\S+) (\S+?)(\?)? (\d+[mh])(?: (.*))?")


def split_segments(line):
    """Split on ' · ' outside double quotes (monitor details never contain a quote)."""
    out, cur, inq, i = [], [], False, 0
    while i < len(line):
        ch = line[i]
        if ch == '"':
            inq = not inq
        if not inq and line.startswith(" · ", i):
            out.append("".join(cur))
            cur = []
            i += 3
            continue
        cur.append(ch)
        i += 1
    out.append("".join(cur))
    return out


def unquote(s):
    s = (s or "").strip()
    return s[1:-1] if len(s) >= 2 and s[0] == s[-1] == '"' else s


def monitor_prefix(slugs):
    """The common `-`-terminated prefix worker-monitor.sh strips from display names."""
    if len(slugs) < 2:
        return ""
    p = os.path.commonprefix(slugs)
    p = p[:p.rindex("-") + 1] if "-" in p else ""
    return "" if any(s == p[:-1] for s in slugs) else p


def resolve(name, label, slugs):
    if name in slugs:
        return name
    for cand in (f"{label}-{name}", monitor_prefix(slugs) + name):
        if cand in slugs:
            return cand
    hits = [s for s in slugs if s.endswith("-" + name)]
    return hits[0] if len(hits) == 1 else None


def needs_text(word, detail, dur):
    d = unquote(detail)
    if word == "ANSWER":
        return f"Has a question for you: {d}", None
    if word == "REVIEW":
        m = re.fullmatch(r"PR#(\d+)", d)
        return (f"PR #{m.group(1)} ready for review" if m else d), None
    if word == "UNBLOCK":
        return d, "blocked"
    if word == "COLLECT":
        return "Finished: collect it", "done"
    if word == "NUDGE":
        m = re.search(r'said:"(.*)"$', detail or "")
        return f"Idle for {dur}" + (f" — last said: {m.group(1)}" if m else ""), None
    if word == "INSPECT":
        return f"Stuck: {d}", None
    if word == "REVIVE":
        return "Session gone: revive or collect", None
    return f"Check: {d}", None  # CHECK


def needs_writes(line, slugs, docs, now_ms, warn):
    """Writes for one monitor line. `docs` is None (no --docs) or {doc id: {"version": int,
    "needsYou": bool, "status": str}} from a fresh ArtifactData list of `workers`."""
    line = line.strip()
    head = line.split(" ", 3)
    if len(head) >= 3 and head[2] == "monitor-error":
        warn(f"monitor-error line, no writes: {line}")
        return []
    segs = split_segments(line)
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (\S+) \d+/\d+ waiting", segs[0])
    if not m:
        raise UsageError(f"not a brain-monitor line: {line!r}")
    ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    since = int(ts.timestamp() * 1000)
    label = m.group(2)
    writes, unclearable = [], False
    for seg in segs[1:]:
        sm = SEG_RE.fullmatch(seg.strip())
        if not sm:
            warn(f"unparsed segment skipped: {seg!r}")
            continue
        name, word, stale, dur, detail = sm.groups()
        if stale or re.search(r"\(stale: [^()]*\)$", detail or ""):
            continue
        slug = resolve(name, label, slugs)
        if slug is None:
            warn(f"worker {name!r} is not in --slugs; skipped")
            continue
        known = docs.get(slug) if docs is not None else None
        if word in CAPS:
            text, status = needs_text(word, detail, dur)
            data = {"needsYou": text, "needsYouSince": since}
            if status:
                data["status"] = status
            if known:  # drop a link left over from an earlier kind of wait
                data.update({k: dict(DELETE) for k in LINK_KEYS})
        elif word in LOWER_WAITING or word == "collected":
            continue
        elif word.isupper():
            warn(f"unknown needs word {word!r} for {name}; skipped")
            continue
        else:  # not waiting: clear only what is known to be set; never create a stub doc
            if docs is None:
                unclearable = True
                continue
            if not (known and known["needsYou"]):
                continue
            data = {k: dict(DELETE) for k in NEEDS_KEYS}
            if known["status"] == "blocked":  # UNBLOCK set it; the worker has resumed
                data["status"] = "working"
        data["updatedAt"] = now_ms
        w = {"op": "update", "collection": "workers", "doc_id": slug, "data": data}
        if known:
            w["if_version"] = known["version"]
        else:
            data["slug"] = slug
        writes.append(w)
    if unclearable:
        warn("non-waiting worker(s) skipped: pass --docs (from an ArtifactData list of "
             "`workers`) so a stale needsYou can be cleared")
    return writes


def load_docs(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError) as e:
        raise UsageError(f"cannot read --docs {path}: {e}")
    shape = ('--docs must be a JSON object of doc id → {"version": int, "needsYou": bool, '
             '"status": str}')
    if not isinstance(raw, dict):
        raise UsageError(shape)
    docs = {}
    for k, v in raw.items():
        if not isinstance(v, dict):
            raise UsageError(f"{shape} (bad entry {k!r})")
        ver, ny, st = v.get("version"), v.get("needsYou", False), v.get("status", "")
        if not isinstance(ver, int) or isinstance(ver, bool) or not isinstance(ny, bool) \
                or not isinstance(st, str):
            raise UsageError(f"{shape} (bad entry {k!r}: {v!r})")
        docs[k] = {"version": ver, "needsYou": ny, "status": st}
    return docs


def cmd_needs(a):
    docs = load_docs(a.docs) if a.docs else None
    now_ms = a.now_ms if a.now_ms is not None else int(time.time() * 1000)
    writes = needs_writes(a.line, a.slugs, docs, now_ms,
                          lambda msg: print(f"dashboard: {msg}", file=sys.stderr))
    print(json.dumps(writes, ensure_ascii=False))
    return 0 if writes else 3


# ========================================================================= cli ====
NEEDS_HELP = """\
Map one brain-monitor line to ArtifactData `update` writes on `workers` (a JSON array on
stdout). needsYouSince = the line's timestamp; updatedAt = --now-ms (default: now).

Capital-letters segments (ANSWER, REVIEW, ...) set needsYou. With --docs, a known doc is
pinned with if_version and its needsYouLink/needsYouLinkLabel are deleted; a doc absent
from --docs (or any doc, without --docs) is new: written unpinned with `slug`.
Non-waiting segments (busy, parked, ...) clear needsYou* only for a known doc whose
needsYou is set (and set status working if it was blocked); without --docs they write
nothing. Lowercase waiting words and `collected` never write.

Exit: 0 writes printed; exit 3 when there are no writes (`[]` is still printed: skip the
batch, ArtifactData needs at least one write); 2 usage error.
"""


def main(argv=None):
    ap = argparse.ArgumentParser(prog="dashboard.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("theme", help="print the theme CSS block for a colour")
    p.add_argument("colour", help="#rgb, #rrggbb or a CSS colour name; only its OKLCH hue is used")

    p = sub.add_parser("render", help="fill the dashboard template")
    p.add_argument("--title", required=True)
    p.add_argument("--colour", "--color", required=True, help="#rgb, #rrggbb or a CSS colour name")
    p.add_argument("--glyph", default="◆")
    p.add_argument("--subtitle-text", default="")
    p.add_argument("--subtitle-url", default="", help="https:// link shown after the subtitle text")
    p.add_argument("--owner", default="The user")
    p.add_argument("--placeholder", default="e.g. dispatch a worker for the next task")
    p.add_argument("--template", default=DEFAULT_TEMPLATE)
    p.add_argument("-o", "--output")

    p = sub.add_parser("lookup", help="print a project's dashboard url (exit 1 if absent)")
    p.add_argument("project", nargs="?")
    p.add_argument("--all", action="store_true", help="print every row as project<TAB>url<TAB>colour")
    p.add_argument("--registry", default=DEFAULT_REGISTRY)

    p = sub.add_parser("register", help="add or update a project's dashboard row")
    p.add_argument("project")
    p.add_argument("url")
    p.add_argument("colour")
    p.add_argument("--registry", default=DEFAULT_REGISTRY)

    p = sub.add_parser("needs", help="brain-monitor line → ArtifactData batch writes (JSON)",
                       formatter_class=argparse.RawDescriptionHelpFormatter,
                       description=NEEDS_HELP)
    p.add_argument("--slugs", nargs="+", required=True, help="the full worker slugs being monitored")
    p.add_argument("--docs", help='JSON file: doc id → {"version": int, "needsYou": bool, "status": str}, '
                   "built from a fresh ArtifactData list of `workers`")
    p.add_argument("--now-ms", type=int, help="updatedAt in epoch ms (default: now)")
    p.add_argument("--line", dest="line_opt", metavar="LINE", help="the monitor line (alternative to the positional)")
    p.add_argument("line", nargs="?", help="one brain-monitor stdout line (quote it)")

    a = ap.parse_args(argv)
    if a.cmd == "needs":
        if a.line is not None and a.line_opt is not None:
            ap.error("needs: give the monitor line once (positional or --line)")
        a.line = a.line_opt if a.line_opt is not None else a.line
        if a.line is None:
            # `--slugs a b "<line>"`: nargs="+" swallowed the line; it is the last value
            if not LINE_START.match(a.slugs[-1]):
                ap.error("needs: missing the monitor line (pass it after the --slugs list, or after --docs)")
            if len(a.slugs) < 2:
                ap.error("needs: no slugs given before the monitor line")
            a.line = a.slugs.pop()
    try:
        if a.cmd == "theme":
            try:
                print(theme_css(a.colour))
            except ValueError as e:
                raise UsageError(str(e))
            return 0
        return {"render": cmd_render, "lookup": cmd_lookup,
                "register": cmd_register, "needs": cmd_needs}[a.cmd](a)
    except UsageError as e:
        print(f"dashboard: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
