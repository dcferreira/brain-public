"""brain-migrate-scope: read-only classifier proposing area/project for vault notes.
Stdlib only, py3.9."""
from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Dict, List, Optional, Tuple

from brain_scope import (
    AREAS, Entry, _KEY_RE, _parse_registry, _split_block, _unquote,
    read_frontmatter, resolve, resolve_slug, set_frontmatter, vault_root,
)

SEED_DIR = os.path.join(os.path.dirname(os.path.realpath(__file__)), "seed")
SCAN_DIRS = ("workers", "sessions", "knowledge", "meetings", "diary", "inbox", "learning")
MOVABLE = ("workers", "sessions", "knowledge", "diary")
MIXABLE = ("diary", "sessions", "meetings", "inbox")
COLUMNS = ["path", "kind", "proposed_area", "proposed_project", "rule", "confidence",
           "dest_path", "mixed", "notes"]
TODAY_FILES = ("00-home/top-of-mind.md", "private/private.md")
_BOLD_RE = re.compile(r"\*\*(.+?)\*\*")


def _seed_rows(seed_name: str) -> List[Tuple[str, str]]:
    """(project, raw table line) for each data row of a seed registry."""
    valid = {e.project for e in _parse_registry(os.path.join(SEED_DIR, seed_name))}
    out: List[Tuple[str, str]] = []
    try:
        with open(os.path.join(SEED_DIR, seed_name), encoding="utf-8") as f:
            for l in f.read().splitlines():
                cell = l.strip().strip("|").split("|")[0].strip() if l.strip().startswith("|") else ""
                if cell in valid:
                    out.append((cell, l))
    except OSError:
        pass
    return out


_REGISTRIES = (("00-home/scopes.md", "scopes.shared.md"), ("private/scopes.md", "scopes.private.md"))


def _known_projects(vault: str, seed_name: str) -> set:
    """Slugs that block merging a `seed_name` row: any slug in either vault registry file
    or in the other seed."""
    known = set()
    for vault_rel, sn in _REGISTRIES:
        known |= {e.project.lower() for e in _parse_registry(os.path.join(vault, vault_rel))}
        if sn != seed_name:
            known |= {e.project.lower() for e in _parse_registry(os.path.join(SEED_DIR, sn))}
    return known


def load_scope_registries(vault: str, from_seed: bool = False) -> Tuple[List[Entry], List[Entry]]:
    """(shared entries, private entries). Each file comes from the vault if present, else the
    seed; seed rows whose project is missing from an existing vault file are merged in."""
    vault_known = set()
    for rel, _ in _REGISTRIES:
        vault_known |= {e.project.lower() for e in _parse_registry(os.path.join(vault, rel))}

    def one(vault_rel: str, seed_name: str) -> List[Entry]:
        # slugs held by the OTHER registry's vault file, and by the other seed
        own = {e.project.lower() for e in _parse_registry(os.path.join(vault, vault_rel))}
        other_seed = {e.project.lower() for r, sn in _REGISTRIES if sn != seed_name
                      for e in _parse_registry(os.path.join(SEED_DIR, sn))}
        other_known = (vault_known - own) | other_seed
        seed = _parse_registry(os.path.join(SEED_DIR, seed_name))
        p = os.path.join(vault, vault_rel)
        if from_seed or not os.path.isfile(p):
            return seed
        have = _parse_registry(p)
        # a slug living in EITHER registry (vault files or seeds) is never re-added here
        known = {e.project.lower() for e in have} | other_known
        return have + [e for e in seed if e.project.lower() not in known]
    return one("00-home/scopes.md", "scopes.shared.md"), one("private/scopes.md", "scopes.private.md")


