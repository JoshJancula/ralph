#!/usr/bin/env python3
"""Standard-library terminal primitives for Ralph Python tools.

Provides capability detection, semantic color, Unicode/ASCII symbol selection,
text clipping/display-width helpers, and simple ANSI escape helpers. The module
has no third-party dependencies and is intentionally tiny so that both
pretty-log renderers and the graph TUI can share the same primitives.

Semantic roles:
  accent    - highlight/branding color
  success   - pass / succeeded / healthy
  warning   - pending / warn / caution
  failure   - fail / error / blocked
  muted     - dim metadata, borders, disabled text
  heading   - strong section headings
  focus     - selected/focused rows
  command   - command names or executable tokens
  path      - filesystem paths and identifiers
  reset     - reset all active attributes

Color depths: 0 (none), 16 (basic ANSI), 256 (256-color palette). Callers pass
a target depth to Style(...). Detection helpers return a recommended depth based
on environment and terminal capability.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
from dataclasses import dataclass
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple

_ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# Matches the CSI parameter bytes + final byte; also covers 'm' and cursor controls.

_CONTROL_TRANSLATION = dict.fromkeys(range(32))
_CONTROL_TRANSLATION[ord("\t")] = " "

_ELLIPSIS = "..."

NO_COLOR = 0
ANSI_16 = 16
ANSI_256 = 256


SEMANTIC_ROLES = (
    "accent",
    "success",
    "warning",
    "failure",
    "muted",
    "heading",
    "focus",
    "command",
    "path",
    "reset",
)


# Default palette maps each role to (code16, code256). Empty code16 means the
# role only emits a sequence at 256-color depth. Reset is always the full reset
# sequence when color is enabled.
_DEFAULT_PALETTE: Dict[str, Tuple[Optional[str], Optional[str]]] = {
    "accent": ("36", "38;5;80"),     # cyan / bright cyan
    "success": ("32", "38;5;71"),    # green / bright green
    "warning": ("33", "38;5;179"),    # yellow / amber
    "failure": ("31", "38;5;167"),    # red / bright red
    "muted": ("2", "38;5;244"),       # dim / grey
    "heading": ("1", "1"),            # bold at both depths
    "focus": ("1;36", "1;38;5;80"),   # bold accent
    "command": ("35", "38;5;176"),    # magenta / soft magenta
    "path": ("36", "38;5;37"),        # cyan / sea green
    "reset": ("0", "0"),
}


@dataclass(frozen=True)
class TermCapabilities:
    """Recommended terminal capability summary."""

    depth: int
    ascii_only: bool
    # width is a hint; callers may override.
    width: int
    color_disabled_by_env: bool

    @property
    def color(self) -> bool:
        return self.depth > 0


class Style:
    """Resolve semantic roles to ANSI SGR sequences for a given color depth."""

    __slots__ = ("depth", "ascii_only", "_cache", "_palette")

    def __init__(
        self,
        depth: int,
        *,
        ascii_only: bool = False,
        palette: Optional[Mapping[str, Tuple[Optional[str], Optional[str]]]] = None,
    ) -> None:
        self.depth = max(0, int(depth))
        self.ascii_only = bool(ascii_only)
        self._palette: Dict[str, Tuple[Optional[str], Optional[str]]] = {
            k: v for k, v in _DEFAULT_PALETTE.items()
        }
        if palette:
            for key, value in palette.items():
                if isinstance(value, tuple) and len(value) == 2:
                    self._palette[str(key)] = value
                elif isinstance(value, str):
                    # Treat a plain string as the 256-color sequence; 16-color uses empty.
                    self._palette[str(key)] = (None, value)
        self._cache: Dict[str, str] = {}

    def __call__(self, role: str) -> str:
        """Return the SGR escape sequence for a semantic role."""
        if self.depth <= 0:
            return ""
        cached = self._cache.get(role)
        if cached is not None:
            return cached
        code16, code256 = self._palette.get(role, (None, None))
        seq = self._resolve(code16, code256)
        self._cache[role] = seq
        return seq

    def _resolve(self, code16: Optional[str], code256: Optional[str]) -> str:
        if self.depth >= ANSI_256 and code256:
            return f"\033[{code256}m"
        if self.depth >= ANSI_16 and code16:
            return f"\033[{code16}m"
        return ""

    def wrap(self, role: str, text: str) -> str:
        """Wrap text with the role's open sequence and reset."""
        if self.depth <= 0:
            return text
        return f"{self(role)}{text}{self('reset')}"

    @property
    def reset(self) -> str:
        return self("reset")

    @property
    def soft_fg_reset(self) -> str:
        """Soft foreground reset (color only, keeps background/dim/bold)."""
        if self.depth <= 0:
            return ""
        return "\033[39m"

    @property
    def dim(self) -> str:
        return self("muted")

    @property
    def bold(self) -> str:
        if self.depth <= 0:
            return ""
        return "\033[1m"

    def clone(self, **overrides: Any) -> "Style":
        depth = overrides.get("depth", self.depth)
        ascii_only = overrides.get("ascii_only", self.ascii_only)
        palette = overrides.get("palette", None)
        return Style(depth, ascii_only=ascii_only, palette=palette)


