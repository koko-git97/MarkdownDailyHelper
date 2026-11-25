"""Versioned JSON CLI for mdreverse and mdrun."""

from collections import defaultdict
from importlib.metadata import version
import json
from pathlib import Path
import re
import sys

from .__main__ import Arguments, _absolute


class InputError(ValueError):
    pass


def _arguments(argv):
    parser = Arguments(add_help=False)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("environment", add_help=False)
    for operation in ("reverse", "run"):
        command = commands.add_parser(operation, add_help=False)
        for key in ("config", "daily-root", "aggregate-root", "cwd"):
            command.add_argument(f"--{key}", type=_absolute, required=True)
        if operation == "reverse":
            command.add_argument("--concept", required=True)
            command.add_argument("--type")
            command.add_argument("--output", type=_absolute)
            command.add_argument("--register", action="store_true")
    return parser.parse_args(argv)


def _check_environment():
    if sys.version_info < (3, 10):
        raise RuntimeError("MDH aggregation requires Python 3.10+")
    for name, expected in (("markdown-it-py", "3.0.0"), ("mdurl", "0.1.2")):
        if version(name) != expected:
            raise RuntimeError(f"{name}=={expected} is required; see mdh_db/requirements.txt")
    import markdown_it
    import mdurl


def _target(path, args, root, *, export=False):
    from .aggregate import AggregateError
    from .aggregate_output import OutputDirectory, _check_spelling, _location, _physically_within, _resolve, safe_path

    _check_spelling(path)
    if not export:
        if isinstance(root, Exception):
            raise root
        if not path.is_relative_to(root.logical):
            raise AggregateError(f"Protected output path: {path}; use {root.logical}")
        root.check()
    directory = OutputDirectory(path.parent, path.parent if export else root.logical)
    candidate = directory.physical / path.name
    target = safe_path(candidate, allow_volume=True)

    def check_protection():
        daily = args.daily_root
        config = args.config
        template = config.with_name("config.template.json")
        aggregate = _resolve(args.aggregate_root) if export else root.physical
        if (path.is_relative_to(daily) or path in (config, template)
                or path.is_relative_to(args.aggregate_root) == export
                or _physically_within(target, _resolve(daily))
                or any(_location(target) == _location(_resolve(settings)) for settings in (config, template))
                or _physically_within(target, aggregate) == export):
            raise AggregateError(f"Protected output path: {path} -> {target}; "
                                 f"aggregate root: {aggregate}; choose an unprotected destination")

    def validate():
        if not export:
            root.check(bind=True)
        directory.check()
        if safe_path(candidate, allow_volume=True) != target:
            raise AggregateError(f"Output path changed: {path} -> {target}")
        check_protection()

    validate()
    return target, validate


def _index(items, directory):
    from .aggregate import normalize, relative_url

    groups = defaultdict(list)
    for concept, entries, path in items:
        groups[concept.category].append((concept, entries, path))
    chunks = ["# Concept index"]
    for category in sorted(groups, key=lambda name: (normalize(name or "未分類"), name)):
        chunks.append(f"## {_single_line(category) or '未分類'}")
        for concept, entries, path in sorted(groups[category], key=lambda item: (
                -item[1][0].day.toordinal() if item[1] else 0, normalize(item[0].name), item[0].name)):
            label = re.sub(r"([\\\[\]])", r"\\\1", _single_line(concept.name))
            if entries:
                label = f"[{label}]({relative_url(path, directory)})"
            latest = entries[0].day if entries else "—"
            chunks.append(f"- {label}（{len(entries)}件・{latest}）")
    return "\n\n".join(chunks) + "\n"


def _single_line(value):
    return " ".join(value.splitlines())


