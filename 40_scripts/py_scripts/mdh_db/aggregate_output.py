"""Validate ownership and publish aggregate, export, index and configuration files."""

from contextlib import contextmanager
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
from tempfile import NamedTemporaryFile

from markdown_it import MarkdownIt

from .aggregate import AggregateError, decode_json, is_link, normalize


_HEADER = re.compile(r"\A<!-- MDH:GENERATED\r?\n([^\r\n]+)\r?\n-->\r?\n")


def generated_bytes(body: str, kind: str, concept: str | None = None, type_filter: str | None = None) -> bytes:
    metadata = {"version": 1, "kind": kind}
    if kind != "index":
        metadata.update(concept=concept, type=type_filter)
    # Keep arbitrary Concept/Type text from closing the HTML comment.
    payload = json.dumps(metadata, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c").replace(">", "\\u003e")
    return f"<!-- MDH:GENERATED\n{payload}\n-->\n\n{body}".encode("utf-8")


def assert_owner(raw: bytes, expected: bytes) -> None:
    text = raw.decode("utf-8-sig")
    match = _HEADER.match(text)
    if not match or any(token.type == "html_block" and token.level == 0
                        and re.match(r"\s*<!-- MDH:GENERATED\b", token.content)
                        for token in MarkdownIt("commonmark").parse(text[match.end():])):
        raise AggregateError("Missing or duplicate MDH generated metadata")
    found = decode_json(match[1])
    owner = decode_json(_HEADER.match(expected.decode("utf-8"))[1])
    if not isinstance(found, dict) or found.keys() != owner.keys() or type(found.get("version")) is not int:
        raise AggregateError("Invalid MDH generated metadata")
    if isinstance(found.get("type"), str) and isinstance(owner.get("type"), str):
        found["type"] = normalize(found["type"].strip())
        owner["type"] = normalize(owner["type"].strip())
    if found != owner:
        raise AggregateError("Generated file belongs to another Concept, Type, kind or version")


def safe_path(path: Path) -> Path:
    """Reject links/reparse points and unsafe Windows path components before writes."""
    if not path.is_absolute() or ".." in path.parts or str(path).startswith("\\\\"):
        raise AggregateError(f"Unsafe output path: {path}")
    for part in path.parts[1:]:
        if (part.endswith((".", " ")) or any(ord(ch) < 32 or ch in ':*?"<>|' for ch in part)
                or re.fullmatch(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])",
                                part.split(".")[0].rstrip(" "), re.I)
                or len(part.encode("utf-16-le")) // 2 > 255):
            raise AggregateError(f"Unsafe output path component: {part!r}")
    if os.name == "nt" and len(str(path).encode("utf-16-le")) // 2 >= 32767:
        raise AggregateError(f"Output path is too long: {path}")
    for component in (*reversed(path.parents), path):
        try:
            info = component.lstat()
        except FileNotFoundError:
            continue
        if is_link(info) or (component != path and not stat.S_ISDIR(info.st_mode)):
            raise AggregateError(f"Unsafe output path component: {component}")
        if component == path and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            raise AggregateError(f"Output is not a single regular file: {component}")
    return path.resolve()


@contextmanager
def _writer(path: Path):
    if os.name != "nt":
        import fcntl

        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            os.close(descriptor)
        return

    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.ReleaseMutex.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    key = sha256(str(path).upper().encode("utf-8")).hexdigest()
    mutex = kernel.CreateMutexW(None, False, f"Global\\MDH.Aggregate.{key}")
    if not mutex:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        if kernel.WaitForSingleObject(mutex, 15000) not in (0, 0x80):
            raise AggregateError(f"Could not acquire output lock: {path}")
        try:
            yield
        finally:
            kernel.ReleaseMutex(mutex)
    finally:
        kernel.CloseHandle(mutex)


def _read_existing(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


_GENERATED = object()


def publish(path: Path, content: bytes, *, expected=_GENERATED) -> bool:
    """Update an owned output, or compare a configuration snapshot for registration."""
    if expected is _GENERATED:
        assert_owner(content, content)
    path = safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if safe_path(path) != path:
        raise AggregateError(f"Output path changed: {path}")
    with _writer(path):
        if safe_path(path) != path:
            raise AggregateError(f"Output path changed: {path}")
        original = _read_existing(path)
        if expected is _GENERATED:
            if original is not None:
                assert_owner(original, content)
        elif expected is None or expected != original:
            raise AggregateError(f"Configuration changed before saving: {path}")
        if original == content:
            return False
        temporary = None
        try:
            with NamedTemporaryFile(dir=path.parent, prefix=".mdh-", suffix=".tmp", delete=False) as handle:
                temporary = Path(handle.name)
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            if safe_path(path) != path or _read_existing(path) != original:
                raise AggregateError(f"Output changed before saving: {path}")
            if original is None:
                if os.name == "nt":
                    os.rename(temporary, path)  # On Windows rename fails if the destination appeared.
                else:
                    os.link(temporary, path)
            else:
                os.replace(temporary, path)
            return True
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