class Symbols:
    """Select Unicode or ASCII symbols based on capability."""

    __slots__ = ("ascii_only",)

    def __init__(self, ascii_only: bool = False) -> None:
        self.ascii_only = bool(ascii_only)

    @property
    def bullet(self) -> str:
        return "*" if self.ascii_only else "●"

    @property
    def branch(self) -> str:
        return "-" if self.ascii_only else "└"

    @property
    def vbar(self) -> str:
        return "|" if self.ascii_only else "│"

    @property
    def spinner(self) -> str:
        return "~" if self.ascii_only else "⟳"

    @property
    def rule(self) -> str:
        return "-" if self.ascii_only else "─"

    @property
    def ellipsis(self) -> str:
        return "..."

    @property
    def selected_marker(self) -> str:
        return ">"

    @property
    def replacement(self) -> str:
        return "\ufffd"


def detect_depth(*, env: Optional[Mapping[str, str]] = None) -> int:
    """Recommend a color depth from the environment.

    Returns NO_COLOR when any standard disabling env var is set or when stdout
    is not a TTY. Returns ANSI_256 when the terminal advertises 256 colors.
    Otherwise ANSI_16.
    """
    env = env if env is not None else os.environ
    if (
        env.get("NO_COLOR")
        or env.get("RALPH_NO_COLOR")
        or str(env.get("RALPH_WORKFLOW_NO_COLOR", "")).strip().lower() in {"1", "true", "yes", "on"}
    ):
        return NO_COLOR
    if env.get("TERM") == "dumb":
        return NO_COLOR
    # Use the explicitly passed stdout_isatty when available; otherwise fall back
    # to the real stdout file descriptor so tests can inject behavior.
    tty = sys.stdout.isatty() if env is os.environ else True
    if not tty:
        return NO_COLOR
    term_program = env.get("TERM_PROGRAM", "")
    colorterm = env.get("COLORTERM", "")
    term = env.get("TERM", "")
    if "256" in term or "256" in colorterm:
        return ANSI_256
    if colorterm in ("truecolor", "24bit", "24-bit"):
        # We still map truecolor to 256-color behavior per the contract.
        return ANSI_256
    if term in ("xterm-256color", "screen-256color", "tmux-256color"):
        return ANSI_256
    if term_program in ("iTerm.app", "WezTerm", "vscode"):
        return ANSI_256
    return ANSI_16


def detect_ascii_only(*, env: Optional[Mapping[str, str]] = None) -> bool:
    """Return True when callers should avoid Unicode box-drawing symbols."""
    env = env if env is not None else os.environ
    if env.get("RALPH_ASCII_ONLY") or env.get("LC_ALL") == "C" or env.get("LANG") == "C":
        return True
    return False


def detect_width(default: int = 80, min_width: int = 40, max_width: int = 120) -> int:
    """Return a reasonable terminal width for wrapping."""
    try:
        cols = shutil.get_terminal_size((default, 24)).columns
    except (ValueError, OSError):
        cols = default
    return max(min_width, min(cols, max_width))


def probe_capabilities(
    *,
    stdin_isatty: Optional[bool] = None,
    stdout_isatty: Optional[bool] = None,
    term: Optional[str] = None,
    environ: Optional[Mapping[str, str]] = None,
    ascii_only: Optional[bool] = None,
    width: Optional[int] = None,
) -> TermCapabilities:
    """Produce a single capability summary for terminal-aware output."""
    env = dict(os.environ if environ is None else environ)
    if stdin_isatty is None:
        stdin_isatty = sys.stdin.isatty()
    if stdout_isatty is None:
        stdout_isatty = sys.stdout.isatty()

    if term is not None:
        env["TERM"] = term

    color_disabled_by_env = bool(
        env.get("NO_COLOR")
        or env.get("RALPH_NO_COLOR")
        or str(env.get("RALPH_WORKFLOW_NO_COLOR", "")).strip().lower() in {"1", "true", "yes", "on"}
        or env.get("TERM") == "dumb"
        or not stdout_isatty
    )

    if color_disabled_by_env:
        depth = NO_COLOR
    else:
        depth = detect_depth(env=env)

    ascii = bool(ascii_only) if ascii_only is not None else detect_ascii_only(env=env)
    return TermCapabilities(
        depth=depth,
        ascii_only=ascii,
        width=width if width is not None else detect_width(),
        color_disabled_by_env=color_disabled_by_env,
    )


def visible_len(text: str) -> int:
    """Length of a string ignoring ANSI SGR escape sequences."""
    return len(_ANSI_ESCAPE_RE.sub("", text))


