CREATE TABLE metadata (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    root_identity TEXT NOT NULL,
    last_attempt TEXT,
    last_full_success TEXT
);
CREATE TABLE sync_file (
    source_path TEXT PRIMARY KEY NOT NULL,
    day TEXT,
    status TEXT NOT NULL CHECK (status IN ('CURRENT', 'STALE', 'INVALID', 'MISSING', 'DELETED')),
    snapshot_id INTEGER UNIQUE,
    observed_hash TEXT CHECK (observed_hash IS NULL OR length(observed_hash) = 64),
    current_hash TEXT GENERATED ALWAYS AS (CASE WHEN status = 'CURRENT' THEN observed_hash END) VIRTUAL,
    diagnosis TEXT,
    observed_at TEXT NOT NULL,
    missing_streak INTEGER NOT NULL DEFAULT 0 CHECK (missing_streak >= 0),
    UNIQUE (snapshot_id, source_path, day),
    FOREIGN KEY (snapshot_id, source_path, day)
        REFERENCES daily(daily_id, source_path, day) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (snapshot_id, current_hash)
        REFERENCES daily(daily_id, source_hash) DEFERRABLE INITIALLY DEFERRED,
    CHECK (snapshot_id IS NULL OR day IS NOT NULL),
    CHECK (status NOT IN ('CURRENT', 'STALE') OR snapshot_id IS NOT NULL),
    CHECK (status NOT IN ('INVALID', 'DELETED') OR snapshot_id IS NULL),
    CHECK (status <> 'CURRENT' OR (observed_hash IS NOT NULL AND diagnosis IS NULL)),
    CHECK (status = 'MISSING' OR missing_streak = 0)
);
CREATE TABLE daily (
    daily_id INTEGER PRIMARY KEY,
    day TEXT NOT NULL UNIQUE,
    source_path TEXT NOT NULL UNIQUE,
    source_hash TEXT NOT NULL CHECK (length(source_hash) = 64),
    indexed_at TEXT NOT NULL,
    UNIQUE (daily_id, source_path, day),
    UNIQUE (daily_id, source_hash),
    FOREIGN KEY (daily_id, source_path, day) REFERENCES sync_file(snapshot_id, source_path, day)
        DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX sync_status_day ON sync_file(status, day);
CREATE TABLE topic (
    daily_id INTEGER NOT NULL REFERENCES daily ON DELETE CASCADE,
    start INTEGER NOT NULL CHECK (start >= 0),
    stop INTEGER NOT NULL CHECK (stop > start),
    title TEXT NOT NULL,
    PRIMARY KEY (daily_id, start)
);
CREATE TABLE section (
    daily_id INTEGER NOT NULL,
    topic_start INTEGER NOT NULL,
    start INTEGER NOT NULL CHECK (start >= 0),
    stop INTEGER NOT NULL CHECK (stop > start),
    level INTEGER NOT NULL CHECK (level BETWEEN 3 AND 6),
    parent_start INTEGER,
    title TEXT NOT NULL,
    PRIMARY KEY (daily_id, topic_start, start),
    FOREIGN KEY (daily_id, topic_start) REFERENCES topic(daily_id, start) ON DELETE CASCADE,
    FOREIGN KEY (daily_id, topic_start, parent_start) REFERENCES section(daily_id, topic_start, start),
    CHECK (start > topic_start AND (parent_start IS NULL OR parent_start < start))
);
CREATE TABLE completion (
    daily_id INTEGER NOT NULL REFERENCES daily ON DELETE CASCADE,
    start INTEGER NOT NULL CHECK (start >= 0),
    stop INTEGER NOT NULL CHECK (stop > start),
    completed_on TEXT NOT NULL,
    payload TEXT NOT NULL,
    category TEXT,
    task TEXT,
    CHECK ((category IS NULL) = (task IS NULL)),
    PRIMARY KEY (daily_id, start)
);

CREATE TABLE search_document (
    daily_id INTEGER NOT NULL REFERENCES daily ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('topic', 'preamble', 'completion', 'daily_segment')),
    group_start INTEGER NOT NULL CHECK (group_start >= 0 AND start >= group_start),
    title TEXT NOT NULL,
    start INTEGER NOT NULL CHECK (start >= 0),
    stop INTEGER NOT NULL CHECK (stop > start),
    line INTEGER NOT NULL CHECK (line >= 1),
    column_no INTEGER NOT NULL CHECK (column_no >= 1),
    body TEXT NOT NULL CHECK (length(body) = stop - start),
    PRIMARY KEY (daily_id, kind, group_start, start)
) WITHOUT ROWID;
CREATE VIEW searchable AS SELECT * FROM search_document;

PRAGMA user_version = 1;