def _execute(args, report, issues):
    from .aggregate import (AggregateError, Concept, collect_entries, conflicts, decode_config, insert_concept,
                            output_parts, read_concepts, select_entries)
    from .aggregate_markdown import render_topics
    from .aggregate_output import OutputDirectory, generated_bytes, publish

    reverse = args.operation == "reverse"
    if reverse and (not args.concept.strip() or (args.type is not None and not args.type.strip())
                    or (args.register and (args.type is not None or args.output is not None))):
        raise InputError("Invalid Concept, Type or Register option combination")
    try:
        snapshot = args.config.read_bytes()
        config_text = snapshot.decode("utf-8-sig")
        config = decode_config(config_text)
        registered = {concept.name: concept for concept in read_concepts(config)}
    except (OSError, ValueError) as error:
        raise InputError(f"{args.config}: {error}") from error
    if reverse:
        requested = registered.get(args.concept, Concept(args.concept))
        concepts = [requested]
        if args.register and requested.name not in registered:
            content = insert_concept(config_text, config, requested.name).encode("utf-8")
            if snapshot.startswith(b"\xef\xbb\xbf"):
                content = b"\xef\xbb\xbf" + content
            publish(args.config, content, expected=snapshot)
            report["registered"] = True
    else:
        concepts = list(registered.values())

    export = reverse and args.output is not None
    preview = reverse and args.type is not None and not export
    root = None
    if not (preview or export):
        try:
            root = OutputDirectory(args.aggregate_root, args.aggregate_root)
        except (OSError, ValueError) as error:
            root = error
    entries = collect_entries(args.daily_root) if concepts else []
    candidates = list(registered.values()) if reverse and not (preview or export) else list(concepts)
    if reverse and not (preview or export) and requested.name not in registered:
        candidates.append(requested)
    parts = {}
    path_errors = {}
    if not (preview or export):
        for candidate in candidates:
            try:
                parts[candidate.name] = output_parts(candidate)
            except AggregateError as error:
                path_errors[candidate.name] = str(error)
        for name in conflicts(parts):
            path_errors[name] = "Aggregate output path collides with another Concept or reserved index.md"

    successful = []
    for concept in concepts:
        try:
            if concept.name in path_errors:
                raise AggregateError(path_errors[concept.name])
            type_filter = args.type.strip() if reverse and args.type is not None else None
            selected = select_entries(entries, concept, type_filter)
            target = None
            if not preview:
                path = args.output if export else args.aggregate_root.joinpath(*parts[concept.name])
                target, validate = _target(path, args, root, export=export)
            changed = False
            if selected:
                directory = target.parent if target else args.cwd
                body = render_topics(_single_line(concept.name), selected, directory, report["warnings"])
                if preview:
                    report["markdown"] = body
                else:
                    kind = "export" if export else "aggregate"
                    changed = publish(target, generated_bytes(body, kind, concept.name, type_filter),
                                      validate=validate)
            successful.append((concept, selected, target))
            report["concepts"].append({"name": concept.name, "topics": len(selected),
                                       "path": str(target) if target and selected else None, "changed": changed})
        except (OSError, ValueError) as error:
            issues.append({"code": "CONCEPT_FAILED", "message": f"{concept.name}: {error}"})
    if not reverse and not issues:
        try:
            index, validate = _target(args.aggregate_root / "index.md", args, root)
            report["index_changed"] = publish(index, generated_bytes(_index(successful, index.parent), "index"),
                                              validate=validate)
        except (OSError, ValueError) as error:
            issues.append({"code": "INDEX_FAILED", "message": str(error)})
    return (1 if successful else 4) if issues else 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    operation = argv[0] if argv else None
    report = {"registered": False, "concepts": [], "warnings": [], "markdown": None, "index_changed": False}
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
                code = 0 if operation == "environment" else _execute(args, report, diagnostics)
            except InputError as error:
                code = 2
                diagnostics.append({"code": "INVALID_INPUT", "message": str(error)})
            except (OSError, ValueError) as error:
                code = 4
                diagnostics.append({"code": "AGGREGATE_FAILED", "message": str(error)})
    report["state"] = {0: "success", 1: "partial"}.get(code, "failed")
    payload = {"contract_version": 1, "operation": operation, "exit_code": code,
               "result": report, "diagnostics": diagnostics}
    sys.stdout.buffer.write((json.dumps(payload) + "\n").encode("utf-8"))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
