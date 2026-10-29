import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.dirname(HERE)
sys.path.insert(0, BIN)

import brain_scope as bs  # noqa: E402

CLI = os.path.join(BIN, "brain-scope")

HEADER = "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        f.write(text)


class ScopeTests(unittest.TestCase):
    def test_norm_scope(self):
        for raw in (None, "", "bogus"):
            self.assertEqual(bs.norm_scope(raw), "shared")
        self.assertEqual(bs.norm_scope("ALL"), "all")
        self.assertEqual(bs.norm_scope("private"), "private")

    def test_scope_includes(self):
        self.assertFalse(bs.scope_includes("shared", "private"))
        self.assertTrue(bs.scope_includes("shared", "work"))
        self.assertTrue(bs.scope_includes("shared", "projects"))
        self.assertTrue(bs.scope_includes("private", "work"))
        self.assertTrue(bs.scope_includes("all", "private"))
        self.assertTrue(bs.scope_includes("shared", "weird"))
        self.assertFalse(bs.scope_includes("shared", "Private"))
        self.assertFalse(bs.scope_includes("shared", " PRIVATE "))

    def test_note_dir_today_file_normalise(self):
        self.assertEqual(bs.note_dir(" Private ", "sessions"), "private/sessions")
        self.assertEqual(bs.today_file("Private"), "private/private.md")

    def test_note_dir_today_file(self):
        self.assertEqual(bs.note_dir("private", "workers"), "private/workers")
        self.assertEqual(bs.note_dir("work", "sessions"), "sessions")
        self.assertEqual(bs.note_dir("projects", "diary"), "diary")
        self.assertEqual(bs.today_file("private"), "private/private.md")
        self.assertEqual(bs.today_file("work"), "00-home/top-of-mind.md")
        self.assertEqual(bs.today_file("projects"), "00-home/top-of-mind.md")


