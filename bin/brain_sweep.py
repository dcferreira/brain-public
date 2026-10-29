"""brain-sweep: move done Today items into Previously this week, and archive old or
oversized Previously entries into planning/YYYY-Www.md. Stdlib only, py3.9.

Touches only the `## Today` and `## Previously this week` sections, and in Today only
top-level `- [x]` items (with their indented continuation lines)."""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Callable, Dict, List, Optional, Tuple

DEFAULT_MAX_KB = 40
_DONE_RE = re.compile(r"^[-*] \[[xX]\] ")
_DATE_RE = re.compile(r"^[-*] (?:\[[xX]\] )?[*_\s]*(\d{4}-\d{2}-\d{2})")
_DATED_BODY_RE = re.compile(r"^[*_\s]*\d{4}-\d{2}-\d{2}")


@dataclass
class Result:
    text: str
    swept: List[str] = field(default_factory=list)
    archives: Dict[str, List[str]] = field(default_factory=dict)
    reason: str = ""

    @property
    def changed(self) -> bool:
        return bool(self.swept or self.archives)


def iso_week(d: date) -> str:
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def _blank(line: str) -> bool:
    return not line.strip()


def _items(lines: List[str]) -> List[Tuple[str, List[str]]]:
    """Split section body lines into ("blank", [line]) and ("block", lines) items. A block
    is a non-indented line plus following indented lines (blank lines inside it allowed
    when an indented line follows)."""
    out: List[Tuple[str, List[str]]] = []
    i = 0
    while i < len(lines):
        if _blank(lines[i]):
            out.append(("blank", [lines[i]]))
            i += 1
            continue
        block = [lines[i]]
        i += 1
        while i < len(lines):
            j = i
            while j < len(lines) and _blank(lines[j]):
                j += 1
            if j < len(lines) and lines[j][:1] in (" ", "\t"):
                block.extend(lines[i : j + 1])
                i = j + 1
            else:
                break
        out.append(("block", block))
    return out


def _join(items: List[Tuple[str, List[str]]]) -> List[str]:
    """Flatten items, collapsing runs of blank lines to one."""
    out: List[str] = []
    prev_blank = False
    for kind, ls in items:
        if kind == "blank":
            if prev_blank:
                continue
            prev_blank = True
        else:
            prev_blank = False
        out.extend(ls)
    return out


def _find(lines: List[str], name: str) -> Optional[Tuple[int, int]]:
    """(heading index, end index exclusive) of the `## <name>` section, else None."""
    for i, line in enumerate(lines):
        if line.startswith("## ") and line[3:].strip().lower().startswith(name):
            j = i + 1
            while j < len(lines) and not re.match(r"^#{1,2} ", lines[j]):
                j += 1
            return i, j
    return None


def _block_date(block: List[str]) -> Optional[date]:
    m = _DATE_RE.match(block[0])
    if not m:
        return None
    try:
        return date.fromisoformat(m.group(1))
    except ValueError:
        return None


def _ensure_nl(s: str) -> str:
    return s if s.endswith("\n") else s + "\n"


def sweep(text: str, today: date, max_bytes: int) -> Result:
    lines = text.splitlines(keepends=True)
    stamp = today.isoformat()

    # (a) pull done items out of Today
    swept: List[List[str]] = []
    tsec = _find(lines, "today")
    if tsec:
        h, e = tsec
        kept: List[Tuple[str, List[str]]] = []
        for kind, ls in _items(lines[h + 1 : e]):
            if kind == "block" and _DONE_RE.match(ls[0]):
                ls = [_ensure_nl(x) for x in ls]
                m = _DONE_RE.match(ls[0])
                if not _DATED_BODY_RE.match(ls[0][m.end():]):
                    ls[0] = f"{m.group(0)}{stamp} — {ls[0][m.end():]}"
                swept.append(ls)
            else:
                kept.append((kind, ls))
        if swept:
            lines[h + 1 : e] = _join(kept)

    # (b) decide what to archive from Previously this week (swept items included)
    psec = _find(lines, "previously this week")
    prev_items = _items(lines[psec[0] + 1 : psec[1]]) if psec else []
    blocks = [ls for ls in swept] + [ls for k, ls in prev_items if k == "block"]
    cur = iso_week(today)
    last = iso_week(today - timedelta(days=7))

    def week_of(b: List[str]) -> str:
        d = _block_date(b)
        return iso_week(d) if d else last

    oversized = len(text.encode()) > max_bytes
    old = [b for b in blocks if week_of(b) < cur]
    to_archive = blocks if oversized else old
    reason = (f"file over {max_bytes // 1024} KB" if oversized else f"older than {cur}") if to_archive else ""
    archives: Dict[str, List[str]] = {}
    for b in to_archive:
        entry = "".join(_ensure_nl(x) for x in b)
        if not re.match(r"^[-*] ", entry):  # prose/heading: keep it off the list items
            entry = f"\n{entry}\n"
        archives.setdefault(week_of(b), []).append(entry)
    gone = {id(b) for b in to_archive}

    if not swept and not to_archive:
        return Result(text=text)

    # rebuild Previously: swept items first (most recent), then what was there
    rest = [(k, ls) for k, ls in prev_items if not (k == "block" and id(ls) in gone)]
    while rest and rest[0][0] == "blank":
        rest.pop(0)
    new_body = ["\n"] + [x for b in swept if id(b) not in gone for x in b] + _join(rest)
    if psec:
        h, e = psec
        if e < len(lines) and not _blank(new_body[-1]):
            new_body.append("\n")
        lines[h + 1 : e] = new_body
    else:
        if lines:
            lines[-1] = _ensure_nl(lines[-1])
            if not _blank(lines[-1]):
                lines.append("\n")
        lines += ["## Previously this week\n"] + new_body

    return Result(
        text="".join(lines),
        swept=["".join(b) for b in swept],
        archives=dict(sorted(archives.items())),
        reason=reason,
    )


