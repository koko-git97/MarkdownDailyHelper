"""Validate ownership and publish aggregate, export, index and configuration files."""

from contextlib import contextmanager
from functools import lru_cache
from hashlib import sha256
import json
import logging
import os
from pathlib import Path
import re
import stat
from tempfile import NamedTemporaryFile

from markdown_it import MarkdownIt

from .aggregate import AggregateError, decode_json, is_link, normalize


_LOGGER = logging.getLogger(__name__)
_HEADER = re.compile(r"\A<!-- MDH:GENERATED\r?\n([^\r\n]+)\r?\n-->\r?\n")
_EXTENDED = "\\\\?\\"
_VOLUME_NAME = re.compile(r"Volume\{[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\}", re.I | re.ASCII)
_UNC_SHARE = re.compile(r"\\\\[^\\/:*?\"<>|.][^\\/:*?\"<>|]*\\[^\\/:*?\"<>|]+")


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


def _volume_path(path: Path) -> bool:
    return (os.name == "nt" and path.drive.startswith(_EXTENDED)
            and _VOLUME_NAME.fullmatch(path.drive[len(_EXTENDED):]) is not None
            and path.anchor == path.drive + "\\")


def _unc_path(path: Path) -> bool:
    return os.name == "nt" and _UNC_SHARE.fullmatch(path.drive) is not None


def _check_spelling(path: Path, *, allow_volume=False, allow_unc=False) -> None:
    if (not path.is_absolute() or ".." in path.parts
            or (str(path).startswith("\\\\") and not (
                (allow_volume and _volume_path(path)) or (allow_unc and _unc_path(path))))):
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

    def attributes(path):
        # GetFileAttributesW cannot query a share root. lstat also checks drive roots.
        if path == Path(path.anchor):
            return 0
        name = str(path)
        if len(name.encode("utf-16-le")) // 2 >= 260 and not _volume_path(path):
            name = _EXTENDED + ("UNC\\" + name[2:] if _unc_path(path) else name)
        result = get_attributes(name)
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


def _identity(info, path):
    if not info.st_ino:
        raise AggregateError(f"Cannot identify output path: {path}")
    return info.st_dev, info.st_ino


def _optional_identity(info):
    return (info.st_dev, info.st_ino) if info.st_ino else None


def _junction_destination(path, info):
    tag = getattr(info, "st_reparse_tag", None)
    if (os.name == "nt" and tag == stat.IO_REPARSE_TAG_MOUNT_POINT
            and info.st_file_attributes & stat.FILE_ATTRIBUTE_DIRECTORY):
        substitution = os.readlink(path)
        if substitution.startswith(_EXTENDED):
            tail = substitution[len(_EXTENDED):]
            destination = Path(tail)
            if destination.is_absolute() and re.fullmatch(r"[A-Za-z]:", destination.drive):
                return destination
            volume = Path(substitution)
            if _volume_path(volume) and substitution.startswith(volume.anchor) and "/" not in substitution:
                return volume
        raise AggregateError(f"Unsafe output path junction: {path} -> {substitution}; use a local directory")
    raise AggregateError(f"Unsafe output path component: {path}; unsupported reparse point "
                         f"(tag: {tag!r}); use a local directory or directory junction")


def _directories(path, junction_root, seen=frozenset(), *, allow_volume=False, allow_unc=False):
    """Walk existing directories one component at a time, before following each junction."""
    _check_spelling(path, allow_volume=allow_volume, allow_unc=allow_unc)
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
            physical, chain = _directories(destination, destination, seen | {link}, allow_volume=True)
            if physical not in chain:
                raise AggregateError(f"Unsafe output path junction: {link} -> {destination}; destination is missing")
            observed.update(chain)
            observed[link] = (_optional_identity(info), destination)
        elif stat.S_ISDIR(info.st_mode):
            observed[physical] = (_optional_identity(info), None)
        else:
            raise AggregateError(f"Unsafe output path component: {physical}")
    return physical, observed


def _file_revision(path):
    try:
        info, linked = _inspect(path)
    except FileNotFoundError:
        return None
    if linked or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AggregateError(f"Output is not a single regular file: {path}")
    # An existing file with no inode must still be distinguishable from absence.
    return (_optional_identity(info), info.st_size, info.st_mtime_ns)


def _canonical_volume_path(path):
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    open_path = kernel.CreateFileW
    open_path.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                          wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    open_path.restype = wintypes.HANDLE
    final_name = kernel.GetFinalPathNameByHandleW
    final_name.argtypes = (wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD)
    final_name.restype = wintypes.DWORD
    close = kernel.CloseHandle
    close.argtypes = (wintypes.HANDLE,)
    close.restype = wintypes.BOOL

    for ancestor in (path, *path.parents):
        handle = open_path(str(ancestor), 0, 7, None, 3, 0x02000000, None)
        if handle == ctypes.c_void_p(-1).value:
            error = ctypes.get_last_error()
            if error in (2, 3) and ancestor != Path(path.anchor):
                continue
            raise ctypes.WinError(error)
        try:
            buffer = ctypes.create_unicode_buffer(32768)
            # Prefer the same DOS name used for existing output and links.
            size = final_name(handle, buffer, len(buffer), 0)
            if not size and ctypes.get_last_error() == 3:
                size = final_name(handle, buffer, len(buffer), 1)
            if not size:
                raise ctypes.WinError(ctypes.get_last_error())
            if size >= len(buffer):
                raise AggregateError(f"Output path is too long: {path}")
            return Path(buffer.value) / path.relative_to(ancestor)
        finally:
            close(handle)
    raise AggregateError(f"Cannot determine the final output path: {path}")


