"""Incremental sync of one existing DB. The caller must serialize all writers."""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date, datetime, timezone
from hashlib import sha256
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat

from .parser import Daily, ParseError, parse_daily
from .search import build_search_spans, insert_search_spans
from .storage import DatabaseIntegrityError, open_database, transaction

DAILY_NAME = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})\.md", re.IGNORECASE)
MAX_MISSING = 10


class _RecheckChanged(OSError):
    """A file reappeared during the deletion transaction."""


class _SourceChanged(OSError):
    """The source could not be verified against the bytes read for indexing."""


@dataclass(frozen=True)
class Diagnostic:
    path: str
    code: str
    message: str
    line: int | None = None


@dataclass(frozen=True)
class SyncResult:
    indexed: int
    unchanged: int
    failed: int
    missing: int
    deleted: int
    last_attempt: str
    last_full_success: str | None
    completed: bool
    scan_error: Diagnostic | None
    deletion_guard: str | None
    diagnostics: tuple[Diagnostic, ...]


@dataclass(frozen=True)
class _Candidate:
    file: Path
    relative: str
    day: str | None
    placement_error: str | None


def _linked(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def daily_root_identity(root: Path) -> str:
    """Identity to supply to storage.create_database for this Daily root."""
    resolved = root.resolve(strict=True)
    info = resolved.stat()
    if not stat.S_ISDIR(info.st_mode):
        raise NotADirectoryError(resolved)
    return f"{os.path.normcase(str(resolved))}:{info.st_dev}:{info.st_ino}"


def _candidate(root: Path, file: Path) -> _Candidate | None:
    match = DAILY_NAME.fullmatch(file.name)
    if match is None:
        return None
    day_text = match[1]
    relative = file.relative_to(root).as_posix()
    # Windows treats .MD and .md alike. Use a single DB identity for either spelling.
    relative = relative[:-3] + ".md"
    try:
        day = date.fromisoformat(day_text)
    except ValueError:
        return _Candidate(file, relative, None, "INVALID_DAILY_DATE")
    expected = f"{day.year:04d}/{day.year:04d}-{day.month:02d}/{day.isoformat()}.md"
    return _Candidate(file, relative, day_text, None if relative == expected else "INVALID_DAILY_PLACEMENT")


def _scan(root: Path) -> list[_Candidate]:
    def fail(error):
        raise error

    found = {}
    for directory, folders, files in os.walk(root, onerror=fail):
        base = Path(directory)
        for folder in folders:
            if _linked((base / folder).lstat()):
                raise OSError(f"Linked directory in Daily root: {base / folder}")
        for name in files:
            candidate = _candidate(root, base / name)
            if candidate is None:
                continue
            if candidate.relative in found:
                raise OSError(f"Duplicate Daily path: {candidate.relative}")
            found[candidate.relative] = candidate
    return sorted(found.values(), key=lambda item: item.relative)


def _observe(db, path, day, status, snapshot_id, digest, diagnosis, now):
    db.execute("""
        INSERT INTO sync_file(source_path, day, status, snapshot_id, observed_hash, diagnosis, observed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_path) DO UPDATE SET
            day=excluded.day, status=excluded.status, snapshot_id=excluded.snapshot_id,
            observed_hash=excluded.observed_hash, diagnosis=excluded.diagnosis,
            observed_at=excluded.observed_at, missing_streak=0
    """, (path, day, status, snapshot_id, digest, diagnosis, now))


def _replace_snapshot(db, candidate: _Candidate, parsed: Daily, digest: str, now: str) -> None:
    daily_id, = db.execute("""
        INSERT INTO daily(source_path, day, source_hash, indexed_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(source_path) DO UPDATE SET source_hash=excluded.source_hash, indexed_at=excluded.indexed_at
        RETURNING daily_id
    """, (candidate.relative, candidate.day, digest, now)).fetchone()
    _observe(db, candidate.relative, candidate.day, "CURRENT", daily_id, digest, None, now)
    for table in ("search_document", "completion", "topic"):
        db.execute(f"DELETE FROM {table} WHERE daily_id=?", (daily_id,))
    for topic in parsed.topics:
        start = topic.span.start
        db.execute("INSERT INTO topic VALUES (?, ?, ?, ?)", (daily_id, start, topic.span.end, topic.heading.title))
        db.executemany("""
            INSERT INTO section(daily_id, topic_start, start, stop, level, parent_start, title)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, ((daily_id, start, item.span.start, item.span.end, item.heading.level,
               None if item.parent_offset == start else item.parent_offset, item.heading.title)
              for item in topic.sections))
    db.executemany("INSERT INTO completion VALUES (?, ?, ?, ?, ?, ?, ?)", (
        (daily_id, item.span.start, item.span.end, item.date.isoformat(), item.payload, item.category, item.task)
        for item in parsed.completions
    ))
    insert_search_spans(db, daily_id, build_search_spans(parsed))


def _read_daily(file: Path) -> bytes:
    info = file.lstat()
    if _linked(info) or not stat.S_ISREG(info.st_mode):
        raise OSError("Daily input is not a regular file")
    return file.read_bytes()


def _verify_source(file: Path, digest: str) -> None:
    try:
        current = sha256(_read_daily(file)).hexdigest()
    except OSError as error:
        raise _SourceChanged(f"Cannot recheck Daily input: {error}") from error
    if current != digest:
        raise _SourceChanged("Daily input changed during synchronization")


def _sync_one(db, candidate: _Candidate, now: str) -> tuple[str, Diagnostic | None]:
    status, snapshot_id, good_hash, snapshot_day = db.execute("""
        SELECT f.status, d.daily_id, d.source_hash, d.day FROM sync_file f
        LEFT JOIN daily d ON d.daily_id=f.snapshot_id WHERE f.source_path=?
    """, (candidate.relative,)).fetchone() or (None, None, None, None)

    digest = None
    try:
        if candidate.placement_error:
            raise ParseError(candidate.placement_error)
        raw = _read_daily(candidate.file)
        digest = sha256(raw).hexdigest()
        if status == "CURRENT" and digest == good_hash:
            _verify_source(candidate.file, digest)
            return "unchanged", None
        parsed = parse_daily(raw)
        with transaction(db, write=True):
            _replace_snapshot(db, candidate, parsed, digest, now)
            _verify_source(candidate.file, digest)
        return "indexed", None
    except (ParseError, OSError, sqlite3.Error) as error:
        if isinstance(error, ParseError):
            code, line = error.code, error.span.line if error.span else None
        elif isinstance(error, _SourceChanged):
            code, line = "DAILY_SOURCE_CHANGED", None
            digest = None
        else:
            code, line = ("DAILY_READ_FAILED" if isinstance(error, OSError) else "DAILY_DATABASE_WRITE_FAILED"), None
        diagnostic = Diagnostic(candidate.relative, code, str(error), line)
        # This is a different transaction. If diagnostics cannot be committed,
        # surface the DB error rather than reporting a successful sync.
        with transaction(db, write=True):
            _observe(db, candidate.relative, snapshot_day or candidate.day,
                     "STALE" if snapshot_id is not None else "INVALID", snapshot_id,
                     digest, f"{code}: {diagnostic.message}", now)
        return "failed", diagnostic


def _valid_relative(relative: str) -> bool:
    path = PurePosixPath(relative)
    return (bool(path.parts) and not path.is_absolute() and relative == path.as_posix()
            and ".." not in path.parts and "\\" not in relative and ":" not in relative)


def _still_absent(root: Path, relative: str) -> bool:
    if not _valid_relative(relative):
        raise DatabaseIntegrityError(f"Invalid stored Daily path: {relative}")
    # A parent might have become a junction after the scan. Never follow it
    # when deciding that an earlier snapshot may be removed.
    path = root
    for part in PurePosixPath(relative).parts:
        path /= part
        try:
            info = path.lstat()
        except FileNotFoundError:
            return True
        if _linked(info):
            raise OSError(f"Linked path during absence recheck: {relative}")
    return False


def _reconcile_absences(db, root, candidates, known_snapshots, confirmed, failed, now):
    rows = db.execute("""
        SELECT f.source_path, f.day, f.snapshot_id, f.missing_streak, d.source_hash, f.observed_hash, f.diagnosis
        FROM sync_file f LEFT JOIN daily d ON d.daily_id=f.snapshot_id WHERE f.status <> 'DELETED'
    """).fetchall()
    seen = {item.relative: item for item in candidates}
    absent = [row for row in rows if row[0] not in seen]
    count = len(absent)
    if not count:
        return 0, 0, None, ()

    mass = count == len(rows) or count > MAX_MISSING or (count >= 2 and count * 2 >= len(rows))
    guard = "MASS_ABSENCE" if mass else "OBSERVATION_FAILED" if failed else None
    misplaced_days = {item.day for item in candidates if item.placement_error and item.day}
    seen_hashes = {row[5] for row in rows if row[0] in seen and row[5]}
    new_hashes = {row[5] for row in rows if row[0] in seen and row[0] not in known_snapshots and row[5]}

    # Check all absences before making any changes. An error or reappearance
    # cancels the entire deletion pass and invalidates the prior streak.
    try:
        reappeared = any(not _still_absent(root, row[0]) for row in absent)
    except OSError as error:
        diagnostics = (Diagnostic("", "ABSENCE_RECHECK_FAILED", str(error)),)
        return 0, 0, "ABSENCE_RECHECK_FAILED", diagnostics
    if reappeared:
        return 0, 0, "ABSENCE_RECHECK_CHANGED", ()

    missing = deleted = 0
    diagnostics = []
    for path, day, snapshot_id, streak, digest, _, previous_reason in absent:
        if not mass and snapshot_id is not None and day in misplaced_days:
            _observe(db, path, day, "STALE", snapshot_id, None, "POSSIBLE_DAILY_MOVE", now)
            diagnostics.append(Diagnostic(path, "POSSIBLE_DAILY_MOVE", "Daily with this date has invalid placement"))
            continue
        # A different candidate with the same source bytes may be a rename.
        moved = digest in new_hashes or (previous_reason == "POSSIBLE_DAILY_RENAME" and digest in seen_hashes)
        reason = "POSSIBLE_DAILY_RENAME" if moved else guard
        if not reason and streak and path in confirmed:
            if not _still_absent(root, path):
                raise _RecheckChanged(path)
            _observe(db, path, day, "DELETED", None, None, None, now)
            if snapshot_id is not None:
                db.execute("DELETE FROM daily WHERE daily_id=?", (snapshot_id,))
            deleted += 1
        else:
            db.execute("""
                UPDATE sync_file SET status='MISSING', observed_hash=NULL, observed_at=?,
                    diagnosis=?, missing_streak=? WHERE source_path=?
            """, (now, reason, 0 if reason else streak + 1, path))
            missing += 1
            if moved:
                diagnostics.append(Diagnostic(path, reason, "Same source bytes observed at another Daily path"))
    return missing, deleted, guard, tuple(diagnostics)


def synchronize(path: Path, root: Path, *, confirm_deletions: Iterable[str] = ()) -> SyncResult:
    """Sync an existing DB. Caller must hold exclusive ownership across this whole call.

    The confirmation list contains exact POSIX-style relative paths from this DB.
    SQLite transactions protect commits, but do not serialize entire sync runs.
    """
    if isinstance(confirm_deletions, (str, bytes)):
        raise ValueError("Pass an iterable of individually confirmed relative paths")
    confirmed = frozenset(confirm_deletions)
    if any(not _valid_relative(item) for item in confirmed):
        raise ValueError("Deletion confirmation requires relative Daily paths")
    root = Path(root).absolute()
    now = datetime.now(timezone.utc).isoformat()
    with open_database(path, read_only=False) as db:
        with transaction(db, write=True):
            row = db.execute("SELECT root_identity, last_full_success FROM metadata WHERE singleton=1").fetchone()
            if row is None:
                raise DatabaseIntegrityError("Database metadata is missing")
            expected, previous_success = row
            known_snapshots = {row[0] for row in db.execute("SELECT source_path FROM daily")}
            db.execute("UPDATE metadata SET last_attempt=? WHERE singleton=1", (now,))

        try:
            if daily_root_identity(root) != expected:
                raise OSError("Daily root identity does not match database")
            candidates = _scan(root)
            if daily_root_identity(root) != expected:
                raise OSError("Daily root changed during scan")
        except OSError as error:
            with transaction(db, write=True):
                db.execute("UPDATE sync_file SET missing_streak=0 WHERE status='MISSING'")
            failure = Diagnostic("", "DAILY_SCAN_FAILED", str(error))
            return SyncResult(0, 0, 0, 0, 0, now, previous_success, False, failure, None, (failure,))

        totals = dict(indexed=0, unchanged=0, failed=0)
        diagnostics = []
        for candidate in candidates:
            outcome, diagnostic = _sync_one(db, candidate, now)
            totals[outcome] += 1
            if diagnostic:
                diagnostics.append(diagnostic)

        scan_error = None
        try:
            with transaction(db, write=True):
                if daily_root_identity(root) != expected:
                    raise OSError("Daily root changed during sync")
                missing, deleted, guard, absence_diagnostics = _reconcile_absences(
                    db, root, candidates, known_snapshots, confirmed, totals["failed"], now
                )
                if daily_root_identity(root) != expected:
                    raise OSError("Daily root changed during deletion recheck")
                diagnostics.extend(absence_diagnostics)
                if guard or totals["failed"]:
                    db.execute("UPDATE sync_file SET missing_streak=0 WHERE status='MISSING'")
                completed = not (guard or missing or diagnostics)
                if completed:
                    db.execute("UPDATE metadata SET last_full_success=? WHERE singleton=1", (now,))
        except OSError as error:
            # Any late filesystem failure rolls back the whole absence pass.
            with transaction(db, write=True):
                db.execute("UPDATE sync_file SET missing_streak=0 WHERE status='MISSING'")
            code = "ABSENCE_RECHECK_CHANGED" if isinstance(error, _RecheckChanged) else "DAILY_SCAN_FAILED"
            scan_error = Diagnostic("", code, str(error))
            diagnostics.append(scan_error)
            missing, deleted, guard, completed = 0, 0, code, False
        return SyncResult(**totals, missing=missing, deleted=deleted, last_attempt=now,
                          last_full_success=now if completed else previous_success, completed=completed,
                          scan_error=scan_error, deletion_guard=guard, diagnostics=tuple(diagnostics))