class FrontmatterTests(unittest.TestCase):
    def test_read_normal(self):
        t = "---\narea: work\nproject: x\n---\nbody\n"
        self.assertEqual(bs.read_frontmatter(t), {"area": "work", "project": "x"})

    def test_read_none(self):
        self.assertEqual(bs.read_frontmatter("hello\n---\na: b\n---\n"), {})

    def test_read_quotes(self):
        t = "---\na: 'x'\nb: \"y\"\n---\n"
        self.assertEqual(bs.read_frontmatter(t), {"a": "x", "b": "y"})

    def test_read_crlf(self):
        t = "---\r\narea: work\r\nproject: x\r\n---\r\nbody\r\n"
        self.assertEqual(bs.read_frontmatter(t), {"area": "work", "project": "x"})

    def test_read_ignores_body_rule(self):
        t = "---\narea: work\n---\nbody\n---\nfoo: bar\n---\n"
        self.assertEqual(bs.read_frontmatter(t), {"area": "work"})

    def test_read_list_key(self):
        t = "---\ntags:\n  - x\n  - y\narea: work\n---\n"
        self.assertEqual(bs.read_frontmatter(t), {"area": "work"})

    def test_set_replace_in_place(self):
        t = "---\nfoo: 1\narea: work\nbar: 2\n---\nbody\n"
        self.assertEqual(
            bs.set_frontmatter(t, {"area": "private"}),
            "---\nfoo: 1\narea: private\nbar: 2\n---\nbody\n",
        )

    def test_set_append(self):
        t = "---\narea: work\n---\nbody\n"
        self.assertEqual(
            bs.set_frontmatter(t, {"project": "p"}),
            "---\narea: work\nproject: p\n---\nbody\n",
        )

    def test_set_create(self):
        self.assertEqual(
            bs.set_frontmatter("body\n", {"area": "work"}),
            "---\narea: work\n---\nbody\n",
        )

    def test_set_body_preserved(self):
        body = "intro\n---\nrule above\n---\nno trailing newline"
        t = "---\narea: work\n---\n" + body
        out = bs.set_frontmatter(t, {"area": "private", "project": "p"})
        self.assertTrue(out.endswith("---\n" + body))
        self.assertEqual(out.count("area:"), 1)
        self.assertEqual(bs.read_frontmatter(out), {"area": "private", "project": "p"})

    def test_set_crlf(self):
        t = "---\r\narea: work\r\n---\r\nbody\r\n"
        out = bs.set_frontmatter(t, {"area": "private", "project": "p"})
        self.assertEqual(out, "---\r\narea: private\r\nproject: p\r\n---\r\nbody\r\n")
        out2 = bs.set_frontmatter("a\r\nb\r\n", {"area": "work"})
        self.assertEqual(out2, "---\r\narea: work\r\n---\r\na\r\nb\r\n")

    def test_bom_read_and_set_preserved(self):
        t = "\ufeff---\narea: work\n---\nbody\n"
        self.assertEqual(bs.read_frontmatter(t), {"area": "work"})
        self.assertEqual(bs.set_frontmatter(t, {"area": "private", "project": "p"}),
                         "\ufeff---\narea: private\nproject: p\n---\nbody\n")
        self.assertEqual(bs.set_frontmatter("\ufeffbody\n", {"area": "work"}),
                         "\ufeff---\narea: work\n---\nbody\n")

    def test_set_replaces_block_key_and_children(self):
        t = "---\narea:\n  - work\n  - x\nproject: p\ntags:\n- a\n---\nb\n"
        out = bs.set_frontmatter(t, {"area": "private", "tags": "t"})
        self.assertEqual(out, "---\narea: private\nproject: p\ntags: t\n---\nb\n")

    def test_set_does_not_touch_list_key(self):
        t = "---\ntags:\n  - x\n---\nb\n"
        out = bs.set_frontmatter(t, {"area": "work"})
        self.assertEqual(out, "---\ntags:\n  - x\narea: work\n---\nb\n")


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.v = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_find_worker_note(self):
        write(os.path.join(self.v, "workers", "a.md"), "x")
        write(os.path.join(self.v, "private", "workers", "b.md"), "x")
        self.assertEqual(bs.find_worker_note("a", self.v), os.path.join(self.v, "workers", "a.md"))
        self.assertEqual(
            bs.find_worker_note("b", self.v), os.path.join(self.v, "private", "workers", "b.md")
        )
        self.assertIsNone(bs.find_worker_note("c", self.v))

    def test_find_worker_note_no_private(self):
        self.assertIsNone(bs.find_worker_note("zzz", self.v))

    def test_registry(self):
        write(
            os.path.join(self.v, "00-home", "scopes.md"),
            "# Scopes\n\n" + HEADER
            + "| budgebell | projects | bb | budgebell- |\n"
            + "| malformed row without pipes |\n"
            + "| badarea | nope | | x- |\n"
            + "| va | work | | va- |\n"
            + "| flow-designer | work | | flow-designer- |\n",
        )
        write(
            os.path.join(self.v, "private", "scopes.md"),
            HEADER + "| clientco | private | clientco, clientco | clientco-, clientco- |\n",
        )
        reg = bs.load_registry(self.v)
        names = [e.project for e in reg]
        self.assertEqual(names, ["budgebell", "va", "flow-designer", "clientco"])
        e = bs.resolve("clientco", reg)
        self.assertEqual(e.project, "clientco")
        self.assertEqual(e.area, "private")
        self.assertEqual(e.aliases, ["clientco", "clientco"])
        self.assertEqual(e.prefixes, ["clientco-", "clientco-"])
        self.assertEqual(bs.resolve("BUDGEBELL", reg).project, "budgebell")
        self.assertIsNone(bs.resolve("nothing", reg))
        self.assertEqual(bs.resolve_slug("flow-designer-foo", reg).project, "flow-designer")
        self.assertEqual(bs.resolve_slug("va-other", reg).project, "va")
        self.assertIsNone(bs.resolve_slug("zzz", reg))

    def test_registry_private_missing(self):
        write(os.path.join(self.v, "00-home", "scopes.md"), HEADER + "| a | work | | a- |\n")
        self.assertEqual([e.project for e in bs.load_registry(self.v)], ["a"])
        self.assertEqual(bs.load_registry(os.path.join(self.v, "nope")), [])


