"""Rebase recognized Markdown destinations without reserializing Topic bodies."""

from bisect import bisect_left
import os
from pathlib import Path
import re
from urllib.parse import quote, unquote, urlsplit

from markdown_it import MarkdownIt
from markdown_it.rules_inline import image, link

from .aggregate import Entry, grouped_entries, relative_url


def _destination_spans(content: str, env: dict):
    spans = []
    references = False
    parser = MarkdownIt("commonmark", {"store_labels": True})

    def observe(rule, rule_name):
        def wrapped(state, silent):
            nonlocal references
            start, token_start = state.pos, len(state.tokens)
            result = rule(state, silent)
            if not result or silent or state.src is not content:
                return result
            end = state.pos
            parsed = next((token for token in state.tokens[token_start:]
                           if token.type == rule_name), None)
            if parsed is None:
                return result
            if parsed.meta.get("label"):
                references = True
                return result
            label_start = start + (rule_name == "image")
            label_end = parser.helpers.parseLinkLabel(state, label_start, rule_name == "link_open")
            if label_end < 0 or state.src[label_end + 1:label_end + 2] != "(" or state.src[end - 1] != ")":
                return result
            first = label_end + 2
            while first < end and content[first] in " \t\n":
                first += 1
            parsed_target = parser.helpers.parseLinkDestination(content, first, end - 1)
            if parsed_target.ok and parsed_target.pos > first:
                spans.append((first, parsed_target.pos, parsed_target.str))
            return result
        return wrapped

    parser.inline.ruler.at("link", observe(link, "link_open"))
    parser.inline.ruler.at("image", observe(image, "image"))
    children = parser.parseInline(content, env)[0].children or []
    html = any(token.type == "html_inline" and re.search(r"\b(?:href|src)\s*=", token.content, re.I)
               for token in children)
    return spans, references or html


def _line_offsets(text: str) -> list[int]:
    return [0, *(match.end() for match in re.finditer(r"\n", text))]


def _inline_offsets(content: str, rows: list[str], offsets: list[int], first: int, stop: int) -> list[int] | None:
    positions = []
    cursor = first
    for line in content.split("\n"):
        while cursor < stop and line not in rows[cursor]:
            cursor += 1
        if cursor >= stop:
            return None
        # Match the inline text at a unique position in this source line.
        start = rows[cursor].find(line)
        if line and rows[cursor].find(line, start + 1) >= 0:
            return None
        absolute = offsets[cursor] + start
        positions.extend(range(absolute, absolute + len(line)))
        positions.append(offsets[cursor] + len(rows[cursor]))
        cursor += 1
    return positions


def _rebase(destination: str, source: Path, directory: Path, warn) -> str | None:
    if not destination or destination.startswith(("/", "\\")):
        return None
    try:
        # urlsplit silently strips some controls and leading spaces. Keep them as URI data.
        encoded = re.sub(r"[\x00-\x20\x7f]", lambda match: quote(match[0], safe=""), destination)
        url = urlsplit(encoded)
        if url.scheme or url.netloc:
            return None
        target = Path(os.path.abspath(source.parent / unquote(url.path))) if url.path else source
        if not target.exists():
            warn(f"Link target is missing: {destination}")
        result = relative_url(target, directory)
    except (OSError, ValueError) as error:
        warn(f"Link kept unchanged: {destination} ({error})")
        return None
    suffix = ""
    if "?" in encoded.split("#", 1)[0]:
        suffix += "?" + url.query
    if "#" in encoded:
        suffix += "#" + url.fragment
    # Markdown-it decoded the original escapes. Restore them without altering URI escapes.
    return result + re.sub(r"[\\()<>&]", lambda match: "\\" + match[0], suffix)


def topic_body(entry: Entry, directory: Path, warnings: list[str], env: dict) -> str:
    def warn(message):
        warnings.append(f"{entry.path}:{entry.topic.heading.span.line}: {message}")

    body = entry.source.text[entry.topic.heading.span.end:entry.topic.span.end]
    body = body.replace("\r\n", "\n").replace("\r", "\n")
    rows = body.split("\n")
    offsets = _line_offsets(body)
    edits = []
    first_line = bisect_left(entry.source.line_starts, entry.topic.heading.span.end)
    for section in entry.topic.sections:
        heading = section.heading
        row = heading.span.line - 1 - first_line
        marker = re.match(r" {0,3}(#{3,6})(?=[ \t]|$)", rows[row])
        if heading.level == 6:
            warn("H6 is already the deepest heading")
        elif marker:
            pos = offsets[row] + marker.start(1)
            edits.append((pos, pos, "#"))
    for token in MarkdownIt("commonmark").parse(body, dict(env)):
        if token.type == "html_block" and re.search(r"\b(?:href|src)\s*=", token.content, re.I):
            warn("HTML link kept unchanged")
        if token.type != "inline":
            continue
        spans, unsupported = _destination_spans(token.content, env)
        if unsupported:
            warn("Reference or HTML link kept unchanged")
        if not spans:
            continue
        positions = _inline_offsets(token.content, rows, offsets, *token.map)
        for start, stop, destination in spans:
            if positions is None or positions[stop - 1] - positions[start] != stop - start - 1:
                warn(f"Could not locate source link exactly: {destination}")
                continue
            replacement = _rebase(destination, entry.path, directory, warn)
            if replacement is not None:
                original = token.content[start:stop]
                if original.startswith("<"):
                    replacement = "<" + replacement + ">"
                edits.append((positions[start], positions[stop - 1] + 1, replacement))
    for start, stop, replacement in sorted(edits, reverse=True):
        body = body[:start] + replacement + body[stop:]
    return body.strip("\n")


def render_topics(name: str, entries: list[Entry], directory: Path, warnings: list[str]) -> str:
    chunks = [f"# {name}"]
    environments = {}
    for group in grouped_entries(entries):
        chunks.append(f"## {group[0].type or '未分類'}")
        for entry in group:
            title = " ".join((entry.title or entry.topic.heading.title).splitlines())
            chunks.append(f"### {entry.day}｜{title}")
            chunks.append(f"[元の日報]({relative_url(entry.path, directory)})")
            if entry.path not in environments:
                env = {}
                MarkdownIt("commonmark").parse(entry.source.text, env)
                environments[entry.path] = env
            if body := topic_body(entry, directory, warnings, environments[entry.path]):
                chunks.append(body)
    return "\n\n".join(chunks) + "\n"
