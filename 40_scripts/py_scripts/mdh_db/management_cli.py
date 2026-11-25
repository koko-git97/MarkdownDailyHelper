"""Read Concept definitions and aggregate Topic counts without using the DB."""

from dataclasses import asdict
import json
import sys

from .__main__ import Arguments, _absolute
from .aggregate_cli import _check_environment


def _arguments(argv):
    parser = Arguments(add_help=False)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("environment")
    concept = commands.add_parser("concept")
    concept.add_argument("--config", type=_absolute, required=True)
    concept.add_argument("--daily-root", type=_absolute)
    concept.add_argument("--count", action="store_true")
    commands.add_parser("type").add_argument("--daily-root", type=_absolute, required=True)
    args = parser.parse_args(argv)
    if args.operation == "concept" and args.count and args.daily_root is None:
        raise ValueError("--count requires --daily-root")
    return args


def _concepts(args, diagnostics):
    from .aggregate import collect_entries, decode_config, read_concepts, select_entries

    concepts = read_concepts(decode_config(args.config.read_text(encoding="utf-8-sig")))
    items = [asdict(concept) for concept in concepts]
    if args.count:
        try:
            entries = collect_entries(args.daily_root)
        except (OSError, ValueError) as error:
            diagnostics.append({"code": "DAILY_FAILED", "message": str(error)})
            for item in items:
                item["topic_count"] = None
        else:
            for item, concept in zip(items, concepts):
                item["topic_count"] = len(select_entries(entries, concept))
    return {"registered_count": len(items), "concepts": items}


def _types(args):
    from .aggregate import collect_entries, normalize

    entries = collect_entries(args.daily_root)
    counts = {}
    for entry in entries:
        key = normalize(entry.type) if entry.type is not None else None
        item = counts.setdefault(key, {"name": entry.type, "key": key, "topic_count": 0})
        item["topic_count"] += 1
    types = [counts[key] for key in sorted(counts, key=lambda key: (key is None, key or ""))]
    return {"source": "daily_markdown", "total_topics": len(entries), "types": types}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    operation = argv[0] if argv else None
    result = None
    diagnostics = []
    try:
        args = _arguments(argv)
    except (OSError, ValueError) as error:
        code = 2
        diagnostics.append({"code": "INVALID_ARGUMENT", "message": str(error)})
    else:
        try:
            _check_environment()
        except Exception as error:
            code = 3
            diagnostics.append({"code": "PYTHON_ENVIRONMENT", "message": str(error)})
        else:
            try:
                if operation == "concept":
                    result = _concepts(args, diagnostics)
                elif operation == "type":
                    result = _types(args)
                code = 1 if diagnostics else 0
            except (OSError, ValueError) as error:
                code = 4
                diagnostics.append({"code": "CONFIG_FAILED" if operation == "concept" else "DAILY_FAILED",
                                    "message": str(error)})
    payload = {"contract_version": 1, "operation": operation, "exit_code": code,
               "result": result, "diagnostics": diagnostics}
    sys.stdout.buffer.write((json.dumps(payload) + "\n").encode("utf-8"))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
