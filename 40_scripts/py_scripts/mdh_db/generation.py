"""Windows generation store. Writers share one lock and readers pin one path."""

from collections.abc import Iterable
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
from datetime import date
from hashlib import sha256
import os
from pathlib import Path
import re
import sqlite3
import stat
from time import sleep
from uuid import uuid4

from .search import SearchResult, search
from .storage import (DailyRootMismatch, DatabaseIntegrityError, SchemaVersionError, check_integrity,
                      create_database, open_database, root_identity_path, transaction)
from .sync import DAILY_NAME, MAX_MISSING, SyncResult, _linked, _scan, _valid_relative, daily_root_identity
from .sync import synchronize as _sync_database

GENERATION = re.compile(rb"db-[a-f0-9]{32}\.sqlite\n")
RETRY_DELAYS = (0.1, 0.3)
SHARING_ERRORS = {32, 33}


class GenerationError(RuntimeError):
    pass


class ActiveDatabaseError(GenerationError):
    pass


class WriterBusy(GenerationError):
    pass


class PublicationBlocked(GenerationError):
    def __init__(self, code: str, paths: Iterable[str] = ()):
        self.code = code
        self.paths = tuple(sorted(paths))
        detail = ", ".join(self.paths)
        super().__init__(f"{code}: {detail}" if detail else code)


@dataclass(frozen=True)
class RebuildResult:
    path: Path
    indexed: int


def _regular(path: Path) -> None:
    info = path.lstat()
    if _linked(info) or not stat.S_ISREG(info.st_mode):
        raise GenerationError(f"Not a regular generation-store file: {path.name}")


def _local_store(store: Path) -> Path:
    store = Path(store).absolute()
    if str(store).startswith("\\\\"):
        raise GenerationError("The generation store requires a local Windows path")
    if store.exists() and _linked(store.lstat()):
        raise GenerationError("The generation store must not be a link")
    return store


@contextmanager
def _writer_lock(store: Path):
    import msvcrt

    lock = store / "writer.lock"
    try:
        _regular(lock)
    except FileNotFoundError:
        pass
    with lock.open("a+b") as handle:
        _regular(lock)
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise WriterBusy("Could not acquire the generation store writer lock") from error
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def active_path(store: Path) -> Path:
    """Resolve exactly one published generation without opening or creating a DB."""
    store = _local_store(store)
    pointer = store / "active"
    try:
        _regular(pointer)
        with pointer.open("rb") as file:
            content = file.read(44)
        if not GENERATION.fullmatch(content):
            raise ActiveDatabaseError("Malformed active generation pointer")
        path = store / content[:-1].decode("ascii")
        _regular(path)
    except FileNotFoundError as error:
        raise ActiveDatabaseError("Active generation pointer or database is missing") from error
    return path


def status_active(store: Path, root: Path | None = None) -> dict:
    """Inspect a store without creating files or changing its active generation."""
    store = _local_store(store)
    counts = dict.fromkeys(("CURRENT", "STALE", "INVALID", "MISSING", "DELETED"), 0)
    if store.exists() and not store.is_dir():
        raise ActiveDatabaseError("Generation store is not a directory")
    try:
        (store / "active").lstat()
    except FileNotFoundError:
        if any(store.glob("db-*.sqlite")):
            raise ActiveDatabaseError("Active pointer missing in an existing generation store")
        return {"initialized": False, "generation": None, "counts": counts,
                "daily_root": None, "configured_daily_root": str(root) if root is not None else None,
                "daily_root_matches": None,
                "last_attempt": None, "last_full_success": None, "incomplete": True}

    path = active_path(store)
    with open_database(path) as db, transaction(db):
        check_integrity(db)
        row = db.execute("SELECT last_attempt, last_full_success, root_identity FROM metadata WHERE singleton=1").fetchone()
        if row is None:
            raise DatabaseIntegrityError("Database metadata is missing")
        attempt, success, identity = row
        counts.update(db.execute("SELECT status, COUNT(*) FROM sync_file GROUP BY status"))
    matches = None
    if root is not None:
        try:
            matches = daily_root_identity(root) == identity
        except OSError:
            matches = False
    return {"initialized": True, "generation": path.name, "counts": counts,
            "daily_root": root_identity_path(identity),
            "configured_daily_root": str(root) if root is not None else None, "daily_root_matches": matches,
            "last_attempt": attempt, "last_full_success": success,
            "incomplete": matches is False or not success or attempt != success
                          or any(counts[state] for state in ("STALE", "INVALID", "MISSING"))}



