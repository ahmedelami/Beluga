#!/usr/bin/env python3
"""Hold a short, renewable, credential-free power assertion on one exact iPhone.

The current macOS user, this checked-out helper, and the pinned UV CPython/stdlib are the trusted
local boundary. Runtime sealing rejects ambient startup hooks, import shadowing, and dependency
drift; it cannot defend against a concurrent malicious process running as that same trusted user.
"""

import argparse
import asyncio
import hashlib
import importlib
import importlib.machinery
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time
from typing import Any


SCHEMA = "opensteamer.iphone15-dev-power-assertion.v1"
EXACT_HARDWARE_UDID = "00008120-0000242E3E32201E"
ASSERTION_TYPE = "PreventUserIdleSystemSleep"
ASSERTION_NAME = "opensteamer-iphone15-dev-visual-oracle"
LEASE_SECONDS = 45
RENEW_AFTER_SECONDS = 15
HEARTBEAT_INTERVAL_SECONDS = 0.5
TUNNEL_OPEN_TIMEOUT_SECONDS = 30
SERVICE_CONNECT_TIMEOUT_SECONDS = 8
ASSERTION_ACQUIRE_TIMEOUT_SECONDS = 5
SERVICE_CLOSE_TIMEOUT_SECONDS = 5
TUNNEL_CLOSE_TIMEOUT_SECONDS = 15
EXPECTED_PYMOBILEDEVICE3_VERSION = "11.12.5"
EXPECTED_PYTHON_EXECUTABLE = Path(
    "/Users/ahmed/.local/share/uv/python/"
    "cpython-3.13.14-macos-aarch64-none/bin/python3.13"
)
EXPECTED_PYTHON_SHA256 = (
    "b5a0d384a1641cd7366eba632a3e5d9387af5216feb50fb29a77d9c84e97138d"
)
EXPECTED_PACKAGE_ROOT = Path(
    "/Users/ahmed/.cache/uv/archive-v0/b5PMJnUwNcGRSShq/"
    "lib/python3.13/site-packages"
)
EXPECTED_STDLIB_PATHS = (
    "/Users/ahmed/.local/share/uv/python/"
    "cpython-3.13.14-macos-aarch64-none/lib/python313.zip",
    "/Users/ahmed/.local/share/uv/python/"
    "cpython-3.13.14-macos-aarch64-none/lib/python3.13",
    "/Users/ahmed/.local/share/uv/python/"
    "cpython-3.13.14-macos-aarch64-none/lib/python3.13/lib-dynload",
)
EXPECTED_SITE_PACKAGES_TREE_SHA256 = (
    "c2cc8270899a50f0d108432906a65d34adc59b36097fd04a0dc65128e7ffe23f"
)
EXPECTED_SITE_PACKAGES_FILE_COUNT = 10668
EXPECTED_SITE_PACKAGES_BYTE_COUNT = 111436193
EXPECTED_NATIVE_TUNNEL_SHA256 = (
    "c398af3997c98cc469a695c585454d1e89d5f688c710cd85cd785c41c5fa7ef7"
)
EXPECTED_POWER_ASSERTION_SHA256 = (
    "6c44196870adfd66efaa1a68c92b5edb268b6d52cc2963ed85178b0358b7edb1"
)


def _file_sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def _has_symlink_ancestor(path: Path) -> bool:
    current = path
    while True:
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            return True
        if current == current.parent:
            return False
        current = current.parent


def _site_packages_tree_identity() -> tuple[str, int, int]:
    if _has_symlink_ancestor(EXPECTED_PACKAGE_ROOT):
        raise RuntimeError("site_packages_symlink_ancestor")
    aggregate = hashlib.sha256()
    file_count = 0
    byte_count = 0
    for directory, directory_names, file_names in os.walk(
        EXPECTED_PACKAGE_ROOT, topdown=True, followlinks=False
    ):
        directory_names.sort()
        file_names.sort()
        parent = Path(directory)
        retained_directories: list[str] = []
        for name in directory_names:
            candidate = parent / name
            metadata = os.lstat(candidate)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise RuntimeError("unsafe_site_packages_directory")
            if name != "__pycache__":
                retained_directories.append(name)
        directory_names[:] = retained_directories
        for name in file_names:
            if name.endswith(".pyc"):
                continue
            candidate = parent / name
            metadata = os.lstat(candidate)
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeError("unsafe_site_packages_file")
            relative = candidate.relative_to(EXPECTED_PACKAGE_ROOT).as_posix()
            aggregate.update(relative.encode("utf-8"))
            aggregate.update(b"\0")
            aggregate.update(str(metadata.st_size).encode("ascii"))
            aggregate.update(b"\0")
            with candidate.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    aggregate.update(chunk)
            aggregate.update(b"\0")
            file_count += 1
            byte_count += metadata.st_size
    return aggregate.hexdigest(), file_count, byte_count