def merge_seed_into_vault_registry(vault: str, vault_rel: str, seed_name: str) -> List[str]:
    """Append seed rows missing from an existing vault registry (existing rows untouched).
    Returns the project slugs added."""
    p = os.path.join(vault, vault_rel)
    text = _read(p)
    known = _known_projects(vault, seed_name)
    add = [(proj, l) for proj, l in _seed_rows(seed_name) if proj.lower() not in known]
    if not add:
        return []
    nl = "\r\n" if "\r\n" in text else "\n"
    if text and not text.endswith("\n"):
        text += nl
    if not any(l.strip().startswith("|") for l in text.splitlines()):
        text += nl + "| project | area | aliases | slug prefixes |" + nl + "|---|---|---|---|" + nl
    text += "".join(l + nl for _, l in add)
    _write(p, text)
    return [proj for proj, _ in add]


def read_list_field(text: str, key: str) -> List[str]:
    """Values of a frontmatter key given as scalar, inline [a, b], or '- x' block list."""
    blk = _split_block(text)
    if not blk:
        return []
    lines, end = blk
    vals: List[str] = []
    i = 1
    while i < end:
        m = _KEY_RE.match(lines[i].rstrip("\r\n"))
        i += 1
        if not m or m.group(1) != key:
            continue
        rest = m.group(2).strip()
        if rest:
            if rest.startswith("[") and rest.endswith("]"):
                rest = rest[1:-1]
            vals += [_unquote(x) for x in rest.split(",") if x.strip()]
        else:
            while i < end:
                s = lines[i].strip()
                if not s.startswith("-"):
                    break
                vals.append(_unquote(s[1:]))
                i += 1
    return [v.lstrip("#") for v in vals if v]


def body_of(text: str) -> str:
    blk = _split_block(text)
    if not blk:
        return text
    lines, end = blk
    return "".join(lines[end + 1:])


# Common English words that are also registry slugs/aliases; too ambiguous for mixed detection.
MIXED_STOPWORDS = frozenset({
    "running", "fitness", "health", "business", "finance", "access", "acme",
    "pulse", "home", "vault",
})


def _term_regex(entries: List[Entry]):
    """Mixed-detection terms: project slugs plus aliases that contain a space or are >= 6
    characters long; anything on MIXED_STOPWORDS is excluded."""
    terms = set()
    for e in entries:
        terms.add(e.project.lower())
        terms.update(a.lower() for a in e.aliases if " " in a.strip() or len(a.strip()) >= 6)
    terms = sorted((t for t in terms if t and t not in MIXED_STOPWORDS), key=len, reverse=True)
    if not terms:
        return None
    return re.compile(r"(?<![\w-])(?:%s)(?![\w-])" % "|".join(re.escape(t) for t in terms))