def search_active(store: Path, query: str, *, include_stale: bool = False,
                  after: date | None = None, before: date | None = None,
                  root: Path | None = None) -> SearchResult:
    path = active_path(store)
    expected = None
    if root is not None:
        try:
            expected = daily_root_identity(root)
        except OSError as error:
            raise ActiveDatabaseError(f"Cannot resolve configured Daily root: {root}") from error
    return search(path, query, include_stale=include_stale, after=after, before=before,
                  expected_root_identity=expected)


def sync_active(store: Path, root: Path, *, confirm_deletions: Iterable[str] = ()) -> SyncResult:
    """Serialize the entire I3 synchronization against the active generation."""
    if isinstance(confirm_deletions, (str, bytes)):
        raise ValueError("Pass an iterable of individual deletion paths")
    confirmed = tuple(confirm_deletions)
    if any(not _valid_relative(item) or not DAILY_NAME.fullmatch(Path(item).name) for item in confirmed):
        raise ValueError("Deletion confirmation requires Daily-root-relative Markdown paths")
    store = _local_store(store)
    with _writer_lock(store):
        path = active_path(store)
        with open_database(path) as db, transaction(db):
            check_integrity(db)
            if confirmed:
                known = {item for (item,) in db.execute(
                    "SELECT source_path FROM sync_file WHERE status <> 'DELETED'"
                )}
                unknown = set(confirmed) - known
                if unknown:
                    raise ValueError(f"Deletion confirmation is not an observed Daily: {', '.join(sorted(unknown))}")
        return _sync_database(path, root, confirm_deletions=confirmed)


def _shared_access_denied(path: Path) -> bool:
    """WinError 5 is ambiguous; retry it only if DELETE access proves sharing conflict."""
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    open_file = kernel.CreateFileW
    open_file.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                          wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    open_file.restype = wintypes.HANDLE
    close_handle = kernel.CloseHandle
    close_handle.argtypes = (wintypes.HANDLE,)
    close_handle.restype = wintypes.BOOL
    handle = open_file(str(path), 0x00010000, 7, None, 3, 0, None)  # DELETE, share all, OPEN_EXISTING
    if handle == ctypes.c_void_p(-1).value:
        return ctypes.get_last_error() in SHARING_ERRORS
    close_handle(handle)
    return False


def _retryable(error: OSError, source: Path, target: Path) -> bool:
    code = getattr(error, "winerror", None)
    return code in SHARING_ERRORS or (
        code == 5 and (_shared_access_denied(target) or _shared_access_denied(source))
    )


def _publish(store: Path, generation: Path) -> None:
    temporary = store / f"pointer-{uuid4().hex}.tmp"
    target = store / "active"
    with temporary.open("xb") as file:
        file.write(generation.name.encode("ascii") + b"\n")
        file.flush()
        os.fsync(file.fileno())
    for delay in (*RETRY_DELAYS, None):
        try:
            os.replace(temporary, target)
            return
        except OSError as error:
            if delay is None or not _retryable(error, temporary, target):
                raise
            sleep(delay)


def _old_paths(store: Path, expected_root: str) -> set[str]:
    try:
        (store / "active").lstat()
    except FileNotFoundError:
        if any(store.glob("db-*.sqlite")):
            raise ActiveDatabaseError("Active pointer missing in an existing generation store")
        return set()
    try:
        with open_database(active_path(store)) as db, transaction(db):
            check_integrity(db)
            row = db.execute("SELECT root_identity FROM metadata WHERE singleton=1").fetchone()
            if row != (expected_root,):
                raise PublicationBlocked("ACTIVE_ROOT_MISMATCH")
            return {path for (path,) in db.execute("SELECT source_path FROM sync_file WHERE status <> 'DELETED'")}

    except (DatabaseIntegrityError, SchemaVersionError, sqlite3.Error, OSError) as error:
        raise ActiveDatabaseError(str(error)) from error