class SourceOnlyFileLoader(importlib.machinery.SourceFileLoader):
    """Compile the sealed source directly; never consult an excluded bytecode cache."""

    def get_code(self, fullname: str) -> Any:
        source_path = self.get_filename(fullname)
        return self.source_to_code(self.get_data(source_path), source_path)


def _install_source_and_extension_only_site_loader() -> None:
    source_and_extension_hook = importlib.machinery.FileFinder.path_hook(
        (
            SourceOnlyFileLoader,
            importlib.machinery.SOURCE_SUFFIXES,
        ),
        (
            importlib.machinery.ExtensionFileLoader,
            importlib.machinery.EXTENSION_SUFFIXES,
        ),
    )

    def sealed_site_packages_path_hook(path: str) -> Any:
        candidate = Path(path)
        if candidate == EXPECTED_PACKAGE_ROOT or EXPECTED_PACKAGE_ROOT in candidate.parents:
            return source_and_extension_hook(path)
        raise ImportError

    sys.path_hooks.insert(0, sealed_site_packages_path_hook)


def _load_verified_runtime() -> tuple[type[Any], type[Any]]:
    if (
        sys.flags.isolated != 1
        or sys.flags.no_site != 1
        or sys.flags.dont_write_bytecode != 1
        or tuple(sys.path) != EXPECTED_STDLIB_PATHS
        or Path(sys.executable) != EXPECTED_PYTHON_EXECUTABLE
        or _has_symlink_ancestor(EXPECTED_PYTHON_EXECUTABLE)
        or _file_sha256(EXPECTED_PYTHON_EXECUTABLE) != EXPECTED_PYTHON_SHA256
        or any(
            module in sys.modules
            for module in (
                "site",
                "sitecustomize",
                "usercustomize",
                "_virtualenv",
                "coloredlogs",
            )
        )
    ):
        raise RuntimeError("unsealed_python_startup")
    # CPython includes a nonexistent versioned zip candidate by default. Remove it before any
    # third-party import so a same-user file creation cannot become a late shadowing path.
    if Path(EXPECTED_STDLIB_PATHS[0]).exists():
        raise RuntimeError("unexpected_stdlib_zip")
    sys.path[:] = list(EXPECTED_STDLIB_PATHS[1:])
    expected_identity = (
        EXPECTED_SITE_PACKAGES_TREE_SHA256,
        EXPECTED_SITE_PACKAGES_FILE_COUNT,
        EXPECTED_SITE_PACKAGES_BYTE_COUNT,
    )
    if _site_packages_tree_identity() != expected_identity:
        raise RuntimeError("unexpected_site_packages_tree")
    expected_files = (
        (
            EXPECTED_PACKAGE_ROOT / "pymobiledevice3/remote/native_tunnel.py",
            EXPECTED_NATIVE_TUNNEL_SHA256,
        ),
        (
            EXPECTED_PACKAGE_ROOT / "pymobiledevice3/services/power_assertion.py",
            EXPECTED_POWER_ASSERTION_SHA256,
        ),
    )
    for expected_path, expected_sha256 in expected_files:
        if _file_sha256(expected_path) != expected_sha256:
            raise RuntimeError("unexpected_pymobiledevice3_source")
    _install_source_and_extension_only_site_loader()
    sys.path.append(str(EXPECTED_PACKAGE_ROOT))
    if importlib.metadata.version("pymobiledevice3") != EXPECTED_PYMOBILEDEVICE3_VERSION:
        raise RuntimeError("unexpected_pymobiledevice3_version")
    native_tunnel = importlib.import_module("pymobiledevice3.remote.native_tunnel")
    power_assertion = importlib.import_module("pymobiledevice3.services.power_assertion")
    for module, (expected_path, _) in zip(
        (native_tunnel, power_assertion), expected_files, strict=True
    ):
        if Path(module.__file__).resolve(strict=True) != expected_path:
            raise RuntimeError("unexpected_pymobiledevice3_import_path")
    if _site_packages_tree_identity() != expected_identity:
        raise RuntimeError("site_packages_changed_during_import")

    class ExistingPairingOnlyNativeRemotedTunnel(native_tunnel.NativeRemotedTunnel):
        """Open the pinned native tunnel without issuing any pairing command."""

        def _establish(self, session: Any) -> str:
            session.browse(self.serial)
            xpc = session._xpc
            if session._device_conn is None:
                raise RuntimeError("missing_existing_pairing_connection")
            response_wrapper = session._request(
                session._device_conn,
                b"RemotePairing.CreateAssertionCommand",
                lambda body: xpc.dictionary_set_int64(body, b"flags", 0),
            )
            try:
                if xpc.dictionary_get_value(response_wrapper, b"error"):
                    raise RuntimeError("existing_pairing_assertion_rejected")
                response = xpc.dictionary_get_value(response_wrapper, b"response")
                if not response:
                    raise RuntimeError("existing_pairing_assertion_missing_response")
                assertion_id = xpc.dictionary_get_value(
                    response, b"assertionIdentifier"
                )
                if assertion_id:
                    session._assertion_id = xpc.retain(assertion_id)
                info = xpc.dictionary_get_value(response, b"info")
                tunnel_ip = xpc.dictionary_get_string(info, b"tunnelIPAddress") if info else None
                if not tunnel_ip:
                    raise RuntimeError("existing_pairing_assertion_missing_address")
                session.tunnel_ip = tunnel_ip.decode()
                return session.tunnel_ip
            finally:
                xpc.release(response_wrapper)

    return ExistingPairingOnlyNativeRemotedTunnel, power_assertion.PowerAssertionService


