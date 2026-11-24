"""Parse Daily Markdown bytes without modifying the source."""

from bisect import bisect_right
from dataclasses import dataclass
from datetime import date
import re

from markdown_it import MarkdownIt
from markdown_it.token import Token


@dataclass(frozen=True)
class Span:
    start: int
    end: int
    line: int
    column: int


@dataclass(frozen=True)
class Source:
    text: str
    has_bom: bool
    line_starts: tuple[int, ...]

    def lines(self, first: int, stop: int) -> Span:
        return Span(self.line_starts[first], self.line_starts[stop], first + 1, 1)

    def text_at(self, span: Span) -> str:
        return self.text[span.start:span.end]


class ParseError(ValueError):
    def __init__(self, code: str, span: Span | None = None):
        self.code = code
        self.span = span
        location = f" at line {span.line}" if span else ""
        super().__init__(code + location)


@dataclass(frozen=True)
class Heading:
    level: int
    title: str
    span: Span


@dataclass(frozen=True)
class Section:
    heading: Heading
    span: Span
    parent_offset: int


@dataclass(frozen=True)
class Topic:
    heading: Heading
    span: Span
    sections: tuple[Section, ...]


@dataclass(frozen=True)
class Completion:
    date: date
    payload: str
    category: str | None
    task: str | None
    span: Span


@dataclass(frozen=True)
class Daily:
    source: Source
    front_matter: Span | None
    worklog: Heading
    worklog_span: Span
    preamble: Span | None
    topics: tuple[Topic, ...]
    completions: tuple[Completion, ...]
    managed: tuple[Span, ...]
    headings: tuple[Heading, ...]
    root_paragraphs: tuple[Span, ...]


EOL = re.compile(r"\r\n|\r|\n")
FM_KEY = re.compile(r"[A-Za-z_][\w.-]*:[ \t]*(?:$|[^ \t])")
WORKLOG = re.compile(r"✅[ \t]*やったこと")
AUTOMATION = "🤖 自動入力"
LEGACY_BOUNDARY = {"📅 今日の予定", AUTOMATION, "🧷タグ", "🧷 タグ", "自動取得", "手動入力"}
MARKER = re.compile(r"<!-- MDH:(NAVIGATION|APPOINTMENTS):(START|END) -->")
TODO = re.compile(r"- \[TODO ([0-9]{4}-[0-9]{2}-[0-9]{2})\] (.+)")
COMMENT = re.compile(r"<!--(?:(?!-->)[\s\S])*-->")


def _read_source(raw: bytes) -> Source:
    has_bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise ParseError("INVALID_UTF8") from error
    # markdown-it normalizes NUL, which would silently change the token content.
    if "\x00" in text:
        raise ParseError("UNSUPPORTED_NUL")
    starts = [0, *(match.end() for match in EOL.finditer(text))]
    if starts[-1] != len(text):
        starts.append(len(text))
    return Source(text, has_bom, tuple(starts))


def _front_matter_end(source: Source, lines: list[str]) -> int:
    if not lines or lines[0] != "---":
        return 0
    close = next((i for i in range(1, len(lines)) if lines[i] in {"---", "..."}), None)
    content = lines[1:close]
    meaningful = [line for line in content if line.strip() and not line.startswith("# ")]
    starts_with_key = bool(meaningful and FM_KEY.match(meaningful[0]))

    if close is None:
        if starts_with_key:
            raise ParseError("FRONT_MATTER_UNCLOSED", source.lines(0, 1))
        return 0
    if not starts_with_key:
        # A heading or other explicit Markdown block distinguishes a leading rule.
        if any(re.match(r" {0,3}(?:#{1,6}[ \t]|[-*+] |>|" + chr(96) * 3 + r"|~~~)", line)
               for line in content):
            return 0
        raise ParseError("FRONT_MATTER_AMBIGUOUS", source.lines(0, close + 1))

    known_keys = {line.partition(":")[0] for line in meaningful} & {"date", "title", "tags", "projects"}
    standalone_date = any(re.fullmatch(r"date:[ \t]+[0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]*", line)
                          for line in meaningful)
    if len(known_keys) < 2 and not standalone_date:
        raise ParseError("FRONT_MATTER_AMBIGUOUS", source.lines(0, close + 1))

    # Look only for boundary evidence. Do not decode YAML or expose metadata.
    for index, line in enumerate(content, 1):
        daily_heading = re.fullmatch(r"#{1,2}[ \t]+(?:✅[ \t]*やったこと|🤖[ \t]+自動入力)[ \t]*", line)
        if daily_heading or (line and not (line.startswith((" ", "\t", "#")) or FM_KEY.match(line))):
            raise ParseError("FRONT_MATTER_AMBIGUOUS", source.lines(index, index + 1))
    return close + 1