class CliTests(unittest.TestCase):
    def run_cli(self, *args, env=None):
        e = dict(os.environ)
        e.pop("BRAIN_SCOPE", None)
        e.update(env or {})
        return subprocess.run([CLI] + list(args), capture_output=True, text=True, env=e)

    def test_includes(self):
        self.assertEqual(self.run_cli("includes", "shared", "private").returncode, 1)
        self.assertEqual(self.run_cli("includes", "all", "private").returncode, 0)

    def test_note_dir(self):
        r = self.run_cli("note-dir", "private", "workers")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "private/workers"))

    def test_norm(self):
        self.assertEqual(self.run_cli("norm", "ALL").stdout.strip(), "all")
        self.assertEqual(self.run_cli("norm").stdout.strip(), "shared")
        self.assertEqual(self.run_cli("norm", env={"BRAIN_SCOPE": "private"}).stdout.strip(), "private")

    def test_today_file(self):
        self.assertEqual(self.run_cli("today-file", "private").stdout.strip(), "private/private.md")
        self.assertEqual(self.run_cli("today-file", "work").stdout.strip(), "00-home/top-of-mind.md")

    def test_find_worker_and_field(self):
        with tempfile.TemporaryDirectory() as v:
            p = os.path.join(v, "private", "workers", "w.md")
            write(p, "---\narea: private\n---\nb\n")
            env = {"BRAIN_VAULT": v}
            r = self.run_cli("find-worker", "w", env=env)
            self.assertEqual((r.returncode, r.stdout.strip()), (0, p))
            self.assertEqual(self.run_cli("find-worker", "nope", env=env).returncode, 1)
            self.assertEqual(self.run_cli("field", p, "area").stdout.strip(), "private")
            self.assertEqual(self.run_cli("field", p, "missing").stdout.strip(), "")


MODELS = "models:\n  embed: hf:a\n  generate: hf:b\n  rerank: hf:c\n"
VAULT_COL = "collections:\n  vault:\n    path: /v\n    pattern: \"**/*.md\"\n"