def _private_parent(path: Path) -> bool:
    try:
        if not path.is_absolute() or ".." in path.parts:
            return False
        immediate_parent = path.parent
        current = immediate_parent
        while True:
            metadata = os.lstat(current)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                return False
            if current == current.parent:
                break
            current = current.parent
        parent_metadata = os.lstat(immediate_parent)
        return (
            parent_metadata.st_uid == os.getuid()
            and stat.S_IMODE(parent_metadata.st_mode) == 0o700
        )
    except OSError:
        return False


def _write_status(
    path: Path,
    *,
    phase: str,
    udid: str,
    owner_pid: int,
    sequence: int,
    lease_expires_at: int | None,
    residual_lease_expires_at: int | None,
    service_closed: bool,
    tunnel_closed: bool,
    error_type: str | None = None,
) -> None:
    payload = {
        "schema": SCHEMA,
        "phase": phase,
        "pid": os.getpid(),
        "ownerPid": owner_pid,
        "udid": udid,
        "assertionType": ASSERTION_TYPE,
        "sequence": sequence,
        "observedAt": int(time.time()),
        "leaseExpiresAt": lease_expires_at,
        "residualLeaseExpiresAt": residual_lease_expires_at,
        "maximumResidualLeaseSeconds": LEASE_SECONDS,
        "serviceClosed": service_closed,
        "tunnelClosed": tunnel_closed,
        "errorType": error_type,
    }
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


async def _acquire_bounded_assertion(service: Any) -> None:
    assertion = service.create_power_assertion(
        ASSERTION_TYPE,
        ASSERTION_NAME,
        LEASE_SECONDS,
        "Bounded OpenSteamer development visual-oracle live step",
    )
    await asyncio.wait_for(
        assertion.__aenter__(), timeout=ASSERTION_ACQUIRE_TIMEOUT_SECONDS
    )
    await asyncio.wait_for(
        assertion.__aexit__(None, None, None), timeout=ASSERTION_ACQUIRE_TIMEOUT_SECONDS
    )


