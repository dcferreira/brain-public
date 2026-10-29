"""Tests for dashboard.py — theme maths, render, registry and monitor-line → db writes.

Run: bash dashboard.test.sh   (or: python3 -m unittest -v dashboard_test, from this dir)
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "dashboard.py")
sys.path.insert(0, HERE)

import dashboard as d  # noqa: E402


def run(*args, input_text=None):
    p = subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, input=input_text)
    return p.returncode, p.stdout, p.stderr


def parse_vars(block):
    return dict(re.findall(r"--([a-z-]+):(#[0-9a-f]{6})", block))


def palettes(colour):
    """(light vars, dark vars) parsed from the theme CSS."""
    css = d.theme_css(colour)
    light = css.split("@media")[0]
    dark = css.split(":root[data-theme=\"dark\"]")[1]
    return parse_vars(light), parse_vars(dark)


def vivid(hue):
    """A vivid in-gamut sRGB hex at the given OKLCH hue."""
    return d.oklch_to_hex(0.65, 0.2, hue)


ROLES = ["bg", "surface", "ink", "muted", "line", "accent", "accent-soft", "on-accent",
         "ok", "ok-soft", "run", "run-soft", "warn", "warn-soft", "bad", "bad-soft", "idle", "idle-soft"]


# ======================================================================= theme ====
class ThemeShape(unittest.TestCase):
    def test_css_shape(self):
        css = d.theme_css("#1f6b6a")
        self.assertTrue(css.startswith(":root{"))
        self.assertIn("color-scheme:light}", css)
        self.assertIn('@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){', css)
        self.assertIn(':root[data-theme="dark"]{', css)
        self.assertEqual(css.count("color-scheme:dark}"), 2)
        light, dark = palettes("#1f6b6a")
        for r in ROLES:
            self.assertIn(r, light, r)
            self.assertIn(r, dark, r)
        # both dark blocks identical
        blocks = re.findall(r"\{([^{}]*color-scheme:dark)\}", css)
        self.assertEqual(len(blocks), 2)
        self.assertEqual(blocks[0], blocks[1])

    def test_fixed_status_colours(self):
        light, dark = palettes("#4b3fa8")
        self.assertEqual(light["ok"], "#2c7748")
        self.assertEqual(light["bad-soft"], "#f6dcd9")
        self.assertEqual(light["warn"], "#985a00")
        self.assertEqual(light["run-soft"], "#dde8f6")
        self.assertEqual(dark["ok"], "#6cc28d")
        self.assertEqual(dark["bad-soft"], "#3c1f1c")
        self.assertEqual(dark["run"], "#7fb0ec")
        self.assertEqual(dark["warn-soft"], "#3a2c17")

    def test_input_forms(self):
        self.assertEqual(d.parse_colour("#abc"), (0xaa, 0xbb, 0xcc))
        self.assertEqual(d.parse_colour("#1F6B6A"), (0x1f, 0x6b, 0x6a))
        self.assertEqual(d.parse_colour("teal"), (0, 0x80, 0x80))
        for bad in ["", "#12", "#gggggg", "notacolour", "123456"]:
            with self.assertRaises(ValueError, msg=bad):
                d.parse_colour(bad)

    def test_cli_theme(self):
        rc, out, _ = run("theme", "#1f6b6a")
        self.assertEqual(rc, 0)
        self.assertIn("--accent:#", out)
        rc, _, err = run("theme", "nope")
        self.assertEqual(rc, 2)
        self.assertIn("colour", err)

    def test_roundtrip(self):
        for h in ["#1f6b6a", "#4b3fa8", "#9a6a12", "#ff0000", "#000000", "#ffffff"]:
            L, C, H = d.hex_to_oklch(h)
            self.assertEqual(d.oklch_to_hex(L, C, H), h)


class Hue(unittest.TestCase):
    def test_hue_extraction(self):
        L, C, H = d.hex_to_oklch("#ff0000")
        self.assertAlmostEqual(H, 29.2, delta=1.0)
        L, C, H = d.hex_to_oklch("#0000ff")
        self.assertAlmostEqual(H, 264.1, delta=1.0)
        self.assertLess(d.hex_to_oklch("#808080")[1], 0.001)

    def test_accent_keeps_hue(self):
        cases = [vivid(h) for h in range(0, 360, 10)] + ["#1f6b6a", "#4b3fa8", "#9a6a12"]
        for c in cases:
            hin = d.hex_to_oklch(c)[2]
            light, dark = palettes(c)
            for name, pal in (("light", light), ("dark", dark)):
                for role in ("accent", "accent-soft"):
                    hout = d.hex_to_oklch(pal[role])[2]
                    diff = abs((hout - hin + 180) % 360 - 180)
                    self.assertLess(diff, 15, f"{c} {name} {role}: in {hin:.1f} out {hout:.1f}")

    def test_only_hue_matters(self):
        # same hue, different lightness/chroma → the same palette (up to the 8-bit
        # rounding of the inputs' hue: every channel within 1)
        a = d.oklch_to_hex(0.4, 0.08, 200)
        b = d.oklch_to_hex(0.8, 0.12, 200)
        for pa, pb in zip(palettes(a), palettes(b)):
            self.assertEqual(pa.keys(), pb.keys())
            for k in pa:
                ca, cb = d.parse_colour(pa[k]), d.parse_colour(pb[k])
                self.assertLessEqual(max(abs(x - y) for x, y in zip(ca, cb)), 1, (k, pa[k], pb[k]))

    def test_grey_is_neutral_slate(self):
        for c in ["#808080", "#000000", "#ffffff"]:
            light, dark = palettes(c)
            for pal in (light, dark):
                self.assertLess(d.hex_to_oklch(pal["accent"])[1], 0.06, c)
                self.assertLess(d.hex_to_oklch(pal["bg"])[1], 0.02, c)
        self.assertEqual(d.theme_css("#808080"), d.theme_css("#000000"))


class Contrast(unittest.TestCase):
    INPUTS = [vivid(h) for h in range(0, 360, 10)] + [
        "#808080", "#000000", "#ffffff", "#1f6b6a", "#4b3fa8", "#9a6a12"]

    def test_wcag_formula(self):
        self.assertAlmostEqual(d.contrast("#000000", "#ffffff"), 21.0, places=3)
        self.assertAlmostEqual(d.contrast("#777777", "#ffffff"), 4.48, places=2)

    def test_contrast_all_hues(self):
        failures = []
        for c in self.INPUTS:
            for name, pal in zip(("light", "dark"), palettes(c)):
                checks = [("ink", "bg", 4.5), ("ink", "surface", 4.5),
                          ("muted", "bg", 4.5), ("muted", "surface", 4.5),
                          ("accent", "surface", 3.0), ("accent", "bg", 3.0),
                          ("on-accent", "accent", 4.5)]
                for fg, bg, need in checks:
                    r = d.contrast(pal[fg], pal[bg])
                    if r < need:
                        failures.append(f"{c} {name} {fg}/{bg} {r:.2f} < {need}")
        self.assertEqual(failures, [])

    def test_chip_pairs(self):
        # every status chip (fg on its own soft bg) and the accent chip reads at AA
        failures = []
        for c in self.INPUTS:
            for name, pal in zip(("light", "dark"), palettes(c)):
                for role in ("ok", "run", "warn", "bad", "idle", "accent"):
                    r = d.contrast(pal[role], pal[role + "-soft"])
                    if r < 4.5:
                        failures.append(f"{c} {name} {role}/{role}-soft {r:.2f} < 4.5")
        self.assertEqual(failures, [])

    def test_vivid_inputs_are_vivid(self):
        # the 36-hue fixture really is chromatic (else the hue test proves nothing)
        for h in range(0, 360, 10):
            self.assertGreater(d.hex_to_oklch(vivid(h))[1], 0.06, h)


# ====================================================================== render ====
FIXTURE = """<!doctype html><title>{{TITLE}}</title><style>{{THEME_CSS}}</style>
<h1><span class="glyph">{{GLYPH}}</span> {{TITLE}}</h1>{{SUBTITLE_HTML}}
<textarea placeholder="{{PLACEHOLDER}}"></textarea>
<script type="application/json" id="config">{{CONFIG_JSON}}</script>
"""


class Render(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tpl = os.path.join(self.tmp.name, "t.html")
        with open(self.tpl, "w") as f:
            f.write(FIXTURE)

    def tearDown(self):
        self.tmp.cleanup()

    def render(self, *extra):
        return run("render", "--template", self.tpl, *extra)

    def test_basic(self):
        rc, out, err = self.render("--title", "Budgebell Control", "--colour", "#1f6b6a")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("{{", out)
        self.assertIn("<title>Budgebell Control</title>", out)
        self.assertIn('<span class="glyph">◆</span>', out)
        self.assertIn(":root{--bg:#", out)
        self.assertIn('placeholder="e.g. dispatch a worker for the next task"', out)
        cfg = json.loads(re.search(r'id="config">(.*)</script>', out).group(1))
        self.assertEqual(cfg, {"owner": "The user", "storageKey": "budgebell-control-view",
                               "title": "Budgebell Control"})
        self.assertIn('</h1>\n<textarea', out)  # no subtitle → empty

    def test_escaping(self):
        rc, out, err = self.render("--title", "A <b>&\"x\"</b>", "--colour", "teal",
                                   "--glyph", "<", "--placeholder", "say \"hi\" & <go>",
                                   "--owner", "Ann</script>")
        self.assertEqual(rc, 0, err)
        self.assertIn("<title>A &lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;</title>", out)
        self.assertIn('<span class="glyph">&lt;</span>', out)
        self.assertIn('placeholder="say &quot;hi&quot; &amp; &lt;go&gt;"', out)
        raw = re.search(r'id="config">(.*)</script>', out).group(1)
        self.assertNotIn("<", raw)
        self.assertNotIn(">", raw)
        self.assertNotIn("&", raw)
        cfg = json.loads(raw)
        self.assertEqual(cfg["owner"], "Ann</script>")
        self.assertEqual(cfg["storageKey"], "a-b-x-b-view")

    def test_subtitle(self):
        rc, out, err = self.render("--title", "T", "--colour", "#4b3fa8",
                                   "--subtitle-text", "The manager's board for",
                                   "--subtitle-url", "https://github.com/x/y")
        self.assertEqual(rc, 0, err)
        self.assertIn('<p class="sub">The manager&#x27;s board for <a href="https://github.com/x/y" '
                      'target="_blank" rel="noopener">x/y</a></p>', out)
        rc, out, _ = self.render("--title", "T", "--colour", "#4b3fa8", "--subtitle-text", "Just text")
        self.assertIn('<p class="sub">Just text</p>', out)
        rc, out, _ = self.render("--title", "T", "--colour", "#4b3fa8",
                                 "--subtitle-url", "https://example.com/a?b=1&c=2")
        self.assertIn('<a href="https://example.com/a?b=1&amp;c=2" target="_blank" rel="noopener">'
                      'example.com/a?b=1&amp;c=2</a>', out)

    def test_bad_url(self):
        rc, _, err = self.render("--title", "T", "--colour", "#4b3fa8",
                                 "--subtitle-text", "x", "--subtitle-url", "javascript:alert(1)")
        self.assertEqual(rc, 2)
        self.assertIn("https://", err)

    def test_unfilled_placeholder_fails(self):
        with open(self.tpl, "a") as f:
            f.write("{{NOPE}}")
        rc, out, err = self.render("--title", "T", "--colour", "#4b3fa8")
        self.assertEqual(rc, 2)
        self.assertIn("{{NOPE}}", err)

    def test_value_with_braces_does_not_trip(self):
        # a value that itself looks like a placeholder is escaped data, not a template hole
        rc, out, err = self.render("--title", "{{X}}", "--colour", "#4b3fa8")
        # braces survive html-escaping, so this must be rejected or survive; we reject it
        # only if it remains as a literal placeholder — title values are user data, so the
        # check is on the template, not the values.
        self.assertEqual(rc, 0, err)
        self.assertIn("<title>{{X}}</title>", out)

    def test_output_file(self):
        out_path = os.path.join(self.tmp.name, "page.html")
        rc, out, err = self.render("--title", "T", "--colour", "#4b3fa8", "-o", out_path)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "")
        with open(out_path) as f:
            self.assertIn("<title>T</title>", f.read())

    def test_real_template_if_present(self):
        real = os.path.join(HERE, "..", "assets", "dashboard.template.html")
        if not os.path.exists(real):
            self.skipTest("template not written yet")
        rc, out, err = run("render", "--title", "X Control", "--colour", "#1f6b6a")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("{{", out)


# ==================================================================== registry ====
class Registry(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.reg = os.path.join(self.tmp.name, "sub", "dashboards.md")

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_file(self):
        rc, out, err = run("lookup", "Budgebell", "--registry", self.reg)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertTrue(err)

    def test_roundtrip_and_upsert(self):
        u1 = "https://claude.ai/artifact/aaa"
        u2 = "https://claude.ai/code/artifact/bbb"
        rc, _, err = run("register", "Budgebell", u1, "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        rc, _, err = run("register", "agent-pawl", u2, "#4b3fa8", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        rc, out, _ = run("lookup", "Budgebell", "--registry", self.reg)
        self.assertEqual((rc, out), (0, u1 + "\n"))
        rc, out, _ = run("lookup", "agent-pawl", "--registry", self.reg)
        self.assertEqual((rc, out), (0, u2 + "\n"))
        rc, _, _ = run("lookup", "budgebell", "--registry", self.reg)  # case-sensitive
        self.assertEqual(rc, 1)
        with open(self.reg) as f:
            text = f.read()
        self.assertTrue(text.startswith("# "))
        self.assertIn("| project | url | colour | created |", text)
        created = re.search(r"\| Budgebell \| \S+ \| #1f6b6a \| (\d{4}-\d{2}-\d{2}) \|", text)
        self.assertTrue(created, text)
        # backdate the created date, then upsert: created preserved, url/colour replaced
        with open(self.reg, "w") as f:
            f.write(text.replace(created.group(1), "2020-01-02"))
        u3 = "https://claude.ai/artifact/ccc"
        rc, _, err = run("register", "Budgebell", u3, "#9a6a12", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        rc, out, _ = run("lookup", "Budgebell", "--registry", self.reg)
        self.assertEqual(out, u3 + "\n")
        with open(self.reg) as f:
            text2 = f.read()
        self.assertIn(f"| Budgebell | {u3} | #9a6a12 | 2020-01-02 |", text2)
        self.assertIn(f"| agent-pawl | {u2} | #4b3fa8 |", text2)
        self.assertEqual(text2.count("Budgebell"), 1)
        # idempotent
        run("register", "Budgebell", u3, "#9a6a12", "--registry", self.reg)
        with open(self.reg) as f:
            self.assertEqual(f.read(), text2)
        rc, out, _ = run("lookup", "--all", "--registry", self.reg)
        self.assertEqual(rc, 0)
        self.assertEqual(out.splitlines(), [f"Budgebell\t{u3}\t#9a6a12", f"agent-pawl\t{u2}\t#4b3fa8"])

    def test_validation(self):
        rc, _, err = run("register", "X", "https://evil.com/x", "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 2)
        rc, _, err = run("register", "X|Y", "https://claude.ai/artifact/a", "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 2)
        rc, _, err = run("register", "X", "https://claude.ai/artifact/a", "nocolour", "--registry", self.reg)
        self.assertEqual(rc, 2)
        self.assertFalse(os.path.exists(self.reg))


    def write(self, text):
        os.makedirs(os.path.dirname(self.reg), exist_ok=True)
        with open(self.reg, "w") as f:
            f.write(text)

    def test_project_named_project(self):
        u = "https://claude.ai/artifact/ppp"
        rc, _, err = run("register", "project", u, "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        rc, out, err = run("lookup", "project", "--registry", self.reg)
        self.assertEqual((rc, out), (0, u + "\n"), err)
        rc, out, _ = run("lookup", "--all", "--registry", self.reg)
        self.assertEqual(out, f"project\t{u}\t#1f6b6a\n")
        # re-register is an upsert, not a second row
        run("register", "project", u, "#4b3fa8", "--registry", self.reg)
        with open(self.reg) as f:
            self.assertEqual(f.read().count(u), 1)

    def test_only_first_matching_table(self):
        self.write("# Dashboards\n\nSome notes:\n\n"
                   "| a | b | c | d |\n|---|---|---|---|\n| Foo | https://claude.ai/artifact/no | #000000 | 2020-01-01 |\n\n"
                   "| project | url | colour | created |\n|---|---|---|---|\n"
                   "| Real | https://claude.ai/artifact/yes | #1f6b6a | 2020-01-01 |\n\n"
                   "| project | url | colour | created |\n|---|---|---|---|\n"
                   "| Later | https://claude.ai/artifact/later | #1f6b6a | 2020-01-01 |\n")
        rc, out, _ = run("lookup", "--all", "--registry", self.reg)
        self.assertEqual(out, "Real\thttps://claude.ai/artifact/yes\t#1f6b6a\n")
        self.assertEqual(run("lookup", "Foo", "--registry", self.reg)[0], 1)
        self.assertEqual(run("lookup", "Later", "--registry", self.reg)[0], 1)
        # register appends to the right table
        u = "https://claude.ai/artifact/new"
        rc, _, err = run("register", "New", u, "#4b3fa8", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        with open(self.reg) as f:
            text = f.read()
        self.assertIn("| Real | https://claude.ai/artifact/yes | #1f6b6a | 2020-01-01 |\n| New | " + u, text)

    def test_file_without_table_gets_one(self):
        self.write("# Dashboards\n\n| a | b | c | d |\n|---|---|---|---|\n| x | y | z | w |\n")
        u = "https://claude.ai/artifact/q"
        rc, _, err = run("register", "Q", u, "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        rc, out, _ = run("lookup", "--all", "--registry", self.reg)
        self.assertEqual(out, f"Q\t{u}\t#1f6b6a\n")
        with open(self.reg) as f:
            self.assertIn("| x | y | z | w |", f.read())

    def test_lookup_normalises_like_register(self):
        u = "https://claude.ai/artifact/s"
        rc, _, err = run("register", "  Spacey  ", u, "#1f6b6a", "--registry", self.reg)
        self.assertEqual(rc, 0, err)
        for name in ("Spacey", " Spacey ", "Spacey\t"):
            rc, out, err = run("lookup", name, "--registry", self.reg)
            self.assertEqual((rc, out), (0, u + "\n"), (name, err))
        rc, _, _ = run("lookup", "a|b", "--registry", self.reg)
        self.assertEqual(rc, 2)


# ======================================================================= needs ====
TS = "2026-10-02T10:04:00Z"
TS_MS = 1790935440000
NOW = 1790936000000


def needs(line, slugs, docs=None, now=NOW):
    """(rc, parsed writes or None, stderr)."""
    args = ["needs", "--slugs", *slugs, "--now-ms", str(now)]
    tmp = None
    if docs is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(docs, tmp)
        tmp.close()
        args += ["--docs", tmp.name]
    rc, out, err = run(*args, line)
    if tmp:
        os.unlink(tmp.name)
    return rc, (json.loads(out) if out.strip() else None), err


def doc(version, needs_you=False, status="working"):
    return {"version": version, "needsYou": needs_you, "status": status}


DEL = {"__delete__": True}
CLEAR = {"needsYou": DEL, "needsYouSince": DEL, "needsYouLink": DEL, "needsYouLinkLabel": DEL}
LINK_DEL = {"needsYouLink": DEL, "needsYouLinkLabel": DEL}


class Needs(unittest.TestCase):
    BB = ["budgebell-log-utc", "budgebell-nudge-cooldown", "budgebell-linux-quiet-probes"]

    def one(self, seg, slug="p-x", name="x", label="p"):
        line = f"{TS} {label} 1/1 waiting · {seg.replace('NAME', name)}"
        rc, writes, err = needs(line, [slug])
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(writes), 1, writes)
        w = writes[0]
        self.assertEqual(w["op"], "update")
        self.assertEqual(w["collection"], "workers")
        self.assertEqual(w["doc_id"], slug)
        return w["data"]

    def waiting(self, data, text, status=None):
        want = {"needsYou": text, "needsYouSince": TS_MS, "updatedAt": NOW, "slug": "p-x"}
        if status:
            want["status"] = status
        self.assertEqual(data, want)

    def test_answer(self):
        self.waiting(self.one('NAME ANSWER 0m "Find brief: Rewrite rows? [1 Yes / 2 No]"'),
                     "Has a question for you: Find brief: Rewrite rows? [1 Yes / 2 No]")

    def test_review_pr(self):
        self.waiting(self.one("NAME REVIEW 0m PR#9"), "PR #9 ready for review")

    def test_review_text(self):
        self.waiting(self.one('NAME REVIEW 0m "awaiting review of the utc branch"'),
                     "awaiting review of the utc branch")

    def test_unblock(self):
        self.waiting(self.one('NAME UNBLOCK 0m "need the API key from the user"'),
                     "need the API key from the user", status="blocked")

    def test_collect(self):
        self.waiting(self.one("NAME COLLECT 0m"), "Finished: collect it", status="done")

    def test_nudge(self):
        self.waiting(self.one('NAME NUDGE 1m note=working said:"I couldn\'t find the brief."'),
                     "Idle for 1m — last said: I couldn't find the brief.")
        self.waiting(self.one("NAME NUDGE 2h note=primed"), "Idle for 2h")

    def test_inspect(self):
        self.waiting(self.one("NAME INSPECT 0m busy 0m, transcript silent 40m"),
                     "Stuck: busy 0m, transcript silent 40m")

    def test_revive(self):
        self.waiting(self.one("NAME REVIVE 0m note=working"), "Session gone: revive or collect")

    def test_check(self):
        self.waiting(self.one("NAME CHECK 0m no note"), "Check: no note")

    # ---- capitals with --docs
    def test_caps_known_doc_pinned_and_drops_stale_link(self):
        line = f'{TS} p 1/1 waiting · x ANSWER 0m "q?"'
        rc, writes, err = needs(line, ["p-x"], docs={"p-x": doc(7, needs_you=True, status="in-review")})
        self.assertEqual(rc, 0, err)
        self.assertEqual(writes, [{"op": "update", "collection": "workers", "doc_id": "p-x", "if_version": 7,
                                   "data": {"needsYou": "Has a question for you: q?", "needsYouSince": TS_MS,
                                            **LINK_DEL, "updatedAt": NOW}}])

    def test_caps_unknown_doc_is_new(self):
        line = f"{TS} p 1/1 waiting · x COLLECT 0m"
        rc, writes, err = needs(line, ["p-x"], docs={"p-other": doc(3)})
        self.assertEqual(rc, 0, err)
        self.assertEqual(writes, [{"op": "update", "collection": "workers", "doc_id": "p-x",
                                   "data": {"needsYou": "Finished: collect it", "needsYouSince": TS_MS,
                                            "status": "done", "updatedAt": NOW, "slug": "p-x"}}])

    # ---- non-waiting segments
    def test_clear_known_doc_that_needs_you(self):
        for seg in ["x busy 14m", "x parked 0m", "x primed 2m", "x working 1m"]:
            line = f"{TS} p 0/1 waiting · {seg}"
            rc, writes, err = needs(line, ["p-x"], docs={"p-x": doc(4, needs_you=True)})
            self.assertEqual(rc, 0, err)
            self.assertEqual(writes, [{"op": "update", "collection": "workers", "doc_id": "p-x",
                                       "if_version": 4, "data": {**CLEAR, "updatedAt": NOW}}], seg)

    def test_clear_blocked_resumes_working(self):
        line = f"{TS} p 0/1 waiting · x busy 1m"
        rc, writes, err = needs(line, ["p-x"], docs={"p-x": doc(9, needs_you=True, status="blocked")})
        self.assertEqual(rc, 0, err)
        self.assertEqual(writes[0]["data"], {**CLEAR, "status": "working", "updatedAt": NOW})

    def test_no_clear_when_nothing_to_clear(self):
        for docs in ({"p-x": doc(4, needs_you=False)}, {}, {"p-x": doc(4, needs_you=False, status="blocked")}):
            rc, writes, err = needs(f"{TS} p 0/1 waiting · x busy 1m", ["p-x"], docs=docs)
            self.assertEqual((rc, writes), (3, []), docs)

    def test_collected_never_writes(self):
        rc, writes, err = needs(f"{TS} p 0/1 waiting · x collected 3h", ["p-x"],
                                docs={"p-x": doc(2, needs_you=True, status="blocked")})
        self.assertEqual((rc, writes), (3, []))

    def test_non_waiting_without_docs_is_noop_with_note(self):
        rc, writes, err = needs(f"{TS} p 0/2 waiting · x busy 1m · y parked 2m", ["p-x", "p-y"])
        self.assertEqual((rc, writes), (3, []))
        self.assertEqual(err.count("--docs"), 1, err)

    def test_lowercase_noop(self):
        for seg in ['NAME question 3m "q?"', "NAME review 40m PR#9", 'NAME blocked 1m "x"',
                    "NAME done 5m", "NAME gone 1m note=working", "NAME idle 1m note=working",
                    "NAME stuck 2m busy 3m, transcript silent 40m", "NAME unknown 1m no note"]:
            line = f"{TS} p 1/1 waiting · {seg.replace('NAME', 'x')}"
            rc, writes, err = needs(line, ["p-x"], docs={"p-x": doc(1, needs_you=True, status="blocked")})
            self.assertEqual((rc, writes), (3, []), seg)

    def test_stale_noop(self):
        line = f"{TS} p 1/2 waiting · x question? 3m \"q\" (stale: host homeserver unreachable) · y busy? 1m (stale: host homeserver unreachable)"
        rc, writes, err = needs(line, ["p-x", "p-y"], docs={"p-y": doc(1, needs_you=True)})
        self.assertEqual((rc, writes), (3, []))

    def test_prefix_stripped_full_line(self):
        line = (f"{TS} budgebell 2/3 waiting · log-utc REVIEW 0m PR#12 · nudge-cooldown review 40m PR#9 "
                "· linux-quiet-probes busy 1m")
        docs = {"budgebell-log-utc": doc(5), "budgebell-linux-quiet-probes": doc(6, needs_you=True)}
        rc, writes, err = needs(line, self.BB, docs=docs)
        self.assertEqual(rc, 0, err)
        self.assertEqual([w["doc_id"] for w in writes], ["budgebell-log-utc", "budgebell-linux-quiet-probes"])
        self.assertEqual(writes[0]["data"]["needsYou"], "PR #12 ready for review")
        self.assertEqual(writes[1]["data"]["needsYou"], DEL)

    def test_exact_name_and_label_override(self):
        # no common prefix → label `workers`, full names
        line = f"{TS} workers 1/2 waiting · budgebell-log-utc UNBLOCK 0m \"x\" · c-a busy 0m"
        rc, writes, _ = needs(line, ["c-a", "budgebell-log-utc"], docs={"c-a": doc(1, needs_you=True)})
        self.assertEqual([w["doc_id"] for w in writes], ["budgebell-log-utc", "c-a"])
        # --label fleet: names still stripped of the slugs' common prefix
        line = f"{TS} fleet 0/2 waiting · a busy 0m · b busy 1m"
        rc, writes, _ = needs(line, ["c-a", "c-b"], docs={"c-a": doc(1, True), "c-b": doc(2, True)})
        self.assertEqual([w["doc_id"] for w in writes], ["c-a", "c-b"])

    def test_detail_containing_separator(self):
        line = f'{TS} p 1/2 waiting · x ANSWER 0m "pick one · or the other [1 A / 2 B]" · y busy 1m'
        rc, writes, err = needs(line, ["p-x", "p-y"], docs={"p-y": doc(1, needs_you=True)})
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(writes), 2)
        self.assertEqual(writes[0]["data"]["needsYou"],
                         "Has a question for you: pick one · or the other [1 A / 2 B]")
        self.assertEqual(writes[1]["doc_id"], "p-y")

    def test_unknown_name_skipped(self):
        line = f"{TS} p 1/2 waiting · x COLLECT 0m · zz busy 1m"
        rc, writes, err = needs(line, ["p-x"])
        self.assertEqual(rc, 0)
        self.assertEqual([w["doc_id"] for w in writes], ["p-x"])
        self.assertIn("zz", err)

    def test_monitor_error(self):
        rc, writes, err = needs(f"{TS} p monitor-error vault /x/workers missing", ["p-x"])
        self.assertEqual((rc, writes), (3, []))
        self.assertIn("monitor-error", err)

    def test_garbage_line(self):
        rc, _, err = run("needs", "--slugs", "p-x", "not a monitor line")
        self.assertEqual(rc, 2)

    def test_docs_validation(self):
        line = f"{TS} p 1/1 waiting · x COLLECT 0m"
        for bad in ([], {"p-x": 3}, {"p-x": {"version": True}}, {"p-x": {"version": "3"}},
                    {"p-x": {"version": 3, "needsYou": "yes"}}, {"p-x": {"version": 3, "status": 1}},
                    {"p-x": {"needsYou": True}}):
            rc, _, err = needs(line, ["p-x"], docs=bad)
            self.assertEqual(rc, 2, bad)
            self.assertIn("--docs", err)

    def test_versions_flag_removed(self):
        rc, _, err = run("needs", "--slugs", "p-x", "--versions", "/dev/null", f"{TS} p 1/1 waiting · x COLLECT 0m")
        self.assertEqual(rc, 2)

    def test_missing_line_detected(self):
        rc, out, err = run("needs", "--slugs", "p-x", "p-y")
        self.assertEqual(rc, 2)
        self.assertIn("missing the monitor line", err)
        rc, out, err = run("needs", "--slugs", "p-x")
        self.assertEqual(rc, 2)
        self.assertIn("missing the monitor line", err)

    def test_line_positions(self):
        line = f"{TS} p 1/1 waiting · x COLLECT 0m"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"p-x": doc(5)}, f)
        try:
            for args in (["--slugs", "p-x", "p-y", line],
                         ["--slugs", "p-x", "p-y", "--docs", f.name, line],
                         ["--slugs", "p-x", "p-y", "--line", line],
                         ["--line", line, "--slugs", "p-x", "p-y"]):
                rc, out, err = run("needs", *args)
                self.assertEqual(rc, 0, (args, err))
                self.assertEqual(json.loads(out)[0]["doc_id"], "p-x", args)
        finally:
            os.unlink(f.name)

    def test_help_documents_exit_3(self):
        rc, out, _ = run("needs", "--help")
        self.assertEqual(rc, 0)
        self.assertIn("exit 3", out)
        self.assertIn("--docs", out)
        self.assertIn("--line", out)
        self.assertIn("exit 3", d.__doc__)

    def test_now_defaults_to_wall_clock(self):
        line = f"{TS} p 1/1 waiting · x COLLECT 0m"
        rc, out, err = run("needs", "--slugs", "p-x", line)
        self.assertEqual(rc, 0, err)
        w = json.loads(out)[0]
        self.assertEqual(w["data"]["needsYouSince"], TS_MS)
        self.assertGreater(w["data"]["updatedAt"], TS_MS)


if __name__ == "__main__":
    unittest.main()
