"""Search over contiguous source spans in one read-only database snapshot."""

from bisect import bisect_right
from collections.abc import Iterable, Iterator
from dataclasses import astuple, dataclass
from datetime import date
from pathlib import Path
import re
import sqlite3

from .parser import AUTOMATION, Daily, EOL
from .storage import DailyRootMismatch, DatabaseIntegrityError, check_integrity, open_database, root_identity_path, transaction

SCHEDULE = "📅 今日の予定"
LINK = r"\[(?:←|→) \d{4}-\d{2}-\d{2}\]\([^)\r\n]*\.md\)"
LEGACY_LINK = re.compile(LINK + rf"(?: \| {LINK})*")
ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
EXCLUDED_STATES = ("STALE", "INVALID", "MISSING", "DELETED")


@dataclass(frozen=True)
class SearchSpan:
    kind: str
    group_start: int
    title: str
    start: int
    stop: int
    line: int
    column: int
    body: str


@dataclass(frozen=True)
class Match:
    term: str
    start: int
    stop: int
    line: int
    column: int
    excerpt: str


@dataclass(frozen=True)
class SearchHit:
    day: str
    path: str
    kind: str
    group_start: int
    title: str
    status: str
    snapshot_hash: str
    matches: tuple[Match, ...]

    @property
    def from_last_good_snapshot(self) -> bool:
        """STALE positions may differ from the current Markdown on disk."""
        return self.status == "STALE"


@dataclass(frozen=True)
class SearchResult:
    hits: tuple[SearchHit, ...]
    excluded: dict[str, int]
    undated_invalid: int
    last_full_success: str | None
    last_attempt: str | None
    stale_in_scope: int
    incomplete: bool


def _groups(daily: Daily):
    """Yield (kind, source identity, title, searchable contiguous ranges)."""
    text = daily.source.text
    denied = [(span.start, span.end) for span in daily.managed]
    if daily.front_matter:
        denied.append((daily.front_matter.start, daily.front_matter.end))

    # Legacy Daily used one generated link line in the header without markers.
    first_heading = daily.headings[0].span.start
    if not any(text[start:end].startswith("<!-- MDH:NAVIGATION:START -->") for start, end in denied):
        legacy = [span for span in daily.root_paragraphs if span.end <= first_heading
                  and LEGACY_LINK.fullmatch(daily.source.text_at(span).rstrip("\r\n"))]
        if len(legacy) == 1:
            denied.append((legacy[0].start, legacy[0].end))

    outside_denied = list(denied)
    excluded_titles = set()
    boundaries = {0, len(text), daily.worklog_span.start, daily.worklog_span.end}
    outside_headings = {}
    parent = None
    headings = daily.headings
    for index, heading in enumerate(headings):
        start = heading.span.start
        if daily.worklog_span.start <= start < daily.worklog_span.end:
            parent = None
            continue
        if heading.level <= 2:
            boundaries.add(start)
            outside_headings[start] = heading.title
        if heading.title == SCHEDULE and heading.level <= 2:
            outside_denied.append((start, heading.span.end))
            excluded_titles.add(start)
        if heading.level == 1:
            parent = heading.title
            if parent == AUTOMATION:
                outside_denied.append((start, heading.span.end))
                excluded_titles.add(start)
        elif parent == SCHEDULE and heading.title in {"自動取得", "手動入力"}:
            outside_denied.append((start, heading.span.end))
            excluded_titles.add(start)
        elif parent == AUTOMATION and heading.level == 2 and heading.title == "done":
            end = next((h.span.start for h in headings[index + 1:] if h.level <= 2), len(text))
            outside_denied.append((start, end))
            excluded_titles.add(start)

    def visible(start, end, exclusions):
        cursor = start
        for left, right in sorted(exclusions):
            if left >= end:
                break
            if right <= cursor:
                continue
            if cursor < left and text[cursor:left].strip():
                yield cursor, left
            cursor = min(end, right)
        if cursor < end and text[cursor:end].strip():
            yield cursor, end

    for topic in daily.topics:
        yield "topic", topic.span.start, topic.heading.title, visible(topic.span.start, topic.span.end, denied)
    if daily.preamble:
        start, end = daily.preamble.start, daily.preamble.end
        yield "preamble", start, "", visible(start, end, denied)
    for completion in daily.completions:
        start, end = completion.span.start, completion.span.end
        yield "completion", start, completion.category or "", visible(start, end, denied)
    limits = sorted(boundaries)
    for start, end in zip(limits, limits[1:]):
        if daily.worklog_span.start <= start < daily.worklog_span.end:
            continue
        title = "" if start in excluded_titles else outside_headings.get(start, "")
        yield "daily_segment", start, title, visible(start, end, outside_denied)


def build_search_spans(daily: Daily) -> Iterator[SearchSpan]:
    """Project parsed structure to independent contiguous source slices."""
    source = daily.source
    for kind, key, title, ranges in _groups(daily):
        for start, stop in ranges:
            line = bisect_right(source.line_starts, start)
            column = start - source.line_starts[line - 1] + 1
            yield SearchSpan(kind, key, title, start, stop, line, column, source.text[start:stop])


