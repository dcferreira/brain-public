"""Vault topic scoping: areas, scopes, frontmatter, registry. Stdlib only, py3.9."""
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

AREAS = ("work", "projects", "private")
SCOPES = ("shared", "private", "all")

_KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):\s*(.*)$")


def vault_root() -> str:
    return os.path.expanduser(os.environ.get("BRAIN_VAULT") or "~/Obsidian/vault")


def norm_scope(raw: Optional[str]) -> str:
    s = (raw or "").strip().lower()
    return s if s in SCOPES else "shared"


def scope_includes(scope: str, area: str) -> bool:
    scope = norm_scope(scope)
    area = (area or "").strip().lower()
    if area not in AREAS:
        area = "work"
    if scope in ("private", "all"):
        return True
    return area != "private"


def _split_block(text: str):
    """Return (lines, end_idx) where lines keep their endings and lines[0] opens the
    block and lines[end_idx] closes it; None if there is no complete block."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r\n") == "---":
            return lines, i
    return None


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


_BOM = "\ufeff"


def read_frontmatter(text: str) -> Dict[str, str]:
    if text.startswith(_BOM):
        text = text[1:]
    blk = _split_block(text)
    if not blk:
        return {}
    lines, end = blk
    out: Dict[str, str] = {}
    for line in lines[1:end]:
        m = _KEY_RE.match(line.rstrip("\r\n"))
        if m and m.group(2).strip() != "":
            out[m.group(1)] = _unquote(m.group(2))
    return out


def set_frontmatter(text: str, updates: Dict[str, str]) -> str:
    if text.startswith(_BOM):
        return _BOM + set_frontmatter(text[1:], updates)
    # newline style = that of the first line (fall back to \n)
    first = text.split("\n", 1)[0]
    nl = "\r\n" if first.endswith("\r") else "\n"
    blk = _split_block(text)
    if not blk:
        head = "---" + nl + "".join("%s: %s%s" % (k, v, nl) for k, v in updates.items()) + "---" + nl
        return head + text
    lines, end = blk
    pending = dict(updates)
    i = 1
    while i < end:
        m = _KEY_RE.match(lines[i].rstrip("\r\n"))
        if m and m.group(1) in pending:
            eol = lines[i][len(lines[i].rstrip("\r\n")):]
            if m.group(2).strip() == "":
                # block/list key: drop its child lines (indented or `- ` items)
                j = i + 1
                while j < end and (lines[j].startswith((" ", "\t")) or lines[j].startswith("- ")
                                   or lines[j].rstrip("\r\n") == "-"):
                    j += 1
                del lines[i + 1:j]
                end -= j - (i + 1)
            lines[i] = "%s: %s%s" % (m.group(1), pending.pop(m.group(1)), eol or nl)
        i += 1
    add = [("%s: %s%s" % (k, v, nl)) for k, v in pending.items()]
    lines[end:end] = add
    return "".join(lines)


def note_dir(area: str, kind: str) -> str:
    return "private/" + kind if (area or "").strip().lower() == "private" else kind


def today_file(area: str) -> str:
    return "private/private.md" if (area or "").strip().lower() == "private" else "00-home/top-of-mind.md"


def find_worker_note(slug: str, vault: Optional[str] = None) -> Optional[str]:
    v = vault or vault_root()
    for rel in ("workers", "private/workers"):
        p = os.path.join(v, rel, slug + ".md")
        if os.path.isfile(p):
            return p
    return None


@dataclass
class Entry:
    project: str
    area: str
    aliases: List[str] = field(default_factory=list)
    prefixes: List[str] = field(default_factory=list)


def _cells(s: str) -> List[str]:
    return [c.strip() for c in s.split(",") if c.strip()]


def _parse_registry(path: str) -> List[Entry]:
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    out: List[Entry] = []
    for line in lines:
        line = line.strip()
        if not line.startswith("|"):
            continue
        parts = [c.strip() for c in line.strip("|").split("|")]
        if len(parts) < 4 or not parts[0]:
            continue
        if set(parts[0]) <= set("-: "):
            continue
        project, area = parts[0], parts[1].lower()
        if area not in AREAS:
            continue
        out.append(Entry(project, area, _cells(parts[2]), _cells(parts[3])))
    return out


def load_registry(vault: Optional[str] = None) -> List[Entry]:
    v = vault or vault_root()
    return _parse_registry(os.path.join(v, "00-home", "scopes.md")) + _parse_registry(
        os.path.join(v, "private", "scopes.md")
    )


def resolve(value: str, registry: List[Entry]) -> Optional[Entry]:
    q = (value or "").strip().lower()
    for e in registry:
        if e.project.lower() == q:
            return e
    for e in registry:
        if any(a.lower() == q for a in e.aliases):
            return e
    return None


def resolve_slug(slug: str, registry: List[Entry]) -> Optional[Entry]:
    s = (slug or "").lower()
    best, best_len = None, 0
    for e in registry:
        for p in e.prefixes:
            if s.startswith(p.lower()) and len(p) > best_len:
                best, best_len = e, len(p)
    return best


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _top_block(lines: List[str], key: str):
    """(start, end) of the top-level `key:` line and its indented body, or None."""
    for i, ln in enumerate(lines):
        if ln.rstrip() == key + ":" or ln.startswith(key + ":"):
            if _indent(ln) == 0:
                j = i + 1
                while j < len(lines) and (not lines[j].strip() or _indent(lines[j]) > 0
                                          or lines[j].lstrip().startswith("#")):
                    j += 1
                while j > i + 1 and not lines[j - 1].strip():
                    j -= 1
                return i, j
    return None


def ensure_vault_ignore(text: str) -> Tuple[str, str]:
    """Line-based: make collections.vault ignore `private/**`.
    Returns (text, status): changed | unchanged | no-vault | unsupported (text untouched)."""
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    cb = _top_block(lines, "collections")
    if cb is None:
        return text, "no-vault"
    vstart = None
    for i in range(cb[0] + 1, cb[1]):
        if lines[i].strip() == "vault:" and _indent(lines[i]) > 0:
            vstart = i
            break
    if vstart is None:
        return text, "no-vault"
    vind = _indent(lines[vstart])
    vend = vstart + 1
    while vend < cb[1] and (not lines[vend].strip() or _indent(lines[vend]) > vind):
        vend += 1
    while vend > vstart + 1 and not lines[vend - 1].strip():
        vend -= 1
    kind = vind + 2
    ig = None
    for i in range(vstart + 1, vend):
        if _indent(lines[i]) == kind and lines[i].lstrip().startswith("ignore:"):
            ig = i
            break
    want = "private/**"
    if ig is None:
        lines[vend:vend] = [" " * kind + "ignore:", " " * (kind + 2) + '- "%s"' % want]
    else:
        rest = lines[ig].split(":", 1)[1].split("#")[0].strip()
        if rest.startswith("["):
            if not rest.endswith("]"):
                return text, "unsupported"
            items = [x.strip().strip("\"'") for x in rest[1:-1].split(",") if x.strip()]
            if want in items:
                return text, "unchanged"
            lines[ig] = " " * kind + "ignore:"
            new = [" " * (kind + 2) + '- "%s"' % x for x in items + [want]]
            lines[ig + 1:ig + 1] = new
        else:
            end = ig + 1
            item_ind = kind + 2
            last = ig
            while end < vend:
                ln = lines[end]
                if ln.strip() and _indent(ln) <= kind and not ln.lstrip().startswith("-"):
                    break
                if ln.lstrip().startswith("-"):
                    item_ind = _indent(ln)
                    if ln.lstrip()[1:].split("#")[0].strip().strip("\"'") == want:
                        return text, "unchanged"
                    last = end
                end += 1
            lines.insert(last + 1, " " * item_ind + '- "%s"' % want)
    return nl.join(lines) + (nl if text.endswith("\n") else ""), "changed"


def qmd_config(conf_dir: str, vault: str) -> List[str]:
    """Idempotently ensure index.yml ignores private/** and private.yml exists.
    Returns human-readable messages (empty list never; 'up to date' when no change)."""
    idx = os.path.join(conf_dir, "index.yml")
    if not os.path.isfile(idx):
        return ["warning: %s missing; qmd not set up on this host, skipping" % idx]
    with open(idx, encoding="utf-8", newline="") as f:
        text = f.read()
    msgs = []
    new, status = ensure_vault_ignore(text)
    if status == "changed":
        tmp = idx + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(new)
        os.replace(tmp, idx)
        msgs.append("added ignore private/** to vault collection in %s" % idx)
    elif status == "no-vault":
        msgs.append("warning: no plain `vault:` collection found in %s; the private subtree is NOT "
                    "excluded from the shared collection" % idx)
    elif status == "unsupported":
        msgs.append("warning: unsupported ignore layout in %s (multi-line flow list); left unchanged, "
                    "private/** is NOT excluded from the shared collection; add it by hand" % idx)
    priv = os.path.join(conf_dir, "private.yml")
    col = 'collections:\n  private:\n    path: %s\n    pattern: "**/*.md"\n' % os.path.join(vault, "private")

    def models_of(t: str) -> str:
        ls = t.splitlines()
        mb = _top_block(ls, "models")
        if mb is None:
            return ""
        return "\n".join(l for l in ls[mb[0]:mb[1]] if not l.lstrip().startswith("#")) + "\n\n"

    if not os.path.exists(priv):
        with open(priv, "w", encoding="utf-8") as f:
            f.write(models_of(text) + col)
        msgs.append("created %s" % priv)
    else:
        with open(priv, encoding="utf-8", newline="") as f:
            ptext = f.read()
        pl = ptext.splitlines()
        cb = _top_block(pl, "collections")
        has = cb is not None and any(
            pl[i].strip() == "private:" and _indent(pl[i]) > 0 for i in range(cb[0] + 1, cb[1]))
        if not has:
            # qmd auto-creates private.yml with `collections: {}` on any --index private call
            with open(priv, "w", encoding="utf-8") as f:
                f.write((models_of(ptext) or models_of(text)) + col)
            msgs.append("added private collection to %s" % priv)
    return msgs or ["up to date"]


