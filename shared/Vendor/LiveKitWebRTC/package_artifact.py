#!/usr/bin/env python3
"""Package reviewed, already-built frameworks. No compilation, signing or publication.

Only a previously absent output directory is accepted. Failed attempts are retained there
without COMPLETE.json; never reuse that directory. Canonical ZIP bytes are deterministic for
identical inputs and the same Python/zlib version; source rebuild determinism is not implied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import tempfile
import zipfile

NAME = "LiveKitWebRTC"
BUNDLE_ID = "io.livekit.LiveKitWebRTC"
DEVELOPER = Path("/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/"
                 "Xcode-26.6.0.app/Contents/Developer")
XCODEBUILD_SHA256 = "d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4"
# Canonical file/type/mode/link manifest of the official 144.7559.11 Mac framework.
OFFICIAL_MAC_MANIFEST_SHA256 = "ed48b96a26ff499911c4a9a5ac700a26c32c845ad82351d5b74054705302ef15"
SLICES = {
    "ios-arm64": ("ios", None, {"arm64"}, 2),
    "ios-arm64-simulator": ("ios", "simulator", {"arm64"}, 7),
    "macos-arm64_x86_64": ("macos", None, {"arm64", "x86_64"}, 1),
}
CPU_NAMES = {0x0100000C: "arm64", 0x01000007: "x86_64"}
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=True) + "\n").encode("ascii")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_path(path):
    path = Path(path)
    require(path.is_absolute() and path == path.resolve(),
            "paths must be absolute, canonical and contain no symlink components")
    return path


def safe_relative(name):
    path = PurePosixPath(name)
    require(name and not name.startswith("/") and "\\" not in name
            and "\x00" not in name and all(part not in ("", ".", "..")
                                            for part in name.split("/")),
            "unsafe archive/manifest path")
    return path


def tree_manifest(root):
    root = canonical_path(root)
    require(root.is_dir(), "framework tree is absent")
    entries = []

    def visit(path, relative):
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        require(mode & ~0o777 == 0, "special permission bits are forbidden")
        entry = {"path": relative, "mode": format(mode, "04o")}
        if relative:
            safe_relative(relative)
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            require(target and not os.path.isabs(target) and "\\" not in target,
                    "absolute or malformed symlink")
            resolved = path.resolve(strict=True)
            require(resolved.is_relative_to(root), "symlink escapes framework tree")
            entry.update(kind="symlink", target=target)
        elif stat.S_ISDIR(metadata.st_mode):
            entry.update(kind="directory")
        elif stat.S_ISREG(metadata.st_mode):
            entry.update(kind="file", size=metadata.st_size, sha256=sha256(path))
        else:
            raise ValueError("special file is forbidden")
        entries.append(entry)
        if entry["kind"] == "directory":
            for child in sorted(path.iterdir(), key=lambda item: item.name):
                require(child.name != ".DS_Store" and not child.name.startswith("._"),
                        "Finder metadata is forbidden")
                visit(child, f"{relative}/{child.name}" if relative else child.name)

    visit(root, "")
    return entries


def macho_architectures(path, expected_platform):
    data = Path(path).read_bytes()
    require(len(data) >= 32, "missing Mach-O header")
    magic = struct.unpack_from(">I", data)[0]
    ranges = []
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 20 if magic == 0xCAFEBABE else 32
        require(0 < count <= 2 and 8 + count * stride <= len(data), "bad fat header")
        for index in range(count):
            offset = 8 + index * stride
            if stride == 20:
                cpu, _, start, size, _ = struct.unpack_from(">IIIII", data, offset)
            else:
                cpu, _, start, size, _, _ = struct.unpack_from(">IIQQII", data, offset)
            require(start >= 8 + count * stride and size >= 32
                    and start + size <= len(data), "fat slice is out of bounds")
            require(all(start + size <= old_start or start >= old_start + old_size
                        for old_start, old_size, _ in ranges), "overlapping fat slices")
            ranges.append((start, size, cpu))
    else:
        ranges = [(0, len(data), None)]
    architectures = set()
    for start, size, fat_cpu in ranges:
        header = struct.unpack_from("<IIIIIIII", data, start)
        _, cpu, _, file_type, command_count, commands_size, _, _ = header
        require(header[0] == 0xFEEDFACF and file_type == 6 and cpu in CPU_NAMES,
                "expected a supported 64-bit dynamic framework")
        require(fat_cpu is None or fat_cpu == cpu, "fat/thin architecture mismatch")
        require(CPU_NAMES[cpu] not in architectures, "duplicate architecture")
        architectures.add(CPU_NAMES[cpu])
        end = start + 32 + commands_size
        require(end <= start + size and command_count <= commands_size // 8,
                "invalid Mach-O load command bounds")
        cursor = start + 32
        platforms, names = [], []
        for _ in range(command_count):
            require(cursor + 8 <= end, "truncated load command")
            command, length = struct.unpack_from("<II", data, cursor)
            require(length >= 8 and length % 8 == 0 and cursor + length <= end,
                    "invalid load command")
            if command == 0x32:  # LC_BUILD_VERSION, from the pinned SDK's loader.h.
                require(length >= 24, "truncated build-version command")
                platforms.append(struct.unpack_from("<I", data, cursor + 8)[0])
            if command == 0x0D:  # LC_ID_DYLIB.
                require(length >= 24, "truncated dylib identity")
                name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
                require(24 <= name_offset < length, "invalid dylib name offset")
                name = data[cursor + name_offset:cursor + length]
                require(b"\0" in name, "unterminated dylib name")
                names.append(name.split(b"\0", 1)[0])
            cursor += length
        require(cursor == end and platforms == [expected_platform],
                "missing, duplicate or wrong Mach-O platform")
        require(names == [b"@rpath/LiveKitWebRTC.framework/LiveKitWebRTC"],
                "unexpected framework install name")
    return architectures


def validate_framework(path, slice_name):
    path = canonical_path(path)
    require(path.name == f"{NAME}.framework", "framework name differs")
    tree_manifest(path)  # Reject escaping links and special files before any tool consumes it.
    platform, _, architectures, platform_id = SLICES[slice_name]
    info_path = (path / "Versions/A/Resources/Info.plist" if platform == "macos"
                 else path / "Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("CFBundleIdentifier") == BUNDLE_ID
            and info.get("CFBundleExecutable") == NAME
            and info.get("CFBundlePackageType") == "FMWK", "framework plist identity differs")
    modulemap = path / "Modules/module.modulemap"
    require(modulemap.is_file() and re.findall(
        r"(?m)^\s*framework\s+module\s+([A-Za-z_]\w*)\s*\{", modulemap.read_text()) == [NAME],
            "framework module identity differs")
    require(macho_architectures(path / NAME, platform_id) == architectures,
            "framework architectures differ")


def verify_official_mac(path):
    validate_framework(path, "macos-arm64_x86_64")
    manifest = tree_manifest(path)
    require(hashlib.sha256(canonical_json(manifest)).hexdigest()
            == OFFICIAL_MAC_MANIFEST_SHA256, "Mac framework differs from official pinned bytes")
    return manifest


def assemble_xcframework(frameworks, destination, log_path):
    tool = DEVELOPER / "usr/bin/xcodebuild"
    require(canonical_path(tool).is_file() and sha256(tool) == XCODEBUILD_SHA256,
            "xcodebuild differs from the pinned tool")
    arguments = [str(tool), "-create-xcframework"]
    for framework in frameworks.values():
        arguments.extend(["-framework", str(framework)])
    arguments.extend(["-output", str(destination)])
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("DYLD_")}
    environment.update(DEVELOPER_DIR=str(DEVELOPER), LC_ALL="C")
    with log_path.open("xb") as log:
        subprocess.run(arguments, env=environment, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=120)


def verify_xcframework(root, official_mac_manifest):
    root = canonical_path(root)
    info = plistlib.loads((root / "Info.plist").read_bytes())
    require(info.get("XCFrameworkFormatVersion") == "1.0"
            and info.get("CFBundlePackageType") == "XFWK", "invalid XCFramework plist")
    libraries = info.get("AvailableLibraries", [])
    require(len(libraries) == 3, "exactly three slices are required")
    identifiers = [item.get("LibraryIdentifier") for item in libraries]
    require(set(identifiers) == set(SLICES), "missing, duplicate or unsupported slice")
    for item in libraries:
        identifier = item["LibraryIdentifier"]
        platform, variant, architectures, _ = SLICES[identifier]
        root_binary_path = f"{NAME}.framework/{NAME}"
        binary_path = item.get("BinaryPath", root_binary_path)
        allowed_binary_paths = {root_binary_path}
        if identifier == "macos-arm64_x86_64":
            # Pinned Xcode's real assembly emits the versioned Mac path; the official
            # release plist uses its root symlink. Accept only these exact spellings.
            allowed_binary_paths.add(f"{NAME}.framework/Versions/A/{NAME}")
        require(item.get("LibraryPath") == f"{NAME}.framework"
                and binary_path in allowed_binary_paths
                and item.get("SupportedPlatform") == platform
                and item.get("SupportedPlatformVariant") == variant
                and len(item.get("SupportedArchitectures", [])) == len(architectures)
                and set(item.get("SupportedArchitectures", [])) == architectures,
                "slice metadata differs")
        slice_root = canonical_path(root / identifier)
        require({child.name for child in slice_root.iterdir()} == {f"{NAME}.framework"},
                "unreviewed slice payload")
        validate_framework(slice_root / f"{NAME}.framework", identifier)
        require((slice_root / binary_path).resolve(strict=True)
                == (slice_root / root_binary_path).resolve(strict=True),
                "BinaryPath does not resolve to the verified framework executable")
    require(tree_manifest(root / "macos-arm64_x86_64" / f"{NAME}.framework")
            == official_mac_manifest, "assembled/extracted Mac subtree changed")
    require({item.name for item in root.iterdir()} == set(SLICES) | {"Info.plist"},
            "unreviewed XCFramework root payload")


def deterministic_zip(root, destination):
    entries = tree_manifest(root)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9, allowZip64=True) as archive:
        for entry in entries:
            relative = entry["path"]
            name = root.name + (f"/{relative}" if relative else "")
            kind = entry["kind"]
            name += "/" if kind == "directory" else ""
            info = zipfile.ZipInfo(name, ZIP_DATE)
            info.create_system = 3
            file_type = {"directory": stat.S_IFDIR, "symlink": stat.S_IFLNK,
                         "file": stat.S_IFREG}[kind]
            info.external_attr = (file_type | int(entry["mode"], 8)) << 16
            if kind == "directory":
                info.external_attr |= 0x10
            info.compress_type = zipfile.ZIP_DEFLATED
            data = (entry["target"].encode("utf-8") if kind == "symlink" else
                    (root / relative).read_bytes() if kind == "file" else b"")
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return entries


def safe_extract(archive_path, destination):
    destination = canonical_path(destination)
    require(destination.is_dir() and not any(destination.iterdir()),
            "extraction requires a new empty directory")
    with zipfile.ZipFile(archive_path) as archive:
        members, seen, total_size = [], set(), 0
        for info in archive.infolist():
            name = info.filename[:-1] if info.filename.endswith("/") else info.filename
            parts = safe_relative(name).parts
            require(parts[0] == f"{NAME}.xcframework" and name not in seen,
                    "duplicate or unexpected archive root")
            seen.add(name)
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK)
                    and stat.S_IMODE(mode) & ~0o777 == 0,
                    "unsupported ZIP entry type or mode")
            require(info.is_dir() == (kind == stat.S_IFDIR), "ZIP type mismatch")
            total_size += info.file_size
            require(total_size <= 512 * 1024 * 1024, "archive exceeds bounded extraction size")
            members.append((info, name, mode, kind))
        kinds = {name: kind for _, name, _, kind in members}
        for _, name, _, _ in members:
            for ancestor in PurePosixPath(name).parents:
                if str(ancestor) != ".":
                    require(kinds.get(str(ancestor)) == stat.S_IFDIR,
                            "missing parent directory or symlink traversal")
        for info, name, mode, kind in sorted(members, key=lambda value: value[1]):
            target = destination / name
            data = archive.read(info)
            if kind == stat.S_IFDIR:
                require(not data, "directory has unexpected contents")
                target.mkdir(mode=0o700)
            elif kind == stat.S_IFREG:
                with target.open("xb") as stream:
                    stream.write(data)
                target.chmod(stat.S_IMODE(mode))
            else:
                link = data.decode("utf-8")
                require(link and not os.path.isabs(link) and "\\" not in link,
                        "unsafe symlink target")
                # Check lexically before creation, then resolve all links after every entry exists.
                normalized = Path(os.path.normpath(target.parent / link))
                require(normalized.is_relative_to(destination / f"{NAME}.xcframework"),
                        "escaping symlink target")
                target.symlink_to(link)
                os.chmod(target, stat.S_IMODE(mode), follow_symlinks=False)
                require(stat.S_IMODE(target.lstat().st_mode) == stat.S_IMODE(mode),
                        "symlink mode restoration failed")
        for _, name, mode, kind in reversed(members):
            if kind == stat.S_IFDIR:
                (destination / name).chmod(stat.S_IMODE(mode))
    root = destination / f"{NAME}.xcframework"
    tree_manifest(root)
    return root


def verify_archive(archive_path, manifest, official_mac_manifest, expected_sha256):
    archive_path = canonical_path(archive_path)
    require(archive_path.is_file() and sha256(archive_path) == expected_sha256,
            "archive checksum differs")
    with tempfile.TemporaryDirectory(prefix=".livekit-verify-", dir=archive_path.parent) as temporary:
        root = safe_extract(archive_path, Path(temporary))
        verify_xcframework(root, official_mac_manifest)
        require(canonical_json(tree_manifest(root)) == manifest,
                "extracted per-entry manifest differs")


def package_artifact(device, simulator, mac, output):
    frameworks = dict(zip(SLICES, map(canonical_path, (device, simulator, mac))))
    output = canonical_path(output)
    require(output.parent.is_dir() and not output.exists(), "output already exists or parent is absent")
    require(all(not output.is_relative_to(path) and not path.is_relative_to(output)
                for path in frameworks.values()), "output overlaps an input")
    for name, framework in frameworks.items():
        validate_framework(framework, name)
    official = verify_official_mac(frameworks["macos-arm64_x86_64"])
    before = {name: tree_manifest(path) for name, path in frameworks.items()}
    output.mkdir(mode=0o700)  # Atomic exclusive reservation; never overwrite/reuse an output.
    root = output / f"{NAME}.xcframework"
    assemble_xcframework(frameworks, root, output / "assembly.log")
    verify_xcframework(root, official)
    require(all(tree_manifest(root / name / f"{NAME}.framework") == before[name]
                for name in frameworks), "assembled framework differs from built input")
    archive = output / f"{NAME}.xcframework.zip"
    manifest = canonical_json(deterministic_zip(root, archive))
    digest = sha256(archive)
    verify_archive(archive, manifest, official, digest)
    require(all(tree_manifest(path) == before[name] for name, path in frameworks.items()),
            "source framework changed during packaging")
    with (output / "ARTIFACT_MANIFEST.json").open("xb") as stream:
        stream.write(manifest)
    with (output / "SHA256SUMS").open("x") as stream:
        stream.write(f"{digest}  {archive.name}\n")
    with (output / "COMPLETE.json").open("xb") as stream:
        stream.write(canonical_json({"archiveSHA256": digest,
                    "manifestSHA256": hashlib.sha256(manifest).hexdigest(),
                    "officialMacManifestSHA256": OFFICIAL_MAC_MANIFEST_SHA256,
                    "xcodebuildSHA256": XCODEBUILD_SHA256,
                    "slices": sorted(SLICES)}))
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("package")
    for option in ("ios-device", "ios-simulator", "official-mac", "output"):
        package.add_argument(f"--{option}", type=Path, required=True)
    verify = commands.add_parser("verify")
    for option in ("archive", "manifest", "official-mac"):
        verify.add_argument(f"--{option}", type=Path, required=True)
    verify.add_argument("--sha256", required=True)
    args = parser.parse_args()
    if args.command == "package":
        print(package_artifact(args.ios_device, args.ios_simulator, args.official_mac, args.output))
    else:
        verify_archive(args.archive, canonical_path(args.manifest).read_bytes(),
                       verify_official_mac(args.official_mac), args.sha256)
        print("LiveKit artifact verified")


if __name__ == "__main__":
    main()