def _resolve(path):
    try:
        if _volume_path(path):
            resolved = _canonical_volume_path(path)
        else:
            for ancestor in (path, *path.parents):
                try:
                    resolved = ancestor.resolve(strict=True) / path.relative_to(ancestor)
                    break
                except FileNotFoundError:
                    if ancestor == Path(path.anchor):
                        raise
    except RuntimeError as error:
        raise AggregateError(f"Unsafe output path: {path}: {error}") from error
    if os.name == "nt":
        # pathlib can retain the extended prefix when its input uses a GUID.
        if resolved.drive.startswith(_EXTENDED) and re.fullmatch(r"[A-Za-z]:", resolved.drive[len(_EXTENDED):]):
            return Path(str(resolved)[len(_EXTENDED):])
        if str(resolved).upper().startswith(_EXTENDED + "UNC\\"):
            return Path("\\\\" + str(resolved)[8:])
    return resolved


def _location(path):
    """Identify a path by its closest existing ancestor and remaining components."""
    for ancestor in (path, *path.parents):
        try:
            info = ancestor.stat()
        except FileNotFoundError:
            continue
        return _optional_identity(info) or ancestor, tuple(
            os.path.normcase(part) for part in path.relative_to(ancestor).parts)
    raise AggregateError(f"Cannot identify output location: {path}")


def _physically_within(path, root):
    if path.is_relative_to(root):
        return True
    location = _location(root)
    return any(_location(ancestor) == location for ancestor in (path, *path.parents))


class OutputDirectory:
    """Resolve the save directory and track observed components."""

    def __init__(self, logical, junction_root=None, *, allow_volume=False):
        self.logical = logical
        self.junction_root = junction_root
        self.allow_volume = allow_volume
        self.physical, self.observed = self._scan()

    def _scan(self):
        path, observed = _directories(self.logical, self.junction_root, allow_volume=self.allow_volume,
                                      allow_unc=self.allow_volume)
        canonical = _resolve(path)
        # Windows resolves aliases such as short names and substituted drives here.
        if canonical != path:
            canonical, physical = _directories(canonical, None, allow_volume=True, allow_unc=True)
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


def safe_path(path: Path, *, allow_volume=False) -> Path:
    """Reject links/reparse points and unsafe Windows path components before writes."""
    _check_spelling(path, allow_volume=allow_volume, allow_unc=allow_volume)
    parent = OutputDirectory(path.parent, allow_volume=allow_volume)
    original = _file_revision(path)
    physical = _resolve(parent.physical / path.name)
    _check_spelling(physical, allow_volume=allow_volume, allow_unc=allow_volume)
    if _file_revision(physical) != original:
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

    key = sha256(str(path).upper().encode("utf-8")).hexdigest()
    with _windows_mutex(key, path):
        yield


@contextmanager
def _windows_mutex(key, path):
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.ReleaseMutex.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
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
    directory = OutputDirectory(path.parent, allow_volume=validate is not None)

    def check():
        if validate is not None:
            validate()
        directory.check()
        if safe_path(path, allow_volume=validate is not None) != path:
            raise AggregateError(f"Output path changed: {path}")

    for parent in reversed(path.parents):
        if parent not in directory.observed:
            check()
            parent.mkdir(exist_ok=True)
            directory.check(bind=True)
    check()
    with _writer(path):
        check()
        original_revision = _file_revision(path)
        original = _read_existing(path)
        if expected is _GENERATED:
            if original is not None:
                assert_owner(original, content)
        elif expected is None or expected != original:
            raise AggregateError(f"Configuration changed before saving: {path}")
        elif original_revision is None or original_revision[0] is None:
            raise AggregateError(f"Cannot identify configuration file: {path}")
        check()
        if _file_revision(path) != original_revision:
            raise AggregateError(f"Output changed before saving: {path}")
        if original == content:
            return False
        temporary = None
        temporary_identity = None
        try:
            with NamedTemporaryFile(dir=path.parent, prefix=".mdh-", suffix=".tmp", delete=False) as handle:
                temporary = Path(handle.name)
                try:
                    temporary_identity = _optional_identity(os.fstat(handle.fileno()))
                except OSError:
                    if expected is not _GENERATED:
                        raise
                if expected is not _GENERATED and temporary_identity is None:
                    raise AggregateError(f"Cannot identify temporary configuration file: {temporary}")
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            check()
            current = _file_revision(temporary)
            if (current is None or (current[0] and temporary_identity and current[0] != temporary_identity)
                    or current[1] != len(content) or temporary.read_bytes() != content
                    or _file_revision(path) != original_revision or _read_existing(path) != original):
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
                try:
                    directory.check()
                    info, linked = _inspect(temporary)
                    if (linked or not stat.S_ISREG(info.st_mode)
                            or _identity(info, temporary) != temporary_identity):
                        raise AggregateError(f"Temporary output changed: {temporary}")
                    temporary.unlink(missing_ok=True)
                except FileNotFoundError:
                    pass
                except (OSError, ValueError) as error:
                    _LOGGER.warning("Temporary output retained at %s: %s", temporary, error)
