"""Read QuickNotes directly without opening the Daily database."""

from dataclasses import asdict
from hashlib import sha256
import os
from pathlib import Path
import stat

from .aggregate import AggregateError
from .aggregate_output import OutputDirectory, _identity, _inspect
from .parser import EOL, ParseError, _read_source
from .search import ASCII_LOWER, matches_in_span, query_terms


def _verify_directories(chain):
    for directory, identity in chain:
        info, linked = _inspect(directory)
        if linked or not stat.S_ISDIR(info.st_mode) or _identity(info, directory) != identity:
            raise OSError("Directory changed during search")


def _revision(info, path):
    # Windows stat and fstat may expose different semantics for ctime.
    return _identity(info, path), info.st_size, info.st_mtime_ns


def _snapshot(path, expected, chain):
    """Read only after comparing the opened handle with the inspected file."""
    _verify_directories(chain)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    with os.fdopen(os.open(path, flags), "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or _revision(before, path) != _revision(expected, path):
            raise OSError("File changed before reading")
        _verify_directories(chain)
        current, linked = _inspect(path)
        if linked or _revision(current, path) != _revision(before, path) or current.st_ctime_ns != expected.st_ctime_ns:
            raise OSError("File changed before reading")
        raw = stream.read()
        after = os.fstat(stream.fileno())
        if _revision(after, path) != _revision(before, path) or after.st_ctime_ns != before.st_ctime_ns:
            raise OSError("File changed during reading")
    _verify_directories(chain)
    current, linked = _inspect(path)
    if linked or _revision(current, path) != _revision(before, path) or current.st_ctime_ns != expected.st_ctime_ns:
        raise OSError("File changed during reading")
    return raw


def search_quicknotes(root: Path, query: str) -> dict:
    terms = query_terms(query)
    needles = tuple(term.translate(ASCII_LOWER) for term in terms)
    logical = OutputDirectory(root, root)
    physical = OutputDirectory(logical.physical, allow_volume=True)
    if physical.physical not in physical.observed:
        raise FileNotFoundError("QuickNotes root does not exist")
    logical.check()
    chain = tuple((p, identity) for p, (identity, _) in physical.observed.items())
    pending = [(physical.physical, chain)]
    hits, diagnostics = [], []
    scanned = matching_lines = 0
    incomplete = False

    def note(code, path, message):
        diagnostics.append({"code": code, "path": path.relative_to(physical.physical).as_posix(),
                            "message": str(message)})

    while pending:
        directory, chain = pending.pop()
        try:
            _verify_directories(chain)
            with os.scandir(directory) as children:
                paths = sorted(Path(child.path) for child in children)
            _verify_directories(chain)
        except (OSError, AggregateError) as error:
            if directory == physical.physical:
                raise
            note("DIRECTORY_READ_FAILED", directory, error)
            incomplete = True
            continue
        for path in paths:
            try:
                _verify_directories(chain)
                info, linked = _inspect(path)
                if linked:
                    note("SKIPPED_REPARSE_POINT", path, "Symbolic links and reparse points are not followed")
                    continue
                if stat.S_ISDIR(info.st_mode):
                    pending.append((path, (*chain, (path, _identity(info, path)))))
                    continue
                if path.suffix.lower() != ".md":
                    continue
                if not stat.S_ISREG(info.st_mode):
                    note("SKIPPED_NON_REGULAR", path, "Only regular Markdown files are searched")
                    continue
                raw = _snapshot(path, info, chain)
                source = _read_source(raw)
            except (OSError, AggregateError, ParseError) as error:
                note("FILE_READ_FAILED", path, error)
                incomplete = True
                continue
            scanned += 1
            if not terms:
                continue
            folded = source.text.translate(ASCII_LOWER)
            if not all(needle in folded for needle in needles):
                continue
            matches = [match for term in terms for match in
                       matches_in_span(source.text, term, 0, 1, 1, folded=folded)]
            numbers = sorted({match.line for match in matches})
            source_lines = EOL.split(source.text)
            name = path.relative_to(physical.physical).as_posix()
            hits.append({"source": "QuickNotes", "path": name, "kind": "file", "title": name,
                         "snapshot_hash": sha256(raw).hexdigest(), "matches": [asdict(match) for match in matches],
                         "lines": [{"line": n, "text": source_lines[n - 1]} for n in numbers]})
            matching_lines += len(numbers)
    logical.check()
    physical.check()
    hits.sort(key=lambda hit: (hit["path"].casefold(), hit["path"]))
    diagnostics.sort(key=lambda item: (item["path"].casefold(), item["path"], item["code"]))
    return {"hits": hits, "files_scanned": scanned, "files_matched": len(hits),
            "matching_lines": matching_lines, "incomplete": incomplete, "diagnostics": diagnostics}
