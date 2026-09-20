import Foundation

/// The SSH peer needs only Python's standard library. stdout is the JSON protocol;
/// stderr contains a short actionable failure. Session payloads remain immutable.
enum SessionSyncRemoteHelper {
    static let python = #"""
import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,189}\Z")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,189}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

class SyncError(Exception):
    pass

class IncompleteSession(SyncError):
    pass

def safe_id(value):
    if not ID.fullmatch(value):
        raise SyncError("The session identifier is not a safe folder name.")
    return value

def root_path(value):
    if not value or len(value.encode("utf-8")) > 2048 or any(unicodedata.category(c) in ("Cc", "Cf") for c in value):
        raise SyncError("The recordings folder contains an invalid character.")
    if not (value.startswith("/") or value.startswith("~/")):
        raise SyncError("Use an absolute recordings folder or a path beginning with ~/.")
    if value == "~/" or any(component in (".", "..") for component in value.split("/")):
        raise SyncError("Use a recordings subfolder without '.' or '..' path components.")
    path = os.path.normpath(os.path.expanduser(value))
    if path == "/" or not os.path.isabs(path):
        raise SyncError("Choose a recordings folder below the filesystem root.")
    return path

def directory(parent, name, create=False):
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    try:
        return os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SyncError("A recordings or staging folder is a symlink or is not a directory.")
        raise

def open_root(path):
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.split("/"):
            if not component:
                continue
            following = directory(descriptor, component, create=True)
            os.close(descriptor)
            descriptor = following
        return descriptor
    except Exception:
        os.close(descriptor)
        raise

def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)

def core_file(folder, name, keep_data=False):
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise SyncError("A session file is a symlink: " + name)
        raise
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise SyncError("A session file is not a regular file: " + name)
        if before.st_size <= 0:
            raise SyncError("A session file is empty: " + name)
        if keep_data and before.st_size > 16 * 1024 * 1024:
            raise SyncError("The session manifest is unexpectedly large.")
        digest = hashlib.sha256()
        count = 0
        content = bytearray() if keep_data else None
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            count += len(block)
            digest.update(block)
            if keep_data:
                if count > 16 * 1024 * 1024:
                    raise SyncError("The session manifest is unexpectedly large.")
                content.extend(block)
        after = os.fstat(descriptor)
        linked = os.stat(name, dir_fd=folder, follow_symlinks=False)
        if identity(before) != identity(after) or identity(after) != identity(linked) or count != after.st_size:
            raise SyncError("A session file changed while it was being checked: " + name)
        return {"name": name, "bytes": count, "sha256": digest.hexdigest()}, content, identity(after)
    finally:
        os.close(descriptor)