def has_ansi(text: str) -> bool:
    return bool(_ANSI_ESCAPE_RE.search(text))


def strip_ansi(text: str) -> str:
    return _ANSI_ESCAPE_RE.sub("", text)


def sanitize_control(text: str, tab: str = " ") -> str:
    """Replace control characters except tab/newline, normalize tab to space."""
    mapping = _CONTROL_TRANSLATION.copy()
    mapping[ord("\t")] = tab
    # Keep newlines so multi-line strings remain multi-line; keep ESC for ANSI.
    del mapping[ord("\n")]
    if ord("\x1b") in mapping:
        del mapping[ord("\x1b")]
    return text.translate(mapping)


def clip_text(
    text: str,
    width: int,
    *,
    pad: bool = False,
    ellipsis: str = _ELLIPSIS,
    tab: str = " ",
) -> str:
    """Truncate to display width without raising. Optional space-padding.

    The width is measured by visible characters after stripping ANSI escapes and
    replacing control characters and tabs.
    """
    width = max(0, int(width))
    cleaned = sanitize_control(str(text), tab=tab).replace("\r", " ").replace("\n", " ")
    if width <= 0:
        return ""
    if visible_len(cleaned) <= width:
        if pad:
            return cleaned.ljust(width)
        return cleaned
    if width <= 3:
        return text[:width]
    # Walk visible characters so ANSI escapes do not consume budget.
    budget = width - len(ellipsis)
    out_chars: list[str] = []
    seen = 0
    in_escape = False
    for ch in cleaned:
        if ch == "\x1b":
            in_escape = True
        if in_escape:
            out_chars.append(ch)
            if ch.isalpha():
                in_escape = False
            continue
        if seen < budget:
            out_chars.append(ch)
            seen += 1
    return "".join(out_chars) + ellipsis


def pad_line(text: str, width: int) -> str:
    """Pad or clip a line to exactly `width` visible characters."""
    clipped = clip_text(text, width, pad=False)
    if visible_len(clipped) < width:
        return clipped.ljust(width)
    return clipped


def truncate(text: str, limit: int = 80, ellipsis: str = _ELLIPSIS) -> str:
    """Strip and truncate a plain string to a visible-character limit."""
    text = text.strip()
    if visible_len(text) <= limit:
        return text
    if limit <= len(ellipsis):
        return ellipsis[:limit]
    return clip_text(text, limit, ellipsis=ellipsis, pad=False)


def plain_style(depth: int = 0, ascii_only: bool = True) -> Tuple[Style, Symbols]:
    """Convenience factory for colorless / ASCII output."""
    return Style(depth=depth, ascii_only=ascii_only), Symbols(ascii_only=ascii_only)


def auto_style(
    *,
    ascii_only: Optional[bool] = None,
    env: Optional[Mapping[str, str]] = None,
) -> Tuple[Style, Symbols, TermCapabilities]:
    """Convenience factory using environment detection."""
    caps = probe_capabilities(environ=env, ascii_only=ascii_only)
    style = Style(depth=caps.depth, ascii_only=caps.ascii_only)
    symbols = Symbols(ascii_only=caps.ascii_only)
    return style, symbols, caps


def resolve_color_code(
    depth: int,
    code16: str,
    code256: str,
    *,
    default16: str = "",
) -> str:
    """Backwards-compatible helper matching the old PrettyRenderer._c shape."""
    if depth >= ANSI_256 and code256:
        return f"\033[{code256}m"
    if depth >= ANSI_16 and code16:
        return f"\033[{code16}m"
    if depth >= ANSI_16 and default16:
        return f"\033[{default16}m"
    return ""


def split_aware(text: str, width: int) -> Sequence[str]:
    """Split a single-line string into chunks of at most `width` visible chars.

    ANSI escape sequences are preserved in the chunk where they appear. This is a
    thin helper for callers that need to wrap pre-colored text.
    """
    if width <= 0:
        return ()
    chunks: list[str] = []
    current: list[str] = []
    seen = 0
    in_escape = False
    for ch in text:
        if ch == "\n":
            chunks.append("".join(current))
            current = []
            seen = 0
            continue
        current.append(ch)
        if ch == "\x1b":
            in_escape = True
        elif in_escape and ch.isalpha():
            in_escape = False
        elif not in_escape:
            seen += 1
            if seen >= width:
                chunks.append("".join(current))
                current = []
                seen = 0
    if current:
        chunks.append("".join(current))
    return chunks


def default_palette() -> Dict[str, Tuple[Optional[str], Optional[str]]]:
    return {k: v for k, v in _DEFAULT_PALETTE.items()}


if __name__ == "__main__":
    style, symbols, caps = auto_style()
    print(f"depth={caps.depth} ascii_only={caps.ascii_only} width={caps.width}")
    for role in SEMANTIC_ROLES:
        print(f"{role}: {repr(style(role))}")