def cli_main(argv: List[str]) -> int:
    if not argv:
        sys.stderr.write("usage: brain-scope norm|includes|note-dir|find-worker|today-file|field|qmd-config ...\n")
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "norm":
        print(norm_scope(args[0] if args else os.environ.get("BRAIN_SCOPE")))
        return 0
    if cmd == "includes" and len(args) == 2:
        return 0 if scope_includes(args[0], args[1]) else 1
    if cmd == "note-dir" and len(args) == 2:
        print(note_dir(args[0], args[1]))
        return 0
    if cmd == "today-file" and len(args) == 1:
        print(today_file(args[0]))
        return 0
    if cmd == "find-worker" and len(args) == 1:
        p = find_worker_note(args[0])
        if p is None:
            return 1
        print(p)
        return 0
    if cmd == "qmd-config" and len(args) == 2:
        for m in qmd_config(args[0], args[1]):
            print("qmd config: " + m)
        return 0
    if cmd == "field" and len(args) == 2:
        try:
            with open(args[0], encoding="utf-8", newline="") as f:
                text = f.read()
        except OSError:
            print("")
            return 0
        print(read_frontmatter(text).get(args[1], ""))
        return 0
    sys.stderr.write("brain-scope: bad usage: %s\n" % " ".join(argv))
    return 2
