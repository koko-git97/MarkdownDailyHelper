"""Aggregate Topic snapshots directly from Daily Markdown."""

from collections import defaultdict
from dataclasses import dataclass
from datetime import date
import json
import os
from pathlib import Path
import re
import stat
import unicodedata
from urllib.parse import quote

from .parser import Source, Topic, parse_daily


class AggregateError(ValueError):
    pass


@dataclass(frozen=True)
class Concept:
    name: str
    keywords: tuple[str, ...] = ()
    category: str = ""


@dataclass(frozen=True)
class Entry:
    path: Path
    day: date
    source: Source
    topic: Topic
    type: str | None
    title: str


def normalize(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold()


def split_type(title: str) -> tuple[str | None, str]:
    prefix = re.match(r"^\[([^\[\]\r\n]*)\]", title)
    if prefix and (label := prefix[1].strip()):
        return label, title[prefix.end():].lstrip()
    return None, title


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AggregateError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _invalid_number(value):
    raise AggregateError(f"Invalid JSON number: {value}")


def decode_json(text: str):
    return json.loads(text, object_pairs_hook=_unique_object, parse_constant=_invalid_number)


@dataclass(frozen=True)
class _JsonNumber:
    literal: str


# Keep number tokens exact and distinct from JSON strings while validating a configuration.
_CONFIG_DECODER = json.JSONDecoder(
    object_pairs_hook=_unique_object, parse_constant=_invalid_number,
    parse_int=_JsonNumber, parse_float=_JsonNumber,
)
_JSON_WHITESPACE = re.compile(r"[ \t\r\n]*")


def decode_config(text: str):
    return _CONFIG_DECODER.decode(text)


def insert_concept(text: str, config: dict, name: str) -> str:
    """Insert only the new property into an already validated configuration."""
    root = _JSON_WHITESPACE.match(text).end()
    opening = root
    member = f'{json.dumps(name, ensure_ascii=False)}: {{"keywords": []}}'
    if "concepts" in config:
        # Decode top-level keys/values to locate the actual member, including escaped key names.
        pos = _JSON_WHITESPACE.match(text, root + 1).end()
        while text[pos] != "}":
            key, after_key = _CONFIG_DECODER.raw_decode(text, pos)
            colon = _JSON_WHITESPACE.match(text, after_key).end()
            value = _JSON_WHITESPACE.match(text, colon + 1).end()
            if key == "concepts":
                opening = value
                break
            _, stop = _CONFIG_DECODER.raw_decode(text, value)
            separator = _JSON_WHITESPACE.match(text, stop).end()
            if text[separator] != ",":
                raise AggregateError("Could not locate the concepts object")
            pos = _JSON_WHITESPACE.match(text, separator + 1).end()
    else:
        member = f'"concepts": {{{member}}}'

    start = opening + 1
    insert_at = _JSON_WHITESPACE.match(text, start).end()
    if text[insert_at] != "}":
        member += "," + (text[start:insert_at] or " ")
    updated = text[:insert_at] + member + text[insert_at:]
    expected = {**config, "concepts": {**config.get("concepts", {}), name: {"keywords": []}}}
    if decode_config(updated) != expected:
        raise AggregateError("Registration would alter existing configuration")
    return updated


def read_concepts(config: dict) -> list[Concept]:
    if not isinstance(config, dict) or not isinstance(config.get("concepts", {}), dict):
        raise AggregateError("config.json and concepts must be JSON objects")
    concepts = []
    for name, value in config.get("concepts", {}).items():
        if not name.strip() or not isinstance(value, dict):
            raise AggregateError(f"Invalid Concept configuration: {name!r}")
        keywords = value.get("keywords", [])
        category = value.get("category", "")
        if not isinstance(keywords, list) or not all(isinstance(item, str) for item in keywords):
            raise AggregateError(f"Concept {name!r}: keywords must be a string array")
        if not isinstance(category, str):
            raise AggregateError(f"Concept {name!r}: category must be a string")
        concepts.append(Concept(name, tuple(keywords), category))
    return concepts


def is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def collect_entries(root: Path) -> list[Entry]:
    """Validate every Markdown input before callers may publish any output."""
    if not root.is_dir():
        raise AggregateError(f"Daily root is not a directory: {root}")

    def on_error(error):
        raise error

    entries = []
    paths = set()
    for directory, dirs, files in os.walk(root, onerror=on_error, followlinks=False):
        base = Path(directory)
        for name in sorted(dirs):
            if is_link((base / name).lstat()):
                raise AggregateError(f"Linked directory in Daily root: {base / name}")
        dirs.sort()
        for name in sorted(files):
            path = base / name
            if path.suffix.lower() != ".md":
                continue
            if base == root and name == "README.md":
                info = path.lstat()
                if is_link(info) or not stat.S_ISREG(info.st_mode):
                    raise AggregateError("Daily README is not a regular file")
                continue
            relative = path.relative_to(root)
            try:
                if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", path.stem):
                    raise AggregateError("Invalid Daily filename")
                day = date.fromisoformat(path.stem)
                if relative.parts[:-1] != (path.stem[:4], path.stem[:7]):
                    raise AggregateError("Invalid Daily directory hierarchy")
                key = normalize(relative.as_posix())
                if key in paths:
                    raise AggregateError("Duplicate Daily path")
                paths.add(key)
                info = path.lstat()
                if is_link(info) or not stat.S_ISREG(info.st_mode):
                    raise AggregateError("Daily input is not a regular file")
                daily = parse_daily(path.read_bytes())
            except (OSError, ValueError) as error:
                raise AggregateError(f"{relative.as_posix()}: {error}") from error
            entries.extend(Entry(path, day, daily.source, topic, *split_type(topic.heading.title))
                           for topic in daily.topics)
    return sorted(entries, key=lambda item: (-item.day.toordinal(), item.path.as_posix(), item.topic.span.start))


def select_entries(entries: list[Entry], concept: Concept, type_filter: str | None = None) -> list[Entry]:
    terms = {normalize(term) for term in (concept.name, *concept.keywords) if term.strip()}
    return [
        entry for entry in entries
        if (type_filter is None or (entry.type is not None and normalize(entry.type) == normalize(type_filter)))
        and any(term in normalize(entry.title) for term in terms)
    ]


_RESERVED = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9]|LPT[1-9])", re.I)


