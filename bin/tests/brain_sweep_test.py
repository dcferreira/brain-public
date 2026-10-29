import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.dirname(HERE)
sys.path.insert(0, BIN)

import brain_sweep as bsw  # noqa: E402

CLI = os.path.join(BIN, "brain-sweep")
MON = date(2026, 10, 19)  # Monday of 2026-W43

THIS_WEEK = "## This week\n\n- [x] goal-looking line that must stay put\n- Personal: ship pawl\n"

TOM = (
    "# Top of Mind\n\nIntro line.\n\n"
    "## Today\n\n"
    "- [/] in progress thing\n"
    "- [x] **finished A** — detail\n"
    "  continuation of A\n"
    "  - nested child of A\n"
    "- [ ] todo thing\n"
    "  - [x] nested done child stays with its parent\n"
    "- [x] 2026-10-18 — already dated B\n"
    "- [-] dropped thing\n\n"
    + THIS_WEEK
    + "\n## Previously this week\n\n"
    "- [x] 2026-10-14 — last week item\n"
    "  with continuation\n"
    "- [x] 2026-10-19 — this week item\n"
)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


def section(text, name):
    out, on = [], False
    for line in text.splitlines(keepends=True):
        if line.startswith("## "):
            on = line[3:].strip().lower().startswith(name.lower())
            if on:
                continue
        if on:
            out.append(line)
    return "".join(out)


class PureSweepTests(unittest.TestCase):
    def test_moves_done_items_with_continuations_and_dates_them(self):
        res = bsw.sweep(TOM, MON, max_bytes=10**9)
        today = section(res.text, "Today")
        self.assertIn("- [/] in progress thing", today)
        self.assertIn("- [ ] todo thing\n  - [x] nested done child stays with its parent", today)
        self.assertIn("- [-] dropped thing", today)
        self.assertNotIn("finished A", today)
        self.assertNotIn("already dated B", today)
        prev = section(res.text, "Previously this week")
        self.assertIn(
            "- [x] 2026-10-19 — **finished A** — detail\n  continuation of A\n  - nested child of A\n", prev
        )
        self.assertEqual(len(res.swept), 2)
        self.assertIn("- [x] 2026-10-18 — already dated B\n", "".join(res.archives["2026-W42"]))
        self.assertNotIn("2026-10-19 — 2026-10-18", res.text + "".join(res.archives["2026-W42"]))

    def test_this_week_and_other_sections_untouched(self):
        res = bsw.sweep(TOM, MON, max_bytes=10**9)
        self.assertIn(THIS_WEEK, res.text)
        self.assertTrue(res.text.startswith("# Top of Mind\n\nIntro line.\n\n## Today\n"))

    def test_age_trigger_archives_only_older_weeks(self):
        res = bsw.sweep(TOM, MON, max_bytes=10**9)
        self.assertEqual(list(res.archives), ["2026-W42"])
        self.assertEqual(
            res.archives["2026-W42"],
            ["- [x] 2026-10-18 — already dated B\n", "- [x] 2026-10-14 — last week item\n  with continuation\n"],
        )
        prev = section(res.text, "Previously this week")
        self.assertNotIn("last week item", prev)
        self.assertNotIn("already dated B", prev)  # dated 18 Oct (W42): archived even though just swept
        self.assertIn("this week item", prev)
        self.assertIn("finished A", prev)
        self.assertEqual(res.reason, "older than 2026-W43")

    def test_size_trigger_archives_everything_by_week(self):
        res = bsw.sweep(TOM, MON, max_bytes=100)
        self.assertEqual(sorted(res.archives), ["2026-W42", "2026-W43"])
        self.assertEqual(section(res.text, "Previously this week").strip(), "")
        self.assertIn("finished A", "".join(res.archives["2026-W43"]))
        self.assertIn("already dated B", "".join(res.archives["2026-W42"]))
        self.assertTrue(res.reason.startswith("file over"))

    def test_undated_legacy_entries_count_as_old_and_go_to_last_week(self):
        text = "## Today\n\n## Previously this week\n\n_W/c 10 Aug — prose_\n\n- [x] undated old thing\n"
        res = bsw.sweep(text, MON, max_bytes=10**9)
        self.assertEqual(list(res.archives), ["2026-W42"])
        self.assertEqual(len(res.archives["2026-W42"]), 2)
        self.assertEqual(section(res.text, "Previously this week").strip(), "")

    def test_nothing_to_do_is_a_no_op(self):
        text = "## Today\n\n- [ ] a\n\n## This week\n\n- g\n\n## Previously this week\n\n- [x] 2026-10-19 — b\n"
        res = bsw.sweep(text, MON, max_bytes=10**9)
        self.assertEqual(res.text, text)
        self.assertFalse(res.changed)

    def test_creates_previously_section_when_missing(self):
        text = "## Today\n\n- [x] done\n\n## This week\n\n- g\n"
        res = bsw.sweep(text, MON, max_bytes=10**9)
        self.assertIn("## Previously this week\n\n- [x] 2026-10-19 — done\n", res.text)
        self.assertIn("## This week\n\n- g\n", res.text)

    def test_swept_items_go_to_the_top_of_previously(self):
        res = bsw.sweep(TOM, MON, max_bytes=10**9)
        prev = section(res.text, "Previously this week").strip().splitlines()
        self.assertTrue(prev[0].startswith("- [x] 2026-10-19 — **finished A**"))


class ArchiveFileTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def test_creates_archive_with_week_heading(self):
        p = os.path.join(self.d, "2026-W42.md")
        bsw.append_archive(p, "2026-W42", ["- [x] a\n", "- [x] b\n  more\n"])
        self.assertEqual(read(p), "# Week 2026-W42\n\n## Done\n\n- [x] a\n- [x] b\n  more\n")

    def test_appends_inside_existing_done_section(self):
        p = os.path.join(self.d, "2026-W42.md")
        write(p, "# Week 2026-W42\n\n## Goals\n- g\n\n## Done\n\n- [x] old\n\n## Retro\nok\n")
        bsw.append_archive(p, "2026-W42", ["- [x] new\n"])
        self.assertEqual(
            read(p), "# Week 2026-W42\n\n## Goals\n- g\n\n## Done\n\n- [x] old\n- [x] new\n\n## Retro\nok\n"
        )

    def test_adds_done_section_when_absent(self):
        p = os.path.join(self.d, "2026-W42.md")
        write(p, "# Week 2026-W42\n\n## Goals\n- g\n")
        bsw.append_archive(p, "2026-W42", ["- [x] new\n"])
        self.assertEqual(read(p), "# Week 2026-W42\n\n## Goals\n- g\n\n## Done\n\n- [x] new\n")


class CliTests(unittest.TestCase):
    def setUp(self):
        self.v = tempfile.mkdtemp()
        self.tom = os.path.join(self.v, "00-home", "top-of-mind.md")
        write(self.tom, TOM)

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, CLI, "--vault", self.v, "--date", "2026-10-19", *args],
            capture_output=True, text=True,
        )

    def test_dry_run_changes_nothing(self):
        r = self.cli("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(self.tom), TOM)
        self.assertFalse(os.path.exists(os.path.join(self.v, "planning")))
        self.assertIn("would sweep 2 done item(s)", r.stdout)
        self.assertIn("would archive 2 item(s) to planning/2026-W42.md", r.stdout)

    def test_run_writes_file_and_archive_and_is_idempotent(self):
        r = self.cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        after = read(self.tom)
        self.assertNotIn("finished A", section(after, "Today"))
        arch = read(os.path.join(self.v, "planning", "2026-W42.md"))
        self.assertIn("- [x] 2026-10-14 — last week item\n  with continuation\n", arch)
        r2 = self.cli()
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(read(self.tom), after)
        self.assertIn("nothing to do", r2.stdout)
        self.assertEqual(read(os.path.join(self.v, "planning", "2026-W42.md")), arch)

    def test_private_file_archives_under_private_planning(self):
        priv = os.path.join(self.v, "private", "private.md")
        write(priv, TOM)
        r = self.cli("--file", "private/private.md")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.v, "private", "planning", "2026-W42.md")))
        self.assertFalse(os.path.exists(os.path.join(self.v, "planning")))
        self.assertEqual(read(self.tom), TOM)

    def test_max_kb_flag_forces_full_archive(self):
        r = self.cli("--max-kb", "0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(section(read(self.tom), "Previously this week").strip(), "")
        self.assertTrue(os.path.exists(os.path.join(self.v, "planning", "2026-W43.md")))

    def test_missing_file_fails(self):
        r = self.cli("--file", "nope.md")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not found", r.stderr)

    def test_rereads_before_writing(self):
        def concurrent_edit():
            write(self.tom, read(self.tom).replace("- [ ] todo thing", "- [ ] todo thing EDITED"))

        bsw.run(self.tom, os.path.join(self.v, "planning"), MON, 40 * 1024, dry_run=False, _before_write=concurrent_edit)
        after = read(self.tom)
        self.assertIn("- [ ] todo thing EDITED", after)
        self.assertNotIn("finished A", section(after, "Today"))

    def test_preserves_file_mode(self):
        os.chmod(self.tom, 0o640)
        self.cli()
        self.assertEqual(os.stat(self.tom).st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
