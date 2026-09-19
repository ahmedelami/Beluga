"""Tiny packaging fixtures only: no native build, Xcode launch, audio or real SDK packaging."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import package_artifact as packaging


def macho(cpu, platform):
    name = b"@rpath/LiveKitWebRTC.framework/LiveKitWebRTC\0"
    length = (24 + len(name) + 7) // 8 * 8
    identity = struct.pack("<IIIIII", 0xD, length, 24, 0, 0, 0) + name
    identity += b"\0" * (length - len(identity))
    build = struct.pack("<IIIIII", 0x32, 24, platform, 0, 0, 0)
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 6, 2,
                         len(build) + len(identity), 0, 0)
    return header + build + identity


def framework(parent, architectures, platform, versioned=False):
    root = parent / "LiveKitWebRTC.framework"
    content = root / "Versions/A" if versioned else root
    content.mkdir(parents=True)
    (content / "Modules").mkdir()
    (content / "Headers").mkdir()
    (content / "Headers/LiveKitWebRTC.h").write_text("// fixture, not runnable SDK code\n")
    (content / "Modules/module.modulemap").write_text("framework module LiveKitWebRTC {}\n")
    slices = [macho(cpu, platform) for cpu in architectures]
    if len(slices) == 1:
        executable = slices[0]
    else:
        executable = struct.pack(">II", 0xCAFEBABE, len(slices))
        offset = 4096
        for cpu, data in zip(architectures, slices):
            executable += struct.pack(">IIIII", cpu, 0, offset, len(data), 12)
            offset += 4096
        for index, data in enumerate(slices):
            executable += b"\0" * ((index + 1) * 4096 - len(executable)) + data
    (content / "LiveKitWebRTC").write_bytes(executable)
    (content / "LiveKitWebRTC").chmod(0o755)
    resources = content / "Resources" if versioned else content
    resources.mkdir(exist_ok=True)
    info = {"CFBundleIdentifier": packaging.BUNDLE_ID,
            "CFBundleExecutable": packaging.NAME, "CFBundlePackageType": "FMWK"}
    (resources / "Info.plist").write_bytes(plistlib.dumps(info))
    if versioned:
        (root / "Versions/Current").symlink_to("A")
        os.chmod(root / "Versions/Current", 0o755, follow_symlinks=False)
        for name in ("Headers", "Modules", "Resources", "LiveKitWebRTC"):
            (root / name).symlink_to(f"Versions/Current/{name}")
            os.chmod(root / name, 0o755, follow_symlinks=False)
    return root


def fixture_assembler(frameworks, destination, log):
    destination.mkdir()
    libraries = []
    for identifier, source in frameworks.items():
        target = destination / identifier / source.name
        shutil.copytree(source, target, symlinks=True)
        platform, variant, architectures, _ = packaging.SLICES[identifier]
        item = {"LibraryIdentifier": identifier, "LibraryPath": source.name,
                "BinaryPath": "LiveKitWebRTC.framework/LiveKitWebRTC",
                "SupportedPlatform": platform,
                "SupportedArchitectures": sorted(architectures)}
        if variant:
            item["SupportedPlatformVariant"] = variant
        libraries.append(item)
    (destination / "Info.plist").write_bytes(plistlib.dumps({
        "AvailableLibraries": libraries, "CFBundlePackageType": "XFWK",
        "XCFrameworkFormatVersion": "1.0"}))
    log.write_text("Fixture assembler; Xcode was not launched.\n")


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="opensteamer-packager-fixture-",
                                                   dir="/Volumes/t7")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.device = framework(self.root / "device", [0x0100000C], 2)
        self.simulator = framework(self.root / "simulator", [0x0100000C], 7)
        self.mac = framework(self.root / "mac", [0x01000007, 0x0100000C], 1, True)
        self.mac_manifest = packaging.tree_manifest(self.mac)
        digest = hashlib.sha256(packaging.canonical_json(self.mac_manifest)).hexdigest()
        self.pin = patch.object(packaging, "OFFICIAL_MAC_MANIFEST_SHA256", digest)
        self.pin.start()
        self.addCleanup(self.pin.stop)
        self.assembler = patch.object(packaging, "assemble_xcframework", fixture_assembler)
        self.assembler.start()
        self.addCleanup(self.assembler.stop)

    def package(self, name="output"):
        return packaging.package_artifact(self.device, self.simulator, self.mac,
                                          self.root / name)

    def assembler_with_binary_path(self, identifier, binary_path):
        def assemble(frameworks, destination, log):
            fixture_assembler(frameworks, destination, log)
            plist = destination / "Info.plist"
            info = plistlib.loads(plist.read_bytes())
            for item in info["AvailableLibraries"]:
                if item["LibraryIdentifier"] == identifier:
                    item["BinaryPath"] = binary_path
            plist.write_bytes(plistlib.dumps(info))
        return assemble

    def test_observed_versioned_mac_binary_path_accepted(self):
        assembler = self.assembler_with_binary_path(
            "macos-arm64_x86_64", "LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")
        with patch.object(packaging, "assemble_xcframework", assembler):
            self.package()
        self.assertTrue((self.root / "output/COMPLETE.json").is_file())

    def test_wrong_mac_binary_versions_and_normalized_aliases_rejected(self):
        paths = ["LiveKitWebRTC.framework/Versions/B/LiveKitWebRTC",
                 "LiveKitWebRTC.framework/Versions/Current/LiveKitWebRTC",
                 "LiveKitWebRTC.framework/Versions/A/../A/LiveKitWebRTC"]
        for index, binary_path in enumerate(paths):
            with self.subTest(binary_path=binary_path):
                assembler = self.assembler_with_binary_path("macos-arm64_x86_64", binary_path)
                with patch.object(packaging, "assemble_xcframework", assembler):
                    with self.assertRaisesRegex(ValueError, "slice metadata"):
                        self.package(f"wrong-version-{index}")

    def test_versioned_ios_binary_paths_rejected(self):
        for identifier in ("ios-arm64", "ios-arm64-simulator"):
            with self.subTest(identifier=identifier):
                assembler = self.assembler_with_binary_path(
                    identifier, "LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")
                with patch.object(packaging, "assemble_xcframework", assembler):
                    with self.assertRaisesRegex(ValueError, "slice metadata"):
                        self.package(f"wrong-{identifier}")

    def test_escaping_and_absolute_binary_paths_rejected(self):
        for index, binary_path in enumerate(("../../LiveKitWebRTC",
                                            "/tmp/LiveKitWebRTC")):
            with self.subTest(binary_path=binary_path):
                assembler = self.assembler_with_binary_path("macos-arm64_x86_64", binary_path)
                with patch.object(packaging, "assemble_xcframework", assembler):
                    with self.assertRaisesRegex(ValueError, "slice metadata"):
                        self.package(f"escape-{index}")

    def test_allowed_mac_path_must_resolve_to_same_verified_executable(self):
        original = self.assembler_with_binary_path(
            "macos-arm64_x86_64", "LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")
        def different_executable(frameworks, destination, log):
            original(frameworks, destination, log)
            framework = destination / "macos-arm64_x86_64/LiveKitWebRTC.framework"
            shutil.copy2(framework / "Versions/A/LiveKitWebRTC",
                         framework / "Versions/A/OtherExecutable")
            (framework / "LiveKitWebRTC").unlink()
            (framework / "LiveKitWebRTC").symlink_to("Versions/A/OtherExecutable")
        with patch.object(packaging, "assemble_xcframework", different_executable):
            with self.assertRaisesRegex(ValueError, "verified framework executable"):
                self.package()

    def test_deterministic_zip_manifest_and_symlinks(self):
        first = self.package("one")
        second = self.package("two")
        self.assertEqual(first, second)
        self.assertEqual((self.root / "one/ARTIFACT_MANIFEST.json").read_bytes(),
                         (self.root / "two/ARTIFACT_MANIFEST.json").read_bytes())
        self.assertTrue((self.root / "one/COMPLETE.json").is_file())
        extraction = self.root / "extracted"
        extraction.mkdir()
        extracted = packaging.safe_extract(self.root / "one/LiveKitWebRTC.xcframework.zip",
                                            extraction)
        mac = extracted / "macos-arm64_x86_64/LiveKitWebRTC.framework"
        self.assertEqual(packaging.tree_manifest(mac), self.mac_manifest)
        self.assertEqual(sum(entry["kind"] == "symlink"
                             for entry in packaging.tree_manifest(mac)), 5)

    def test_missing_slice_rejected_without_output(self):
        with self.assertRaises((ValueError, FileNotFoundError)):
            packaging.package_artifact(self.device, self.root / "missing", self.mac,
                                        self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_symlink_modes_survive_private_extraction_umask(self):
        previous_mask = os.umask(0o077)
        try:
            self.package()
            extraction = self.root / "private-extracted"
            extraction.mkdir()
            extracted = packaging.safe_extract(
                self.root / "output/LiveKitWebRTC.xcframework.zip", extraction)
        finally:
            os.umask(previous_mask)
        mac = extracted / "macos-arm64_x86_64/LiveKitWebRTC.framework"
        manifest = packaging.tree_manifest(mac)
        self.assertEqual(manifest, self.mac_manifest)
        self.assertEqual([entry["mode"] for entry in manifest
                          if entry["kind"] == "symlink"], ["0755"] * 5)

    def test_symlink_mode_restoration_failure_is_not_bypassed(self):
        self.package()
        extraction = self.root / "unsupported-extracted"
        extraction.mkdir()
        real_chmod = os.chmod
        nofollow_attempts = []

        def reject_nofollow(path, mode, **kwargs):
            if kwargs.get("follow_symlinks") is False:
                nofollow_attempts.append(Path(path))
                raise NotImplementedError("fixture rejects symlink chmod")
            return real_chmod(path, mode, **kwargs)

        with patch.object(packaging.os, "chmod", side_effect=reject_nofollow):
            with self.assertRaisesRegex(NotImplementedError, "symlink chmod"):
                packaging.safe_extract(
                    self.root / "output/LiveKitWebRTC.xcframework.zip", extraction)
        self.assertEqual(len(nofollow_attempts), 1)
        self.assertTrue(nofollow_attempts[0].is_symlink())
        self.assertEqual(packaging.tree_manifest(self.mac), self.mac_manifest)

    def test_existing_output_is_never_overwritten(self):
        self.package()
        checksum = packaging.sha256(self.root / "output/LiveKitWebRTC.xcframework.zip")
        with self.assertRaises(ValueError):
            self.package()
        self.assertEqual(packaging.sha256(self.root / "output/LiveKitWebRTC.xcframework.zip"),
                         checksum)

    def test_wrong_platform_rejected_before_assembly(self):
        (self.simulator / "LiveKitWebRTC").write_bytes(macho(0x0100000C, 2))
        with self.assertRaisesRegex(ValueError, "platform"):
            self.package()
        self.assertFalse((self.root / "output").exists())

    def test_unsupported_simulator_architecture_rejected(self):
        (self.simulator / "LiveKitWebRTC").write_bytes(macho(0x01000007, 7))
        with self.assertRaisesRegex(ValueError, "architectures"):
            self.package()

    def test_changed_official_mac_rejected(self):
        (self.mac / "Versions/A/Headers/LiveKitWebRTC.h").write_text("changed")
        with self.assertRaisesRegex(ValueError, "official pinned bytes"):
            self.package()

    def test_escaping_input_symlink_rejected(self):
        (self.simulator / "escape").symlink_to("../..")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.package()

    def test_missing_assembled_slice_rejected(self):
        def incomplete(frameworks, destination, log):
            fixture_assembler(frameworks, destination, log)
            shutil.rmtree(destination / "ios-arm64-simulator")
        with patch.object(packaging, "assemble_xcframework", incomplete):
            with self.assertRaises((ValueError, FileNotFoundError)):
                self.package()
        self.assertFalse((self.root / "output/COMPLETE.json").exists())

    def test_source_mutation_during_assembly_rejected(self):
        def mutate(frameworks, destination, log):
            fixture_assembler(frameworks, destination, log)
            (self.device / "Headers/LiveKitWebRTC.h").write_text("changed after assembly")
        with patch.object(packaging, "assemble_xcframework", mutate):
            with self.assertRaisesRegex(ValueError, "source framework changed"):
                self.package()
        self.assertFalse((self.root / "output/COMPLETE.json").exists())

    def test_assembled_ios_mutation_rejected(self):
        def mutate_copy(frameworks, destination, log):
            fixture_assembler(frameworks, destination, log)
            (destination / "ios-arm64/LiveKitWebRTC.framework/Headers/LiveKitWebRTC.h").write_text(
                "different output with same framework identity")
        with patch.object(packaging, "assemble_xcframework", mutate_copy):
            with self.assertRaisesRegex(ValueError, "differs from built input"):
                self.package()
        self.assertFalse((self.root / "output/COMPLETE.json").exists())

    def test_zip_slip_rejected_before_extraction(self):
        archive = self.root / "unsafe.zip"
        with zipfile.ZipFile(archive, "x") as writer:
            info = zipfile.ZipInfo("../escaped")
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            writer.writestr(info, b"bad")
        destination = self.root / "extract"
        destination.mkdir()
        with self.assertRaisesRegex(ValueError, "unsafe"):
            packaging.safe_extract(archive, destination)
        self.assertEqual(list(destination.iterdir()), [])
        self.assertFalse((self.root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()
