"""Read QuickNotes directly without opening the Daily database."""

from dataclasses import asdict
from hashlib import sha256
import os
from pathlib import Path
import stat

from .parser import EOL, ParseError, _read_source
from .search import ASCII_LOWER, matches_in_span, query_terms


def _inspect(path):
    info = path.lstat()
    tag = getattr(info, "st_reparse_tag", None)
    # The Cloud Files tags describe managed content, not a redirected name.
    cloud = tag is not None and tag & ~0xF000 == 0x9000001A
    reparse = getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    return info, stat.S_ISLNK(info.st_mode) or bool(reparse and not cloud)


def _same_identity(first, second):
    return not (first.st_ino and second.st_ino) or (
        first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def _verify_directories(chain):
    for index, (directory, expected) in enumerate(chain):
        info, linked = _inspect(directory) if index else (directory.stat(), False)
        if linked or not stat.S_ISDIR(info.st_mode) or not _same_identity(info, expected):
            raise OSError("Directory changed during search")


def _same_revision(first, second):
    # Windows stat and fstat may expose different semantics for ctime.
    return (_same_identity(first, second) and first.st_size == second.st_size
            and first.st_mtime_ns == second.st_mtime_ns)


def _snapshot(path, expected, chain):
    """Read only after comparing the opened handle with the inspected file."""
    _verify_directories(chain)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    with os.fdopen(os.open(path, flags), "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not _same_revision(before, expected):
            raise OSError("File changed before reading")
        _verify_directories(chain)
        current, linked = _inspect(path)
        if linked or not _same_revision(current, before) or current.st_ctime_ns != expected.st_ctime_ns:
            raise OSError("File changed before reading")
        raw = stream.read()
        after = os.fstat(stream.fileno())
        if not _same_revision(after, before) or after.st_ctime_ns != before.st_ctime_ns:
            raise OSError("File changed during reading")
    _verify_directories(chain)
    current, linked = _inspect(path)
    if linked or not _same_revision(current, before) or current.st_ctime_ns != expected.st_ctime_ns:
        raise OSError("File changed during reading")
    return raw


def search_quicknotes(root: Path, query: str) -> dict:
    terms = query_terms(query)
    needles = tuple(term.translate(ASCII_LOWER) for term in terms)
    root_info = root.stat()
    if not stat.S_ISDIR(root_info.st_mode):
        raise NotADirectoryError(root)
    root_chain = ((root, root_info),)
    pending = [(root, root_chain)]
    hits, diagnostics = [], []
    scanned = matching_lines = 0
    incomplete = False

    def note(code, path, message):
        diagnostics.append({"code": code, "path": path.relative_to(root).as_posix(),
                            "message": str(message)})

    while pending:
        directory, chain = pending.pop()
        try:
            _verify_directories(chain)
            with os.scandir(directory) as children:
                paths = sorted(Path(child.path) for child in children)
            _verify_directories(chain)
        except OSError as error:
            if directory == root:
                raise
            note("DIRECTORY_READ_FAILED", directory, error)
            incomplete = True
            continue
        for path in paths:
            try:
                _verify_directories(chain)
                info, linked = _inspect(path)
                if linked:
                    note("SKIPPED_REPARSE_POINT", path, "Links and unsupported reparse points are not followed")
                    continue
                if stat.S_ISDIR(info.st_mode):
                    if info.st_ino and any(_same_identity(info, ancestor) for _, ancestor in chain if ancestor.st_ino):
                        note("SKIPPED_REPARSE_POINT", path, "Directory cycle is not followed")
                        continue
                    pending.append((path, (*chain, (path, info))))
                    continue
                if path.suffix.lower() != ".md":
                    continue
                if not stat.S_ISREG(info.st_mode):
                    note("SKIPPED_NON_REGULAR", path, "Only regular Markdown files are searched")
                    continue
                raw = _snapshot(path, info, chain)
                source = _read_source(raw)
            except (OSError, ParseError) as error:
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
            name = path.relative_to(root).as_posix()
            hits.append({"source": "QuickNotes", "path": name, "kind": "file", "title": name,
                         "snapshot_hash": sha256(raw).hexdigest(), "matches": [asdict(match) for match in matches],
                         "lines": [{"line": n, "text": source_lines[n - 1]} for n in numbers]})
            matching_lines += len(numbers)
    _verify_directories(root_chain)
    hits.sort(key=lambda hit: (hit["path"].casefold(), hit["path"]))
    diagnostics.sort(key=lambda item: (item["path"].casefold(), item["path"], item["code"]))
    return {"hits": hits, "files_scanned": scanned, "files_matched": len(hits),
            "matching_lines": matching_lines, "incomplete": incomplete, "diagnostics": diagnostics}