def filename_part(name: str, *, suffix: str = "") -> str:
    normalized = unicodedata.normalize("NFKC", name)
    candidate = "".join("_" if ch.isspace() or unicodedata.category(ch) == "Cc" or ch in '\\/:*?"<>|'
                        else ch for ch in normalized)
    candidate = re.sub(r"_+", "_", candidate).lstrip("_").rstrip("_. ")
    if not candidate:
        raise AggregateError(f"Invalid output name: {name!r}")
    if _RESERVED.fullmatch(candidate.split(".")[0].rstrip(" ")):
        candidate = "_" + candidate
    if len((candidate + suffix).encode("utf-16-le")) // 2 > 255:
        raise AggregateError(f"Output name exceeds 255 UTF-16 code units: {name!r}")
    return candidate + suffix


def output_parts(concept: Concept) -> tuple[str, ...]:
    category = (filename_part(concept.category),) if concept.category else ()
    return (*category, filename_part(concept.name, suffix=".md"))


def conflicts(outputs: dict[str, tuple[str, ...]]) -> set[str]:
    blocked = set()
    terminal = {("index.md",): [""]}
    for name, parts in outputs.items():
        terminal.setdefault(tuple(normalize(part) for part in parts), []).append(name)
    for parts, names in terminal.items():
        if len(names) > 1:
            blocked.update(names)
        parent = terminal.get(parts[:1]) if len(parts) > 1 else None
        if parent:
            blocked.update((*names, *parent))
    return blocked - {""}


def grouped_entries(entries: list[Entry]) -> list[list[Entry]]:
    groups = defaultdict(list)
    for entry in entries:
        groups[normalize(entry.type) if entry.type is not None else None].append(entry)
    return sorted(groups.values(), key=lambda group: (-group[0].day.toordinal(),
                                                       normalize(group[0].type or "未分類"), group[0].type or ""))


def relative_url(target: Path, directory: Path) -> str:
    if os.name == "nt" and target.drive and target.drive.lower() != directory.drive.lower():
        # There is no relative path across Windows drives.
        if target.drive.startswith("\\\\?\\"):
            raise AggregateError(f"Cannot generate a file URI without a drive-letter target: {target}")
        return target.as_uri()
    path = Path(os.path.relpath(target, directory)).as_posix()
    return "".join(char if not char.isascii() and char.isprintable() else quote(char, safe="/")
                   for char in path)