def describe_session(parent, folder_name, expected_id=None):
    folder = directory(parent, folder_name)
    try:
        manifest_file, content, manifest_identity = core_file(folder, "manifest.json", keep_data=True)
        try:
            manifest = json.loads(content.decode("utf-8"))
        except (ValueError, UnicodeError):
            raise SyncError("The session manifest is not valid UTF-8 JSON.")
        if not isinstance(manifest, dict):
            raise SyncError("The session manifest must be an object.")
        status = manifest.get("status")
        if not isinstance(status, str):
            raise SyncError("The session manifest has no valid recording status.")
        if status != "complete":
            raise IncompleteSession("The session is not complete yet.")
        identifier = manifest.get("id")
        if not isinstance(identifier, str):
            raise SyncError("The session manifest is missing its identifier.")
        safe_id(identifier)
        if identifier != (expected_id if expected_id is not None else folder_name):
            raise SyncError("The session identifier does not match its folder.")
        if not isinstance(manifest.get("endedAt"), str) or not manifest["endedAt"].strip():
            raise SyncError("The completed session has no end time.")
        if manifest.get("unfinishedFiles", []) != []:
            raise SyncError("The session still has unfinished files.")
        chunks = manifest.get("chunks")
        if not isinstance(chunks, list) or not chunks:
            raise SyncError("The session contains no completed video chunks.")
        files = [manifest_file]
        identities = {"manifest.json": manifest_identity}
        chunk_names = set()
        for chunk in chunks:
            if not isinstance(chunk, dict):
                raise SyncError("The session contains an invalid video chunk.")
            name = chunk.get("fileName")
            if not isinstance(name, str) or not NAME.fullmatch(name) or not name.endswith(".mp4"):
                raise SyncError("A video chunk has an unsafe filename.")
            if name in chunk_names:
                raise SyncError("The session lists a video chunk more than once.")
            chunk_names.add(name)
            declared = chunk.get("byteCount", 0)
            if isinstance(declared, bool) or not isinstance(declared, int) or declared < 0:
                raise SyncError("A video chunk has an invalid byte count.")
            descriptor, _, file_identity = core_file(folder, name)
            if descriptor["bytes"] <= 0 or (declared != 0 and declared != descriptor["bytes"]):
                raise SyncError("A video chunk is empty or its size does not match the manifest: " + name)
            files.append(descriptor)
            identities[name] = file_identity
        try:
            os.stat("diagnostics.json", dir_fd=folder, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            descriptor, _, file_identity = core_file(folder, "diagnostics.json")
            files.append(descriptor)
            identities["diagnostics.json"] = file_identity
        for name, expected in identities.items():
            if identity(os.stat(name, dir_fd=folder, follow_symlinks=False)) != expected:
                raise SyncError("A session file changed during validation: " + name)
        files.sort(key=lambda item: item["name"])
        fingerprint = hashlib.sha256()
        for item in files:
            fingerprint.update((item["name"] + "\0" + str(item["bytes"]) + "\0" + item["sha256"] + "\n").encode("utf-8"))
        return {"id": identifier, "digest": fingerprint.hexdigest(), "files": files}
    finally:
        os.close(folder)

def inventory(root, path):
    sessions, rejected = [], []
    for name in sorted(os.listdir(root)):
        if name.startswith("."):
            continue
        try:
            safe_id(name)
            info = os.stat(name, dir_fd=root, follow_symlinks=False)
            if stat.S_ISREG(info.st_mode):
                continue
            sessions.append(describe_session(root, name))
        except IncompleteSession:
            continue
        except (SyncError, OSError) as error:
            rejected.append(name + ": " + str(error))
    return {"root": path, "sessions": sessions, "rejected": rejected}

def staging_name(identifier, digest):
    safe_id(identifier)
    if not DIGEST.fullmatch(digest):
        raise SyncError("The session fingerprint is invalid.")
    return identifier + "-" + digest

def prepare(root, path, identifier, digest):
    name = staging_name(identifier, digest)
    staging = directory(root, ".scholarseye-sync", create=True)
    try:
        target = directory(staging, name, create=True)
        try:
            os.fchmod(staging, 0o700)
            os.fchmod(target, 0o700)
            for entry in os.listdir(target):
                if not stat.S_ISREG(os.stat(entry, dir_fd=target, follow_symlinks=False).st_mode):
                    raise SyncError("The staging folder contains an unsafe non-regular file.")
        finally:
            os.close(target)
    finally:
        os.close(staging)
    return {"path": os.path.join(path, ".scholarseye-sync", name)}

def matching_destination(root, identifier, digest):
    try:
        os.stat(identifier, dir_fd=root, follow_symlinks=False)
    except FileNotFoundError:
        return False
    try:
        existing = describe_session(root, identifier)
    except (SyncError, OSError):
        raise SyncError("A different or invalid session already exists at the destination; nothing was overwritten.")
    if existing["digest"] != digest:
        raise SyncError("A different session already uses this identifier; nothing was overwritten.")
    return True

def finalize(root, path, identifier, digest):
    name = staging_name(identifier, digest)
    if matching_destination(root, identifier, digest):
        return {"status": "unchanged"}
    staging = directory(root, ".scholarseye-sync")
    try:
        descriptor = describe_session(staging, name, expected_id=identifier)
        if descriptor["digest"] != digest:
            raise SyncError("The copied session failed its fingerprint check; nothing was imported.")
        # Descriptor-relative rename provides macOS RENAME_EXCL's atomic
        # no-overwrite guarantee without following changed parent symlinks.
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(staging, os.fsencode(name), root, os.fsencode(identifier), 4) != 0:
            code = ctypes.get_errno()
            if code == errno.EEXIST and matching_destination(root, identifier, digest):
                return {"status": "unchanged"}
            raise SyncError("The verified session could not be imported: " + os.strerror(code))
        os.fsync(root)
        return {"status": "imported"}
    finally:
        os.close(staging)

def main():
    if len(sys.argv) < 3:
        raise SyncError("Missing sync action or recordings folder.")
    action, path = sys.argv[1], root_path(sys.argv[2])
    if action not in ("inventory", "prepare", "finalize"):
        raise SyncError("Unknown session sync action.")
    if len(sys.argv) != (3 if action == "inventory" else 5):
        raise SyncError("Incorrect arguments for the session sync action.")
    root = open_root(path)
    try:
        if action == "inventory":
            result = inventory(root, path)
        elif action == "prepare":
            result = prepare(root, path, sys.argv[3], sys.argv[4])
        else:
            result = finalize(root, path, sys.argv[3], sys.argv[4])
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    finally:
        os.close(root)

try:
    main()
except (SyncError, OSError, ValueError, AttributeError) as error:
    print("Session sync: " + str(error), file=sys.stderr)
    sys.exit(1)
"""#
}
