"""UTF-8 JSON entry point for the MDH PowerShell integration."""

import argparse
from dataclasses import asdict
from datetime import date
from importlib.metadata import PackageNotFoundError, version
import json
from pathlib import Path
import re
import sqlite3
import sys


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def _absolute(value):
    path = Path(value)
    if not path.is_absolute():
        raise ValueError(f"An absolute path is required: {value}")
    return path


def _date(value):
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise ValueError(f"Expected yyyy-MM-dd: {value}")
    return date.fromisoformat(value)


def _arguments(argv):
    parser = Arguments(prog="mdh_db", add_help=False)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("environment", add_help=False)
    quicknotes = commands.add_parser("quicknotes", add_help=False)
    quicknotes.add_argument("--root", type=_absolute, required=True)
    quicknotes.add_argument("--query", required=True)
    for operation in ("status", "sync", "rebuild", "search"):
        command = commands.add_parser(operation, add_help=False)
        command.add_argument("--store", type=_absolute, required=True)
        command.add_argument("--daily-root", type=_absolute, required=operation in ("sync", "rebuild"))
        if operation == "rebuild":
            command.add_argument("--only-if-uninitialized", action="store_true")
        if operation == "sync":
            command.add_argument("--confirm-deletion", action="append", default=[])
        if operation == "search":
            command.add_argument("--query", required=True)
            command.add_argument("--from", dest="after", type=_date)
            command.add_argument("--to", dest="before", type=_date)
            command.add_argument("--include-stale", action="store_true")
    args = parser.parse_args(argv)
    if args.operation == "search" and args.after and args.before and args.after > args.before:
        raise ValueError("Search start date must not be after its end date")
    return args


def _environment():
    if sys.platform != "win32":
        raise RuntimeError("MDH DB requires Windows")
    if sys.version_info < (3, 10) or sqlite3.sqlite_version_info < (3, 35):
        raise RuntimeError("MDH DB requires Python 3.10+ and SQLite 3.35+")
    dependencies = {}
    for name, required in (("markdown-it-py", "3.0.0"), ("mdurl", "0.1.2")):
        try:
            installed = version(name)
        except PackageNotFoundError:
            installed = None
        if installed != required:
            raise RuntimeError(f"{name}=={required} is required; see mdh_db/requirements.txt (found: {installed})")
        dependencies[name] = installed
    import markdown_it  # Verify that the distribution is actually importable.
    import mdurl

    return {"python": sys.version.split()[0], "sqlite": sqlite3.sqlite_version, "dependencies": dependencies}


def _diagnostic(code, message, **details):
    return {"code": code, "message": str(message), **details}


def _execute(args):
    if args.operation == "quicknotes":
        from .quicknotes_search import search_quicknotes

        try:
            return 0, search_quicknotes(args.root, args.query), []
        except OSError as error:
            return 4, None, [_diagnostic("QUICKNOTES_ROOT", error)]
        except ValueError as error:
            return 2, None, [_diagnostic("INVALID_INPUT", error)]

    from . import generation
    from .storage import DailyRootMismatch, DatabaseIntegrityError, SchemaVersionError

    operation = args.operation
    try:
        if operation == "status":
            result = generation.status_active(args.store, args.daily_root)
            if result["daily_root_matches"] is False:
                error = DailyRootMismatch(result["daily_root"], result["configured_daily_root"])
                return 4, result, [_diagnostic("DAILY_ROOT_MISMATCH", error)]
            return 0, result, []
        if operation == "search":
            response = generation.search_active(args.store, args.query, include_stale=args.include_stale,
                                                after=args.after, before=args.before, root=args.daily_root)
            result = asdict(response)
            for hit, original in zip(result["hits"], response.hits):
                hit["from_last_good_snapshot"] = original.from_last_good_snapshot
            return 0, result, []
        if operation == "sync":
            confirmed = [path.replace("\\", "/") for path in args.confirm_deletion]
            response = generation.sync_active(args.store, args.daily_root, confirm_deletions=confirmed)
            diagnostics = [asdict(item) for item in response.diagnostics]
            code = 4 if response.scan_error else 0 if response.completed else 1
            return code, asdict(response), diagnostics
        response = generation.rebuild(args.store, args.daily_root, only_if_uninitialized=args.only_if_uninitialized)
        return 0, {"path": str(response.path), "indexed": response.indexed}, []
    except ValueError as error:
        return 2, None, [_diagnostic("INVALID_INPUT", error)]
    except generation.WriterBusy as error:
        return 5, None, [_diagnostic("WRITER_BUSY", error)]
    except generation.PublicationBlocked as error:
        return 6, None, [_diagnostic(error.code, error, paths=error.paths)]
    except DailyRootMismatch as error:
        return 4, None, [_diagnostic("DAILY_ROOT_MISMATCH", error)]
    except generation.ActiveDatabaseError as error:
        return 4, None, [_diagnostic("ACTIVE_DATABASE_ERROR", error)]
    except (DatabaseIntegrityError, SchemaVersionError, sqlite3.Error, OSError, generation.GenerationError) as error:
        return (6 if operation == "rebuild" else 4), None, [_diagnostic(type(error).__name__, error)]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    operation = argv[0] if argv and argv[0] in {"status", "sync", "rebuild", "search", "quicknotes", "environment"} else None
    try:
        args = _arguments(argv)
    except ValueError as error:
        code, result, diagnostics = 2, None, [_diagnostic("INVALID_ARGUMENT", error)]
    else:
        try:
            environment = _environment()
        except Exception as error:
            code, result, diagnostics = 3, None, [_diagnostic("PYTHON_ENVIRONMENT", error)]
        else:
            try:
                if args.operation == "environment":
                    code, result, diagnostics = 0, environment, []
                else:
                    code, result, diagnostics = _execute(args)
            except Exception as error:
                code, result, diagnostics = (6 if operation == "rebuild" else 4), None, [
                    _diagnostic("UNEXPECTED_ERROR", f"{type(error).__name__}: {error}")]
    payload = {"contract_version": 1, "operation": operation, "exit_code": code,
               "result": result, "diagnostics": diagnostics}
    sys.stdout.buffer.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