def _manifest(root: Path, expected_root: str) -> dict[str, str]:
    if daily_root_identity(root) != expected_root:
        raise PublicationBlocked("INPUT_ROOT_CHANGED")
    files = {}
    for candidate in _scan(root):
        if candidate.placement_error:
            raise PublicationBlocked(candidate.placement_error, (candidate.relative,))
        _regular(candidate.file)
        files[candidate.relative] = sha256(candidate.file.read_bytes()).hexdigest()
    if daily_root_identity(root) != expected_root:
        raise PublicationBlocked("INPUT_ROOT_CHANGED")
    return files


def _verify_candidate(path: Path, expected_root: str) -> dict[str, str]:
    with open_database(path) as db, transaction(db):
        check_integrity(db)
        if db.execute("PRAGMA journal_mode").fetchone() != ("delete",):
            raise PublicationBlocked("CANDIDATE_JOURNAL_MODE")
        metadata = db.execute("""
            SELECT root_identity, last_attempt, last_full_success FROM metadata WHERE singleton=1
        """).fetchone()
        if metadata is None or metadata[0] != expected_root or not metadata[1] or metadata[1] != metadata[2]:
            raise PublicationBlocked("INCOMPLETE_CANDIDATE")
        observed = db.execute("""
            SELECT f.source_path, f.status, d.source_hash FROM sync_file f
            LEFT JOIN daily d ON f.snapshot_id=d.daily_id
        """).fetchall()
        if any(status != "CURRENT" or digest is None for _, status, digest in observed):
            raise PublicationBlocked("INCOMPLETE_CANDIDATE")
    if any(path.with_name(path.name + suffix).exists() for suffix in ("-wal", "-shm", "-journal")):
        raise PublicationBlocked("CANDIDATE_HAS_SIDECARS")
    return {relative: digest for relative, _, digest in observed}


def _check_missing(previous: set[str], current: dict[str, str]) -> None:
    missing = previous.difference(current)
    count = len(missing)
    if count:
        mass = count == len(previous) or count > MAX_MISSING or (count >= 2 and count * 2 >= len(previous))
        raise PublicationBlocked("MASS_ABSENCE" if mass else "UNCONFIRMED_ABSENCE", missing)


def rebuild(store: Path, root: Path, *, only_if_uninitialized: bool = False) -> RebuildResult:
    """Build privately and atomically publish only a verified, complete generation."""
    store = _local_store(store)
    root = Path(root).absolute()
    store.mkdir(parents=True, exist_ok=True)
    with _writer_lock(store):
        if only_if_uninitialized and status_active(store)["initialized"]:
            raise PublicationBlocked("ALREADY_INITIALIZED")
        expected_root = daily_root_identity(root)
        previous = _old_paths(store, expected_root)
        initial = _manifest(root, expected_root)
        _check_missing(previous, initial)

        token = uuid4().hex
        candidate = store / f"build-{token}.sqlite"
        generation = store / f"db-{token}.sqlite"
        create_database(candidate, root_identity=expected_root)
        with open_database(candidate, read_only=False) as db:
            if db.execute("PRAGMA journal_mode = DELETE").fetchone() != ("delete",):
                raise PublicationBlocked("CANDIDATE_JOURNAL_MODE")

        result = _sync_database(candidate, root)
        if any(item.code == "DAILY_SOURCE_CHANGED" for item in result.diagnostics):
            raise PublicationBlocked("SOURCE_CHANGED_DURING_BUILD")
        if not result.completed or result.failed or result.indexed != len(initial):
            raise PublicationBlocked("FULL_BUILD_FAILED", (item.path for item in result.diagnostics if item.path))

        recorded = _verify_candidate(candidate, expected_root)
        final = _manifest(root, expected_root)
        _check_missing(previous, final)
        if recorded != initial or final != initial:
            raise PublicationBlocked("SOURCE_CHANGED_DURING_BUILD")

        # Do not overwrite a generation, even if the generated name collides.
        candidate.rename(generation)
        _publish(store, generation)
        return RebuildResult(generation, result.indexed)