class Classifier:
    def __init__(self, vault: str, from_seed: bool = False):
        self.vault = vault
        self.shared, self.private = load_scope_registries(vault, from_seed)
        self.registry = self.shared + self.private
        self.shared_re = _term_regex([e for e in self.registry if e.area != "private"])
        self.private_re = _term_regex([e for e in self.registry if e.area == "private"])
        self.today_lines: List[str] = []
        for rel in TODAY_FILES:
            try:
                with open(os.path.join(vault, rel), encoding="utf-8", errors="replace") as f:
                    self.today_lines += [l for l in f.read().splitlines() if l.strip()]
            except OSError:
                pass

    # ---- rule helpers
    def _today_line(self, slug: str, fm: Dict[str, str]) -> Optional[str]:
        needles = ["workers/" + slug, "brain-worker-" + slug]
        m = _BOLD_RE.search(fm.get("today_action", ""))
        if m:
            needles.append("**" + m.group(1) + "**")
        pats = [re.compile(r"(?<![\w-])" + re.escape(n) + r"(?![\w-])") for n in needles[:2]]
        for line in self.today_lines:
            if any(p.search(line) for p in pats) or (len(needles) > 2 and needles[2] in line):
                return line
        return None

    def _from_today(self, line: str) -> Optional[Entry]:
        """Returns an Entry (or a synthetic private/home entry) or None."""
        segs = [s.strip() for s in line.split(" — ")]
        cand = None
        for s in segs[1:]:
            cand = resolve(s, self.registry)
            if cand:
                break
        low = line.lower()
        if "personal project" in low:
            for i, s in enumerate(segs):
                if s.lower().startswith("personal project") and i + 1 < len(segs):
                    e = resolve(segs[i + 1], self.registry)
                    if e:
                        return e
        if "[personal]" in low:
            if cand and cand.area == "private":
                return cand
            return Entry("home", "private")
        return None

    def classify(self, rel: str) -> Dict[str, str]:
        parts = rel.split("/")
        under_private = parts[0] == "private"
        top = parts[1] if under_private and len(parts) > 2 else parts[0]
        kind = top
        stem = os.path.splitext(parts[-1])[0]
        try:
            with open(os.path.join(self.vault, rel), encoding="utf-8", errors="replace", newline="") as f:
                text = f.read()
        except OSError:
            text = ""
        fm = read_frontmatter(text)
        notes: List[str] = []

        def later_rules() -> Optional[Tuple[Entry, str, str]]:
            e = resolve_slug(stem, self.registry)
            if e:
                return e, "slug-prefix", "high"
            vals = read_list_field(text, "tags") + [fm.get(k, "") for k in ("week_goal", "customer", "project")]
            for v in vals:
                e = resolve(v, self.registry) if v else None
                if e:
                    return e, "alias", "medium"
            if kind == "workers":
                line = self._today_line(stem, fm)
                if line:
                    e = self._from_today(line)
                    if e:
                        return e, "today-label", "medium"
            return None

        area, project, rule, conf = "work", "", "unclassified", "low"
        fixed = False  # rule 1/2: mixed detection does not override
        if fm.get("area", "").lower() in AREAS:
            area, project, rule, conf, fixed = fm["area"].lower(), fm.get("project", ""), "frontmatter", "high", True
        elif kind == "learning" or under_private:
            area, rule, conf, fixed = "private", "folder", "high", True
            if kind == "learning":
                project = "learning"
            else:
                hit = later_rules()
                if hit and hit[0].area == "private":
                    project = hit[0].project
        else:
            hit = later_rules()
            if hit:
                e, rule, conf = hit
                area, project = e.area, e.project

        mixed = "no"
        mixed_private = False
        if kind in MIXABLE:
            body = body_of(text).lower()
            if (self.private_re and self.shared_re and self.private_re.search(body)
                    and self.shared_re.search(body)):
                mixed = "yes"
                notes.append("mixed")
                if not fixed:
                    if rule == "alias" and area == "private":
                        mixed_private = True  # tag/week_goal says private: keep, flag for review
                        notes.append("mixed-private")
                    else:
                        area = "work"

        # destination
        dest = rel
        if (mixed == "no" or mixed_private) and not under_private and area == "private":
            if kind in MOVABLE:
                dest = "private/" + rel
            elif kind == "learning":
                dest = "private/" + rel
            elif kind in ("meetings", "inbox"):
                notes.append("private item in %s: move by hand" % kind)
        if dest != rel and os.path.exists(os.path.join(self.vault, dest)):
            notes.append("collision")
        return {"path": rel, "kind": kind, "proposed_area": area, "proposed_project": project,
                "rule": rule, "confidence": conf, "dest_path": dest, "mixed": mixed,
                "notes": "; ".join(notes)}

    def scan(self) -> List[str]:
        out: List[str] = []
        roots = list(SCAN_DIRS) + ["private"]
        for r in roots:
            base = os.path.join(self.vault, r)
            for dp, dns, fns in os.walk(base):
                dns[:] = sorted(d for d in dns if not d.startswith("."))
                for fn in fns:
                    if not fn.endswith(".md") or fn.startswith("."):
                        continue
                    rel = os.path.relpath(os.path.join(dp, fn), self.vault).replace(os.sep, "/")
                    if r == "private" and rel.count("/") < 2:
                        continue  # private/private.md, private/scopes.md
                    out.append(rel)
        return sorted(out)