def _atomic_write(path: str, text: str) -> None:
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(prefix=".brain-sweep.", dir=d)
    try:
        with os.fdopen(fd, "w", newline="") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def append_archive(path: str, week: str, entries: List[str]) -> None:
    """Append entries under `## Done` in planning/<week>.md, creating it if absent."""
    chunk = "".join(entries)
    if not os.path.exists(path):
        _atomic_write(path, f"# Week {week}\n\n## Done\n\n{chunk}")
        return
    with open(path) as f:
        lines = f.read().splitlines(keepends=True)
    sec = _find(lines, "done")
    if sec is None:
        if lines:
            lines[-1] = _ensure_nl(lines[-1])
            if not _blank(lines[-1]):
                lines.append("\n")
        lines += ["## Done\n", "\n", chunk]
    else:
        h, e = sec
        end = e
        while end > h + 1 and _blank(lines[end - 1]):
            end -= 1
        if end == h + 1:
            ins = ["\n", chunk] + (["\n"] if e < len(lines) else [])
            lines[h + 1 : e] = ins
        else:
            lines[end - 1] = _ensure_nl(lines[end - 1])
            lines.insert(end, chunk)
    _atomic_write(path, "".join(lines))


def _read(path: str) -> str:
    with open(path, newline="") as f:
        return f.read()


def run(
    path: str,
    archive_dir: str,
    today: date,
    max_bytes: int,
    dry_run: bool,
    _before_write: Optional[Callable[[], None]] = None,
    label_root: Optional[str] = None,
) -> List[str]:
    res = sweep(_read(path), today, max_bytes)
    if not dry_run and res.changed:
        if _before_write:
            _before_write()
        # Re-read right before writing so a concurrent edit is not clobbered.
        res = sweep(_read(path), today, max_bytes)
        for week, entries in res.archives.items():
            append_archive(os.path.join(archive_dir, f"{week}.md"), week, entries)
        if res.changed:
            _atomic_write(path, res.text)
    would = "would " if dry_run else ""
    rel = lambda p: os.path.relpath(p, label_root) if label_root else p  # noqa: E731
    out = [f"brain-sweep: {rel(path)} ({len(_read(path).encode()) // 1024} KB){' [dry run]' if dry_run else ''}"]
    if not res.changed:
        out.append("nothing to do")
        if len(res.text.encode()) > max_bytes:
            out.append(f"still over {max_bytes // 1024} KB: the bulk is open Today items or This week — trim by hand")
        return out
    if res.swept:
        out.append(f"{would}sweep {len(res.swept)} done item(s) from Today into Previously this week")
        out += ["  " + s.splitlines()[0][:120] for s in res.swept]
    for week, entries in res.archives.items():
        dest = rel(os.path.join(archive_dir, f"{week}.md"))
        out.append(f"{would}archive {len(entries)} item(s) to {dest} ({res.reason})")
    return out


def cli_main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog="brain-sweep", description=__doc__.splitlines()[0])
    ap.add_argument("--vault", default=os.environ.get("BRAIN_VAULT") or "~/Obsidian/vault")
    ap.add_argument("--file", default="00-home/top-of-mind.md", help="relative to the vault, or absolute")
    ap.add_argument("--archive-dir", help="default: planning/ (private/planning/ for a file under private/)")
    ap.add_argument("--max-kb", type=int, default=DEFAULT_MAX_KB, help="archive everything above this size")
    ap.add_argument("--date", help="YYYY-MM-DD, default today")
    ap.add_argument("--dry-run", action="store_true", help="print what would move; write nothing")
    a = ap.parse_args(argv)

    vault = os.path.abspath(os.path.expanduser(a.vault))
    path = os.path.join(vault, os.path.expanduser(a.file))
    if not os.path.isfile(path):
        print(f"brain-sweep: {path} not found", file=sys.stderr)
        return 1
    if a.archive_dir:
        archive_dir = os.path.join(vault, os.path.expanduser(a.archive_dir))
    elif os.path.realpath(path).startswith(os.path.realpath(os.path.join(vault, "private")) + os.sep):
        archive_dir = os.path.join(vault, "private", "planning")
    else:
        archive_dir = os.path.join(vault, "planning")
    today = date.fromisoformat(a.date) if a.date else date.today()
    for line in run(path, archive_dir, today, a.max_kb * 1024, a.dry_run, label_root=vault):
        print(line)
    return 0