def _token_span(source: Source, token: Token, base: int) -> Span:
    first, stop = token.map
    return source.lines(base + first, base + stop)


def _managed_regions(source: Source, tokens: list[Token], base: int) -> tuple[Span, ...]:
    starts: dict[str, Span] = {}
    closed: dict[str, Span] = {}
    for token in tokens:
        if token.type != "html_block" or token.level != 0:
            continue
        match = MARKER.fullmatch(token.content.strip())
        if not match:
            continue
        name, side = match.groups()
        here = _token_span(source, token, base)
        if name in closed or (side == "START") == (name in starts):
            raise ParseError("MANAGED_MARKERS_AMBIGUOUS", here)
        if side == "START":
            starts[name] = here
        else:
            start = starts.pop(name)
            closed[name] = Span(start.start, here.end, start.line, 1)
    if starts:
        raise ParseError("MANAGED_MARKERS_UNCLOSED", next(iter(starts.values())))
    ordered = tuple(sorted(closed.values(), key=lambda span: span.start))
    if len(ordered) == 2 and ordered[0].end > ordered[1].start:
        raise ParseError("MANAGED_REGIONS_OVERLAP", ordered[1])
    return ordered


def _root_headings(source: Source, tokens: list[Token], base: int, managed: tuple[Span, ...]) -> tuple[Heading, ...]:
    result = []
    for index, token in enumerate(tokens):
        if token.type != "heading_open" or token.level != 0:
            continue
        span = _token_span(source, token, base)
        if any(region.start <= span.start < region.end for region in managed):
            continue
        result.append(Heading(int(token.tag[1:]), tokens[index + 1].content, span))
    return tuple(result)


def _bounded_body(heading: Heading, end: int) -> Span:
    return Span(heading.span.start, end, heading.span.line, 1)


def _topic_sections(topic: Heading, end: int, children: tuple[Heading, ...]) -> tuple[Section, ...]:
    sections = []
    stack: list[tuple[Heading, Heading]] = []
    for heading in children:
        while stack and stack[-1][0].level >= heading.level:
            finished, parent = stack.pop()
            sections.append(Section(finished, _bounded_body(finished, heading.span.start), parent.span.start))
        parent = stack[-1][0] if stack else topic
        stack.append((heading, parent))
    for heading, parent in stack:
        sections.append(Section(heading, _bounded_body(heading, end), parent.span.start))
    return tuple(sorted(sections, key=lambda section: section.span.start))


def _completion_line(source: Source, span: Span) -> Completion | None:
    match = TODO.fullmatch(source.text_at(span).rstrip("\r\n"))
    if not match:
        return None
    date_text, payload = match.groups()
    try:
        completed = date.fromisoformat(date_text)
    except ValueError:
        return None

    # The existing writer does not escape the separator. Preserve the full
    # payload and only split when there is exactly one viable separator.
    separators = [
        match.start() for match in re.finditer(r": ", payload)
        if payload[:match.start()].strip() and payload[match.end():].strip()
    ]
    if not separators:
        return None
    category = task = None
    if len(separators) == 1:
        split = separators[0]
        category, task = payload[:split], payload[split + 2:]
    return Completion(completed, payload, category, task, span)