def write_report(rows: List[Dict[str, str]], out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "migration-report.csv"), "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)

    def table(rs):
        return ["| path | area | project | rule | conf | dest | notes |", "|---|---|---|---|---|---|---|"] + [
            "| %s | %s | %s | %s | %s | %s | %s |" % (
                r["path"], r["proposed_area"], r["proposed_project"] or "-", r["rule"],
                r["confidence"], r["dest_path"], r["notes"]) for r in rs]

    counts: Dict[Tuple[str, str], int] = {}
    for r in rows:
        k = (r["proposed_area"], r["proposed_project"] or "-")
        counts[k] = counts.get(k, 0) + 1
    unclassified = sum(1 for r in rows if r["rule"] == "unclassified")
    md = ["# Migration report", "", "%d notes scanned." % len(rows),
          "%d unclassified — run the LLM pass (see SKILL/README) before apply." % unclassified, "",
          "## Counts by area and project", "", "| area | project | notes |", "|---|---|---|"]
    md += ["| %s | %s | %d |" % (a, p, n) for (a, p), n in sorted(counts.items())]
    sections = [
        ("Moves (dest_path changes)", [r for r in rows if r["dest_path"] != r["path"]]),
        ("Low or medium confidence", [r for r in rows if r["confidence"] in ("low", "medium")]),
        ("Mixed notes (stay put)", [r for r in rows if r["mixed"] == "yes"]),
        ("Private notes in meetings/inbox (move by hand)",
         [r for r in rows if r["kind"] in ("meetings", "inbox") and r["proposed_area"] == "private"]),
    ]
    for title, rs in sections:
        md += ["", "## %s (%d)" % (title, len(rs)), ""] + (table(rs) if rs else ["None."])
    with open(os.path.join(out_dir, "migration-report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")


SPLIT_HEADINGS = ("## Today", "## This week", "## Previously this week")
TOM_REL = "00-home/top-of-mind.md"
PRIVATE_REL = "private/private.md"


def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def _write(path: str, text: str) -> None:
    """Atomic: temp file in the same directory, then os.replace."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".brain-migrate-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write(text)
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_rows(report: str) -> Tuple[List[Dict[str, str]], List[str]]:
    """(rows, problems). Raises ValueError if the header is not exactly COLUMNS."""
    rows: List[Dict[str, str]] = []
    problems: List[str] = []
    with open(report, encoding="utf-8", newline="") as f:
        r = csv.reader(f)
        header = next(r, None)
        if header != COLUMNS:
            raise ValueError("report header must be exactly: %s" % ",".join(COLUMNS))
        for row in r:
            if not row:
                continue
            if len(row) != len(COLUMNS):
                problems.append("line %d: expected %d columns, got %d" % (r.line_num, len(COLUMNS), len(row)))
                continue
            d = dict(zip(COLUMNS, row))
            problems += ["%s: %s" % (d["path"], m) for m in validate_row(d)]
            rows.append(d)
    return rows, problems


def validate_row(row: Dict[str, str]) -> List[str]:
    out: List[str] = []
    area, path, dest = row["proposed_area"], row["path"], row["dest_path"]
    if area not in AREAS:
        out.append("proposed_area %r is not one of %s" % (area, "/".join(AREAS)))
        return out
    if dest != path and not (area == "private" and dest.startswith("private/")):
        out.append("moves to %s but area is %s (only private-area notes move, into private/)" % (dest, area))
    if dest.startswith("private/") and area != "private":
        out.append("dest under private/ but area is %s" % area)
    return out


def _inside(vault: str, rel: str) -> Optional[str]:
    p = os.path.normpath(os.path.join(vault, rel))
    root = os.path.normpath(vault)
    if os.path.isabs(rel) or not (p == root or p.startswith(root + os.sep)):
        return None
    return p


def row_updates(row: Dict[str, str]) -> Dict[str, str]:
    upd = {"area": row["proposed_area"]}
    if row["proposed_project"]:
        upd["project"] = row["proposed_project"]
    return upd


def plan_row(vault: str, row: Dict[str, str], seen_dests: set) -> str:
    """'skip', 'noop', 'change' or 'error:<why>'."""
    if "collision" in row["notes"]:
        return "skip"
    if row["mixed"] == "yes" and row["proposed_area"] == "work":
        return "skip"  # mixed work: leave untouched so a later classify can still re-decide
    src, dst = _inside(vault, row["path"]), _inside(vault, row["dest_path"])
    if not src or not dst:
        return "error:path outside vault"
    if not os.path.isfile(src):
        return "error:source missing"
    if dst != src:
        if dst in seen_dests:
            return "error:duplicate destination"
        if os.path.lexists(dst):
            return "error:destination exists"
    try:
        old = _read(src)
    except OSError as e:
        return "error:unreadable (%s)" % e
    if set_frontmatter(old, row_updates(row)) == old and dst == src:
        return "noop"
    if dst != src:
        seen_dests.add(dst)
    return "change"


def _side_project(line: str, registry: List[Entry]) -> Optional[Entry]:
    """Work/projects registry entry named by a `Personal project — X` (or `— X —`) label."""
    segs = [x.strip() for x in line.split(" \u2014 ")]
    for i, seg in enumerate(segs[1:], 1):
        after_label = segs[i - 1].lower().startswith("personal project")
        cands = [seg] + (seg.split()[:1] if after_label else [])
        if seg.lower().startswith("personal project"):
            continue
        for c in cands:
            e = resolve(c, registry)
            if e and e.area in ("work", "projects"):
                return e
    return None


def plan_top_of_mind(vault: str):
    """(lines, keep, moved, moved_lines, relabelled, n). Lines under the split headings that carry
    [personal] either move to private.md as [private] or, when a side-project label resolves to a
    work/projects entry, stay with the [personal] marker removed."""
    tom = os.path.join(vault, TOM_REL)
    if not os.path.isfile(tom):
        return None
    registry = sum(load_scope_registries(vault), [])
    lines = _read(tom).splitlines(keepends=True)
    keep: List[str] = []
    moved: Dict[str, List[str]] = {}
    moved_lines: List[str] = []
    relabelled: List[str] = []
    heading = None
    i = 0
    n = 0
    while i < len(lines):
        ln = lines[i]
        bare = ln.rstrip("\r\n")
        if bare.startswith("## "):
            heading = bare.rstrip() if bare.rstrip() in SPLIT_HEADINGS else None
        if heading and bare.startswith("- [") and "[personal]" in bare:
            if _side_project(bare, registry):
                relabelled.append(bare)
                new = ln.replace("[personal] ", "", 1) if "[personal] " in ln else ln.replace("[personal]", "", 1)
                keep.append(new)
                i += 1
                continue
            blk = [ln.replace("[personal]", "[private]", 1)]
            moved_lines.append(bare)
            i += 1
            while i < len(lines) and re.match(r"^(?: {2,}|\t)\s*\S", lines[i]):
                blk.append(lines[i])
                i += 1
            moved.setdefault(heading, []).extend(blk)
            n += 1
            continue
        keep.append(ln)
        i += 1
    return lines, keep, moved, moved_lines, relabelled, n


def split_top_of_mind(vault: str) -> int:
    """Move [personal] action lines (plus indented continuations) to private/private.md;
    side-project lines stay, minus the [personal] marker. Returns lines moved."""
    tom = os.path.join(vault, TOM_REL)
    plan = plan_top_of_mind(vault)
    if plan is None:
        return 0
    lines, keep, moved, _, relabelled, n = plan
    if not n and not relabelled:
        return 0
    if not n:
        _write(tom, "".join(keep))
        return 0
    nl = "\r\n" if any(l.endswith("\r\n") for l in lines) else "\n"

    def fix_eol(b: List[str]) -> List[str]:
        return [l if l.endswith("\n") else l + nl for l in b]

    priv = os.path.join(vault, PRIVATE_REL)
    os.makedirs(os.path.dirname(priv), exist_ok=True)
    if os.path.isfile(priv):
        plines = _read(priv).splitlines(keepends=True)
    else:
        plines = ["# Private \u2014 top of mind" + nl] + sum(
            ([nl, h + nl] for h in SPLIT_HEADINGS), [])
    for h in SPLIT_HEADINGS:
        if h not in moved:
            continue
        add = fix_eol(moved[h])
        idx = next((k for k, l in enumerate(plines) if l.rstrip() == h), None)
        if idx is None:
            if plines and not plines[-1].endswith("\n"):
                plines[-1] += nl
            plines += [nl, h + nl] + add
            continue
        end = idx + 1
        while end < len(plines) and not plines[end].startswith("## "):
            end += 1
        while end - 1 > idx and not plines[end - 1].strip():
            end -= 1
        if end > 0 and not plines[end - 1].endswith("\n"):
            plines[end - 1] += nl
        plines[end:end] = add
    _write(priv, "".join(plines))
    _write(tom, "".join(keep))
    return n


def _unique_tarball(bdir: str) -> str:
    base = os.path.join(bdir, "vault-%s" % time.strftime("%Y%m%d-%H%M%S"))
    cand, n = base + ".tar.gz", 1
    while os.path.lexists(cand):
        n += 1
        cand = "%s-%d.tar.gz" % (base, n)
    return cand


def make_backup(vault: str, bdir: str) -> Tuple[Optional[str], str]:
    """Snapshot the vault (symlinks resolved) and verify it. (path, error)."""
    real = os.path.realpath(vault)
    try:
        os.makedirs(bdir, exist_ok=True)
        tarball = _unique_tarball(bdir)
        r = subprocess.run(["tar", "czf", tarball, "-C", os.path.dirname(real), os.path.basename(real)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None, r.stderr.strip() or "tar exited %d" % r.returncode
        r = subprocess.run(["tar", "tzf", tarball], capture_output=True, text=True)
        if r.returncode != 0 or not any(l.endswith(".md") for l in r.stdout.splitlines()):
            return None, "archive %s verification failed (no .md files listed)" % tarball
        return tarball, ""
    except (OSError, subprocess.SubprocessError) as e:
        return None, str(e)


def apply_main(a, vault: str) -> int:
    try:
        rows, problems = read_rows(a.report)
    except (OSError, ValueError, UnicodeDecodeError) as e:
        sys.stderr.write("brain-migrate-scope: bad report: %s\n" % e)
        return 2
    if problems:
        sys.stderr.write("brain-migrate-scope: invalid report rows, nothing written:\n")
        for pr in problems:
            sys.stderr.write("  %s\n" % pr)
        return 2
    seen: set = set()
    plans = [(r, plan_row(vault, r, seen)) for r in rows]
    n_change = sum(1 for _, act in plans if act == "change")
    n_move = sum(1 for r, act in plans if act == "change" and r["dest_path"] != r["path"])
    n_skip = sum(1 for _, act in plans if act != "change")
    refused = [(r, act[6:]) for r, act in plans if act.startswith("error:")]
    if not a.yes:
        print("would tag/move %d notes (%d moves), skip %d (%d refused). Re-run with --yes to apply."
              % (n_change, n_move, n_skip, len(refused)))
        for r, why in refused:
            print("refused %s: %s" % (r["path"], why))
        plan = plan_top_of_mind(vault)
        if plan:
            for l in plan[3]:
                print("top-of-mind: would move to private.md: %s" % l)
            for l in plan[4]:
                print("top-of-mind: would relabel (drop [personal], stays): %s" % l)
        return 3
    bdir = os.path.expanduser(a.backup_dir or "~/Obsidian/backups")
    tarball, err = make_backup(vault, bdir)
    if not tarball:
        sys.stderr.write("brain-migrate-scope: backup failed, aborting: %s\n" % err)
        return 1
    print("backup: %s" % tarball)
    tagged = moved = skipped = errors = 0
    for row, act in plans:
        if act != "change":
            skipped += 1
            if act.startswith("error:"):
                errors += 1
                sys.stderr.write("skip %s: %s\n" % (row["path"], act[6:]))
            continue
        src, dst = os.path.join(vault, row["path"]), os.path.join(vault, row["dest_path"])
        try:
            cur = _read(src)  # re-read: the note may have changed since planning
            new = set_frontmatter(cur, row_updates(row))
            if new != cur:
                _write(src, new)
                tagged += 1
            if dst != src:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.link(src, dst)  # raises if dst exists
                os.unlink(src)
                moved += 1
        except OSError as e:
            errors += 1
            skipped += 1
            sys.stderr.write("error %s: %s\n" % (row["path"], e))
    personal = 0
    try:
        personal = split_top_of_mind(vault)
        for rel, seed in (("00-home/scopes.md", "scopes.shared.md"), ("private/scopes.md", "scopes.private.md")):
            dst = os.path.join(vault, rel)
            if not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(SEED_DIR, seed), dst)
                print("seeded %s" % rel)
            else:
                added = merge_seed_into_vault_registry(vault, rel, seed)
                if added:
                    print("merged seed rows into %s: %s" % (rel, ", ".join(added)))
    except OSError as e:
        errors += 1
        sys.stderr.write("error top-of-mind/registries: %s\n" % e)
    if not a.no_qmd:
        for cmd in (["qmd", "update"], ["qmd", "--index", "private", "update"]):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    sys.stderr.write("%s failed (%d): %s\n" % (" ".join(cmd), r.returncode, r.stderr.strip()))
            except OSError as e:
                sys.stderr.write("%s failed: %s\n" % (" ".join(cmd), e))
    print("moved %d, tagged %d, skipped %d, errors %d, top-of-mind lines moved %d"
          % (moved, tagged, skipped, errors, personal))
    return 1 if errors else 0


def cli_main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog="brain-migrate-scope")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("classify", help="read-only: propose area/project for every note")
    c.add_argument("--vault", default=None)
    c.add_argument("--registry-from-seed", action="store_true")
    c.add_argument("--out", required=True)
    ap_ = sub.add_parser("apply", help="apply a reviewed report: snapshot, tag, move, split top-of-mind")
    ap_.add_argument("--report", required=True)
    ap_.add_argument("--vault", default=None)
    ap_.add_argument("--backup-dir", default=None)
    ap_.add_argument("--no-qmd", action="store_true")
    ap_.add_argument("--yes", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return int(e.code or 0)
    vault = os.path.expanduser(a.vault) if a.vault else vault_root()
    if not os.path.isdir(vault):
        sys.stderr.write("brain-migrate-scope: vault not found: %s\n" % vault)
        return 2
    if a.cmd == "apply":
        return apply_main(a, vault)
    real_v, real_o = os.path.realpath(vault), os.path.realpath(os.path.expanduser(a.out))
    if real_o == real_v or real_o.startswith(real_v + os.sep):
        sys.stderr.write("brain-migrate-scope: --out %s is inside the vault; the report lists private "
                         "paths and would be indexed into the shared index. Use a directory outside it.\n" % a.out)
        return 2
    cl = Classifier(vault, a.registry_from_seed)
    rows = [cl.classify(rel) for rel in cl.scan()]
    write_report(rows, a.out)
    print("classified %d notes -> %s" % (len(rows), a.out))
    return 0
