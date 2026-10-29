import csv
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.dirname(HERE)
sys.path.insert(0, BIN)

import brain_migrate as bm  # noqa: E402
import brain_scope as bs  # noqa: E402

CLI = os.path.join(BIN, "brain-migrate-scope")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        f.write(text)


def snapshot(root):
    snap = {}
    for dp, _, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            with open(p, "rb") as f:
                snap[p] = (os.stat(p).st_mtime_ns, hashlib.sha256(f.read()).hexdigest())
    return snap


TOM = (
    "# Top of mind\n\n## Today\n"
    "- [x] [personal] **Fix the garden gate.** details — Personal — me\n"
    "- [ ] [personal] **Ship pawl release.** details — Personal project — agent-pawl — x\n"
    "- [ ] **Foo bar thing.** see workers/foo-bar — Personal project — agent-pawl\n"
    "- [ ] [personal] **Foo thing.** see workers/foo — Personal — me\n"
    "- [ ] **Chase invoices.** see workers/chase-invoices\n"
)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.v = os.path.join(self.tmp, "vault")
        self.out = os.path.join(self.tmp, "out")
        v = self.v
        write(os.path.join(v, "00-home/top-of-mind.md"), TOM)
        # rule 1
        write(os.path.join(v, "workers/fm-note.md"), "---\narea: projects\nproject: budgebell\n---\nbody\n")
        # rule 3 + longest prefix: flow-design-x -> flow-designer? "flow-designer-" vs "flow-design-": longest wins
        write(os.path.join(v, "workers/flow-designer-fix.md"), "---\nslug: x\n---\nb\n")
        write(os.path.join(v, "workers/flow-design-thing.md"), "b\n")
        write(os.path.join(v, "workers/fix-flow-design-bug.md"), "b\n")  # fix-flow-design- beats fix-
        # rule 4 via tags list
        write(os.path.join(v, "sessions/2026-10-01 stuff.md"),
              "---\ntags:\n  - misc\n  - habits\n---\nbody\n")
        write(os.path.join(v, "workers/wg.md"), "---\nweek_goal: clientco\n---\n")
        # rule 5
        write(os.path.join(v, "workers/garden.md"),
              '---\nslug: garden\ntoday_action: "**Fix the garden gate.** more"\n---\n')
        write(os.path.join(v, "workers/pawl-release-zzz.md"), "---\nslug: zzz\n---\n")  # slug-prefix pawl- wins
        write(os.path.join(v, "workers/rel.md"),
              '---\nslug: rel\ntoday_action: "**Ship pawl release.** x"\n---\n')
        write(os.path.join(v, "workers/chase-invoices.md"), "---\nslug: chase-invoices\n---\n")
        # rule 6
        write(os.path.join(v, "knowledge/random.md"), "nothing here\n")
        # learning
        write(os.path.join(v, "learning/cv/2026.md"), "cv\n")
        # mixed diary
        write(os.path.join(v, "diary/2026-10-02.md"), "Did garden stuff, then carco work.\n")
        write(os.path.join(v, "diary/2026-10-03.md"), "Only carco today. business-dead? no, businesslike.\n")
        write(os.path.join(v, "diary/2026-10-04.md"), "re-vault-ing and pulse-check\n")  # hyphen = word char
        # meetings private flagged
        write(os.path.join(v, "meetings/2026-10-05 learning call.md"), "---\ntags: [learning]\n---\nx\n")
        write(os.path.join(v, "workers/foo.md"), "---\nslug: foo\n---\n")
        write(os.path.join(v, "workers/foo-bar.md"), "---\nslug: foo-bar\n---\n")
        # mixed notes that would otherwise be private / projects
        write(os.path.join(v, "diary/2026-10-06.md"), "---\ntags: [learning]\n---\ncarco and learning\n")
        write(os.path.join(v, "diary/2026-10-07.md"), "---\ntags: [habits]\n---\ncarco and garden\n")
        # collision
        write(os.path.join(v, "workers/business-dup.md"), "a\n")
        write(os.path.join(v, "private/workers/business-dup.md"), "b\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_classify(self, *extra):
        r = subprocess.run([CLI, "classify", "--vault", self.v, "--out", self.out, *extra],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.out, "migration-report.csv"), newline="") as f:
            return {row["path"]: row for row in csv.DictReader(f)}