def insert_search_spans(db: sqlite3.Connection, daily_id: int, spans: Iterable[SearchSpan]) -> None:
    """Insert spans in the caller's snapshot transaction without committing."""
    if not db.in_transaction:
        raise ValueError("Search spans require an active transaction")
    db.executemany("""
        INSERT INTO search_document
            (daily_id, kind, group_start, title, start, stop, line, column_no, body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, ((daily_id, *astuple(span)) for span in spans))


def _like_pattern(term: str) -> str:
    literal = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{literal}%"


def query_terms(query: str) -> tuple[str, ...]:
    if "\x00" in query:
        raise ValueError("Search query must not contain NUL")
    return tuple(dict.fromkeys(query.split()))


def matches_in_span(body, term, start, line, column, *, require_match=False, folded=None):
    """Yield the first match per source line, using code-point positions."""
    haystack = body.translate(ASCII_LOWER) if folded is None else folded
    needle = term.translate(ASCII_LOWER)
    index = haystack.find(needle)
    if index < 0 and require_match:
        raise DatabaseIntegrityError("SQLite LIKE and source position matching disagree")
    line_start = 0
    for newline in EOL.finditer(body):
        if index == -1:
            break
        if index < newline.start():
            stop = index + len(term)
            yield Match(term, start + index, start + stop, line,
                        column + index - line_start, body[index:stop])
            index = haystack.find(needle, newline.end())
        line_start, line, column = newline.end(), line + 1, 1
    if index != -1:
        stop = index + len(term)
        yield Match(term, start + index, start + stop, line,
                    column + index - line_start, body[index:stop])


def _matched_groups(db, terms, accepted, lower, upper) -> tuple[SearchHit, ...]:
    if not terms:
        return ()
    placeholders = ", ".join("(?, ?)" for _ in terms)
    state_params = ", ".join("?" for _ in accepted)
    rows = db.execute(rf"""
        WITH terms(term_id, pattern) AS (VALUES {placeholders}),
        matched AS MATERIALIZED (
            SELECT d.day, d.source_path, d.source_hash, f.status, s.*, q.term_id
            FROM searchable s
            JOIN daily d USING (daily_id)
            JOIN sync_file f ON f.snapshot_id = d.daily_id
            CROSS JOIN terms q
            WHERE f.status IN ({state_params}) AND s.body LIKE q.pattern ESCAPE '\'
              AND (? IS NULL OR d.day >= ?) AND (? IS NULL OR d.day <= ?)
        ),
        eligible AS (
            SELECT daily_id, kind, group_start FROM matched
            GROUP BY daily_id, kind, group_start HAVING COUNT(DISTINCT term_id) = ?
        )
        SELECT day, source_path, kind, group_start, title, status, source_hash,
               start, line, column_no, body, term_id
        FROM matched JOIN eligible USING (daily_id, kind, group_start)
        ORDER BY day DESC, group_start, kind, start, term_id
    """, (*[value for index, term in enumerate(terms) for value in (index, _like_pattern(term))],
          *accepted, lower, lower, upper, upper, len(terms)))
    hits = {}
    for *key, start, line, column, body, term_id in rows:
        term = terms[term_id]
        matches = hits.setdefault(tuple(key), [])
        matches.extend(matches_in_span(body, term, start, line, column, require_match=True))
    return tuple(SearchHit(*key, tuple(matches)) for key, matches in hits.items())


def search(path: Path, query: str, *, include_stale: bool = False,
           after: date | None = None, before: date | None = None,
           expected_root_identity: str | None = None) -> SearchResult:
    """Search stored snapshots without reading source files or updating SQLite.

    Date bounds are inclusive. Blank queries return coverage with no hits.
    """
    if after is not None and before is not None and after > before:
        raise ValueError("Search start date must not be after its end date")
    terms = query_terms(query)
    accepted = ("CURRENT", "STALE") if include_stale else ("CURRENT",)
    lower = after.isoformat() if after is not None else None
    upper = before.isoformat() if before is not None else None
    with open_database(path) as db, transaction(db):
        check_integrity(db)
        metadata = db.execute(
            "SELECT last_full_success, last_attempt, root_identity FROM metadata WHERE singleton = 1"
        ).fetchone()
        if metadata is None:
            raise DatabaseIntegrityError("Database metadata is missing")
        last_full_success, last_attempt, root_identity = metadata
        if expected_root_identity is not None and root_identity != expected_root_identity:
            raise DailyRootMismatch(root_identity_path(root_identity), root_identity_path(expected_root_identity))
        counts = dict(db.execute("""
            SELECT status, COUNT(*) FROM sync_file
            WHERE (? IS NULL OR day >= ?) AND (? IS NULL OR day <= ?)
            GROUP BY status
        """, (lower, lower, upper, upper)))
        undated = 0
        if lower is not None or upper is not None:
            undated, = db.execute(
                "SELECT COUNT(*) FROM sync_file WHERE day IS NULL AND status = 'INVALID'"
            ).fetchone()
        hits = _matched_groups(db, terms, accepted, lower, upper)

    excluded = {state: counts.get(state, 0) for state in EXCLUDED_STATES if state not in accepted}
    incomplete = bool(
        undated or last_full_success is None or last_attempt != last_full_success
        or any(excluded.get(state, 0) for state in ("STALE", "INVALID", "MISSING"))
    )
    return SearchResult(hits, excluded, undated, last_full_success, last_attempt,
                        counts.get("STALE", 0) if include_stale else 0, incomplete)
