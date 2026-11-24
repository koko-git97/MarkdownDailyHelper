"""Explicit SQLite creation, version checks, and transaction boundaries."""

from contextlib import closing, contextmanager
from pathlib import Path
import sqlite3


SCHEMA_VERSION = 1
SCHEMA_PATH = Path(__file__).with_name("schema.sql")


class SchemaVersionError(RuntimeError):
    def __init__(self, found: int):
        self.found = found
        super().__init__(f"Unsupported database schema version {found}; expected {SCHEMA_VERSION}")


class DatabaseIntegrityError(RuntimeError):
    pass


class DailyRootMismatch(RuntimeError):
    def __init__(self, indexed_root: str, configured_root: str):
        super().__init__(f"Daily root does not match the index. Indexed: {indexed_root}. Configured: {configured_root}.")


def root_identity_path(identity: str) -> str:
    return identity.rsplit(":", 2)[0]


def _check_schema_version(db: sqlite3.Connection) -> None:
    version, = db.execute("PRAGMA user_version").fetchone()
    if version != SCHEMA_VERSION:
        raise SchemaVersionError(version)


@contextmanager
def transaction(db: sqlite3.Connection, *, write: bool = False):
    """Use one explicit transaction, including deferred constraints at commit."""
    db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
    try:
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise


def create_database(path: Path, *, root_identity: str) -> None:
    """Initialize a new scratch or candidate database without opening an existing file."""
    if not root_identity.strip():
        raise ValueError("root_identity must not be empty")

    schema = SCHEMA_PATH.read_text(encoding="utf-8")
    path = Path(path)
    path.touch(exist_ok=False)
    with closing(sqlite3.connect(path)) as db:
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA synchronous = FULL")
        try:
            # executescript starts by committing any pending transaction. Put
            # BEGIN inside the script so the schema and metadata commit together.
            db.executescript("BEGIN IMMEDIATE;\n" + schema)
            _check_schema_version(db)
            db.execute("INSERT INTO metadata(singleton, root_identity) VALUES (1, ?)", (root_identity,))
            db.commit()
        except BaseException:
            db.rollback()
            raise


@contextmanager
def open_database(path: Path, *, read_only: bool = True):
    """Open a versioned database. Neither mode creates or upgrades a file."""
    mode = "ro" if read_only else "rw"
    uri = Path(path).absolute().as_uri() + f"?mode={mode}"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        db.execute("PRAGMA foreign_keys = ON")
        _check_schema_version(db)
        if read_only:
            db.execute("PRAGMA query_only = ON")
        else:
            db.execute("PRAGMA synchronous = FULL")
        yield db


def check_integrity(db: sqlite3.Connection) -> None:
    results = db.execute("PRAGMA integrity_check").fetchall()
    if results != [("ok",)]:
        raise DatabaseIntegrityError(f"integrity_check failed: {results!r}")
    violations = db.execute("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise DatabaseIntegrityError(f"foreign_key_check failed: {violations!r}")