async def _run(args: argparse.Namespace) -> int:
    tunnel_type, power_assertion_type = _load_verified_runtime()
    stop_requested = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        loop.add_signal_handler(signal_number, stop_requested.set)

    sequence = 0
    last_lease_expires_at: int | None = None
    tunnel = tunnel_type(serial=args.udid)
    service: Any | None = None
    run_error: BaseException | None = None
    service_closed = False
    tunnel_closed = False
    try:
        rsd = await asyncio.wait_for(
            tunnel.aopen(), timeout=TUNNEL_OPEN_TIMEOUT_SECONDS
        )
        if rsd.udid != args.udid:
            raise RuntimeError("wrong_device")
        service = power_assertion_type(rsd)
        await asyncio.wait_for(
            service.connect(), timeout=SERVICE_CONNECT_TIMEOUT_SECONDS
        )
        while not stop_requested.is_set():
            if os.getppid() != args.owner_pid or args.stop_file.exists():
                break
            await _acquire_bounded_assertion(service)
            last_lease_expires_at = int(time.time()) + LEASE_SECONDS
            renewal_deadline = time.monotonic() + RENEW_AFTER_SECONDS
            while time.monotonic() < renewal_deadline:
                if (
                    stop_requested.is_set()
                    or os.getppid() != args.owner_pid
                    or args.stop_file.exists()
                ):
                    break
                sequence += 1
                _write_status(
                    args.heartbeat,
                    phase="active",
                    udid=args.udid,
                    owner_pid=args.owner_pid,
                    sequence=sequence,
                    lease_expires_at=last_lease_expires_at,
                    residual_lease_expires_at=None,
                    service_closed=False,
                    tunnel_closed=False,
                )
                try:
                    await asyncio.wait_for(
                        stop_requested.wait(),
                        timeout=HEARTBEAT_INTERVAL_SECONDS,
                    )
                except asyncio.TimeoutError:
                    pass
    except BaseException as error:
        run_error = error
    finally:
        if service is not None:
            try:
                await asyncio.wait_for(
                    service.close(), timeout=SERVICE_CLOSE_TIMEOUT_SECONDS
                )
                service_closed = True
            except BaseException as error:
                run_error = run_error or error
        try:
            await asyncio.wait_for(
                tunnel.aclose(), timeout=TUNNEL_CLOSE_TIMEOUT_SECONDS
            )
            tunnel_closed = True
        except BaseException as error:
            run_error = run_error or error

    if run_error is None and last_lease_expires_at is not None:
        _write_status(
            args.heartbeat,
            phase="stopped",
            udid=args.udid,
            owner_pid=args.owner_pid,
            sequence=sequence,
            lease_expires_at=None,
            residual_lease_expires_at=last_lease_expires_at,
            service_closed=service_closed,
            tunnel_closed=tunnel_closed,
        )
        return 0
    try:
        _write_status(
            args.heartbeat,
            phase="failed",
            udid=args.udid,
            owner_pid=args.owner_pid,
            sequence=sequence,
            lease_expires_at=None,
            residual_lease_expires_at=last_lease_expires_at,
            service_closed=service_closed,
            tunnel_closed=tunnel_closed,
            error_type=type(run_error).__name__ if run_error is not None else "NoLease",
        )
    except Exception:
        pass
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-runtime", action="store_true")
    parser.add_argument("--udid")
    parser.add_argument("--owner-pid", type=int)
    parser.add_argument("--heartbeat", type=Path)
    parser.add_argument("--stop-file", type=Path)
    args = parser.parse_args()
    if args.verify_runtime:
        if any(
            value is not None
            for value in (args.udid, args.owner_pid, args.heartbeat, args.stop_file)
        ):
            return 2
        _load_verified_runtime()
        return 0
    if (
        args.udid != EXACT_HARDWARE_UDID
        or args.owner_pid is None
        or args.owner_pid <= 1
        or args.owner_pid != os.getppid()
        or args.heartbeat is None
        or args.stop_file is None
        or args.heartbeat == args.stop_file
        or not _private_parent(args.heartbeat)
        or not _private_parent(args.stop_file)
        or args.heartbeat.exists()
        or args.heartbeat.is_symlink()
        or args.stop_file.exists()
        or args.stop_file.is_symlink()
    ):
        return 2
    return asyncio.run(_run(args))


if __name__ == "__main__":
    raise SystemExit(main())
