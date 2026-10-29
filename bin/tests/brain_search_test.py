import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.dirname(HERE)
CLI = os.path.join(BIN, "brain-search")

STUB = """#!/usr/bin/env python3
import os, sys
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
key = "STUB_PRIVATE_JSON" if "--index" in sys.argv else "STUB_DEFAULT_JSON"
path = os.environ.get(key)
if not path:
    print("[]"); sys.exit(0)
data = open(path, "rb").read()
if data.strip() == b"EXIT1":
    sys.stderr.write("boom\\n"); sys.exit(1)
sys.stdout.buffer.write(data)
"""

REG = "| project | area | aliases | slug prefixes |\n|---|---|---|---|\n| clientco | projects | clientco | clientco- |\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def hit(file, score, title="t", snippet="snip"):
    return {"docid": "#1", "score": score, "file": file, "line": 1, "title": title, "snippet": snippet}


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.vault = os.path.join(t, "vault")
        self.log = os.path.join(t, "log")
        open(self.log, "w").close()
        self.stub = os.path.join(t, "qmd")
        write(self.stub, STUB)
        os.chmod(self.stub, 0o755)
        write(os.path.join(self.vault, "00-home", "scopes.md"), REG)
        write(os.path.join(self.vault, "knowledge", "a.md"), "---\nproject: clientco\n---\nA\n")
        write(os.path.join(self.vault, "knowledge", "b.md"), "---\nproject: other\n---\nB\n")
        write(os.path.join(self.vault, "knowledge", "c.md"), "---\narea: private\n---\nC\n")
        write(os.path.join(self.vault, "private", "knowledge", "p.md"), "---\narea: private\n---\nP\n")
        self.default_json = os.path.join(t, "d.json")
        self.private_json = os.path.join(t, "p.json")

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, which, hits):
        path = self.default_json if which == "d" else self.private_json
        write(path, hits if isinstance(hits, str) else json.dumps(hits))

    def run_cli(self, *args, scope=None, project=None):
        env = dict(os.environ)
        for k in ("BRAIN_SCOPE", "BRAIN_PROJECT"):
            env.pop(k, None)
        env.update(BRAIN_QMD=self.stub, BRAIN_VAULT=self.vault, STUB_LOG=self.log,
                   STUB_DEFAULT_JSON=self.default_json, STUB_PRIVATE_JSON=self.private_json)
        if scope:
            env["BRAIN_SCOPE"] = scope
        if project:
            env["BRAIN_PROJECT"] = project
        return subprocess.run([sys.executable, CLI] + list(args), env=env,
                              capture_output=True, text=True)

    def calls(self):
        return open(self.log).read().splitlines()

    def test_shared_only_default_index_and_drops_private(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/private/knowledge/p.md", 0.9, "P"),
                       hit("qmd://vault/knowledge/c.md", 0.8, "C")])
        r = self.run_cli("foo", "bar")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertNotIn("--index", self.calls()[0])
        self.assertIn("search foo bar --format json -n 5", self.calls()[0])
        self.assertIn("## A\nknowledge/a.md · score 0.5", r.stdout)
        self.assertNotIn("## P", r.stdout)
        self.assertNotIn("## C", r.stdout)

    def test_all_scope_interleaves_by_rank(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        self.put("p", [hit("qmd://private/knowledge/p.md?index=private", 0.6, "P")])
        r = self.run_cli("--scope", "all", "q")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(any("--index private" in c for c in self.calls()))
        order = [l for l in r.stdout.splitlines() if l.startswith("## ")]
        self.assertEqual(order, ["## A", "## P", "## B"])
        self.assertIn("private/knowledge/p.md", r.stdout)

    def test_all_scope_low_private_scores_not_starved(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.8, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        self.put("p", [hit("qmd://private/knowledge/p.md?index=private", 0.0, "P")])
        r = self.run_cli("--scope", "all", "-n", "2", "q")
        self.assertEqual(r.returncode, 0, r.stderr)
        order = [l for l in r.stdout.splitlines() if l.startswith("## ")]
        self.assertEqual(order, ["## A", "## P"])

    def test_env_scope_and_limit(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        r = self.run_cli("-n", "1", "q", scope="all")
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(r.stdout.count("## "), 1)

    def test_project_filter_and_alias(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        for p in ("clientco", "clientco"):
            open(self.log, "w").close()
            r = self.run_cli("--project", p, "q")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("## A", r.stdout)
            self.assertNotIn("## B", r.stdout)
            self.assertIn("-n 25", self.calls()[0])

    def test_empty_project_disables_filter(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        r = self.run_cli("--project", "", "q", project="clientco")
        self.assertIn("## A", r.stdout)
        self.assertIn("## B", r.stdout)
        self.assertIn("-n 5", self.calls()[0])

    def test_env_project_filters(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A"),
                       hit("qmd://vault/knowledge/b.md", 0.7, "B")])
        r = self.run_cli("q", project="clientco")
        self.assertIn("## A", r.stdout)
        self.assertNotIn("## B", r.stdout)

    def test_private_index_failure_still_prints_default(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A")])
        self.put("p", "EXIT1")
        r = self.run_cli("--scope", "all", "q")
        self.assertEqual(r.returncode, 0)
        self.assertIn("## A", r.stdout)
        self.assertTrue(r.stderr.strip())
        self.assertNotIn("Traceback", r.stderr)

    def test_garbage_output(self):
        self.put("d", "garbage")
        r = self.run_cli("q")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertNotIn("Traceback", r.stderr)

    def test_invalid_utf8_output(self):
        with open(self.default_json, "wb") as f:
            f.write(b"\xff\xfe[]")
        r = self.run_cli("q")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertNotIn("Traceback", r.stderr)
        self.assertTrue(r.stderr.strip())

    def run_resolve(self, home_stubs=(), brain_qmd=None):
        """Run with a temp HOME and a PATH holding only python3 (no real qmd)."""
        t = self.tmp.name
        home = os.path.join(t, "home")
        pybin = os.path.join(t, "pybin")
        os.makedirs(pybin, exist_ok=True)
        if not os.path.exists(os.path.join(pybin, "python3")):
            os.symlink(sys.executable, os.path.join(pybin, "python3"))
        for rel in home_stubs:
            p = os.path.join(home, rel)
            write(p, STUB.replace('f.write(" ".join', 'f.write("%s " + " ".join' % rel))
            os.chmod(p, 0o755)
        env = {"HOME": home, "PATH": pybin, "BRAIN_VAULT": self.vault, "STUB_LOG": self.log}
        if brain_qmd:
            env["BRAIN_QMD"] = brain_qmd
        return subprocess.run([sys.executable, CLI, "q"], env=env, capture_output=True, text=True)

    def test_resolves_nodenv_shim(self):
        r = self.run_resolve([".nodenv/shims/qmd"])
        self.assertEqual(r.returncode, 0)
        self.assertEqual([c.split()[0] for c in self.calls()], [".nodenv/shims/qmd"])
        self.assertNotIn("not found", r.stderr)

    def test_resolves_local_bin(self):
        r = self.run_resolve([".local/bin/qmd"])
        self.assertEqual(r.returncode, 0)
        self.assertEqual([c.split()[0] for c in self.calls()], [".local/bin/qmd"])

    def test_nodenv_preferred_over_local_bin(self):
        self.run_resolve([".nodenv/shims/qmd", ".local/bin/qmd"])
        self.assertEqual([c.split()[0] for c in self.calls()], [".nodenv/shims/qmd"])

    def test_brain_qmd_wins_over_home_candidates(self):
        r = self.run_resolve([".nodenv/shims/qmd", ".local/bin/qmd"], brain_qmd=self.stub)
        self.assertEqual(r.returncode, 0)
        # self.stub is the plain STUB (no tag prefix): first token is an arg, not a home path
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("search"), calls)

    def test_nothing_available_warns_rc0(self):
        r = self.run_resolve()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertIn("qmd not found", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_binary(self):
        r = self.run_resolve(brain_qmd="/nonexistent/qmd")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertNotIn("Traceback", r.stderr)

    def test_deleted_file(self):
        self.put("d", [hit("qmd://vault/knowledge/gone.md", 0.9, "Gone"),
                       hit("qmd://vault/knowledge/a.md", 0.5, "A")])
        r = self.run_cli("--project", "clientco", "q")
        self.assertNotIn("## Gone", r.stdout)
        self.assertIn("## A", r.stdout)
        r = self.run_cli("q")  # shared scope: dropped
        self.assertNotIn("## Gone", r.stdout)
        self.assertIn("## A", r.stdout)
        r = self.run_cli("q", scope="all")  # private-including scope: kept
        self.assertIn("## Gone", r.stdout)

    def test_private_index_uri_suffix_stripped_and_project_filtered(self):
        write(os.path.join(self.vault, "private", "knowledge", "q.md"),
              "---\narea: private\nproject: clientco\n---\nQ\n")
        self.put("d", [])
        self.put("p", [hit("qmd://private/knowledge/p.md?index=private", 0.6, "P"),
                       hit("qmd://private/knowledge/q.md?index=private", 0.5, "Q")])
        r = self.run_cli("--scope", "all", "--project", "clientco", "q")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("## Q", r.stdout)
        self.assertIn("private/knowledge/q.md ", r.stdout)
        self.assertNotIn("index=private", r.stdout)
        self.assertNotIn("## P", r.stdout)  # project: missing -> filtered
        r = self.run_cli("--scope", "all", "--json", "q")
        self.assertEqual(sorted(h["path"] for h in json.loads(r.stdout)),
                         ["private/knowledge/p.md", "private/knowledge/q.md"])

    def test_json_output(self):
        self.put("d", [hit("qmd://vault/knowledge/a.md", 0.5, "A")])
        r = self.run_cli("--json", "q")
        data = json.loads(r.stdout)
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["title"], "A")
        self.assertEqual(data[0]["path"], "knowledge/a.md")


if __name__ == "__main__":
    unittest.main()
