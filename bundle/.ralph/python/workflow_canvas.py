#!/usr/bin/env python3
"""Backend-neutral semantic cell canvas for Ralph's workflow terminal UI.

The canvas contains printable text and semantic role names only.  It knows
nothing about terminal color escape sequences or a particular screen backend;
plain output and a future interactive painter consume the same cells/spans.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Iterable, Iterator, Optional, Sequence, Tuple


DEFAULT_ROLE = "default"
_ROLE_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_ANSI_RE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)?)"
)
_ELLIPSIS = "…"
_ZWJ = "\u200d"


def sanitize_text(value: object) -> str:
    """Return printable, single-line text with terminal escapes removed."""

    text = _ANSI_RE.sub("", str(value)).replace("\x1b", "")
    chars = []
    for char in text:
        codepoint = ord(char)
        if char == "\t":
            chars.append(" ")
        elif codepoint < 32 or 0x7F <= codepoint <= 0x9F:
            chars.append(" ")
        else:
            chars.append(char)
    return "".join(chars)


def normalize_role(role: Optional[str]) -> str:
    """Validate and normalize a semantic role name."""

    if role is None or role == "":
        return DEFAULT_ROLE
    if not isinstance(role, str) or not _ROLE_RE.fullmatch(role):
        raise ValueError(f"invalid semantic style role: {role!r}")
    return role


def _is_extender(char: str) -> bool:
    codepoint = ord(char)
    return bool(
        unicodedata.combining(char)
        or unicodedata.category(char) in {"Mn", "Mc", "Me"}
        or 0xFE00 <= codepoint <= 0xFE0F
        or 0xE0100 <= codepoint <= 0xE01EF
        or char == _ZWJ
    )


def graphemes(value: object) -> Tuple[str, ...]:
    """Split text into terminal-safe clusters without external dependencies.

    This intentionally covers the terminal cases the canvas must preserve:
    combining marks, variation selectors, and zero-width-joiner sequences.
    """

    text = sanitize_text(value)
    clusters = []
    current = ""
    join_next = False
    for char in text:
        if not current:
            current = char
        elif _is_extender(char) or join_next:
            current += char
        else:
            clusters.append(current)
            current = char
        join_next = char == _ZWJ
    if current:
        clusters.append(current)
    return tuple(clusters)


def cluster_width(cluster: str) -> int:
    """Return the display-cell width of one cluster."""

    widths = []
    for char in cluster:
        if _is_extender(char) or unicodedata.category(char).startswith("C"):
            widths.append(0)
        else:
            widths.append(2 if unicodedata.east_asian_width(char) in {"W", "F"} else 1)
    if _ZWJ in cluster:
        return max(widths, default=0)
    return sum(widths)


def display_width(value: object) -> int:
    """Return terminal display columns for plain text."""

    return sum(cluster_width(cluster) for cluster in graphemes(value))


def _prefix(value: object, width: int) -> str:
    budget = max(0, int(width))
    output = []
    used = 0
    for cluster in graphemes(value):
        cluster_columns = cluster_width(cluster)
        if cluster_columns == 0:
            if output:
                output[-1] += cluster
            continue
        if used + cluster_columns > budget:
            break
        output.append(cluster)
        used += cluster_columns
    return "".join(output)


def truncate_text(value: object, width: int, *, ellipsis: str = _ELLIPSIS) -> str:
    """Clip text to display columns, adding an ellipsis when it is truncated."""

    width = max(0, int(width))
    text = sanitize_text(value)
    if width == 0:
        return ""
    if display_width(text) <= width:
        return text
    marker = sanitize_text(ellipsis)
    marker_width = display_width(marker)
    if marker_width <= 0:
        return _prefix(text, width)
    if marker_width > width:
        return _prefix(marker, width)
    return _prefix(text, width - marker_width) + marker


def fit_text(
    value: object,
    width: int,
    *,
    align: str = "left",
    ellipsis: str = _ELLIPSIS,
    pad: bool = True,
) -> str:
    """Truncate and optionally pad text to exactly ``width`` columns."""

    width = max(0, int(width))
    if align not in {"left", "center", "right"}:
        raise ValueError("align must be left, center, or right")
    text = truncate_text(value, width, ellipsis=ellipsis)
    if not pad:
        return text
    remaining = width - display_width(text)
    if align == "right":
        return " " * remaining + text
    if align == "center":
        left = remaining // 2
        return " " * left + text + " " * (remaining - left)
    return text + " " * remaining


@dataclass(frozen=True)
class StyledText:
    """A text fragment carrying a semantic style role, never terminal escapes."""

    text: str
    role: str = DEFAULT_ROLE

    def __post_init__(self) -> None:
        object.__setattr__(self, "text", sanitize_text(self.text))
        object.__setattr__(self, "role", normalize_role(self.role))

    @property
    def width(self) -> int:
        return display_width(self.text)


@dataclass(frozen=True)
class Cell:
    """One display cell. Continuations reserve the tail of a wide glyph."""

    text: str = " "
    role: str = DEFAULT_ROLE
    continuation: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "text", "" if self.continuation else sanitize_text(self.text))
        object.__setattr__(self, "role", normalize_role(self.role))


@dataclass(frozen=True)
class StyledSpan:
    """A row-local run of adjacent cells sharing one semantic role."""

    row: int
    column: int
    text: str
    role: str
    width: int

    def __post_init__(self) -> None:
        text = sanitize_text(self.text)
        object.__setattr__(self, "row", max(0, int(self.row)))
        object.__setattr__(self, "column", max(0, int(self.column)))
        object.__setattr__(self, "text", text)
        object.__setattr__(self, "role", normalize_role(self.role))
        object.__setattr__(self, "width", display_width(text))


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.x + self.width

    @property
    def bottom(self) -> int:
        return self.y + self.height

    def inset(self, top: int, right: int, bottom: int, left: int) -> "Rect":
        return Rect(
            self.x + max(0, left),
            self.y + max(0, top),
            max(0, self.width - max(0, left) - max(0, right)),
            max(0, self.height - max(0, top) - max(0, bottom)),
        )


@dataclass(frozen=True)
class BorderChars:
    top_left: str
    horizontal: str
    top_right: str
    vertical: str
    bottom_left: str
    bottom_right: str


UNICODE_BORDER = BorderChars("┌", "─", "┐", "│", "└", "┘")
ASCII_BORDER = BorderChars("+", "-", "+", "|", "+", "+")


@dataclass(frozen=True)
class ColumnSpec:
    min_width: int = 0
    weight: int = 1
    max_width: Optional[int] = None

    def __post_init__(self) -> None:
        if self.min_width < 0 or self.weight <= 0:
            raise ValueError("column minimum must be non-negative and weight must be positive")
        if self.max_width is not None and self.max_width < self.min_width:
            raise ValueError("column maximum cannot be smaller than its minimum")


@dataclass(frozen=True)
class ColumnAllocation:
    widths: Tuple[int, ...]
    gap: int

    @property
    def used(self) -> int:
        return sum(self.widths) + self.gap * max(0, len(self.widths) - 1)

    def positions(self, origin: int = 0) -> Tuple[int, ...]:
        positions = []
        cursor = origin
        for width in self.widths:
            positions.append(cursor)
            cursor += width + self.gap
        return tuple(positions)


def _proportional(total: int, weights: Sequence[int]) -> list[int]:
    if total <= 0 or not weights:
        return [0 for _ in weights]
    weight_sum = sum(weights)
    raw = [total * weight / weight_sum for weight in weights]
    result = [int(value) for value in raw]
    order = sorted(range(len(weights)), key=lambda index: (-(raw[index] - result[index]), index))
    for index in order[: total - sum(result)]:
        result[index] += 1
    return result


def allocate_columns(
    total_width: int, specs: Sequence[ColumnSpec], *, gap: int = 1
) -> ColumnAllocation:
    """Allocate integer column widths with minimums, weights, caps, and tiny-size safety."""

    total_width = max(0, int(total_width))
    gap = max(0, int(gap))
    specs = tuple(specs)
    if not specs:
        return ColumnAllocation((), 0)
    actual_gap = min(gap, total_width // max(1, len(specs) - 1)) if len(specs) > 1 else 0
    available = max(0, total_width - actual_gap * (len(specs) - 1))
    minimums = [spec.min_width for spec in specs]
    if sum(minimums) > available:
        return ColumnAllocation(tuple(_proportional(available, minimums)), actual_gap)

    widths = minimums[:]
    remaining = available - sum(widths)
    while remaining > 0:
        eligible = [
            index
            for index, spec in enumerate(specs)
            if spec.max_width is None or widths[index] < spec.max_width
        ]
        if not eligible:
            break
        shares = _proportional(remaining, [specs[index].weight for index in eligible])
        granted = 0
        for eligible_index, share in zip(eligible, shares):
            spec = specs[eligible_index]
            capacity = remaining if spec.max_width is None else spec.max_width - widths[eligible_index]
            amount = min(share, capacity)
            widths[eligible_index] += amount
            granted += amount
        if granted == 0:
            widths[eligible[0]] += 1
            granted = 1
        remaining -= granted
    return ColumnAllocation(tuple(widths), actual_gap)


def _padding(value: int | Sequence[int]) -> Tuple[int, int, int, int]:
    if isinstance(value, int):
        values = (value, value, value, value)
    else:
        parts = tuple(int(part) for part in value)
        if len(parts) == 2:
            values = (parts[0], parts[1], parts[0], parts[1])
        elif len(parts) == 4:
            values = parts
        else:
            raise ValueError("padding must be an integer or a 2/4-item sequence")
    return tuple(max(0, part) for part in values)  # type: ignore[return-value]


def truncate_spans(
    spans: Iterable[StyledText], width: int, *, ellipsis: str = _ELLIPSIS
) -> Tuple[StyledText, ...]:
    """Clip semantic spans without splitting a display cluster."""

    width = max(0, int(width))
    source = tuple(spans)
    if width == 0 or not source:
        return ()
    if sum(span.width for span in source) <= width:
        return source
    marker = truncate_text(ellipsis, width, ellipsis="")
    marker_width = display_width(marker)
    budget = width - marker_width
    output = []
    used = 0
    last_role = source[0].role
    for span in source:
        piece = _prefix(span.text, budget - used)
        if piece:
            output.append(StyledText(piece, span.role))
            used += display_width(piece)
            last_role = span.role
        if used >= budget:
            break
    if marker:
        output.append(StyledText(marker, last_role))
    return tuple(output)


def progress_spans(
    completed: int,
    total: Optional[int],
    width: int,
    *,
    ascii_only: bool = False,
) -> Tuple[StyledText, ...]:
    """Return a fixed-width semantic progress bar or a numeric fallback."""

    completed = max(0, int(completed))
    width = max(0, int(width))
    known_total = total is not None and int(total) > 0
    numeric = f"{completed}/{int(total)}" if known_total else f"{completed}/?"
    numeric_role = "success" if known_total and completed >= int(total) else "accent"
    if width == 0:
        return ()
    if not known_total or width < display_width(numeric) + 5:
        return (StyledText(fit_text(numeric, width, pad=True), numeric_role),)

    inner = width - display_width(numeric) - 3
    fraction = min(completed, int(total)) / int(total)
    filled = min(inner, max(0, int(fraction * inner + 0.5)))
    full_char, empty_char = ("#", "-") if ascii_only else ("━", "─")
    return (
        StyledText("[", "muted"),
        StyledText(full_char * filled, "success"),
        StyledText(empty_char * (inner - filled), "muted"),
        StyledText("] ", "muted"),
        StyledText(numeric, numeric_role),
    )


class Canvas:
    """A clipped two-dimensional grid of printable semantic cells."""

    def __init__(self, width: int, height: int, *, role: str = DEFAULT_ROLE) -> None:
        self.width = max(0, int(width))
        self.height = max(0, int(height))
        self.default_role = normalize_role(role)
        self._cells = [
            [Cell(role=self.default_role) for _ in range(self.width)]
            for _ in range(self.height)
        ]

    @property
    def cells(self) -> Tuple[Tuple[Cell, ...], ...]:
        return tuple(tuple(row) for row in self._cells)

    def cell(self, x: int, y: int) -> Optional[Cell]:
        if 0 <= x < self.width and 0 <= y < self.height:
            return self._cells[y][x]
        return None

    def _clear_glyph(self, x: int, y: int) -> None:
        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        row = self._cells[y]
        lead = x
        while lead > 0 and row[lead].continuation:
            lead -= 1
        if row[lead].continuation:
            row[x] = Cell(role=self.default_role)
            return
        row[lead] = Cell(role=self.default_role)
        cursor = lead + 1
        while cursor < self.width and row[cursor].continuation:
            row[cursor] = Cell(role=self.default_role)
            cursor += 1

    def _write_cluster(self, x: int, y: int, cluster: str, role: str) -> int:
        columns = cluster_width(cluster)
        if columns <= 0:
            if 0 < x <= self.width and 0 <= y < self.height:
                lead = x - 1
                while lead > 0 and self._cells[y][lead].continuation:
                    lead -= 1
                previous = self._cells[y][lead]
                if previous.text.strip():
                    self._cells[y][lead] = Cell(previous.text + cluster, previous.role)
            return x
        if x < 0 or x + columns > self.width or not (0 <= y < self.height):
            return x + columns
        for column in range(x, x + columns):
            self._clear_glyph(column, y)
        self._cells[y][x] = Cell(cluster, role)
        for column in range(x + 1, x + columns):
            self._cells[y][column] = Cell("", role, True)
        return x + columns

    def write(
        self,
        x: int,
        y: int,
        text: object,
        *,
        role: str = DEFAULT_ROLE,
        max_width: Optional[int] = None,
    ) -> int:
        """Write clipped text and return the next logical display column."""

        role = normalize_role(role)
        limit = None if max_width is None else max(0, int(max_width))
        cursor = int(x)
        used = 0
        for cluster in graphemes(text):
            columns = cluster_width(cluster)
            if limit is not None and used + columns > limit:
                break
            cursor = self._write_cluster(cursor, int(y), cluster, role)
            used += columns
        return cursor

    def write_spans(
        self,
        x: int,
        y: int,
        spans: Iterable[StyledText],
        *,
        max_width: Optional[int] = None,
    ) -> int:
        cursor = int(x)
        remaining = None if max_width is None else max(0, int(max_width))
        for span in spans:
            if not isinstance(span, StyledText):
                raise TypeError("write_spans accepts StyledText values")
            before = cursor
            cursor = self.write(cursor, y, span.text, role=span.role, max_width=remaining)
            if remaining is not None:
                remaining = max(0, remaining - (cursor - before))
                if remaining == 0:
                    break
        return cursor

    def fill(self, rect: Rect, text: str = " ", *, role: str = DEFAULT_ROLE) -> None:
        role = normalize_role(role)
        cluster = graphemes(text)
        fill_char = cluster[0] if cluster and cluster_width(cluster[0]) == 1 else " "
        left = max(0, rect.x)
        right = min(self.width, rect.right)
        top = max(0, rect.y)
        bottom = min(self.height, rect.bottom)
        for y in range(top, bottom):
            for x in range(left, right):
                self._clear_glyph(x, y)
                self._cells[y][x] = Cell(fill_char, role)

    def draw_text(
        self,
        x: int,
        y: int,
        width: int,
        text: object,
        *,
        role: str = DEFAULT_ROLE,
        align: str = "left",
        ellipsis: str = _ELLIPSIS,
    ) -> None:
        self.write(x, y, fit_text(text, width, align=align, ellipsis=ellipsis), role=role)

    def draw_box(
        self,
        rect: Rect,
        *,
        role: str = "muted",
        title: Optional[str] = None,
        padding: int | Sequence[int] = 0,
        ascii_only: bool = False,
        clear: bool = False,
    ) -> Rect:
        """Draw a safely clipped border and return its padded content rectangle."""

        top_pad, right_pad, bottom_pad, left_pad = _padding(padding)
        inner = rect.inset(1 + top_pad, 1 + right_pad, 1 + bottom_pad, 1 + left_pad)
        if rect.width <= 0 or rect.height <= 0:
            return inner
        chars = ASCII_BORDER if ascii_only else UNICODE_BORDER
        if clear:
            self.fill(rect, role=self.default_role)
        if rect.height == 1:
            self.write(rect.x, rect.y, chars.horizontal * rect.width, role=role)
            return inner
        if rect.width == 1:
            for y in range(rect.y, rect.bottom):
                self.write(rect.x, y, chars.vertical, role=role)
            return inner
        self.write(
            rect.x,
            rect.y,
            chars.top_left + chars.horizontal * (rect.width - 2) + chars.top_right,
            role=role,
        )
        for y in range(rect.y + 1, rect.bottom - 1):
            self.write(rect.x, y, chars.vertical, role=role)
            self.write(rect.right - 1, y, chars.vertical, role=role)
        self.write(
            rect.x,
            rect.bottom - 1,
            chars.bottom_left + chars.horizontal * (rect.width - 2) + chars.bottom_right,
            role=role,
        )
        if title and rect.width > 4:
            label = " " + truncate_text(title, rect.width - 4) + " "
            self.write(rect.x + 2, rect.y, label, role="heading", max_width=rect.width - 3)
        return inner

    def draw_row(
        self,
        rect: Rect,
        spans: Iterable[StyledText],
        *,
        selected: bool = False,
        marker: str = ">",
        ellipsis: str = _ELLIPSIS,
    ) -> None:
        """Draw one clipped row with a non-color selected marker and focus role."""

        if rect.width <= 0 or rect.height <= 0:
            return
        row_role = "focus" if selected else self.default_role
        self.fill(Rect(rect.x, rect.y, rect.width, 1), role=row_role)
        marker_text = marker if selected else " " * display_width(marker)
        marker_text = truncate_text(marker_text, rect.width, ellipsis="")
        self.write(rect.x, rect.y, marker_text, role=row_role)
        content_x = rect.x + display_width(marker_text)
        available = max(0, rect.width - display_width(marker_text))
        clipped = truncate_spans(spans, available, ellipsis=ellipsis)
        if selected:
            clipped = tuple(StyledText(span.text, "focus") for span in clipped)
        self.write_spans(content_x, rect.y, clipped, max_width=available)

    def iter_spans(self, *, include_blank: bool = True) -> Iterator[StyledSpan]:
        """Yield deterministic row-local style runs for a screen backend."""

        for y, row in enumerate(self._cells):
            start = 0
            role: Optional[str] = None
            text_parts = []
            width = 0

            def emit() -> Optional[StyledSpan]:
                if role is None or width == 0:
                    return None
                text = "".join(text_parts)
                if not include_blank and not text.strip():
                    return None
                return StyledSpan(y, start, text, role, width)

            for x, cell in enumerate(row):
                if role is None:
                    start = x
                    role = cell.role
                elif cell.role != role:
                    span = emit()
                    if span is not None:
                        yield span
                    start = x
                    role = cell.role
                    text_parts = []
                    width = 0
                width += 1
                if not cell.continuation:
                    text_parts.append(cell.text)
            span = emit()
            if span is not None:
                yield span

    def render_plain_lines(self, *, trim_trailing: bool = False) -> Tuple[str, ...]:
        lines = []
        for row in self._cells:
            line = "".join(cell.text for cell in row if not cell.continuation)
            lines.append(line.rstrip() if trim_trailing else line)
        return tuple(lines)

    def render_plain(self, *, trim_trailing: bool = False) -> str:
        return "\n".join(self.render_plain_lines(trim_trailing=trim_trailing))

    def snapshot_dict(self, *, trim_trailing: bool = True) -> dict:
        """Return reviewed plain lines plus semantic role spans (no ANSI bytes)."""

        plain = list(self.render_plain_lines(trim_trailing=trim_trailing))
        spans_by_row: dict[int, list] = {}
        for span in self.iter_spans(include_blank=False):
            spans_by_row.setdefault(span.row, []).append(
                {
                    "col": span.column,
                    "text": span.text,
                    "role": span.role,
                    "width": span.width,
                }
            )
        spans = [spans_by_row.get(row, []) for row in range(self.height)]
        return {"width": self.width, "height": self.height, "plain": plain, "spans": spans}
