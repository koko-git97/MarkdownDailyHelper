"""Validate ownership and publish aggregate, export, index and configuration files."""

from contextlib import contextmanager
from functools import lru_cache
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


def _check_spelling(path: Path) -> None:
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


@lru_cache(maxsize=1)
def _windows_attributes():
    import ctypes
    from ctypes import wintypes

    get_attributes = ctypes.WinDLL("kernel32", use_last_error=True).GetFileAttributesW
    get_attributes.argtypes = (wintypes.LPCWSTR,)
    get_attributes.restype = wintypes.DWORD
    get_drive_type = ctypes.WinDLL("kernel32", use_last_error=True).GetDriveTypeW
    get_drive_type.argtypes = (wintypes.LPCWSTR,)
    get_drive_type.restype = wintypes.UINT

    def attributes(path):
        if path == Path(path.anchor) and get_drive_type(path.anchor) not in (2, 3, 5, 6):
            raise AggregateError(f"Unsafe output path drive: {path}; use a local drive")
        result = get_attributes("\\\\?\\" + str(path))
        if result == 0xFFFFFFFF:
            error = ctypes.get_last_error()
            if error in (2, 3):
                raise FileNotFoundError(path)
            raise ctypes.WinError(error)
        return result

    return attributes


def _inspect(path):
    # Windows lstat may follow reparse points other than name surrogates.
    attributes = _windows_attributes()(path) if os.name == "nt" else 0
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        if attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise AggregateError(f"Unsafe output path: cannot inspect reparse point {path}") from error
        raise
    return info, is_link(info) or bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def _identity(info):
    return info.st_dev, info.st_ino


def _junction_destination(path, info):
    tag = getattr(info, "st_reparse_tag", None)
    if (os.name == "nt" and tag == stat.IO_REPARSE_TAG_MOUNT_POINT
            and info.st_file_attributes & stat.FILE_ATTRIBUTE_DIRECTORY):
        substitution = os.readlink(path)
        if substitution.startswith("\\\\?\\"):
            destination = Path(substitution[4:])
            if destination.is_absolute() and re.fullmatch(r"[A-Za-z]:", destination.drive):
                return destination
        raise AggregateError(f"Unsafe output path junction: {path} -> {substitution}; use a local directory")
    raise AggregateError(f"Unsafe output path component: {path}; unsupported reparse point "
                         f"(tag: {tag!r}); use a local directory or directory junction")


def _directories(path, junction_root, seen=frozenset()):
    """Walk existing directories one component at a time, before following each junction."""
    _check_spelling(path)
    physical = Path(path.anchor)
    observed = {}
    for logical, part in zip((*reversed(path.parents), path), ("", *path.parts[1:])):
        physical = physical / part
        try:
            info, linked = _inspect(physical)
        except FileNotFoundError:
            continue
        if linked:
            if junction_root is None:
                raise AggregateError(f"Unsafe output path component: {physical}; reparse points are not allowed")
            if not junction_root.is_relative_to(logical):
                raise AggregateError(f"Unsafe output path component: {logical} ({physical}); "
                                     f"junctions are allowed only at or above {junction_root}")
            link = physical
            if link in seen or len(seen) >= 63:
                raise AggregateError(f"Unsafe output path: circular or excessive junction chain at {link}")
            destination = _junction_destination(link, info)
            physical, chain = _directories(destination, destination, seen | {link})
            if physical not in chain:
                raise AggregateError(f"Unsafe output path junction: {link} -> {destination}; destination is missing")
            observed.update(chain)
            observed[link] = (_identity(info), destination)
        elif stat.S_ISDIR(info.st_mode):
            observed[physical] = (_identity(info), None)
        else:
            raise AggregateError(f"Unsafe output path component: {physical}")
    return physical, observed


def _file_identity(path):
    try:
        info, linked = _inspect(path)
    except FileNotFoundError:
        return None
    if linked or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AggregateError(f"Output is not a single regular file: {path}")
    return _identity(info)


def _resolve(path):
    try:
        return path.resolve()
    except RuntimeError as error:
        raise AggregateError(f"Unsafe output path: {path}: {error}") from error


class OutputDirectory:
    """Pin a physical directory and the existing components used to reach it."""

    def __init__(self, logical, junction_root=None):
        self.logical = logical
        self.junction_root = junction_root
        self.physical, self.observed = self._scan()

    def _scan(self):
        path, observed = _directories(self.logical, self.junction_root)
        canonical = _resolve(path)
        # Windows resolves aliases such as short names and substituted drives here.
        canonical, physical = _directories(canonical, None)
        if observed.get(path) != physical.get(canonical):
            raise AggregateError(f"Output directory changed: {self.logical} -> {canonical}")
        observed.update(physical)
        return canonical, observed

    def check(self, *, bind=False):
        path, observed = self._scan()
        if (path != self.physical or any(observed.get(key) != value for key, value in self.observed.items())
                or any(destination is not None and key not in self.observed
                       for key, (_, destination) in observed.items())):
            raise AggregateError(f"Output directory changed: {self.logical} -> {self.physical} (now {path})")
        if bind:
            self.observed = observed


def safe_path(path: Path) -> Path:
    """Reject links/reparse points and unsafe Windows path components before writes."""
    _check_spelling(path)
    parent = OutputDirectory(path.parent)
    original = _file_identity(path)
    physical = _resolve(parent.physical / path.name)
    _check_spelling(physical)
    if _file_identity(physical) != original:
        raise AggregateError(f"Output path changed: {path}")
    return physical


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


def publish(path: Path, content: bytes, *, expected=_GENERATED, validate=None) -> bool:
    """Update an owned output, or compare a configuration snapshot for registration."""
    if expected is _GENERATED:
        assert_owner(content, content)
    if validate is None:
        path = safe_path(path)
    directory = OutputDirectory(path.parent)

    def check():
        if validate is not None:
            validate()
        directory.check()
        if safe_path(path) != path:
            raise AggregateError(f"Output path changed: {path}")

    for parent in reversed(path.parents):
        if parent not in directory.observed:
            check()
            parent.mkdir(exist_ok=True)
            directory.check(bind=True)
    check()
    with _writer(path):
        check()
        original_identity = _file_identity(path)
        original = _read_existing(path)
        if expected is _GENERATED:
            if original is not None:
                assert_owner(original, content)
        elif expected is None or expected != original:
            raise AggregateError(f"Configuration changed before saving: {path}")
        check()
        if _file_identity(path) != original_identity:
            raise AggregateError(f"Output changed before saving: {path}")
        if original == content:
            return False
        temporary = None
        temporary_identity = None
        try:
            with NamedTemporaryFile(dir=path.parent, prefix=".mdh-", suffix=".tmp", delete=False) as handle:
                temporary = Path(handle.name)
                temporary_identity = _identity(os.fstat(handle.fileno()))
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            check()
            if (_file_identity(path) != original_identity or _read_existing(path) != original
                    or _file_identity(temporary) != temporary_identity):
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
            if temporary is not None and temporary_identity is not None:
                try:
                    directory.check()
                    info, linked = _inspect(temporary)
                    if not linked and stat.S_ISREG(info.st_mode) and _identity(info) == temporary_identity:
                        temporary.unlink(missing_ok=True)
                except (OSError, ValueError):
                    # A moved parent or replaced temp name cannot be cleaned up safely.
                    pass