class MigrateTests(Fixture):
    def test_columns(self):
        self.run_classify()
        with open(os.path.join(self.out, "migration-report.csv")) as f:
            self.assertEqual(f.readline().strip(),
                             "path,kind,proposed_area,proposed_project,rule,confidence,dest_path,mixed,notes")

    def test_rules(self):
        rows = self.run_classify()
        r = rows["workers/fm-note.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"], r["rule"], r["confidence"]),
                         ("projects", "budgebell", "frontmatter", "high"))
        r = rows["workers/flow-designer-fix.md"]
        self.assertEqual((r["proposed_project"], r["rule"], r["confidence"]), ("flow-designer", "slug-prefix", "high"))
        self.assertEqual(rows["workers/flow-design-thing.md"]["proposed_project"], "flow-designer")
        self.assertEqual(rows["workers/fix-flow-design-bug.md"]["proposed_project"], "flow-designer")
        self.assertEqual(rows["workers/pawl-release-zzz.md"]["proposed_project"], "agent-pawl")
        r = rows["sessions/2026-10-01 stuff.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"], r["rule"], r["confidence"]),
                         ("projects", "budgebell", "alias", "medium"))
        self.assertEqual(rows["workers/wg.md"]["proposed_project"], "clientco")
        r = rows["knowledge/random.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"], r["rule"], r["confidence"]),
                         ("work", "", "unclassified", "low"))

    def test_today_label(self):
        rows = self.run_classify()
        r = rows["workers/garden.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"], r["rule"], r["confidence"]),
                         ("private", "home", "today-label", "medium"))
        self.assertEqual(r["dest_path"], "private/workers/garden.md")
        r = rows["workers/rel.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"], r["rule"], r["dest_path"]),
                         ("projects", "agent-pawl", "today-label", "workers/rel.md"))
        # worker found through workers/<slug> mention; no label -> unclassified
        self.assertEqual(rows["workers/chase-invoices.md"]["rule"], "unclassified")

    def test_learning_and_private_folder(self):
        rows = self.run_classify()
        r = rows["learning/cv/2026.md"]
        self.assertEqual((r["kind"], r["proposed_area"], r["proposed_project"], r["rule"], r["dest_path"]),
                         ("learning", "private", "learning", "folder", "private/learning/cv/2026.md"))
        r = rows["private/workers/business-dup.md"]
        self.assertEqual((r["kind"], r["proposed_area"], r["proposed_project"], r["rule"], r["dest_path"]),
                         ("workers", "private", "business", "folder", "private/workers/business-dup.md"))

    def test_mixed(self):
        rows = self.run_classify()
        r = rows["diary/2026-10-02.md"]
        self.assertEqual((r["mixed"], r["proposed_area"], r["dest_path"]), ("yes", "work", "diary/2026-10-02.md"))
        self.assertEqual(rows["diary/2026-10-03.md"]["mixed"], "no")
        self.assertEqual(rows["diary/2026-10-04.md"]["mixed"], "no")

    def test_prefix_slug_needles_do_not_cross(self):
        rows = self.run_classify()
        r = rows["workers/foo.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"]), ("private", "home"))
        r = rows["workers/foo-bar.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"]), ("projects", "agent-pawl"))

    def test_mixed_forced_to_work(self):
        rows = self.run_classify()
        r = rows["diary/2026-10-07.md"]
        self.assertEqual((r["mixed"], r["proposed_area"], r["proposed_project"], r["dest_path"]),
                         ("yes", "work", "budgebell", "diary/2026-10-07.md"))

    def test_mixed_private_alias_stays_private_and_flagged(self):
        r = self.run_classify()["diary/2026-10-06.md"]
        self.assertEqual((r["mixed"], r["proposed_area"], r["proposed_project"], r["dest_path"]),
                         ("yes", "private", "learning", "private/diary/2026-10-06.md"))
        self.assertIn("mixed-private", r["notes"])

    def test_mixed_ignores_common_words(self):
        write(os.path.join(self.v, "diary/2026-10-08.md"), "the deploy is running, needs access to the bucket\n")
        write(os.path.join(self.v, "diary/2026-10-09.md"), "clientco call about the learning\n")
        rows = self.run_classify()
        self.assertEqual(rows["diary/2026-10-08.md"]["mixed"], "no")
        self.assertEqual(rows["diary/2026-10-09.md"]["mixed"], "yes")
        self.assertIn("running", bm.MIXED_STOPWORDS)

    def test_vault_registry_missing_seed_rows_are_merged_in_memory(self):
        write(os.path.join(self.v, "00-home/scopes.md"),
              "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n| zed | work | | zed- |\n")
        rows = self.run_classify()
        self.assertEqual(rows["workers/flow-design-thing.md"]["proposed_project"], "flow-designer")

    def test_out_inside_vault_refused(self):
        r = subprocess.run([CLI, "classify", "--vault", self.v, "--out", os.path.join(self.v, "reports")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("inside the vault", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.v, "reports")))

    def test_missing_vault(self):
        r = subprocess.run([CLI, "classify", "--vault", self.v + "-nope", "--out", self.out],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("not found", r.stderr)

    def test_meetings_private_flagged_not_moved(self):
        rows = self.run_classify()
        r = rows["meetings/2026-10-05 learning call.md"]
        self.assertEqual((r["proposed_area"], r["proposed_project"]), ("private", "learning"))
        self.assertEqual(r["dest_path"], r["path"])
        self.assertIn("meetings", r["notes"])

    def test_collision(self):
        rows = self.run_classify()
        r = rows["workers/business-dup.md"]
        self.assertEqual(r["dest_path"], "private/workers/business-dup.md")
        self.assertIn("collision", r["notes"])

    def test_report_md(self):
        self.run_classify()
        with open(os.path.join(self.out, "migration-report.md")) as f:
            md = f.read()
        self.assertIn("unclassified — run the LLM pass (see SKILL/README) before apply", md)
        self.assertIn("workers/garden.md", md)
        self.assertIn("diary/2026-10-02.md", md)

    def test_registry_from_vault_overrides_seed(self):
        write(os.path.join(self.v, "00-home/scopes.md"),
              "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n| zed | work | | zed- |\n")
        write(os.path.join(self.v, "workers/zed-1.md"), "b\n")
        rows = self.run_classify()
        self.assertEqual(rows["workers/zed-1.md"]["proposed_project"], "zed")
        self.assertEqual(rows["workers/flow-design-thing.md"]["proposed_project"], "flow-designer")  # seed merged in
        rows = self.run_classify("--registry-from-seed")
        self.assertEqual(rows["workers/zed-1.md"]["rule"], "unclassified")

    def test_read_only(self):
        before = snapshot(self.v)
        self.run_classify()
        self.assertEqual(before, snapshot(self.v))

    def test_idempotent_after_apply(self):
        rows = self.run_classify()
        v = self.v
        for rel, r in rows.items():
            if "collision" in r["notes"]:
                continue
            src = os.path.join(v, rel)
            with open(src, newline="") as f:
                text = f.read()
            text = bs.set_frontmatter(text, {"area": r["proposed_area"], "project": r["proposed_project"] or "x"})
            dst = os.path.join(v, r["dest_path"])
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            write(dst, text)
            if dst != src:
                os.remove(src)
        rows2 = self.run_classify()
        for rel, r in rows2.items():
            if "collision" in r["notes"]:
                continue
            self.assertEqual(r["dest_path"], r["path"], rel)
            self.assertIn(r["rule"], ("frontmatter", "folder"), rel)


TOM_CONT = TOM + (
    "  - sub bullet of chase\n"
    "- [ ] [personal] **Parent with subs.** x\n"
    "  - sub one\n"
    "    - sub two\n"
    "- [ ] **Work parent.** y\n"
    "  - work sub\n"
    "\n## This week\n- [ ] [personal] **Week goal.** z\n- [ ] work goal\n"
    "\n## Notes\n- [ ] [personal] left alone in other section\n"
)


class ApplyTests(Fixture):
    def setUp(self):
        super().setUp()
        write(os.path.join(self.v, "00-home/top-of-mind.md"), TOM_CONT)
        self.bak = os.path.join(self.tmp, "bak")

    def classify(self):
        return self.run_classify()

    def apply(self, *extra, yes=True):
        args = [CLI, "apply", "--report", os.path.join(self.out, "migration-report.csv"),
                "--vault", self.v, "--backup-dir", self.bak, "--no-qmd"]
        if yes:
            args.append("--yes")
        return subprocess.run(args + list(extra), capture_output=True, text=True)

    def read(self, rel):
        with open(os.path.join(self.v, rel), newline="") as f:
            return f.read()

    def test_requires_yes(self):
        self.classify()
        before = snapshot(self.v)
        r = self.apply(yes=False)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(before, snapshot(self.v))
        self.assertFalse(os.path.exists(self.bak))

    def test_bad_header(self):
        self.classify()
        csvp = os.path.join(self.out, "migration-report.csv")
        with open(csvp) as f:
            t = f.read()
        with open(csvp, "w") as f:
            f.write(t.replace("proposed_area", "area", 1))
        before = snapshot(self.v)
        r = self.apply()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(before, snapshot(self.v))

    def test_apply(self):
        self.classify()
        orig_tom = TOM_CONT
        r = self.apply()
        self.assertEqual(r.returncode, 0, r.stderr)
        tars = [f for f in os.listdir(self.bak) if f.startswith("vault-") and f.endswith(".tar.gz")]
        self.assertEqual(len(tars), 1)
        # private worker moved + tagged
        self.assertFalse(os.path.exists(os.path.join(self.v, "workers/garden.md")))
        t = self.read("private/workers/garden.md")
        self.assertEqual(bs.read_frontmatter(t).get("area"), "private")
        self.assertEqual(bs.read_frontmatter(t).get("project"), "home")
        # learning moved
        self.assertEqual(self.read("private/learning/cv/2026.md").split("\n")[0], "---")
        self.assertFalse(os.path.exists(os.path.join(self.v, "learning/cv/2026.md")))
        # collision untouched
        self.assertEqual(self.read("workers/business-dup.md"), "a\n")
        self.assertEqual(bs.read_frontmatter(self.read("private/workers/business-dup.md")).get("area"), "private")
        # no project key when empty; mixed diary left untouched
        t = self.read("knowledge/random.md")
        self.assertEqual(t, "---\narea: work\n---\nnothing here\n")
        self.assertEqual(self.read("diary/2026-10-02.md"),
                         "Did garden stuff, then carco work.\n")  # mixed work: untouched
        # top-of-mind: remaining == original minus personal lines (with continuations)
        stay = "- [ ] [personal] **Ship pawl release.** details \u2014 Personal project \u2014 agent-pawl \u2014 x\n"
        orig_tom = orig_tom.replace(stay, stay.replace("[personal] ", ""))  # side project: stays, relabelled
        moved = {"- [x] [personal] **Fix the garden gate.** details \u2014 Personal \u2014 me\n",
                 "- [ ] [personal] **Foo thing.** see workers/foo \u2014 Personal \u2014 me\n",
                 "- [ ] [personal] **Parent with subs.** x\n  - sub one\n    - sub two\n",
                 "- [ ] [personal] **Week goal.** z\n"}
        rest = orig_tom
        for blk in moved:
            self.assertIn(blk, rest)
            rest = rest.replace(blk, "", 1)
        self.assertEqual(self.read("00-home/top-of-mind.md"), rest)
        priv = self.read("private/private.md")
        self.assertTrue(priv.startswith("# Private \u2014 top of mind\n"))
        self.assertNotIn("[personal]", priv)
        today, week = priv.split("## This week")
        self.assertIn("- [x] [private] **Fix the garden gate.**", today)
        self.assertNotIn("Ship pawl", priv)
        self.assertIn("- [ ] **Ship pawl release.** details", self.read("00-home/top-of-mind.md"))
        self.assertLess(today.index("garden gate"), today.index("Foo thing"))
        self.assertIn("- [ ] [private] **Parent with subs.** x\n  - sub one\n    - sub two\n", today)
        self.assertIn("[private] **Week goal.**", week)
        self.assertIn("## Previously this week", priv)
        # registries seeded
        self.assertTrue(os.path.isfile(os.path.join(self.v, "00-home/scopes.md")))
        self.assertTrue(os.path.isfile(os.path.join(self.v, "private/scopes.md")))

    def test_second_apply_noop(self):
        self.classify()
        self.assertEqual(self.apply().returncode, 0)
        self.run_classify()
        before = snapshot(self.v)
        r = self.apply()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(before, snapshot(self.v))
        self.assertIn("moved 0, tagged 0", r.stdout)

    def test_dest_appeared_is_refused(self):
        self.classify()
        write(os.path.join(self.v, "private/workers/garden.md"), "other\n")
        r = self.apply()
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("destination exists", r.stderr)
        self.assertEqual(self.read("private/workers/garden.md"), "other\n")
        self.assertTrue(os.path.exists(os.path.join(self.v, "workers/garden.md")))
        self.assertNotIn("area", bs.read_frontmatter(self.read("workers/garden.md")))

    def test_backup_failure_aborts(self):
        self.classify()
        write(self.bak, "i am a file, not a dir")
        before = snapshot(self.v)
        r = self.apply()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(before, snapshot(self.v))

    def test_crlf_top_of_mind(self):
        write(os.path.join(self.v, "00-home/top-of-mind.md"),
              "## Today\r\n- [ ] [personal] **A.** x\r\n  - sub\r\n- [ ] keep\r\n")
        self.classify()
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(self.read("00-home/top-of-mind.md"), "## Today\r\n- [ ] keep\r\n")
        self.assertIn("- [ ] [private] **A.** x\r\n  - sub\r\n", self.read("private/private.md"))


    # ---- fix round 1
    def edit_csv(self, fn):
        csvp = os.path.join(self.out, "migration-report.csv")
        with open(csvp, newline="") as f:
            rows = list(csv.reader(f))
        rows = fn(rows)
        with open(csvp, "w", newline="") as f:
            csv.writer(f).writerows(rows)

    def row(self, rows, path):
        return next(r for r in rows if r[0] == path)

    def test_stale_edit_survives(self):
        self.classify()
        orig = bm.make_backup

        def slow_backup(vault, bdir):
            res = orig(vault, bdir)
            with open(os.path.join(self.v, "workers/garden.md"), "a") as f:
                f.write("late edit by a running worker\n")
            return res
        bm.make_backup = slow_backup
        try:
            ns = type("A", (), dict(report=os.path.join(self.out, "migration-report.csv"), yes=True,
                                    backup_dir=self.bak, no_qmd=True))
            self.assertEqual(bm.apply_main(ns, self.v), 0)
        finally:
            bm.make_backup = orig
        t = self.read("private/workers/garden.md")
        self.assertIn("late edit by a running worker", t)
        self.assertEqual(bs.read_frontmatter(t).get("area"), "private")

    def test_symlinked_vault_backup(self):
        self.classify()
        link = os.path.join(self.tmp, "vaultlink")
        os.symlink(self.v, link)
        args = [CLI, "apply", "--report", os.path.join(self.out, "migration-report.csv"),
                "--vault", link, "--backup-dir", self.bak, "--no-qmd", "--yes"]
        r = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        tar = [f for f in os.listdir(self.bak)][0]
        lst = subprocess.run(["tar", "tzf", os.path.join(self.bak, tar)], capture_output=True, text=True).stdout
        self.assertIn("vault/workers/garden.md", lst)

    def test_backup_names_do_not_clobber(self):
        self.classify()
        self.assertEqual(self.apply().returncode, 0)
        self.classify()
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(len(os.listdir(self.bak)), 2)

    def test_tab_continuation(self):
        write(os.path.join(self.v, "00-home/top-of-mind.md"),
              "## Today\n- [ ] [personal] **A.** x\n\t- tabbed\n- [ ] keep\n")
        self.classify()
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(self.read("00-home/top-of-mind.md"), "## Today\n- [ ] keep\n")
        self.assertIn("**A.** x\n\t- tabbed\n", self.read("private/private.md"))

    def test_bad_rows_exit_2(self):
        self.classify()
        self.edit_csv(lambda rs: [r if r[0] != "knowledge/random.md" else
                                  [r[0], r[1], "bogus"] + r[3:] for r in rs])
        before = snapshot(self.v)
        r = self.apply()
        self.assertEqual(r.returncode, 2)
        self.assertIn("knowledge/random.md", r.stderr)
        self.assertEqual(before, snapshot(self.v))
        self.classify()
        self.edit_csv(lambda rs: rs + [["short", "row"]])
        r = self.apply()
        self.assertEqual(r.returncode, 2)
        self.assertIn("columns", r.stderr)
        self.classify()

        def bad_dest(rs):
            self.row(rs, "knowledge/random.md")[6] = "private/knowledge/random.md"  # area work
            return rs
        self.edit_csv(bad_dest)
        self.assertEqual(self.apply().returncode, 2)
        self.assertEqual(before, snapshot(self.v))

    def _extra_row(self, path, dest, area="private", project="home"):
        self.classify()
        self.edit_csv(lambda rs: rs + [[path, "workers", area, project, "frontmatter", "high", dest, "no", ""]])

    def test_outside_vault_row(self):
        self._extra_row("../outside.md", "private/workers/x.md")
        write(os.path.join(self.tmp, "outside.md"), "o\n")
        r = self.apply()
        self.assertEqual(r.returncode, 1)
        self.assertIn("outside vault", r.stderr)
        self.assertEqual(open(os.path.join(self.tmp, "outside.md")).read(), "o\n")
        self.assertFalse(os.path.exists(os.path.join(self.v, "private/workers/x.md")))
        # other rows still applied
        self.assertTrue(os.path.exists(os.path.join(self.v, "private/workers/garden.md")))

    def test_dry_run_prints_top_of_mind_moves_and_relabels(self):
        self.classify()
        before = snapshot(self.v)
        r = self.apply(yes=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("would move to private.md: - [x] [personal] **Fix the garden gate.**", r.stdout)
        self.assertIn("would relabel (drop [personal], stays): - [ ] [personal] **Ship pawl release.**", r.stdout)
        self.assertNotIn("would move to private.md: - [ ] [personal] **Ship pawl", r.stdout)
        self.assertEqual(before, snapshot(self.v))

    def test_apply_merges_seed_rows_into_existing_registry(self):
        reg = os.path.join(self.v, "00-home/scopes.md")
        mine = "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n| zed | work | | zed- |\n"
        write(reg, mine)
        self.classify()
        r = self.apply()
        self.assertEqual(r.returncode, 0, r.stderr)
        got = self.read("00-home/scopes.md")
        self.assertTrue(got.startswith(mine), got)
        self.assertIn("| flow-designer | work |", got)
        self.assertIn("| agent-pawl | projects |", got)
        self.assertEqual(got.count("| zed |"), 1)
        again = self.apply()
        self.assertEqual(self.read("00-home/scopes.md"), got)
        self.assertNotIn("merged seed rows into 00-home", again.stdout)

    def test_slug_moved_between_registries_is_not_re_added(self):
        seed = os.path.join(self.tmp, "seed")
        shutil.copytree(bm.SEED_DIR, seed)
        hdr = "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n"
        write(os.path.join(seed, "scopes.private.md"), hdr + "| brain | private | | brain- |\n| learning | private | | learning- |\n")
        write(os.path.join(self.v, "00-home/scopes.md"), hdr + "| brain | projects | | brain-, vault- |\n")
        write(os.path.join(self.v, "private/scopes.md"), hdr + "| learning | private | | learning- |\n")
        old = bm.SEED_DIR
        bm.SEED_DIR = seed
        try:
            added = bm.merge_seed_into_vault_registry(self.v, "private/scopes.md", "scopes.private.md")
            self.assertNotIn("brain", added)
            self.assertNotIn("| brain |", self.read("private/scopes.md"))
            shared, private = bm.load_scope_registries(self.v)
        finally:
            bm.SEED_DIR = old
        self.assertEqual([e.area for e in shared if e.project == "brain"], ["projects"])
        self.assertFalse([e for e in private if e.project == "brain"])

    def test_apply_skips_mixed_work_rows_untouched(self):
        self.classify()
        r = self.apply()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read("diary/2026-10-02.md"), "Did garden stuff, then carco work.\n")
        self.assertEqual(self.read("diary/2026-10-07.md"), "---\ntags: [habits]\n---\ncarco and garden\n")

    def test_missing_source_row_and_dry_run_lists(self):
        self._extra_row("workers/ghost.md", "private/workers/ghost.md")
        r = self.apply(yes=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("refused workers/ghost.md: source missing", r.stdout)
        r = self.apply()
        self.assertEqual(r.returncode, 1)
        self.assertIn("source missing", r.stderr)
        self.assertIn("errors 1", r.stdout)

    def test_duplicate_dest(self):
        self.classify()
        write(os.path.join(self.v, "workers/twin.md"), "t\n")
        self.edit_csv(lambda rs: rs + [["workers/twin.md", "workers", "private", "home", "frontmatter",
                                        "high", "private/workers/garden.md", "no", ""]])
        r = self.apply(yes=False)
        self.assertIn("refused workers/twin.md: duplicate destination", r.stdout)
        r = self.apply()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.read("workers/twin.md"), "t\n")
        self.assertIn("area: private", self.read("private/workers/garden.md"))


if __name__ == "__main__":
    unittest.main()
