#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Render the /devflow:create-issue Step 3.6 fresh-context audit prompt.

This is the create-issue sibling of ``scripts/render-grounding-block.sh``: the
single deterministic renderer of a load-bearing prompt surface, so the
orchestrator stops hand-emitting the ~2,000-word audit-instruction block into
every dispatch. The canonical prose lives in the committed template file
``skills/create-issue/references/audit-prompt-template.md`` (resolved relative
to THIS file, never the cwd — the repo layout and the vendored-plugin layout
both place ``scripts/`` and ``skills/`` as siblings under one root).

Contract (issue #600):

- Stateless: reads no run state, writes no file, takes no stdin. The only reads
  are the committed template file and — for consumer-dimension forwarding — the
  consumer extension ``.devflow/prompt-extensions/create-issue.md``, resolved
  from the git repo root per the #295 SHARED REPO-ROOT CONFIG CONTRACT (a native
  ``git`` subprocess, cwd fallback; never a ``.sh`` exec — the #275 constraint).
- Closed argument surface: closed-vocabulary mode/arm/hook tokens, a kebab-case
  slug, absolute paths, and the machine-generated sentinel pair. No free-text
  parameter (the draft title never crosses a command line — it travels in the
  orchestrator's dispatch preamble prose).
- Modes, complete by construction: the dispatch arms ``file`` /
  ``embed`` / ``inline`` mirroring ``issue-audit-state.py``'s arm vocabulary,
  plus ``checklist`` (the Step 3.5 self-check), ``extract`` (the generic
  section-extraction hook, consumed by both the Step 3.6 ``## Audit dimensions``
  forwarding and the Step 2 ``## Evidence axes`` forwarding), and ``status-only``
  (the orchestrator's fail-fast one-line probe).
- Output contract: stdout's FIRST line is ``render-status:`` with a value from
  the closed set {appended, absent, unestablished}; stdout's LAST line is the
  fixed terminal marker ``render-end:`` on every full render, so a truncated
  delivery (the consumer section is appended last and is the first text a
  tool-result cap eats) is positionally detectable. ``status-only`` prints
  exactly the one status line (it IS one line; no end marker).
- Failure (unusable arguments, unreadable template file) exits non-zero with
  EMPTY stdout and a stderr breadcrumb — which, together with out-of-position
  markers, is the no-contract-output signal the skill's degraded arms key on.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

STATUS_PREFIX = "render-status:"
END_MARKER = "render-end:"

# Closed vocabularies (complete by construction).
_MODES = ("file", "embed", "inline", "checklist", "extract", "status-only")
_DISPATCH_ARMS = ("file", "embed", "inline")
# Extraction hooks map to the two consumer section headings they forward.
_HOOKS = {
    "audit-dimensions": "## Audit dimensions",
    "evidence-axes": "## Evidence axes",
}
# Consumer-dimension status values (the render-status: value set).
_STATUS_APPENDED = "appended"
_STATUS_ABSENT = "absent"
_STATUS_UNESTABLISHED = "unestablished"

# Template block markers. A block is bounded by
#   <!-- render-block: <space-separated arm/mode set> -->
#   ... block body ...
#   <!-- render-block-end -->
# and is emitted only when the current arm/mode is in its set. Slots inside a
# block are substituted after selection.
_BLOCK_OPEN_PREFIX = "<!-- render-block:"
_BLOCK_OPEN_SUFFIX = "-->"
_BLOCK_CLOSE = "<!-- render-block-end -->"


class RenderError(Exception):
    """A renderer failure: exit non-zero, empty stdout, stderr breadcrumb."""


def _default_template_path() -> Path:
    # Resolve the template relative to THIS file's location, never the cwd, so
    # the vendored-plugin layout (scripts/ and skills/ siblings under the
    # vendor root) resolves identically to the repo checkout.
    return (
        Path(__file__).resolve().parent.parent
        / "skills"
        / "create-issue"
        / "references"
        / "audit-prompt-template.md"
    )


def _repo_root() -> str | None:
    # #295 SHARED REPO-ROOT CONFIG CONTRACT, Python-reader shape: a native git
    # subprocess (Windows-safe, no .sh exec — #275), shallow-clone-safe
    # (--show-toplevel reads no history). git can exit non-zero while genuinely
    # inside a repo (safe.directory) or be absent, so a non-zero/OSError result
    # simply falls back to cwd rather than asserting "not in a repo".
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
        )
    except OSError:
        return None
    root = r.stdout.strip() if r.returncode == 0 else ""
    return root or None


def _default_extension_path() -> Path:
    root = _repo_root()
    base = Path(root) if root is not None else Path.cwd()
    return base / ".devflow" / "prompt-extensions" / "create-issue.md"


# --------------------------------------------------------------------------
# Consumer extension delivery triage + section extraction.
#
# The triage mirrors scripts/load-prompt-extension.sh (a coupled pair):
#   present regular readable file          -> read text, extract section
#   absent / present-but-empty             -> no section  (status absent)
#   present-but-unreadable / broken symlink
#     / present-but-non-regular file       -> unestablished (never "absent")
# --------------------------------------------------------------------------
def _read_extension(path: Path) -> tuple[str, str]:
    """Return (state, text). state is one of 'ok' / 'absent' / 'unestablished'.

    'ok' text is the file contents (possibly empty -> caller treats as absent).
    """
    # Broken symlink: is a symlink whose target does not exist.
    if path.is_symlink() and not path.exists():
        return ("unestablished", "")
    if not path.exists():
        return ("absent", "")
    # Present-but-non-regular (directory, fifo, device, symlink-to-dir).
    if not path.is_file():
        return ("unestablished", "")
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        # Present-but-unreadable (permissions) or undecodable payload.
        return ("unestablished", "")
    return ("ok", text)


def extract_section(text: str, heading: str) -> str:
    """Extract every ``## heading`` section, per the four extraction clauses.

    1. A section spans its heading line to the next line beginning ``## ``
       (two hashes + a space) or end of file.
    2. Duplicate same-heading sections concatenate in file order.
    3. An empty section (no non-whitespace body) equals an absent heading.
    4. A heading line inside an HTML comment block or a fenced code block is
       not a heading (an unclosed fence runs to end of file).

    Returns the concatenated section BODIES (heading lines excluded), or the
    empty string when the heading is absent or every match is body-empty.
    """
    target = heading.rstrip()
    in_fence = False
    fence_kind = ""  # '`' or '~'
    in_comment = False
    in_section = False
    collected: list[str] = []
    def _track_comment(current: bool, text_line: str) -> bool:
        # Last-marker-wins comment-block state (mirrors load-prompt-extension.sh).
        if "<!--" not in text_line and "-->" not in text_line:
            return current
        last_open = text_line.rfind("<!--")
        last_close = text_line.rfind("-->")
        if last_open > last_close:
            return True
        if last_close > last_open:
            return False
        return current

    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()

        # Comment-block state is resolved BEFORE fence detection, so a code-fence
        # marker (``` / ~~~) that sits INSIDE an open HTML comment is inert — it
        # neither opens nor closes a fence. Evaluating the fence branch first
        # would toggle `in_fence` on a commented-out fence line and then swallow
        # a later real heading (the load-prompt-extension.sh divergence #600's
        # review caught).
        if in_comment:
            in_comment = _track_comment(in_comment, line)
            if in_section:
                collected.append(raw)
            continue

        # Fence tracking (``` or ~~~). A fence toggles only on its own kind.
        if stripped.startswith("```") or stripped.startswith("~~~"):
            kind = stripped[0]
            if not in_fence:
                in_fence = True
                fence_kind = kind
            elif kind == fence_kind:
                in_fence = False
                fence_kind = ""
            if in_section:
                collected.append(raw)
            continue
        if in_fence:
            if in_section:
                collected.append(raw)
            continue

        # A line is a heading candidate BEFORE the comment-open check, so a
        # heading carrying a trailing inline comment still matches by its full
        # line (mirrors load-prompt-extension.sh).
        is_heading = line.startswith("## ")
        if is_heading:
            if line == target:
                in_section = True
                continue
            # A different '## ' heading terminates the current section.
            if in_section:
                in_section = False
            # fall through to comment tracking for this line too

        # A `## ` heading line is tested for heading-ness above BEFORE this
        # comment-open check, so a heading with a trailing inline comment still
        # matches; a non-heading line here may open a comment for later lines.
        in_comment = _track_comment(in_comment, line)

        if in_section:
            collected.append(raw)

    body = "\n".join(collected).strip("\n")
    if not body.strip():
        return ""
    return body


def consumer_dimensions(ext_path: Path, heading: str) -> tuple[str, str]:
    """Return (status, section_text) for a consumer section forwarding hook."""
    state, text = _read_extension(ext_path)
    if state == "unestablished":
        return (_STATUS_UNESTABLISHED, "")
    if state == "absent":
        return (_STATUS_ABSENT, "")
    section = extract_section(text, heading)
    if not section:
        return (_STATUS_ABSENT, "")
    return (_STATUS_APPENDED, section)


# --------------------------------------------------------------------------
# Template parsing / block selection.
# --------------------------------------------------------------------------
def _parse_blocks(template_text: str) -> list[tuple[frozenset[str], str]]:
    """Parse the template into (arm/mode set, body) blocks in file order.

    Text outside any block is ignored (it is the human-facing documentation of
    slots and the extraction rule, for the degraded manual arms). A missing
    close marker is a template defect -> RenderError.
    """
    blocks: list[tuple[frozenset[str], str]] = []
    current_set: frozenset[str] | None = None
    current_lines: list[str] = []
    for line in template_text.splitlines():
        s = line.strip()
        if s.startswith(_BLOCK_OPEN_PREFIX) and s.endswith(_BLOCK_OPEN_SUFFIX):
            if current_set is not None:
                raise RenderError(
                    "template malformed: nested render-block open marker"
                )
            spec = s[len(_BLOCK_OPEN_PREFIX):-len(_BLOCK_OPEN_SUFFIX)].strip()
            current_set = frozenset(spec.split())
            current_lines = []
            continue
        if s == _BLOCK_CLOSE:
            if current_set is None:
                raise RenderError(
                    "template malformed: render-block-end without an open marker"
                )
            blocks.append((current_set, "\n".join(current_lines)))
            current_set = None
            current_lines = []
            continue
        if current_set is not None:
            current_lines.append(line)
    if current_set is not None:
        raise RenderError("template malformed: unterminated render-block")
    return blocks


def _load_template(template_path: Path) -> str:
    try:
        return template_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise RenderError(
            f"could not read audit-prompt template at {template_path}: {exc}"
        ) from exc


def _substitute(text: str, slots: dict[str, str]) -> str:
    for key, value in slots.items():
        text = text.replace(key, value)
    return text


def _dimensions_block_for_status(status: str, section: str) -> str:
    if status == _STATUS_APPENDED:
        return section
    if status == _STATUS_ABSENT:
        return "(no consumer audit dimensions)"
    return "(consumer audit dimensions could not be established)"


def render_dispatch(
    mode: str,
    template_path: Path,
    slug: str,
    draft_path: str | None,
    sentinel_open: str | None,
    sentinel_close: str | None,
    ext_path: Path,
) -> str:
    """Assemble a full render for a dispatch arm (``mode`` in _DISPATCH_ARMS) or
    the checklist self-check (``mode == "checklist"``). ``mode`` doubles as the
    block-selection token, so the checklist branch passes ``"checklist"``."""
    blocks = _parse_blocks(_load_template(template_path))

    status, section = consumer_dimensions(ext_path, _HOOKS["audit-dimensions"])
    # `{CONSUMER_DIMENSIONS}` is substituted LAST (dict-insertion order): the
    # consumer-extension text spliced in is then never re-scanned for `<slug>` /
    # `{DRAFT_PATH}` tokens it may legitimately contain. Keep it last.
    slots = {
        "<slug>": slug,
        "{DRAFT_PATH}": draft_path or "",
        "{SENTINEL_OPEN}": sentinel_open or "",
        "{SENTINEL_CLOSE}": sentinel_close or "",
        "{CONSUMER_DIMENSIONS}": _dimensions_block_for_status(status, section),
    }

    parts: list[str] = []
    for arm_set, body in blocks:
        if mode in arm_set:
            parts.append(_substitute(body, slots).strip("\n"))
    inner = "\n\n".join(p for p in parts if p.strip())
    return f"{STATUS_PREFIX} {status}\n{inner}\n{END_MARKER}"


def render_extract(hook: str, ext_path: Path) -> str:
    """Section-extraction mode: forward one consumer section (both hooks)."""
    heading = _HOOKS[hook]
    # consumer_dimensions returns section="" for every non-appended status.
    status, section = consumer_dimensions(ext_path, heading)
    return f"{STATUS_PREFIX} {status}\n{section}\n{END_MARKER}"


def render_status_only(ext_path: Path) -> str:
    status, _ = consumer_dimensions(ext_path, _HOOKS["audit-dimensions"])
    return f"{STATUS_PREFIX} {status}"


# --------------------------------------------------------------------------
# CLI.
# --------------------------------------------------------------------------
def _kebab_slug(value: str) -> str:
    # Closed-vocabulary slug: lowercase kebab-case only. Rejects any free text.
    if not value or not all(c.islower() or c.isdigit() or c == "-" for c in value):
        raise argparse.ArgumentTypeError(
            f"slug must be lowercase kebab-case (got {value!r})"
        )
    return value


def _sentinel(value: str) -> str:
    # Closed shape: AUDIT-<hex>-OPEN / AUDIT-<hex>-CLOSE (issue-audit-state.py).
    if not (value.startswith("AUDIT-") and value.endswith(("-OPEN", "-CLOSE"))):
        raise argparse.ArgumentTypeError(
            f"sentinel must be an AUDIT-<tag>-OPEN/CLOSE token (got {value!r})"
        )
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="render-audit-prompt.py",
        description="Render the create-issue Step 3.6 fresh-context audit prompt.",
    )
    parser.add_argument("mode", choices=_MODES)
    parser.add_argument("--slug", type=_kebab_slug)
    parser.add_argument("--draft-path")  # absolute path (file arm)
    parser.add_argument("--sentinel-open", type=_sentinel)
    parser.add_argument("--sentinel-close", type=_sentinel)
    parser.add_argument("--hook", choices=tuple(_HOOKS))
    parser.add_argument("--template-file")  # absolute path override (tests)
    parser.add_argument("--extension-file")  # absolute path override (tests)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    template_path = (
        Path(args.template_file) if args.template_file else _default_template_path()
    )
    ext_path = (
        Path(args.extension_file)
        if args.extension_file
        else _default_extension_path()
    )

    try:
        if args.mode in _DISPATCH_ARMS:
            if args.slug is None:
                raise RenderError(f"--slug is required for the {args.mode} arm")
            if args.mode == "file" and not args.draft_path:
                raise RenderError("--draft-path is required for the file arm")
            if args.mode == "embed" and not (
                args.sentinel_open and args.sentinel_close
            ):
                raise RenderError(
                    "--sentinel-open and --sentinel-close are required for the "
                    "embed arm"
                )
            out = render_dispatch(
                args.mode,
                template_path,
                args.slug,
                args.draft_path,
                args.sentinel_open,
                args.sentinel_close,
                ext_path,
            )
        elif args.mode == "checklist":
            out = render_dispatch(
                "checklist",
                template_path,
                args.slug or "",
                None,
                None,
                None,
                ext_path,
            )
        elif args.mode == "extract":
            if not args.hook:
                raise RenderError("--hook is required for extract mode")
            out = render_extract(args.hook, ext_path)
        elif args.mode == "status-only":
            out = render_status_only(ext_path)
        else:  # unreachable: choices already constrain mode
            raise RenderError(f"unknown mode {args.mode}")
    except RenderError as exc:
        sys.stderr.write(f"render-audit-prompt.py: {exc}\n")
        return 1

    sys.stdout.write(out + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