def _classify_done(source: Source, heading: Heading, end: int, tokens: list[Token], base: int, *, managed: bool) -> tuple[Completion, ...]:
    records = []
    ignored_lines = set()
    eligible_lines = set()
    for token in tokens:
        if token.map is None:
            continue
        span = _token_span(source, token, base)
        if not heading.span.end <= span.start < end:
            continue
        if token.type == "list_item_open" and token.level == 1 and token.markup == "-":
            eligible_lines.add(span.line - 1)
        elif token.level == 0 and (
            token.type == "hr" or (
                token.type == "html_block" and COMMENT.fullmatch(token.content.strip())
                and not MARKER.fullmatch(token.content.strip())
            )
        ):
            ignored_lines.update(range(base + token.map[0], base + token.map[1]))

    first = bisect_right(source.line_starts, heading.span.end) - 1
    stop = bisect_right(source.line_starts, end) - 1
    substantive = []
    for index in range(first, stop):
        span = source.lines(index, index + 1)
        if index in ignored_lines or not source.text_at(span).strip():
            continue
        record = _completion_line(source, span) if index in eligible_lines else None
        if record:
            records.append(record)
        else:
            substantive.append(span)
    if substantive and (managed or records):
        raise ParseError("INVALID_MANAGED_DONE" if managed else "MIXED_LEGACY_DONE", substantive[0])
    return tuple(records)


def parse_daily(raw: bytes) -> Daily:
    """Return structure and spans indexed into the original BOM-free Unicode text."""
    source = _read_source(raw)
    lines = EOL.split(source.text)
    if lines and not lines[-1]:
        lines.pop()
    base = _front_matter_end(source, lines)
    front_matter = source.lines(0, base) if base else None
    tokens = MarkdownIt("commonmark").parse(source.text[source.line_starts[base]:])
    managed = _managed_regions(source, tokens, base)
    headings = _root_headings(source, tokens, base, managed)
    worklogs = tuple(h for h in headings if h.level <= 2 and WORKLOG.fullmatch(h.title))
    if len(worklogs) != 1:
        raise ParseError("WORKLOG_MISSING" if not worklogs else "WORKLOG_AMBIGUOUS",
                         worklogs[-1].span if worklogs else None)

    worklog = worklogs[0]
    afterward = headings[headings.index(worklog) + 1:]
    closing_h1 = next((h for h in afterward if h.level == 1), None)
    end = closing_h1.span.start if closing_h1 else len(source.text)
    inside = tuple(h for h in afterward if h.span.start < end)
    peers = tuple(h for h in inside if h.level == 2)
    if worklog.level == 2:
        boundary = next((h for h in peers if h.title in LEGACY_BOUNDARY), None)
        if boundary or (peers and not closing_h1):
            raise ParseError("LEGACY_WORKLOG_AMBIGUOUS", (boundary or peers[0]).span)

    preamble_end = peers[0].span.start if peers else end
    preamble = None
    if source.text[worklog.span.end:preamble_end].strip():
        line = bisect_right(source.line_starts, worklog.span.end)
        preamble = Span(worklog.span.end, preamble_end, line, 1)

    topics = []
    completions = []
    for index, peer in enumerate(peers):
        topic_end = peers[index + 1].span.start if index + 1 < len(peers) else end
        if peer.title == "done":
            records = _classify_done(source, peer, topic_end, tokens, base, managed=False)
            if records:
                completions.extend(records)
                continue
        children = tuple(h for h in inside if peer.span.start < h.span.start < topic_end)
        topics.append(Topic(peer, _bounded_body(peer, topic_end),
                            _topic_sections(peer, topic_end, children)))

    automation = tuple(h for h in headings if h.level == 1 and h.title == AUTOMATION)
    if len(automation) > 1:
        raise ParseError("AUTOMATION_AMBIGUOUS", automation[1].span)
    if automation:
        parent = automation[0]
        for index, heading in enumerate(headings):
            if heading.span.start > parent.span.start and heading.level == 1:
                stop = index
                break
        else:
            stop = len(headings)
        auto_end = headings[stop].span.start if stop < len(headings) else len(source.text)
        children = tuple(h for h in headings[headings.index(parent) + 1:stop] if h.level == 2)
        done = tuple(h for h in children if h.title == "done")
        if len(done) != 1:
            raise ParseError("MANAGED_DONE_AMBIGUOUS" if done else "MANAGED_DONE_MISSING", parent.span)
        position = children.index(done[0]) + 1
        stop = children[position].span.start if position < len(children) else auto_end
        completions.extend(_classify_done(source, done[0], stop, tokens, base, managed=True))

    root_paragraphs = tuple(_token_span(source, token, base) for token in tokens
                            if token.type == "paragraph_open" and token.level == 0)
    return Daily(source, front_matter, worklog, _bounded_body(worklog, end),
                 preamble, tuple(topics), tuple(sorted(completions, key=lambda row: row.span.start)),
                 managed, headings, root_paragraphs)