class QmdConfigTests(unittest.TestCase):
    def setup(self, text):
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d, True)
        write(os.path.join(d, "index.yml"), text)
        return d

    def read(self, d, name="index.yml"):
        with open(os.path.join(d, name)) as f:
            return f.read()

    def check(self, text, expect_ignore_lines, preserved=True):
        d = self.setup(text)
        msgs = bs.qmd_config(d, "/v")
        self.assertNotEqual(msgs, ["up to date"])
        got = self.read(d)
        self.assertEqual(got.count("private/**"), 1, got)
        self.assertEqual(got.count("ignore:"), 1, got)
        for ln in expect_ignore_lines:
            self.assertIn(ln, got.splitlines())
        # everything else preserved
        for ln in text.splitlines() if preserved else []:
            self.assertIn(ln, got.splitlines())
        before = got
        self.assertEqual(bs.qmd_config(d, "/v"), ["up to date"])
        self.assertEqual(self.read(d), before)
        return d

    def test_vault_first_models_after(self):
        d = self.check(VAULT_COL + MODELS, ["    ignore:", '      - "private/**"'])
        self.assertTrue(self.read(d).endswith(MODELS))

    def test_models_first(self):
        self.check(MODELS + VAULT_COL, ["    ignore:", '      - "private/**"'])

    def test_extra_keys_and_other_collection(self):
        text = (MODELS + "update:\n  command: x\n" + VAULT_COL
                + "  other:\n    path: /o\n    pattern: \"*.md\"\ncontext:\n  a: b\n")
        d = self.check(text, [])
        got = self.read(d).splitlines()
        i = got.index("    ignore:")
        self.assertEqual(got[i - 1], '    pattern: "**/*.md"')
        self.assertEqual(got[i + 2], "  other:")

    def test_existing_ignore_list_appended(self):
        text = VAULT_COL + "    ignore:\n      - \"archive/**\"\n      - 'tmp/**'\n" + MODELS
        d = self.check(text, ['      - "private/**"'])
        got = self.read(d).splitlines()
        self.assertEqual(got.index('      - "private/**"'), got.index("      - 'tmp/**'") + 1)

    def test_existing_ignore_already_has_private(self):
        text = VAULT_COL + "    ignore:\n      - \"private/**\"\n" + MODELS
        d = self.setup(text)
        self.assertEqual(bs.qmd_config(d, "/v")[0], "created %s" % os.path.join(d, "private.yml"))
        self.assertEqual(self.read(d), text)

    def test_ignore_before_pattern_and_flow_list(self):
        text = "collections:\n  vault:\n    ignore: [\"a/**\"]\n    path: /v\n" + MODELS
        d = self.check(text, ["    ignore:", '      - "a/**"', '      - "private/**"'], preserved=False)
        self.assertIn("    path: /v", self.read(d))

    def test_private_yml_contents_and_not_overwritten(self):
        d = self.setup(VAULT_COL + MODELS)
        bs.qmd_config(d, "/home/x/vault")
        self.assertEqual(
            self.read(d, "private.yml"),
            MODELS + "\ncollections:\n  private:\n    path: /home/x/vault/private\n    pattern: \"**/*.md\"\n",
        )
        custom = "collections:\n  private:\n    path: /elsewhere\n"
        write(os.path.join(d, "private.yml"), custom)
        self.assertEqual(bs.qmd_config(d, "/home/x/vault"), ["up to date"])
        self.assertEqual(self.read(d, "private.yml"), custom)

    def test_private_yml_empty_collections_is_rewritten(self):
        d = self.setup(VAULT_COL + MODELS)
        write(os.path.join(d, "private.yml"), "collections: {}\n")
        msgs = bs.qmd_config(d, "/home/x/vault")
        self.assertIn("added private collection to %s" % os.path.join(d, "private.yml"), msgs)
        want = MODELS + "\ncollections:\n  private:\n    path: /home/x/vault/private\n    pattern: \"**/*.md\"\n"
        self.assertEqual(self.read(d, "private.yml"), want)
        self.assertEqual(bs.qmd_config(d, "/home/x/vault"), ["up to date"])
        self.assertEqual(self.read(d, "private.yml"), want)

    def test_private_yml_models_but_no_collections_keeps_own_models(self):
        d = self.setup(VAULT_COL + MODELS)
        own = "models:\n  embed: hf:own\n"
        write(os.path.join(d, "private.yml"), own + "\ncollections: {}\n")
        bs.qmd_config(d, "/v")
        got = self.read(d, "private.yml")
        self.assertTrue(got.startswith(own), got)
        self.assertIn("  private:\n    path: /v/private", got)
        self.assertNotIn("hf:a", got)
        self.assertEqual(bs.qmd_config(d, "/v"), ["up to date"])

    def test_empty_flow_list_becomes_block(self):
        text = "collections:\n  vault:\n    path: /v\n    ignore: []\n" + MODELS
        self.check(text, ["    ignore:", '      - "private/**"'], preserved=False)

    def test_multiline_flow_list_unsupported_unchanged(self):
        text = "collections:\n  vault:\n    ignore: [\n      \"a/**\",\n    ]\n    path: /v\n" + MODELS
        d = self.setup(text)
        msgs = bs.qmd_config(d, "/v")
        self.assertTrue(msgs[0].startswith("warning: unsupported"), msgs)
        self.assertEqual(self.read(d), text)

    def test_no_vault_key_warns_not_up_to_date(self):
        for text in ('collections:\n  "vault":\n    path: /v\n' + MODELS, "collections: {}\n" + MODELS):
            d = self.setup(text)
            msgs = bs.qmd_config(d, "/v")
            self.assertTrue(msgs[0].startswith("warning") and "NOT excluded" in msgs[0], msgs)
            self.assertNotIn("up to date", msgs)
            self.assertEqual(self.read(d), text)

    def test_comments_not_copied_and_no_tmp_left(self):
        d = self.setup(VAULT_COL + "models:\n  # note\n  embed: hf:a\n")
        bs.qmd_config(d, "/v")
        self.assertNotIn("#", self.read(d, "private.yml"))
        self.assertEqual(sorted(os.listdir(d)), ["index.yml", "private.yml"])

    def test_missing_index_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            msgs = bs.qmd_config(d, "/v")
            self.assertTrue(msgs[0].startswith("warning"))
            self.assertFalse(os.path.exists(os.path.join(d, "private.yml")))

    def test_cli(self):
        d = self.setup(VAULT_COL + MODELS)
        r = subprocess.run([sys.executable, CLI, "qmd-config", d, "/v"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn("qmd config:", r.stdout)


if __name__ == "__main__":
    unittest.main()
