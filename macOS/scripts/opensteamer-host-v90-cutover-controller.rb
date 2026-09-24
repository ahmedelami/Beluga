#!/usr/bin/ruby
# frozen_string_literal: true

# One-shot V90 host cutover controller.
#
# Preflight and self-test are observation-only. Execute is deliberately separate and accepts only
# a fresh, sealed capsule plus two independently transported SHA-256 digests. All predecessor and
# live-session expectations are compiled below; callers cannot substitute them on the command line.

require "digest"
require "fiddle/import"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "rexml/document"
require "securerandom"
require "shellwords"
require "tempfile"
require "tmpdir"

module OpenSteamerV90Cutover
  class Failure < StandardError; end
  class CommittedButUnverified < Failure; end
  class JournalPersistenceUnverified < Failure; end

  module DarwinRename
    extend Fiddle::Importer
    dlload Fiddle.dlopen(nil)
    extern "int renamex_np(const char *, const char *, unsigned int)"
  end

  module Pins
    extend self

    SOURCE_BRANCH = "fix/ios-metal-watchdog-testflight-83"
    SOURCE_UPSTREAM = "origin/fix/ios-metal-watchdog-testflight-83"
    SOURCE_COMMIT = "229eabc22b9990891c5e5b2a5cfa27111f0a6b3e"
    SOURCE_TREE = "0192ef02be478f094afe1f66b50fe3b14717d0ea"
    TOOLING_ROOT = "/Volumes/t7/beluga-ios-metal-watchdog-release-83"
    TOOLING_REMOTE_URL = "https://github.com/ahmedelami/opensteamer.git"
    TOOLING_FILES = {
      "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh" => 0o755,
      "macOS/scripts/opensteamer-host-v90-cutover-controller.rb" => 0o644,
      "macOS/scripts/opensteamer-v90-coreaudio-route-monitor.swift" => 0o644,
      "macOS/scripts/run-opensteamer-host-v90-cutover.sh" => 0o755
    }.freeze

    TEAM_ID = "MSMG8CJLB3"
    EXECUTABLE_IDENTIFIER = "com.elamin.AudioStreamer.CaptureServer"
    FRAMEWORK_IDENTIFIER = "io.livekit.LiveKitWebRTC"
    V86_CDHASH = "e41c23322912104a648e791bfb0d3a5714323b26"
    V86_DESIGNATED_REQUIREMENT = 'identifier "com.elamin.AudioStreamer.CaptureServer" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Ahmed Elamin (92LVX32M8K)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
    APPROVED_PREDECESSOR_REFERENCE_SHA256 = "553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66"
    APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE = 11_442_304
    APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_OFFSET = 11_401_072
    APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_SIZE = 41_232
    APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256 = "a7885a8d1ffef70f5a747eaed984a6cb70fe382491fcc6fbf8505aa0ad47ff5b"
    APPROVED_PREDECESSOR_REFERENCE_CDHASH = V86_CDHASH
    APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256 = "e41c23322912104a648e791bfb0d3a5714323b26b1b299ae5f0cfa225f68aba0"
    APPROVED_PREDECESSOR_REFERENCE_TEAM_ID = TEAM_ID
    APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER = EXECUTABLE_IDENTIFIER
    APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT = V86_DESIGNATED_REQUIREMENT
    LIVE_APP = "/Applications/opensteamer Host.app"
    LIVE_EXECUTABLE = "#{LIVE_APP}/Contents/MacOS/CaptureServer"
    LIVE_FRAMEWORK_IDENTITY_PATH = "#{LIVE_APP}/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
    LIVE_FRAMEWORK = "#{LIVE_APP}/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC"
    LIVE_INFO_PLIST = "#{LIVE_APP}/Contents/Info.plist"
    LIVE_V86_IDENTITIES = {
      LIVE_APP => [16_777_232, 35_118_780],
      LIVE_EXECUTABLE => [16_777_232, 35_118_785],
      LIVE_FRAMEWORK => [16_777_232, 35_118_799],
      LIVE_INFO_PLIST => [16_777_232, 35_118_916]
    }.freeze
    LAUNCH_LABEL = "gui/501/org.example.opensteamer.worldwide"
    LAUNCH_AGENT = "/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist"
    LAUNCH_AGENT_SHA256 = "e8242cfa600bb5e62695cd954bcf59ce76a3884c5d4394accef4215ec642ee7a"
    LAUNCH_AGENT_V86_IDENTITY = [16_777_232, 35_118_917].freeze
    LAUNCH_ARGUMENTS = [
      LIVE_EXECUTABLE,
      "--worldwide",
      "--allow-remote-control",
      "--virtual-phone-display",
      "--secondary-test-viewer",
      "--duration",
      "0",
      "--verbose",
      "--rendezvous-url",
      "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev"
    ].freeze
    LAUNCH_ENVIRONMENT = { "OSLogRateLimit" => "64" }.freeze
    LAUNCH_STDOUT = "/var/tmp/opensteamer-worldwide-host.log"
    LAUNCH_STDERR = "/var/tmp/opensteamer-worldwide-host.err.log"

    # Exact committed V86 bytes and signature identity currently restored by the V89 rollback.
    V86_EXECUTABLE_SHA256 = "b6d51fce0a9d2169d2ee28749210a3faee6f1f7360063060c97b11c298e63d5b"
    V86_FRAMEWORK_SHA256 = "d0b2075bd97686dd65749665b4c32ec27ca242347cd99df2b53255901aa5036a"
    V86_INFO_PLIST_SHA256 = "9c6568c97ef11321edc1cc53a5fc070c491ea713a872fb6b119f777ce34e8b55"
    V86_SOURCE_COMMIT = "2321b65806b9d30554c2382d699dd89d9feebac5"
    V86_SOURCE_TREE = "d60e2a71f66fe92399e491bca2773981bcbec62f"

    RUNTIME_ROOT = "/Users/ahmed/Library/Application Support/opensteamer"
    V90_UPDATE_ROOT = "#{RUNTIME_ROOT}/paired-host-updates-v90"
    V90_PENDING_POINTER = "#{RUNTIME_ROOT}/pending-paired-host-update-v90"
    V90_ACTIVE_POINTER = "#{RUNTIME_ROOT}/active-paired-host-update-v90"
    V90_LOCK = "#{RUNTIME_ROOT}/paired-host-update-v90.lock"
    V90_JOURNAL_HEADER = "OPENSTEAMER_PAIRED_HOST_UPDATE_V90"

    ROUTE_MONITOR_SOURCE = File.expand_path("opensteamer-v90-coreaudio-route-monitor.swift", __dir__)
    ROUTE_MONITOR_SOURCE_SHA256 = "4a788f63122b84a51b3009a544cda62589664ba51fd5a6bc1658381fdc28e36d"
    SWIFTC = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    SWIFTC_LINK_TARGET = "swift-frontend"
    SWIFTC_SHA256 = "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb"
    SWIFTC_IDENTITY = [16_777_240, 15_755_469].freeze
    MACOS_SDK = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
    MACOS_SDK_LINK_TARGET = "MacOSX.sdk"
    MACOS_SDK_IDENTITY = [16_777_240, 15_672_618].freeze
    MACOS_SDK_SETTINGS_SHA256 = "f8d005f09381389167f9e0aeaa169bc9e7dff162ef22ca2fd8e98df7ff1acafe"
    ROUTE_MONITOR_READY = "READY input=BlackHole2ch_UID output=BuiltInSpeakerDevice system=BuiltInSpeakerDevice"
    ROUTE_MONITOR_RESULT = "RESULT notifications=0 teardown=clean input=BlackHole2ch_UID output=BuiltInSpeakerDevice system=BuiltInSpeakerDevice"
    LAUNCHER_ATTESTATION = "opensteamer-v90-pinned-launcher-v1"

    V89_POINTER = "#{RUNTIME_ROOT}/active-paired-host-update-v89"
    V89_POINTER_SHA256 = "5c2c7b0d60de0682d208e399a68ffd81cf46cdfd3a10d1774f7f39d8eb550111"
    V89_EVIDENCE = "#{RUNTIME_ROOT}/paired-host-updates-v89/paired-v89-rollback-1790170925-fc6fdfc5-5ffc-4dc0-8f19-44461f5577aa"
    V89_EVIDENCE_IDENTITY = [16_777_232, 35_118_775].freeze
    V89_JOURNAL_SHA256 = "9a1b8ca4968184e7d2858e297b112669c93760342b00ba02fadf0b25f844920b"
    V89_RESULT_SHA256 = "175c22b0701cc9c3cbd6cc8f0bf2b4f76f2da86f3e57bfc449248232f2d0f051"
    V89_TERMINAL = "2026-09-23T14:01:43Z STATE COMMITTED_EXACT_V86"
    V89_RESULT = <<~RESULT.freeze
      result=success
      pid=94637
      nonce=b12cbe392896f7511bd1b9221a59738b6e6b5e0b1137f970cb1f2049cb804b04
      target=exact-v86
      selected=1080x1920@1080x1920 60.00Hz
    RESULT

    V86_POINTER = "#{RUNTIME_ROOT}/active-paired-host-update-v86"
    V86_POINTER_SHA256 = "c6a6692f3010a27000c5e00076180c785826051c4935ee6c1909a27f8bef95a0"
    V86_EVIDENCE = "#{RUNTIME_ROOT}/paired-host-updates-v86/paired-v86-update-1789870013-15b50a46-6dbb-4cbc-b10a-0a571a36930d"
    V86_EVIDENCE_IDENTITY = [16_777_232, 34_295_052].freeze
    V86_JOURNAL_SHA256 = "3c23e10b914cbd040f11882bb6544386f3c09b5b51e0ad97716d6375853bcc7d"
    V86_RESULT_SHA256 = "787f211adcd87b522bc8c1b4608ceae0f38e7cb2b4d469658cb081147e3c5557"
    V86_PROVENANCE_SHA256 = "ff368577a21d88637b7d6b3df4faea3bbf0fc33fc9cac0ef8c895cb6d60f47c8"
    V86_APP_MANIFEST_SHA256 = "ef345a8e610242cb9d00c4e7ab4b877fff4eb759389803f4f323330ef9576132"
    V86_ROUTE_SHA256 = "d449ef1af733211f3de839229c8993d1431a277a0e3efcff300ed7a8a8e47f02"
    V86_TERMINAL = "STATE COMMITTED"

    LIVE_PID = 94_637
    LIVE_PROCESS_START = "Wed Sep 23 10:01:33 2026"
    LIVE_NONCE = "b12cbe392896f7511bd1b9221a59738b6e6b5e0b1137f970cb1f2049cb804b04"
    LIVE_LOCK = <<~LOCK.freeze
      OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1
      pid=94637
      nonce=b12cbe392896f7511bd1b9221a59738b6e6b5e0b1137f970cb1f2049cb804b04
    LOCK
    LIVE_LOCK_PATH = "/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock"
    LIVE_LOCK_DIRECTORY_IDENTITY = [16_777_232, 10_835_207].freeze
    LIVE_LOCK_IDENTITY = [16_777_232, 10_835_208].freeze
    LIVE_DISPLAY_MODE = "1080x1920@1080x1920 60.00Hz"
    ROUTES = {
      "output" => '{"name": "Mac mini Speakers", "type": "output", "id": "102", "uid": "BuiltInSpeakerDevice"}',
      "system" => '{"name": "Mac mini Speakers", "type": "system", "id": "102", "uid": "BuiltInSpeakerDevice"}',
      "input" => '{"name": "BlackHole 2ch", "type": "input", "id": "61", "uid": "BlackHole2ch_UID"}'
    }.freeze

    V86_HELPERS = {
      "SwitchAudioSource" => "9a29148a58b91c6ac13281b3cc1915922bdadd00ab09b3267271e5925d52fb64",
      "controller" => "0beb8e96aabd059ee5f108dfd05d7d5d99fa52b58f56ab942a31ee8efd33f528",
      "probe-worldwide-lock-v23" => "602c4578dcaec75629126d799056591dd0cea80c2f1ccaae5d91b0c341867e4f",
      "select-live-display-mode-v23" => "ee67b4797787098ea1073e4b579355366f534d865ff233a8b780ec5552c8f2a3",
      "verify-live-display-topology-v23" => "1502e07358f2316f4dee1fb12ce380cc5e9588cd6393ea3f34656ab80e9db292",
      "verify-live-mac-host-process.sh" => "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41",
      "verify-media-v1-host-bundle.sh" => "e8a486a8e7360e5d3c8517e237e046fc21b3ccc2a3eb5e14ccd5d40135742e0c"
    }.freeze

    PAYLOAD_SCHEMA = "opensteamer.v90-deployment-payload-manifest.v2"
    CAPSULE_SCHEMA = "opensteamer.v90-host-oracle-capsule-metadata.v1"
    HANDOFF_SCHEMA = "opensteamer.v90-screen-oracle-host-identity-handoff.v1"
    IDENTITY_SCHEMA = "opensteamer.sealed-live-mac-host-identity.v1"

    PAYLOAD_KEYS = %w[
      schema sourceCommit sourceTree sourceBranch sourceUpstream sourceExportRelativePath
      sourceTreeManifestRelativePath sourceTreeManifestSHA256 candidateAppRelativePath
      candidateAppTreeManifestRelativePath candidateAppTreeManifestSHA256
      candidateExecutableRelativePath candidateExecutableSHA256
      candidateMediaFrameworkExecutableRelativePath candidateMediaFrameworkExecutableSHA256
      candidateInfoPlistRelativePath candidateInfoPlistSHA256 candidateLaunchPlistRelativePath
      candidateLaunchPlistSHA256 capsuleMetadataRelativePath capsuleMetadataSHA256
      handoffRelativePath handoffSHA256 hostIdentityManifestRelativePath
      hostIdentityManifestSHA256 designatedRequirementReferenceRelativePath
      designatedRequirementReferenceSHA256 candidateAppCopyManifestRelativePath
      designatedRequirementReferenceFileSize
      designatedRequirementReferenceCodeSignatureDataOffset
      designatedRequirementReferenceCodeSignatureDataSize
      designatedRequirementReferenceUnsignedPrefixSHA256
      designatedRequirementReferenceCDHash designatedRequirementReferenceCodeDirectorySHA256
      designatedRequirementReferenceTeamIdentifier designatedRequirementReferenceIdentifier
      designatedRequirementReferenceDesignatedRequirement
      candidateAppCopyManifestSHA256 toolingBranch toolingUpstream toolingCommit toolingTree
      toolingRemoteURL assemblerScriptRelativePath assemblerScriptGitBlob
    ].freeze
    CAPSULE_KEYS = %w[
      schema candidateAppRelativePath candidateExecutableSHA256
      candidateMediaFrameworkExecutableSHA256 designatedRequirementReferenceRelativePath
      designatedRequirementReferenceSHA256
    ].freeze
    HANDOFF_KEYS = %w[
      schema capsuleMetadataSHA256 candidateAppRelativePath candidateExecutableSHA256
      candidateMediaFrameworkExecutableSHA256 designatedRequirementReferenceRelativePath
      designatedRequirementReferenceSHA256 expectedTeamIdentifier hostIdentityManifestBasename
      hostIdentityManifestSHA256 hostIdentityManifestSHA256Basename
    ].freeze
    IDENTITY_KEYS = %w[
      schema executablePath executableSHA256 executableCDHash executableIdentifier
      executableTeamIdentifier mediaFrameworkExecutablePath mediaFrameworkExecutableSHA256
      mediaFrameworkExecutableCDHash mediaFrameworkExecutableIdentifier
      mediaFrameworkExecutableTeamIdentifier
    ].freeze

    ALLOWED_CANDIDATE_SYMLINKS = {
      "Contents/Frameworks/LiveKitWebRTC.framework/Headers" => "Versions/Current/Headers",
      "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" => "Versions/Current/LiveKitWebRTC",
      "Contents/Frameworks/LiveKitWebRTC.framework/Modules" => "Versions/Current/Modules",
      "Contents/Frameworks/LiveKitWebRTC.framework/Resources" => "Versions/Current/Resources",
      "Contents/Frameworks/LiveKitWebRTC.framework/Versions/Current" => "A"
    }.freeze
  end

  module Util
    extend self

    SHA256 = /\A[0-9a-f]{64}\z/.freeze
    RELATIVE = /\A[^\x00-\x1f\x7f]+\z/.freeze

    class DuplicateRejectingHash < Hash
      def []=(key, value)
        raise Failure, "JSON contains duplicate key #{key.inspect}" if key?(key)
        super
      end
    end

    def fail!(message)
      raise Failure, message
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    rescue SystemCallError => error
      fail!("could not hash #{path}: #{error.message}")
    end

    def sha256_text(text)
      Digest::SHA256.hexdigest(text.b)
    end

    def exact_prefixed_values(text, prefix)
      binary_prefix = prefix.b
      text.b.lines.map do |line|
        stripped = line.strip
        stripped.delete_prefix(binary_prefix) if stripped.start_with?(binary_prefix)
      end.compact
    end

    def assert_sha!(value, label)
      fail!("#{label} is not a lowercase SHA-256") unless SHA256.match?(value.to_s)
    end

    def strict_json(path, keys, schema)
      text = File.binread(path)
      object = JSON.parse(text, object_class: DuplicateRejectingHash, array_class: Array)
      fail!("#{path} is not a flat JSON object") unless object.is_a?(Hash)
      fail!("#{path} fields differ from strict schema") unless object.keys.sort == keys.sort
      fail!("#{path} contains non-string values") unless object.values.all? { |value| value.is_a?(String) }
      fail!("#{path} has wrong schema") unless object.fetch("schema") == schema
      object
    rescue JSON::ParserError => error
      fail!("#{path} is not strict JSON: #{error.message}")
    end

    def relative_path!(value, label)
      candidate = value.to_s
      clean = Pathname.new(candidate).cleanpath.to_s
      fail!("#{label} is not a normalized relative path") unless
        RELATIVE.match?(candidate) && !candidate.start_with?("/") && clean == candidate &&
        candidate != "." && !candidate.end_with?("/") && !candidate.include?("//")
      candidate
    end

    def inside(root, relative, label)
      relative_path!(relative, label)
      joined = File.join(root, relative)
      expanded = File.expand_path(joined)
      fail!("#{label} escapes capsule") unless expanded.start_with?(root + File::SEPARATOR)
      joined
    end

    def regular_file!(path, label, mode: nil, owner: nil, links: 1)
      stat = File.lstat(path)
      fail!("#{label} is not a regular non-symlink file") unless stat.file?
      fail!("#{label} has wrong owner") if owner && stat.uid != owner
      fail!("#{label} has wrong mode") if mode && (stat.mode & 0o7777) != mode
      fail!("#{label} has wrong hard-link count") if links && stat.nlink != links
      clean_node_metadata!(path, label)
      stat
    rescue Errno::ENOENT
      fail!("#{label} is missing")
    end

    def directory!(path, label, mode: nil, owner: nil)
      stat = File.lstat(path)
      fail!("#{label} is not a real directory") unless stat.directory?
      fail!("#{label} has wrong owner") if owner && stat.uid != owner
      fail!("#{label} has wrong mode") if mode && (stat.mode & 0o7777) != mode
      clean_node_metadata!(path, label)
      stat
    rescue Errno::ENOENT
      fail!("#{label} is missing")
    end

    def exact_file!(path, expected_sha, label, **metadata)
      regular_file!(path, label, **metadata)
      assert_sha!(expected_sha, "#{label} expected digest")
      fail!("#{label} digest mismatch") unless sha256(path) == expected_sha
    end

    def bsd_flags(path, label)
      value = capture!("/usr/bin/stat", "-f", "%f", path).strip
      Integer(value, 10)
    rescue ArgumentError
      fail!("#{label} BSD flags are malformed")
    end

    def clean_node_metadata!(path, label)
      listing = capture!("/bin/ls", "-lde", path).lines.first.to_s
      fail!("#{label} has an ACL") if listing.split.first.to_s.include?("+")
      stdout, stderr, status = Open3.capture3("/usr/bin/xattr", path)
      fail!("could not inspect #{label} xattrs: #{stderr.strip}") unless status.success?
      fail!("#{label} has extended attributes") unless stdout.empty?
      fail!("#{label} has nonzero BSD flags") unless bsd_flags(path, label).zero?
      true
    end

    def sidecar!(committed, sidecar, expected, label)
      exact_file!(committed, expected, label, mode: 0o600, owner: Process.euid)
      regular_file!(sidecar, "#{label} sidecar", mode: 0o600, owner: Process.euid)
      fail!("#{label} sidecar is not canonical") unless File.binread(sidecar) == "#{expected}\n"
    end

    def capture!(*command, stdin_data: nil)
      stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin_data)
      fail!("command failed: #{command.shelljoin}: #{stderr.strip}") unless status.success?
      stdout
    end

    def canonical_absolute!(path, label)
      fail!("#{label} is not canonical absolute path") unless
        path.start_with?("/") && File.expand_path(path) == path && File.realpath(path) == path
      path
    rescue Errno::ENOENT
      fail!("#{label} is missing")
    end
  end

  # The retained predecessor is copied out of its original app bundle before cutover. A standalone
  # copy is intentionally not treated as full-bundle resource proof because its Info.plist and
  # sealed resources remain behind. Revalidate the copied code object without weakening its
  # identity: exact bytes, unsigned Mach-O prefix, embedded signature extent, CodeDirectory digest,
  # TeamIdentifier, identifier, and designated requirement are all independently pinned.
  module PredecessorReferenceFingerprint
    extend self

    MACH_HEADER_64_SIZE = 32
    MH_MAGIC_64 = 0xfeedfacf
    CPU_TYPE_ARM64 = 0x0100000c
    LC_CODE_SIGNATURE = 0x1d

    def verify!(path, label: "capsule predecessor reference")
      stat, data = read_snapshot(path, label)
      Util.fail!("#{label} size differs from approved predecessor") unless
        stat.size == Pins::APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE
      Util.fail!("#{label} full-file digest differs from approved predecessor") unless
        Digest::SHA256.hexdigest(data) == Pins::APPROVED_PREDECESSOR_REFERENCE_SHA256

      data_offset, data_size = signature_layout(data)
      Util.fail!("#{label} LC_CODE_SIGNATURE layout differs from approved predecessor") unless
        data_offset == Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_OFFSET &&
        data_size == Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_SIZE &&
        data_offset + data_size == data.bytesize
      prefix = data.byteslice(0, data_offset)
      Util.fail!("#{label} unsigned-prefix digest differs from approved predecessor") unless
        prefix && Digest::SHA256.hexdigest(prefix) == Pins::APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256

      metadata = combined_codesign!("--display", "--verbose=6", path)
      exact_field!(metadata, "Identifier=", Pins::APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER, label)
      exact_field!(metadata, "TeamIdentifier=", Pins::APPROVED_PREDECESSOR_REFERENCE_TEAM_ID, label)
      exact_field!(metadata, "CDHash=", Pins::APPROVED_PREDECESSOR_REFERENCE_CDHASH, label)
      exact_field!(
        metadata,
        "CandidateCDHashFull sha256=",
        Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256,
        label
      )

      requirements = combined_codesign!("--display", "--requirements", "-", path)
      designated = requirements.lines.map { |line| line.strip.sub(/\A# /, "") }
                               .select { |line| line.start_with?("designated => ") }
      expected = "designated => #{Pins::APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT}"
      Util.fail!("#{label} designated requirement differs from approved predecessor") unless
        designated == [expected]
      final_stat, final_data = read_snapshot(path, label)
      Util.fail!("#{label} identity or bytes changed during fingerprint verification") unless
        [final_stat.dev, final_stat.ino, final_stat.size] == [stat.dev, stat.ino, stat.size] &&
        Digest::SHA256.hexdigest(final_data) == Pins::APPROVED_PREDECESSOR_REFERENCE_SHA256
      true
    rescue Errno::ENOENT, Errno::EACCES => error
      Util.fail!("could not fingerprint #{label}: #{error.message}")
    end

    def signature_layout(data)
      Util.fail!("predecessor reference is too short for a Mach-O header") if
        data.bytesize < MACH_HEADER_64_SIZE
      magic, cpu_type, _cpu_subtype, _file_type, command_count, commands_size,
        _flags, _reserved = data.byteslice(0, MACH_HEADER_64_SIZE).unpack("V8")
      Util.fail!("predecessor reference is not a thin 64-bit Mach-O") unless magic == MH_MAGIC_64
      Util.fail!("predecessor reference is not arm64") unless cpu_type == CPU_TYPE_ARM64
      command_end = MACH_HEADER_64_SIZE + commands_size
      Util.fail!("predecessor reference load-command extent is invalid") if
        command_end > data.bytesize || command_count.zero?

      cursor = MACH_HEADER_64_SIZE
      signatures = []
      command_count.times do
        Util.fail!("predecessor reference has a truncated load command") if cursor + 8 > command_end
        command, command_size = data.byteslice(cursor, 8).unpack("V2")
        Util.fail!("predecessor reference has an invalid load-command size") if
          command_size < 8 || (command_size % 8) != 0 || cursor + command_size > command_end
        if command == LC_CODE_SIGNATURE
          Util.fail!("predecessor LC_CODE_SIGNATURE has an invalid size") unless command_size == 16
          signatures << data.byteslice(cursor + 8, 8).unpack("V2")
        end
        cursor += command_size
      end
      Util.fail!("predecessor reference load-command count/size mismatch") unless cursor == command_end
      Util.fail!("predecessor reference must contain exactly one LC_CODE_SIGNATURE") unless
        signatures.length == 1
      signatures.fetch(0)
    end

    private

    def read_snapshot(path, label)
      before = Util.regular_file!(path, label, mode: 0o755, owner: Process.euid, links: 1)
      opened = nil
      data = nil
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        Util.fail!("#{label} changed while opening") unless
          opened.file? &&
          [opened.dev, opened.ino, opened.size, opened.nlink] ==
            [before.dev, before.ino, before.size, 1]
        data = file.read
        Util.fail!("#{label} short read") unless data.bytesize == opened.size
      end
      after = File.lstat(path)
      Util.fail!("#{label} changed while reading") unless
        after.file? && [after.dev, after.ino, after.size, after.nlink] ==
          [opened.dev, opened.ino, opened.size, 1]
      [opened, data]
    end

    def combined_codesign!(*arguments)
      stdout, stderr, status = Open3.capture3("/usr/bin/codesign", *arguments)
      Util.fail!("codesign metadata inspection failed: #{stderr.strip}") unless status.success?
      stdout.b + stderr.b
    end

    def exact_field!(metadata, prefix, expected, label)
      values = Util.exact_prefixed_values(metadata, prefix)
      Util.fail!("#{label} #{prefix.delete_suffix('=')} differs from approved predecessor") unless
        values == [expected]
    end
  end

  # Live invocations are accepted only from the canonical clean worktree whose HEAD is the
  # single fresh remote branch tip. Each runtime tool must be byte-identical to its tracked HEAD
  # blob. This proof is intentionally repeated during the final capsule replay before STOP_INTENT.
  module ToolingProof
    extend self

    def verify!
      root = Pins::TOOLING_ROOT
      Util.fail!("tooling root is not canonical") unless
        File.expand_path(root) == root && File.realpath(root) == root
      Util.directory!(root, "V90 tooling root", mode: 0o755, owner: Process.euid)

      branch = git!("symbolic-ref", "--short", "HEAD").strip
      upstream = git!("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}").strip
      Util.fail!("tooling branch differs from pinned V90 branch") unless branch == Pins::SOURCE_BRANCH
      Util.fail!("tooling upstream differs from pinned V90 upstream") unless upstream == Pins::SOURCE_UPSTREAM

      fetch_urls = git!("remote", "get-url", "--all", "origin").lines.map(&:chomp)
      push_urls = git!("remote", "get-url", "--push", "--all", "origin").lines.map(&:chomp)
      Util.fail!("tooling origin fetch URL differs") unless fetch_urls == [Pins::TOOLING_REMOTE_URL]
      Util.fail!("tooling origin push URL differs") unless push_urls == [Pins::TOOLING_REMOTE_URL]

      head = git!("rev-parse", "HEAD").strip
      tree = git!("rev-parse", "HEAD^{tree}").strip
      upstream_head = git!("rev-parse", "@{u}").strip
      [head, tree, upstream_head].each do |object_id|
        Util.fail!("tooling Git identity is malformed") unless object_id.match?(/\A[0-9a-f]{40}\z/)
      end
      Util.fail!("tooling HEAD differs from local upstream") unless head == upstream_head
      Util.fail!("tooling worktree is not clean") unless
        git!("status", "--porcelain=v1", "--untracked-files=all").empty?

      remote = git!("ls-remote", "--exit-code", "--refs", "--heads", "origin", "refs/heads/#{branch}")
      Util.fail!("tooling remote branch lookup is not a single exact record") unless
        remote.lines.map(&:chomp) == ["#{head}\trefs/heads/#{branch}"]

      blobs = {}
      Pins::TOOLING_FILES.each do |relative, mode|
        path = File.join(root, relative)
        Util.fail!("tooling file path is not canonical: #{relative}") unless File.realpath(path) == path
        Util.regular_file!(
          path,
          "tracked V90 tooling file #{relative}",
          mode: mode,
          owner: Process.euid,
          links: 1
        )
        tracked = git!("ls-files", "--error-unmatch", "--", relative).lines.map(&:chomp)
        Util.fail!("V90 tooling file is not uniquely tracked: #{relative}") unless tracked == [relative]
        working_blob = git!("hash-object", "--no-filters", "--", relative).strip
        head_blob = git!("rev-parse", "HEAD:#{relative}").strip
        Util.fail!("V90 tooling blob identity is malformed: #{relative}") unless
          working_blob.match?(/\A[0-9a-f]{40}\z/) && head_blob.match?(/\A[0-9a-f]{40}\z/)
        Util.fail!("V90 tooling bytes differ from tracked HEAD: #{relative}") unless working_blob == head_blob
        blobs[relative] = head_blob
      end

      {
        commit: head,
        tree: tree,
        launcher_blob: blobs.fetch("macOS/scripts/run-opensteamer-host-v90-cutover.sh"),
        assembler_blob: blobs.fetch("macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh")
      }
    rescue Errno::ENOENT
      Util.fail!("canonical V90 tooling path is missing")
    end

    def verify_launcher_environment!(proof)
      expected = {
        "OPENSTEAMER_V90_LAUNCHER_ATTESTATION" => Pins::LAUNCHER_ATTESTATION,
        "OPENSTEAMER_V90_LAUNCHER_PATH" => File.join(
          Pins::TOOLING_ROOT,
          "macOS/scripts/run-opensteamer-host-v90-cutover.sh"
        ),
        "OPENSTEAMER_V90_TOOLING_COMMIT" => proof.fetch(:commit),
        "OPENSTEAMER_V90_TOOLING_TREE" => proof.fetch(:tree),
        "OPENSTEAMER_V90_LAUNCHER_BLOB" => proof.fetch(:launcher_blob),
        "OPENSTEAMER_V90_ASSEMBLER_BLOB" => proof.fetch(:assembler_blob)
      }
      expected.each do |key, value|
        Util.fail!("live V90 launcher attestation mismatch: #{key}") unless ENV[key] == value
      end
      true
    end

    private

    def git!(*arguments)
      Util.capture!("/usr/bin/git", "-C", Pins::TOOLING_ROOT, *arguments)
    end
  end

  class TreeManifest
    include Util

    def initialize(root, kind)
      @root = root
      @kind = kind
    end

    def verify!(manifest_path)
      expected = File.binread(manifest_path)
      actual, symlinks = render
      Util.fail!("#{@kind} tree manifest does not exactly match filesystem") unless actual == expected
      if @kind == :candidate
        Util.fail!("candidate aliases differ from reviewed five-link set") unless symlinks == Pins::ALLOWED_CANDIDATE_SYMLINKS
      else
        Util.fail!("source export contains a symbolic link") unless symlinks.empty?
      end
      true
    end

    def render
      Util.directory!(@root, "#{@kind} tree root")
      entries = []
      enumerate(@root, "", entries)
      Util.fail!("#{@kind} tree is empty") if entries.empty?
      symlinks = {}
      records = entries.sort_by { |relative, _| relative.b }.map do |relative, path|
        Util.relative_path!(relative, "#{@kind} tree entry")
        stat = File.lstat(path)
        assert_clean_metadata!(path, relative)
        flags = Util.bsd_flags(path, "#{@kind} tree entry #{relative}")
        Util.fail!("unsafe BSD flags in #{@kind} tree: #{relative}") unless flags.zero?
        metadata = format("%04o:%d:%d:%d:%d:%d", stat.mode & 0o7777, stat.uid, stat.gid, stat.nlink, stat.size, flags)
        if stat.symlink?
          target = File.readlink(path)
          Util.fail!("unsafe symlink target") if target.empty? || target.match?(/[\x00-\x1f\x7f]/)
          Util.fail!("hard-linked symbolic link in candidate tree") unless stat.nlink == 1
          symlinks[relative] = target
          assert_reviewed_alias_resolution!(relative, path, target)
          "L\t#{metadata}\t#{Util.sha256_text(target)}\t#{target}\t#{relative}\n"
        elsif stat.file?
          Util.fail!("hard-linked file in #{@kind} tree") unless stat.nlink == 1
          "F\t#{metadata}\t#{Util.sha256(path)}\t#{relative}\n"
        elsif stat.directory?
          "D\t#{metadata}\t#{relative}\n"
        else
          Util.fail!("unsupported file type in #{@kind} tree: #{relative}")
        end
      end
      [records.join, symlinks]
    end

    private

    def enumerate(directory, prefix, entries)
      Dir.children(directory).each do |name|
        Util.fail!("unsafe tree name") if name.match?(/[\x00-\x1f\x7f]/)
        relative = prefix.empty? ? name : File.join(prefix, name)
        path = File.join(directory, name)
        stat = File.lstat(path)
        entries << [relative, path]
        enumerate(path, relative, entries) if stat.directory?
      end
    end

    def assert_clean_metadata!(path, relative)
      listing = Util.capture!("/bin/ls", "-lde", path).lines.first.to_s
      Util.fail!("ACL in #{@kind} tree: #{relative}") if listing.split.first.to_s.include?("+")
      command = ["/usr/bin/xattr"]
      command << "-s" if File.lstat(path).symlink?
      stdout, stderr, status = Open3.capture3(*command, path)
      Util.fail!("could not inspect xattrs for #{relative}: #{stderr.strip}") unless status.success?
      Util.fail!("xattrs in #{@kind} tree: #{relative}") unless stdout.empty?
    end

    def assert_reviewed_alias_resolution!(relative, path, target)
      return unless @kind == :candidate
      Util.fail!("candidate tree has unreviewed symlink") unless Pins::ALLOWED_CANDIDATE_SYMLINKS[relative] == target
      resolved = File.realpath(File.join(File.dirname(path), target))
      Util.fail!("candidate alias escapes app") unless resolved.start_with?(File.realpath(@root) + "/")
      if relative == "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        Util.fail!("candidate framework alias is not executable code") unless File.file?(resolved) && File.executable?(resolved)
      else
        Util.fail!("candidate framework alias is not a directory") unless File.directory?(resolved)
      end
    rescue Errno::ENOENT
      Util.fail!("candidate alias is dangling: #{relative}")
    end
  end

  class CopyManifest
    def initialize(root)
      @root = root
    end

    def verify!(manifest_path)
      expected = File.binread(manifest_path)
      actual, aliases = render
      Util.fail!("candidate copy-stable manifest mismatch") unless actual == expected
      Util.fail!("candidate copy aliases differ from reviewed set") unless aliases == Pins::ALLOWED_CANDIDATE_SYMLINKS
      true
    end

    def render
      Util.directory!(@root, "candidate copy root", mode: 0o755, owner: Process.euid)
      entries = []
      enumerate(@root, "", entries)
      aliases = {}
      records = entries.sort_by { |relative, _| relative.b }.map do |relative, path|
        Util.relative_path!(relative, "candidate copy entry")
        stat = File.lstat(path)
        assert_clean_metadata!(path, relative)
        flags = Util.bsd_flags(path, "candidate copy entry #{relative}")
        Util.fail!("unsafe BSD flags in candidate copy: #{relative}") unless flags.zero?
        mode = format("%04o", stat.mode & 0o7777)
        if stat.symlink?
          target = File.readlink(path)
          aliases[relative] = target
          Util.fail!("candidate copy has unreviewed symlink") unless Pins::ALLOWED_CANDIDATE_SYMLINKS[relative] == target
          Util.fail!("candidate copy has hard-linked symlink") unless stat.nlink == 1
          assert_alias_resolution!(relative, path, target)
          "L\t#{Util.sha256_text(target)}\t#{target}\t#{relative}\n"
        elsif stat.file?
          Util.fail!("candidate copy contains hard-linked file") unless stat.nlink == 1
          "F\t#{mode}:#{stat.size}\t#{Util.sha256(path)}\t#{relative}\n"
        elsif stat.directory?
          "D\t#{mode}\t#{relative}\n"
        else
          Util.fail!("candidate copy contains unsupported file type: #{relative}")
        end
      end
      [records.join, aliases]
    end

    private

    def enumerate(directory, prefix, entries)
      Dir.children(directory).each do |name|
        Util.fail!("unsafe candidate copy name") if name.match?(/[\x00-\x1f\x7f]/)
        relative = prefix.empty? ? name : File.join(prefix, name)
        path = File.join(directory, name)
        stat = File.lstat(path)
        entries << [relative, path]
        enumerate(path, relative, entries) if stat.directory?
      end
    end

    def assert_clean_metadata!(path, relative)
      listing = Util.capture!("/bin/ls", "-lde", path).lines.first.to_s
      Util.fail!("ACL in candidate copy: #{relative}") if listing.split.first.to_s.include?("+")
      command = ["/usr/bin/xattr"]
      command << "-s" if File.lstat(path).symlink?
      stdout, stderr, status = Open3.capture3(*command, path)
      Util.fail!("could not inspect candidate copy xattrs: #{stderr.strip}") unless status.success?
      Util.fail!("xattrs in candidate copy: #{relative}") unless stdout.empty?
    end

    def assert_alias_resolution!(relative, path, target)
      resolved = File.realpath(File.join(File.dirname(path), target))
      Util.fail!("candidate alias escapes app") unless resolved.start_with?(File.realpath(@root) + "/")
      if relative == "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        Util.fail!("candidate copy framework alias is not executable code") unless File.file?(resolved) && File.executable?(resolved)
      else
        Util.fail!("candidate copy framework alias is not a directory") unless File.directory?(resolved)
      end
    rescue Errno::ENOENT
      Util.fail!("candidate copy alias is dangling: #{relative}")
    end
  end

  module LaunchContract
    extend self

    def verify!(path)
      root = REXML::Document.new(File.binread(path)).root
      Util.fail!("launch plist root is invalid") unless root && root.name == "plist"
      dict = root.elements.to_a.reject { |node| node.is_a?(REXML::Text) }.first
      value = parse_node(dict)
      expected = {
        "Label" => "org.example.opensteamer.worldwide",
        "ProgramArguments" => Pins::LAUNCH_ARGUMENTS,
        "RunAtLoad" => true,
        "KeepAlive" => true,
        "ThrottleInterval" => 10,
        "StandardOutPath" => Pins::LAUNCH_STDOUT,
        "StandardErrorPath" => Pins::LAUNCH_STDERR,
        "EnvironmentVariables" => Pins::LAUNCH_ENVIRONMENT
      }
      Util.fail!("launch plist differs from exact ten-argument V90 contract") unless value == expected
      true
    rescue REXML::ParseException => error
      Util.fail!("launch plist is malformed: #{error.message}")
    end

    def parse_node(node)
      Util.fail!("unexpected empty plist value") unless node
      case node.name
      when "dict"
        children = node.elements.to_a
        Util.fail!("plist dict has odd child count") unless children.length.even?
        result = {}
        children.each_slice(2) do |key, value|
          Util.fail!("plist dict key is malformed") unless key.name == "key"
          Util.fail!("plist contains duplicate key #{key.text.inspect}") if result.key?(key.text)
          result[key.text] = parse_node(value)
        end
        result
      when "array"
        node.elements.to_a.map { |child| parse_node(child) }
      when "string" then node.text.to_s
      when "integer"
        Integer(node.text, 10)
      when "true" then true
      when "false" then false
      else Util.fail!("unsupported plist node #{node.name}")
      end
    rescue ArgumentError
      Util.fail!("plist integer is malformed")
    end
  end

  class Capsule
    attr_reader :root, :payload, :paths, :identity

    def initialize(root, external_handoff_sha, external_payload_sha)
      @root = root.sub(%r{/+\z}, "")
      @external_handoff_sha = external_handoff_sha
      @external_payload_sha = external_payload_sha
      @paths = {}
    end

    def verify!
      Util.assert_sha!(@external_handoff_sha, "external handoff digest")
      Util.assert_sha!(@external_payload_sha, "external payload digest")
      Util.canonical_absolute!(@root, "capsule root")
      Util.directory!(@root, "capsule root", mode: 0o700, owner: Process.euid)
      reject_forbidden_root!

      payload_path = File.join(@root, "v90-deployment-payload-manifest.json")
      Util.sidecar!(payload_path, payload_path + ".sha256", @external_payload_sha, "payload manifest")
      @payload = Util.strict_json(payload_path, Pins::PAYLOAD_KEYS, Pins::PAYLOAD_SCHEMA)
      validate_fixed_payload!
      resolve_payload_paths!
      validate_capsule_shape!

      Util.exact_file!(@paths.fetch(:source_tree_manifest), @payload.fetch("sourceTreeManifestSHA256"), "source tree manifest", mode: 0o600, owner: Process.euid)
      Util.exact_file!(@paths.fetch(:candidate_tree_manifest), @payload.fetch("candidateAppTreeManifestSHA256"), "candidate tree manifest", mode: 0o600, owner: Process.euid)
      Util.exact_file!(@paths.fetch(:candidate_copy_manifest), @payload.fetch("candidateAppCopyManifestSHA256"), "candidate copy manifest", mode: 0o600, owner: Process.euid)
      Util.directory!(@paths.fetch(:source), "source export", mode: 0o700, owner: Process.euid)
      Util.directory!(@paths.fetch(:candidate), "candidate app", mode: 0o755, owner: Process.euid)
      TreeManifest.new(@paths.fetch(:source), :source).verify!(@paths.fetch(:source_tree_manifest))
      TreeManifest.new(@paths.fetch(:candidate), :candidate).verify!(@paths.fetch(:candidate_tree_manifest))
      CopyManifest.new(@paths.fetch(:candidate)).verify!(@paths.fetch(:candidate_copy_manifest))

      validate_direct_bytes!
      validate_metadata!
      validate_handoff!
      validate_identity!
      LaunchContract.verify!(@paths.fetch(:launch_plist))
      true
    end

    def fingerprint
      @payload.values_at(*Pins::PAYLOAD_KEYS).join("\0")
    end

    private

    def reject_forbidden_root!
      forbidden = ["/Applications", Pins::RUNTIME_ROOT]
      lowered = @root.downcase
      Util.fail!("capsule is inside installed/protected runtime") if forbidden.any? do |prefix|
        lowered == prefix.downcase || lowered.start_with?(prefix.downcase + "/")
      end
    end

    def validate_fixed_payload!
      fixed = {
        "sourceCommit" => Pins::SOURCE_COMMIT,
        "sourceTree" => Pins::SOURCE_TREE,
        "sourceBranch" => Pins::SOURCE_BRANCH,
        "sourceUpstream" => Pins::SOURCE_UPSTREAM,
        "sourceExportRelativePath" => "source",
        "sourceTreeManifestRelativePath" => "v90-source-export-tree-manifest.txt",
        "candidateAppRelativePath" => "candidate/opensteamer Host.app",
        "candidateAppTreeManifestRelativePath" => "v90-candidate-app-tree-manifest.txt",
        "candidateAppCopyManifestRelativePath" => "v90-candidate-app-copy-manifest.txt",
        "candidateExecutableRelativePath" => "candidate/opensteamer Host.app/Contents/MacOS/CaptureServer",
        "candidateMediaFrameworkExecutableRelativePath" => "candidate/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC",
        "candidateInfoPlistRelativePath" => "candidate/opensteamer Host.app/Contents/Info.plist",
        "candidateLaunchPlistRelativePath" => "deployment/org.example.opensteamer.worldwide.plist",
        "capsuleMetadataRelativePath" => "trusted-v90-host-oracle-capsule-metadata.json",
        "handoffRelativePath" => "v90-screen-oracle-handoff/v90-screen-oracle-host-identity-handoff.json",
        "hostIdentityManifestRelativePath" => "v90-screen-oracle-handoff/sealed-live-mac-host-identity.json",
        "designatedRequirementReferenceRelativePath" => "trusted-reference/CaptureServer",
        "designatedRequirementReferenceSHA256" => Pins::APPROVED_PREDECESSOR_REFERENCE_SHA256,
        "designatedRequirementReferenceFileSize" => Pins::APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE.to_s,
        "designatedRequirementReferenceCodeSignatureDataOffset" => Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_OFFSET.to_s,
        "designatedRequirementReferenceCodeSignatureDataSize" => Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATA_SIZE.to_s,
        "designatedRequirementReferenceUnsignedPrefixSHA256" => Pins::APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256,
        "designatedRequirementReferenceCDHash" => Pins::APPROVED_PREDECESSOR_REFERENCE_CDHASH,
        "designatedRequirementReferenceCodeDirectorySHA256" => Pins::APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256,
        "designatedRequirementReferenceTeamIdentifier" => Pins::APPROVED_PREDECESSOR_REFERENCE_TEAM_ID,
        "designatedRequirementReferenceIdentifier" => Pins::APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER,
        "designatedRequirementReferenceDesignatedRequirement" => Pins::APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT,
        "toolingBranch" => Pins::SOURCE_BRANCH,
        "toolingUpstream" => Pins::SOURCE_UPSTREAM,
        "toolingRemoteURL" => "https://github.com/ahmedelami/opensteamer.git",
        "assemblerScriptRelativePath" => "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh"
      }
      fixed.each do |key, expected|
        Util.fail!("payload #{key} differs from fixed V90 contract") unless @payload.fetch(key) == expected
      end
      Pins::PAYLOAD_KEYS.grep(/SHA256\z/).each { |key| Util.assert_sha!(@payload.fetch(key), "payload #{key}") }
      %w[toolingCommit toolingTree assemblerScriptGitBlob].each do |key|
        Util.fail!("payload #{key} is not a lowercase Git object id") unless @payload.fetch(key).match?(/\A[0-9a-f]{40}\z/)
      end
      tooling = ToolingProof.verify!
      Util.fail!("payload toolingCommit differs from fresh reviewed tooling") unless
        @payload.fetch("toolingCommit") == tooling.fetch(:commit)
      Util.fail!("payload toolingTree differs from fresh reviewed tooling") unless
        @payload.fetch("toolingTree") == tooling.fetch(:tree)
      Util.fail!("payload assemblerScriptGitBlob differs from tracked assembler") unless
        @payload.fetch("assemblerScriptGitBlob") == tooling.fetch(:assembler_blob)
      Util.assert_sha!(Pins::APPROVED_PREDECESSOR_REFERENCE_SHA256, "compiled approved predecessor-reference digest")
      Util.fail!("predecessor reference lacks explicit compiled approval") unless
        @payload.fetch("designatedRequirementReferenceSHA256") == Pins::APPROVED_PREDECESSOR_REFERENCE_SHA256
      Util.fail!("payload handoff digest differs from external transport") unless @payload.fetch("handoffSHA256") == @external_handoff_sha
      Util.fail!("candidate launch plist is not byte-identical to pinned live contract") unless @payload.fetch("candidateLaunchPlistSHA256") == Pins::LAUNCH_AGENT_SHA256
    end

    def resolve_payload_paths!
      mapping = {
        source: "sourceExportRelativePath",
        source_tree_manifest: "sourceTreeManifestRelativePath",
        candidate: "candidateAppRelativePath",
        candidate_tree_manifest: "candidateAppTreeManifestRelativePath",
        candidate_copy_manifest: "candidateAppCopyManifestRelativePath",
        executable: "candidateExecutableRelativePath",
        framework: "candidateMediaFrameworkExecutableRelativePath",
        info_plist: "candidateInfoPlistRelativePath",
        launch_plist: "candidateLaunchPlistRelativePath",
        metadata: "capsuleMetadataRelativePath",
        handoff: "handoffRelativePath",
        identity: "hostIdentityManifestRelativePath",
        reference: "designatedRequirementReferenceRelativePath"
      }
      mapping.each { |name, key| @paths[name] = Util.inside(@root, @payload.fetch(key), "payload #{key}") }
      Util.fail!("source plist cannot be used as deployment plist") if @paths[:launch_plist].start_with?(@paths[:source] + "/")
    end

    def validate_capsule_shape!
      expected_top = [
        "candidate", "deployment", "source", "trusted-reference",
        "trusted-v90-host-oracle-capsule-metadata.json", "v90-candidate-app-tree-manifest.txt",
        "v90-candidate-app-copy-manifest.txt",
        "v90-deployment-payload-manifest.json", "v90-deployment-payload-manifest.json.sha256",
        "v90-screen-oracle-handoff", "v90-source-export-tree-manifest.txt"
      ]
      Util.fail!("capsule top-level names differ from strict layout") unless Dir.children(@root).sort == expected_top.sort
      {
        File.join(@root, "candidate") => ["opensteamer Host.app"],
        File.join(@root, "deployment") => ["org.example.opensteamer.worldwide.plist"],
        File.join(@root, "trusted-reference") => ["CaptureServer"],
        File.join(@root, "v90-screen-oracle-handoff") => [
          "sealed-live-mac-host-identity.json",
          "sealed-live-mac-host-identity.json.sha256",
          "v90-screen-oracle-host-identity-handoff.json",
          "v90-screen-oracle-host-identity-handoff.json.sha256"
        ]
      }.each do |directory, children|
        Util.directory!(directory, "capsule layout directory", mode: 0o700, owner: Process.euid)
        Util.fail!("capsule directory contains unpinned names: #{directory}") unless Dir.children(directory).sort == children.sort
      end
    end

    def validate_direct_bytes!
      {
        executable: "candidateExecutableSHA256",
        framework: "candidateMediaFrameworkExecutableSHA256",
        info_plist: "candidateInfoPlistSHA256",
        launch_plist: "candidateLaunchPlistSHA256",
        metadata: "capsuleMetadataSHA256",
        handoff: "handoffSHA256",
        identity: "hostIdentityManifestSHA256",
        reference: "designatedRequirementReferenceSHA256"
      }.each do |name, digest_key|
        expected = @payload.fetch(digest_key)
        mode = {
          executable: 0o755,
          framework: 0o755,
          info_plist: 0o644,
          launch_plist: 0o600,
          metadata: 0o600,
          handoff: 0o600,
          identity: 0o600,
          reference: 0o755
        }.fetch(name)
        Util.exact_file!(@paths.fetch(name), expected, name.to_s.tr("_", " "), mode: mode, owner: Process.euid)
      end
      Util.sidecar!(@paths.fetch(:handoff), @paths.fetch(:handoff) + ".sha256", @external_handoff_sha, "handoff")
      PredecessorReferenceFingerprint.verify!(@paths.fetch(:reference))
    end

    def validate_metadata!
      metadata = Util.strict_json(@paths.fetch(:metadata), Pins::CAPSULE_KEYS, Pins::CAPSULE_SCHEMA)
      cross = {
        "candidateAppRelativePath" => @payload.fetch("candidateAppRelativePath"),
        "candidateExecutableSHA256" => @payload.fetch("candidateExecutableSHA256"),
        "candidateMediaFrameworkExecutableSHA256" => @payload.fetch("candidateMediaFrameworkExecutableSHA256"),
        "designatedRequirementReferenceRelativePath" => @payload.fetch("designatedRequirementReferenceRelativePath"),
        "designatedRequirementReferenceSHA256" => @payload.fetch("designatedRequirementReferenceSHA256")
      }
      cross.each { |key, expected| Util.fail!("capsule metadata #{key} mismatch") unless metadata.fetch(key) == expected }
    end

    def validate_handoff!
      handoff = Util.strict_json(@paths.fetch(:handoff), Pins::HANDOFF_KEYS, Pins::HANDOFF_SCHEMA)
      expected = {
        "capsuleMetadataSHA256" => @payload.fetch("capsuleMetadataSHA256"),
        "candidateAppRelativePath" => @payload.fetch("candidateAppRelativePath"),
        "candidateExecutableSHA256" => @payload.fetch("candidateExecutableSHA256"),
        "candidateMediaFrameworkExecutableSHA256" => @payload.fetch("candidateMediaFrameworkExecutableSHA256"),
        "designatedRequirementReferenceRelativePath" => @payload.fetch("designatedRequirementReferenceRelativePath"),
        "designatedRequirementReferenceSHA256" => @payload.fetch("designatedRequirementReferenceSHA256"),
        "expectedTeamIdentifier" => Pins::TEAM_ID,
        "hostIdentityManifestBasename" => File.basename(@paths.fetch(:identity)),
        "hostIdentityManifestSHA256" => @payload.fetch("hostIdentityManifestSHA256"),
        "hostIdentityManifestSHA256Basename" => File.basename(@paths.fetch(:identity)) + ".sha256"
      }
      expected.each { |key, value| Util.fail!("handoff #{key} mismatch") unless handoff.fetch(key) == value }
      Util.sidecar!(@paths.fetch(:identity), @paths.fetch(:identity) + ".sha256", @payload.fetch("hostIdentityManifestSHA256"), "host identity")
    end

    def validate_identity!
      identity = Util.strict_json(@paths.fetch(:identity), Pins::IDENTITY_KEYS, Pins::IDENTITY_SCHEMA)
      expected = {
        "executablePath" => Pins::LIVE_EXECUTABLE,
        "executableSHA256" => @payload.fetch("candidateExecutableSHA256"),
        "executableIdentifier" => Pins::EXECUTABLE_IDENTIFIER,
        "executableTeamIdentifier" => Pins::TEAM_ID,
        "mediaFrameworkExecutablePath" => Pins::LIVE_FRAMEWORK_IDENTITY_PATH,
        "mediaFrameworkExecutableSHA256" => @payload.fetch("candidateMediaFrameworkExecutableSHA256"),
        "mediaFrameworkExecutableIdentifier" => Pins::FRAMEWORK_IDENTIFIER,
        "mediaFrameworkExecutableTeamIdentifier" => Pins::TEAM_ID
      }
      expected.each { |key, value| Util.fail!("host identity #{key} mismatch") unless identity.fetch(key) == value }
      %w[executableCDHash mediaFrameworkExecutableCDHash].each do |key|
        Util.fail!("host identity #{key} malformed") unless identity.fetch(key).match?(/\A[0-9a-f]{40}\z/)
      end
      @identity = identity
    end
  end

  class SessionFence
    Snapshot = Struct.new(:device, :inode, :size, :last_reset_offset, :digest, keyword_init: true)

    def self.observe!(path, pid, nonce, prior: nil)
      stat = Util.regular_file!(path, "host stdout log", owner: Process.euid, links: 1)
      if prior
        Util.fail!("host stdout log was replaced") unless [stat.dev, stat.ino] == [prior.device, prior.inode]
        Util.fail!("host stdout log was truncated") if stat.size < prior.size
      end
      data = nil
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        Util.fail!("host stdout log changed while opening") unless
          opened.file? && [opened.dev, opened.ino, opened.nlink] == [stat.dev, stat.ino, 1]
        observed_size = opened.size
        data = observed_size.zero? ? "" : file.pread(observed_size, 0)
        Util.fail!("host stdout log short read") unless data.bytesize == observed_size
        after = File.lstat(path)
        Util.fail!("host stdout log changed while reading") unless
          after.file? && [after.dev, after.ino, after.nlink] == [opened.dev, opened.ino, 1]
        stat = opened
      end
      if prior
        prefix = data.byteslice(0, prior.size)
        Util.fail!("host stdout log historical bytes changed") unless
          prefix && Digest::SHA256.hexdigest(prefix) == prior.digest
      end
      online = "Worldwide paired-device availability is online pid=#{pid} nonce=#{nonce}"
      Util.fail!("host log lacks pinned generation availability marker") unless data.include?(online)
      reset_patterns = [
        "Worldwide availability is waiting for the paired iPhone",
        "Worldwide viewer disconnected",
        "Worldwide peer returned to idle"
      ]
      reset = reset_patterns.map { |marker| data.rindex(marker) }.compact.max
      Util.fail!("host log has no quiescent-session boundary") unless reset
      if prior
        Util.fail!("host quiescent-session boundary changed") unless reset == prior.last_reset_offset
      end
      suffix = data.byteslice(reset..-1)
      unsafe = [
        "Worldwide authenticated media route selected",
        "Starting screen video capture",
        "peerConnected=true",
        "controlOpen=true"
      ]
      Util.fail!("host has an authenticated/active peer after quiescent boundary") if unsafe.any? { |marker| suffix.include?(marker) }
      Util.fail!("host screen remains active") if suffix.rindex("Starting screen video capture").to_i > suffix.rindex("Stopping screen video capture").to_i
      Snapshot.new(
        device: stat.dev,
        inode: stat.ino,
        size: stat.size,
        last_reset_offset: reset,
        digest: Digest::SHA256.hexdigest(data)
      )
    rescue Errno::ELOOP, Errno::ENOENT => error
      Util.fail!("host stdout log cannot be safely opened: #{error.message}")
    end
  end

  class Coordinator
    attr_reader :committed

    def initialize(host, capsule)
      @host = host
      @capsule = capsule
      @stop_intent = false
      @prepared = false
      @irreversible = false
      @committed = false
      @rollback_attempted = false
    end

    def preflight!
      @capsule.verify!
      @host.preflight!(@capsule)
      @host.preflight!(@capsule) # A second complete observation rejects unstable evidence.
      true
    end

    def execute!
      preflight!
      # Mark the prepare attempt before entering it so an asynchronous interrupt cannot land in
      # the otherwise-unobservable gap after prepare returns and strand its fresh namespace.
      @prepared = true
      @host.prepare!(@capsule)
      @capsule.verify! # Last transitive byte replay immediately precedes STOP_INTENT.
      @host.revalidate_immediately_before_stop!(@capsule)
      # Bind durable STOP_INTENT to the rollback latch. A deferred signal after this block must
      # take the exact-V86 rollback path, never the mutation-free pre-stop abort path.
      Thread.handle_interrupt(Interrupt => :never) do
        begin
          @host.journal!("STOP_INTENT")
        ensure
          # A full STOP_INTENT record observed after an fsync error is not success, but it is
          # enough to forbid the pre-stop deletion path. Recovery must follow the rollback graph.
          @stop_intent = true if @host.stop_intent_on_disk?
        end
      end
      @host.journal!("INSTALL_HOLDS_VERIFIED")
      @host.stop_predecessor!
      @host.hold_predecessor!
      @host.publish_candidate!
      @host.start_candidate!
      @host.verify_candidate_ready!
      @host.journal!("READY_VERIFIED")
      @host.journal!("COMMIT_INTENT")
      @host.prepare_irreversible_commit!
      # V90_COMMIT_IRREVERSIBLE is the durable point of no return. Signals are deferred until the
      # exact on-disk journal state and the in-memory no-rollback latch agree.
      Thread.handle_interrupt(Interrupt => :never) do
        @host.journal!("V90_COMMIT_IRREVERSIBLE")
        @irreversible = true
      end
      @host.finalize_postcommit!
      # COMMITTED_V90 is deliberately the last fallible success gate. It certifies final route
      # readback plus zero-notification monitor teardown, and is never followed by rollback.
      Thread.handle_interrupt(Interrupt => :never) do
        @host.journal!("COMMITTED_V90")
        @committed = true
      end
      true
    rescue Exception => original # rubocop:disable Lint/RescueException
      if @stop_intent && irreversible_or_indeterminate?
        @irreversible = true
        committed_but_unverified_after(original)
      end
      rollback_after(original) if @stop_intent && !@committed
      abort_before_stop_after(original) if @prepared && !@stop_intent
      raise
    end

    def interrupt!
      error = Failure.new("cutover interrupted")
      committed_but_unverified_after(error) if @stop_intent && irreversible_or_indeterminate?
      rollback_after(error) if @stop_intent && !@committed
      raise error
    end

    private

    def irreversible_or_indeterminate?
      return true if @irreversible
      @host.irreversible_on_disk?
    rescue Exception # rubocop:disable Lint/RescueException
      # If the authoritative journal inode cannot be read and reconciled after STOP_INTENT, the
      # controller cannot prove that the point of no return was not persisted. Destructive
      # rollback is therefore forbidden.
      true
    end

    def rollback_after(original)
      return if @rollback_attempted
      @rollback_attempted = true
      Thread.handle_interrupt(Interrupt => :never) { @host.rollback_exact_v86! }
    rescue Exception => rollback_error # rubocop:disable Lint/RescueException
      raise Failure, "#{original.message}; exact V86 rollback failed: #{rollback_error.message}"
    end

    def abort_before_stop_after(original)
      Thread.handle_interrupt(Interrupt => :never) { @host.abort_before_stop! }
    rescue Exception => cleanup_error # rubocop:disable Lint/RescueException
      raise Failure, "#{original.message}; exact pre-stop cleanup failed: #{cleanup_error.message}"
    end

    def committed_but_unverified_after(original)
      Thread.handle_interrupt(Interrupt => :never) do
        @host.record_committed_unverified!(original)
      end
      raise CommittedButUnverified,
            "#{original.message}; V90 crossed V90_COMMIT_IRREVERSIBLE and remains live; " \
            "commit safety proof is incomplete and exact-V86 rollback was intentionally forbidden"
    rescue CommittedButUnverified
      raise
    rescue Exception => evidence_error # rubocop:disable Lint/RescueException
      raise CommittedButUnverified,
            "#{original.message}; V90 crossed V90_COMMIT_IRREVERSIBLE and remains live; " \
            "committed-but-unverified evidence also failed: #{evidence_error.message}; rollback forbidden"
    end
  end

  class RealHost
    include Util

    SUCCESS_STATES = %w[
      BEGUN INPUTS_VERIFIED STOP_INTENT INSTALL_HOLDS_VERIFIED V86_STOPPED V86_HELD
      V90_PUBLISHED V90_BOOTSTRAPPED READY_VERIFIED COMMIT_INTENT
      V90_COMMIT_IRREVERSIBLE COMMITTED_V90
    ].freeze
    ROLLBACK_STATES = %w[
      ROLLBACK_STARTED V90_STOPPED FAILED_V90_ARCHIVED V86_RESTORED V86_BOOTSTRAPPED
      ROLLED_BACK_EXACT_V86
    ].freeze
    JOURNAL_TRANSITIONS = begin
      transitions = {
        nil => %w[BEGUN ABORTED_BEFORE_STOP],
        "BEGUN" => %w[INPUTS_VERIFIED ABORTED_BEFORE_STOP],
        "INPUTS_VERIFIED" => %w[STOP_INTENT ABORTED_BEFORE_STOP],
        "STOP_INTENT" => %w[INSTALL_HOLDS_VERIFIED ROLLBACK_STARTED],
        "INSTALL_HOLDS_VERIFIED" => %w[V86_STOPPED ROLLBACK_STARTED],
        "ROLLBACK_STARTED" => %w[V90_STOPPED],
        "V90_STOPPED" => %w[FAILED_V90_ARCHIVED],
        "FAILED_V90_ARCHIVED" => %w[V86_RESTORED],
        "V86_RESTORED" => %w[V86_BOOTSTRAPPED],
        "V86_BOOTSTRAPPED" => %w[ROLLED_BACK_EXACT_V86],
        "V90_COMMIT_IRREVERSIBLE" => %w[COMMITTED_V90 COMMITTED_V90_UNVERIFIED],
        "COMMITTED_V90" => %w[COMMITTED_V90_UNVERIFIED]
      }
      SUCCESS_STATES.each_cons(2) { |from, to| (transitions[from] ||= []) << to }
      %w[V86_STOPPED V86_HELD V90_PUBLISHED V90_BOOTSTRAPPED READY_VERIFIED COMMIT_INTENT].each do |from|
        (transitions[from] ||= []) << "ROLLBACK_STARTED"
      end
      transitions.transform_values!(&:freeze)
      transitions.freeze
    end

    def initialize
      @prepared = false
      @predecessor_stopped = false
      @candidate_installed = false
      @candidate_started = false
      @aborted = false
      @transaction = nil
      @journal = nil
      @session = nil
      @new_pid = nil
      @new_nonce = nil
      @route_monitor = nil
      @route_monitor_stopped = false
      @route_monitor_failure = nil
      @last_journal_state = nil
      @journal_io = nil
      @post_stop_helpers_root = nil
      @route_monitor_module_cache_path = nil
      @route_monitor_compiler_tmp_path = nil
    end

    def preflight!(capsule)
      verify_fresh_namespace!
      verify_origins!
      verify_capsule_code!(capsule)
      @session = verify_live_v86!(@session)
      true
    end

    def prepare!(capsule)
      verify_fresh_namespace!
      create_owned_directory!(
        Pins::V90_LOCK,
        0o700,
        "V90 runtime root after lock creation"
      ) { |identity| @lock_identity = identity }
      create_owned_directory!(
        Pins::V90_UPDATE_ROOT,
        0o700,
        "V90 runtime root after update-root creation"
      ) { |identity| @update_root_identity = identity }
      transaction_name = "paired-v90-update-#{Time.now.to_i}-#{Process.pid}-#{SecureRandom.uuid}"
      @transaction = File.join(Pins::V90_UPDATE_ROOT, transaction_name)
      create_owned_directory!(
        @transaction,
        0o700,
        "V90 update root after transaction creation"
      ) { |identity| @transaction_identity = identity }
      @journal = File.join(@transaction, "journal.log")
      write_durable(@journal, "#{Pins::V90_JOURNAL_HEADER}\n", 0o600, exclusive: true) do |identity|
        @journal_identity = identity
      end
      journal!("BEGUN")
      start_route_monitor!
      stage_post_stop_evidence!(capsule)
      publish_owned_pointer!(Pins::V90_PENDING_POINTER, "#{@transaction}\n") do |identity|
        @pending_identity = identity
      end

      @token = SecureRandom.uuid
      @staged_app = "/Applications/.opensteamer-paired-v90-install-#{@token}.app"
      @backup_app = "/Applications/.opensteamer-paired-v90-rollback-#{@token}.app"
      @failed_app = "/Applications/.opensteamer-paired-v90-failed-#{@token}.app"
      launch_parent = File.dirname(Pins::LAUNCH_AGENT)
      @staged_plist = File.join(launch_parent, ".org.example.opensteamer.worldwide.v90-install-#{@token}.plist")
      @backup_plist = File.join(launch_parent, ".org.example.opensteamer.worldwide.v86-rollback-#{@token}.plist")
      @failed_plist = File.join(launch_parent, ".org.example.opensteamer.worldwide.v90-failed-#{@token}.plist")
      [@staged_app, @backup_app, @failed_app, @staged_plist, @backup_plist, @failed_plist].each do |path|
        Util.fail!("transaction staging name already exists") if File.exist?(path) || File.symlink?(path)
      end
      create_owned_directory!(
        @staged_app,
        0o755,
        "Applications directory after staged-app creation"
      ) { |identity| @staged_app_identity = identity }
      Dir.children(capsule.paths.fetch(:candidate)).each do |name|
        FileUtils.cp_r(File.join(capsule.paths.fetch(:candidate), name), @staged_app, preserve: true)
      end
      write_durable(
        @staged_plist,
        File.binread(capsule.paths.fetch(:launch_plist)),
        0o600,
        exclusive: true
      ) { |identity| @staged_plist_identity = identity }
      ensure_same_filesystem!(@staged_app, Pins::LIVE_APP)
      ensure_same_filesystem!(@staged_plist, Pins::LAUNCH_AGENT)
      durably_sync_staged_candidate!(capsule)
      route_monitor_clean!
      durably_sync_transaction_topology!
      journal!("INPUTS_VERIFIED")
      @prepared = true
    rescue Exception => original # rubocop:disable Lint/RescueException
      begin
        Thread.handle_interrupt(Interrupt => :never) { abort_before_stop! }
      rescue Exception => cleanup_error # rubocop:disable Lint/RescueException
        raise Failure, "#{original.message}; exact pre-stop cleanup failed: #{cleanup_error.message}"
      end
      raise
    end

    def revalidate_immediately_before_stop!(capsule)
      Util.fail!("transaction was not prepared") unless @prepared
      verify_origins!
      verify_capsule_code!(capsule)
      verify_post_stop_evidence!(capsule)
      durably_sync_staged_candidate!(capsule)
      @session = verify_live_v86!(@session)
      route_monitor_clean!
      durably_sync_transaction_topology!
      true
    end

    def journal!(state)
      Util.fail!("journal is unavailable") unless @journal
      prior_bytes = read_journal_bytes!
      prior_states = parse_journal_bytes!(prior_bytes)
      Util.fail!("journal memory/disk state diverged") unless prior_states.last == @last_journal_state
      allowed = JOURNAL_TRANSITIONS.fetch(@last_journal_state, [])
      Util.fail!("invalid journal transition #{@last_journal_state.inspect} -> #{state}") unless
        allowed.include?(state)
      line = "#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} STATE #{state}\n"
      @journal_io ||= File.open(@journal, File::RDWR | File::APPEND | File::NOFOLLOW)
      assert_open_identity!(@journal, @journal_io, "V90 journal")
      write_all!(@journal_io, line, "V90 journal #{state}")
      @journal_io.flush
      strict_fsync_io!(@journal_io, "V90 journal #{state}")
      Util.fail!("journal append bytes differ after fsync") unless read_journal_bytes! == prior_bytes + line
      Util.fail!("journal append topology differs after fsync") unless
        parse_journal_bytes!(read_journal_bytes!) == prior_states + [state]
      @last_journal_state = state
      true
    rescue Exception => error # rubocop:disable Lint/RescueException
      # The journal inode and its directory entry were made durable during prepare. If the exact
      # full record is observable after a write/fsync exception, conservatively accept it as the
      # state boundary. This prevents a durable point-of-no-return record from being followed by
      # rollback merely because an error was reported after persistence.
      current = @journal ? read_journal_bytes! : nil
      if current && prior_bytes && line && current == prior_bytes + line &&
         parse_journal_bytes!(current) == prior_states + [state]
        @last_journal_state = state
        raise JournalPersistenceUnverified,
              "#{state} record is complete but its fsync did not certify durability: #{error.message}"
      end
      if current && prior_bytes && line && current.start_with?(prior_bytes) &&
         line.start_with?(current.byteslice(prior_bytes.bytesize..-1).to_s)
        begin
          @journal_io.truncate(prior_bytes.bytesize)
          @journal_io.flush
          strict_fsync_io!(@journal_io, "V90 journal torn-record rollback")
          Util.fail!("journal torn-record rollback was not exact") unless read_journal_bytes! == prior_bytes
          Util.fail!("journal topology changed during torn-record rollback") unless
            parse_journal_bytes!(read_journal_bytes!) == prior_states
        rescue Exception => repair_error # rubocop:disable Lint/RescueException
          raise Failure,
                "#{error.message}; journal append is indeterminate and exact truncation failed: #{repair_error.message}"
        end
      end
      raise error
    end

    def stop_predecessor!
      route_monitor_clean!
      command!("/bin/launchctl", "bootout", Pins::LAUNCH_LABEL)
      wait_until!(15, "predecessor did not stop cleanly") { runtime_absent? }
      verify_routes!
      route_monitor_clean!
      @predecessor_stopped = true
      journal!("V86_STOPPED")
    end

    def hold_predecessor!
      Util.fail!("predecessor is not stopped") unless @predecessor_stopped
      exclusive_rename(Pins::LIVE_APP, @backup_app)
      exclusive_rename(Pins::LAUNCH_AGENT, @backup_plist)
      route_monitor_clean!
      journal!("V86_HELD")
    end

    def publish_candidate!
      Util.fail!("V86 app/plist are not held") unless File.exist?(@backup_app) && File.exist?(@backup_plist)
      exclusive_rename(@staged_app, Pins::LIVE_APP)
      exclusive_rename(@staged_plist, Pins::LAUNCH_AGENT)
      @candidate_installed = true
      route_monitor_clean!
      journal!("V90_PUBLISHED")
    end

    def start_candidate!
      Util.fail!("candidate is not installed") unless @candidate_installed
      command!("/bin/launchctl", "bootstrap", "gui/501", Pins::LAUNCH_AGENT)
      @candidate_started = true
      route_monitor_clean!
      journal!("V90_BOOTSTRAPPED")
    end

    def verify_candidate_ready!
      wait_until!(90, "V90 host did not become ready") do
        begin
          establish_candidate_stability_baseline!
        rescue Failure
          false
        end
      end
      run_candidate_stability_window!
      true
    end

    def prepare_irreversible_commit!
      Util.fail!("candidate readiness was not established") unless @new_pid && @new_nonce
      result = <<~RESULT
        result=pending-terminal
        terminal_required=V90_COMMIT_IRREVERSIBLE,COMMITTED_V90
        pid=#{@new_pid}
        nonce=#{@new_nonce}
        target=v90
        selected=#{Pins::LIVE_DISPLAY_MODE}
        candidate_executable_sha256=#{@candidate_executable_sha}
        payload_manifest_sha256=#{@payload_sha}
        handoff_sha256=#{@handoff_sha}
      RESULT
      write_durable(File.join(@transaction, "result.txt"), result, 0o600, exclusive: true)
      publish_owned_pointer!(Pins::V90_ACTIVE_POINTER, "#{@transaction}\n") do |identity|
        @active_pointer_identity = identity
      end
      remove_pending_pointer_if_owned!
      remove_lock_if_owned!
      strict_fsync_directory!(Pins::RUNTIME_ROOT, "V90 runtime root before commit decision")
      verify_candidate_stability_sample!
      route_monitor_clean!
      true
    end

    def finalize_postcommit!
      Util.fail!("V90 commit is not irreversible") unless irreversible_on_disk?
      stop_route_monitor!
      verify_routes!
      result = <<~RESULT
        result=success-pending-terminal
        terminal_required=COMMITTED_V90
        point_of_no_return=V90_COMMIT_IRREVERSIBLE
        pid=#{@new_pid}
        nonce=#{@new_nonce}
        target=v90
        selected=#{Pins::LIVE_DISPLAY_MODE}
        candidate_executable_sha256=#{@candidate_executable_sha}
        payload_manifest_sha256=#{@payload_sha}
        handoff_sha256=#{@handoff_sha}
        route_monitor=#{Pins::ROUTE_MONITOR_RESULT}
      RESULT
      write_durable(
        File.join(@transaction, "commit-safety-proof.txt"),
        result,
        0o600,
        exclusive: true
      )
      verify_routes!
      true
    end

    def irreversible_on_disk?
      return true if %w[V90_COMMIT_IRREVERSIBLE COMMITTED_V90 COMMITTED_V90_UNVERIFIED].include?(
        @last_journal_state
      )
      @journal ? journal_has_exact_terminal_record?("V90_COMMIT_IRREVERSIBLE", anywhere: true) : false
    end

    def stop_intent_on_disk?
      return true if @last_journal_state && @last_journal_state != "BEGUN" &&
                     @last_journal_state != "INPUTS_VERIFIED" &&
                     @last_journal_state != "ABORTED_BEFORE_STOP"
      @journal ? journal_has_exact_terminal_record?("STOP_INTENT", anywhere: true) : false
    end

    def record_committed_unverified!(original)
      return true if @committed_unverified_recorded
      errors = []
      attempt_cleanup(errors, "sticky monitor teardown") do
        stop_route_monitor!(allow_failure: true) if @route_monitor
        raise @route_monitor_failure if @route_monitor_failure
      end
      attempt_cleanup(errors, "final route readback") { verify_routes! }
      evidence = <<~RESULT
        result=committed-but-unverified
        point_of_no_return=V90_COMMIT_IRREVERSIBLE
        target=v90
        pid=#{@new_pid}
        nonce=#{@new_nonce}
        original_error=#{original.class}: #{original.message.to_s.gsub(/[\r\n]/, " ")}
        evidence_errors=#{errors.join(" | ").gsub(/[\r\n]/, " ")}
        rollback=forbidden
      RESULT
      write_durable(
        File.join(@transaction, "committed-but-unverified.txt"),
        evidence,
        0o600,
        exclusive: true
      )
      journal!("COMMITTED_V90_UNVERIFIED") unless @last_journal_state == "COMMITTED_V90_UNVERIFIED"
      @committed_unverified_recorded = true
      true
    end

    def abort_before_stop!
      return true if @aborted
      Util.fail!("cannot use pre-stop abort after predecessor stop") if @predecessor_stopped
      errors = []
      attempt_cleanup(errors, "abort journal") { journal!("ABORTED_BEFORE_STOP") if @journal && File.file?(@journal) }
      attempt_cleanup(errors, "route monitor teardown") do
        stop_route_monitor!(allow_failure: true) if @route_monitor
        raise @route_monitor_failure if @route_monitor_failure
      end
      attempt_cleanup(errors, "staged app") do
        remove_tree_exact!(@staged_app, @staged_app_identity) if @staged_app_identity && path_present?(@staged_app)
      end
      attempt_cleanup(errors, "staged plist") do
        unlink_exact!(@staged_plist, @staged_plist_identity) if @staged_plist_identity && path_present?(@staged_plist)
      end
      attempt_cleanup(errors, "pending pointer") { remove_pending_pointer_if_owned! }
      attempt_cleanup(errors, "journal descriptor") do
        @journal_io.close if @journal_io && !@journal_io.closed?
        @journal_io = nil
      end
      attempt_cleanup(errors, "transaction directory") do
        remove_tree_exact!(@transaction, @transaction_identity) if @transaction_identity && path_present?(@transaction)
      end
      attempt_cleanup(errors, "update root") do
        remove_empty_directory_exact!(Pins::V90_UPDATE_ROOT, @update_root_identity) if @update_root_identity
      end
      attempt_cleanup(errors, "transaction lock") { remove_lock_if_owned! }
      attempt_cleanup(errors, "runtime directory sync") do
        strict_fsync_directory!(Pins::RUNTIME_ROOT, "V90 runtime root after abort")
      end
      @aborted = true
      Util.fail!("pre-stop cleanup errors: #{errors.join('; ')}") unless errors.empty?
      true
    end

    def rollback_exact_v86!
      journal!("ROLLBACK_STARTED") if @journal
      system("/bin/launchctl", "bootout", Pins::LAUNCH_LABEL, out: File::NULL, err: File::NULL)
      wait_until!(15, "host did not become absent for rollback") { runtime_absent? }
      journal!("V90_STOPPED") if @journal
      archive_candidate_exact!(@staged_app_identity, [Pins::LIVE_APP, @staged_app], @failed_app, "V90 app")
      archive_candidate_exact!(@staged_plist_identity, [Pins::LAUNCH_AGENT, @staged_plist], @failed_plist, "V90 plist")
      journal!("FAILED_V90_ARCHIVED") if @journal
      restore_predecessor_exact!(
        Pins::LIVE_APP,
        @backup_app,
        Pins::LIVE_V86_IDENTITIES.fetch(Pins::LIVE_APP),
        "V86 app"
      )
      restore_predecessor_exact!(
        Pins::LAUNCH_AGENT,
        @backup_plist,
        Pins::LAUNCH_AGENT_V86_IDENTITY,
        "V86 plist"
      )
      verify_installed_v86_bytes!
      journal!("V86_RESTORED") if @journal
      command!("/bin/launchctl", "bootstrap", "gui/501", Pins::LAUNCH_AGENT)
      journal!("V86_BOOTSTRAPPED") if @journal
      wait_until!(90, "exact V86 did not restart after rollback") do
        begin
          pid, runs = launch_identity
          record = strict_lock_record
          next false unless runs == 1 && pid.positive? && record.fetch(:pid) == pid
          @rollback_pid = pid
          @rollback_nonce = record.fetch(:nonce)
          verify_dynamic_process!(pid, expected_cdhash: Pins::V86_CDHASH) && verify_installed_v86_bytes!
        rescue Failure
          false
        end
      end
      restore_display_if_needed!
      wait_until!(15, "V86 display mode was not restored") { current_display_mode == Pins::LIVE_DISPLAY_MODE }
      31.times do
        verify_dynamic_process!(@rollback_pid, expected_cdhash: Pins::V86_CDHASH)
        verify_installed_v86_bytes!
        retain_rollback_safety_failure { verify_routes! }
        route_monitor_clean!(allow_failure: true)
        Util.fail!("V86 host generation changed during rollback proof") unless
          strict_lock_record == { pid: @rollback_pid, nonce: @rollback_nonce }
        sleep 1
      end
      remove_provisional_active_pointer!
      remove_pending_pointer_if_owned!
      remove_lock_if_owned!
      strict_fsync_directory!(Pins::RUNTIME_ROOT, "V90 runtime root after rollback")
      route_monitor_clean!(allow_failure: true) if @route_monitor
      stop_route_monitor!(allow_failure: true) if @route_monitor
      retain_rollback_safety_failure { verify_routes! }
      if @route_monitor_failure
        Util.fail!("rollback route-monitor safety failure: #{@route_monitor_failure.message}")
      end
      rollback_result = <<~RESULT
        result=pending-terminal
        terminal_required=ROLLED_BACK_EXACT_V86
        pid=#{@rollback_pid}
        nonce=#{@rollback_nonce}
        target=exact-v86
        selected=#{Pins::LIVE_DISPLAY_MODE}
      RESULT
      write_durable(
        File.join(@transaction, "rollback-result.txt"),
        rollback_result,
        0o600,
        exclusive: true
      )
      journal!("ROLLED_BACK_EXACT_V86") if @journal
      true
    end

    private

    # These no-op hooks exist only so the offline self-test can hold the exact asynchronous-signal
    # windows open. Production subclasses never override them.
    def after_directory_create_before_identity!(_path)
      true
    end

    def after_file_create_before_identity!(_path)
      true
    end

    def set_durable_mode!(io, mode, label)
      io.chmod(mode)
      true
    rescue SystemCallError => error
      Util.fail!("#{label} chmod failed: #{error.message}")
    end

    def create_owned_directory!(path, mode, parent_label)
      identity = nil
      Thread.handle_interrupt(Interrupt => :never) do
        Dir.mkdir(path, mode)
        after_directory_create_before_identity!(path)
        identity = file_identity(path)
        yield identity if block_given?
        File.open(path, File::RDONLY | File::NOFOLLOW) do |directory|
          opened = directory.stat
          Util.fail!("owned directory changed while opening: #{path}") unless
            opened.directory? && [opened.dev, opened.ino, opened.ftype] == identity
          set_durable_mode!(directory, mode, "owned directory #{path}")
          strict_fsync_io!(directory, "owned directory #{path}")
        end
        assert_identity!(path, identity, "owned directory #{path}")
        Util.fail!("owned directory mode differs: #{path}") unless
          (File.lstat(path).mode & 0o7777) == mode
        strict_fsync_directory!(File.dirname(path), parent_label)
      end
      identity
    rescue SystemCallError => error
      Util.fail!("could not create durable owned directory #{path}: #{error.message}")
    end

    def write_all!(io, bytes, label)
      offset = 0
      while offset < bytes.bytesize
        written = io.write(bytes.byteslice(offset, bytes.bytesize - offset))
        Util.fail!("#{label} made no write progress") unless written && written.positive?
        offset += written
      end
      Util.fail!("#{label} short write") unless offset == bytes.bytesize
      true
    end

    def assert_open_identity!(path, io, label)
      path_stat = File.lstat(path)
      open_stat = io.stat
      Util.fail!("#{label} is not a regular file") unless path_stat.file? && open_stat.file?
      Util.fail!("#{label} open/path identity changed") unless
        [path_stat.dev, path_stat.ino, path_stat.nlink] == [open_stat.dev, open_stat.ino, 1]
      true
    end

    def strict_fsync_io!(io, label)
      io.fsync
      true
    rescue SystemCallError => error
      Util.fail!("#{label} fsync failed: #{error.message}")
    end

    def strict_fsync_directory!(path, label)
      flags = File::RDONLY | File::NOFOLLOW
      File.open(path, flags) do |directory|
        before = File.lstat(path)
        opened = directory.stat
        Util.fail!("#{label} is not a real directory") unless before.directory? && opened.directory?
        Util.fail!("#{label} open/path identity changed") unless
          [before.dev, before.ino] == [opened.dev, opened.ino]
        strict_fsync_io!(directory, label)
        after = File.lstat(path)
        Util.fail!("#{label} changed while syncing") unless
          after.directory? && [after.dev, after.ino] == [before.dev, before.ino]
      end
      true
    rescue Errno::ELOOP, Errno::ENOENT => error
      Util.fail!("#{label} cannot be safely opened: #{error.message}")
    end

    def strict_fsync_regular!(path, label)
      before = File.lstat(path)
      Util.fail!("#{label} is not a regular non-symlink file") unless before.file?
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened = file.stat
        Util.fail!("#{label} changed while opening") unless
          opened.file? && [opened.dev, opened.ino, opened.nlink, opened.size] ==
            [before.dev, before.ino, before.nlink, before.size]
        strict_fsync_io!(file, label)
        after = File.lstat(path)
        Util.fail!("#{label} changed while syncing") unless
          [after.dev, after.ino, after.nlink, after.size] ==
            [before.dev, before.ino, before.nlink, before.size]
      end
      true
    rescue Errno::ELOOP, Errno::ENOENT => error
      Util.fail!("#{label} cannot be safely opened: #{error.message}")
    end

    def durably_sync_tree!(root)
      root_stat = File.lstat(root)
      Util.fail!("staged candidate root is not a real directory") unless root_stat.directory?
      directories = []
      visit = lambda do |path|
        stat = File.lstat(path)
        Util.fail!("staged candidate crosses filesystems: #{path}") unless stat.dev == root_stat.dev
        if stat.directory?
          directories << path
          Dir.each_child(path) { |name| visit.call(File.join(path, name)) }
        elsif stat.file?
          strict_fsync_regular!(path, "staged candidate file #{path}")
        elsif stat.symlink?
          # Symlink target bytes are committed by fsyncing the containing directory. CopyManifest
          # independently constrains the exact five aliases and their targets.
          next
        else
          Util.fail!("staged candidate contains unsupported node: #{path}")
        end
      end
      visit.call(root)
      directories.sort_by { |path| -path.count(File::SEPARATOR) }.each do |directory|
        strict_fsync_directory!(directory, "staged candidate directory #{directory}")
      end
      true
    end

    def durably_sync_staged_candidate!(capsule)
      verify_staged_candidate!(capsule)
      durably_sync_tree!(@staged_app)
      strict_fsync_directory!(File.dirname(@staged_app), "staged candidate parent")
      strict_fsync_regular!(@staged_plist, "staged V90 launch plist")
      strict_fsync_directory!(File.dirname(@staged_plist), "staged launch-plist parent")
      verify_staged_candidate!(capsule)
      true
    end

    def durably_sync_transaction_topology!(
      runtime_root: Pins::RUNTIME_ROOT,
      update_root: Pins::V90_UPDATE_ROOT,
      lock_path: Pins::V90_LOCK
    )
      children = [
        [@post_stop_helpers_root, @post_stop_helpers_root_identity, "staged observer-tools directory"],
        [@route_monitor_module_cache_path, @route_monitor_module_cache_identity,
         "route-monitor module-cache directory"],
        [@route_monitor_compiler_tmp_path, @route_monitor_compiler_tmp_identity,
         "route-monitor compiler TMPDIR"]
      ]
      children.each do |path, identity, label|
        Util.fail!("#{label} identity was not recorded") unless path && identity
        Util.fail!("#{label} escaped the transaction") unless File.dirname(path) == @transaction
        assert_identity!(path, identity, label)
        strict_fsync_directory!(path, label)
      end

      Util.fail!("V90 transaction identity was not recorded") unless @transaction && @transaction_identity
      Util.fail!("V90 transaction escaped the update root") unless File.dirname(@transaction) == update_root
      assert_identity!(@transaction, @transaction_identity, "V90 transaction directory")
      strict_fsync_directory!(@transaction, "V90 transaction directory")

      Util.fail!("V90 update-root identity was not recorded") unless @update_root_identity
      Util.fail!("V90 update root has the wrong parent") unless File.dirname(update_root) == runtime_root
      assert_identity!(update_root, @update_root_identity, "V90 update root")
      strict_fsync_directory!(update_root, "V90 update root")

      Util.fail!("V90 lock identity was not recorded") unless @lock_identity
      Util.fail!("V90 lock has the wrong parent") unless File.dirname(lock_path) == runtime_root
      assert_identity!(lock_path, @lock_identity, "V90 transaction lock")
      strict_fsync_directory!(lock_path, "V90 transaction lock")

      strict_fsync_directory!(runtime_root, "V90 runtime root topology")
      true
    end

    def parse_journal_bytes!(bytes)
      lines = bytes.lines
      Util.fail!("V90 journal header is missing or malformed") unless
        lines.shift == "#{Pins::V90_JOURNAL_HEADER}\n"
      prior = nil
      states = lines.map do |line|
        match = line.match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z STATE ([A-Z0-9_]+)\n\z/)
        Util.fail!("V90 journal contains a torn or malformed record") unless match
        state = match[1]
        Util.fail!("V90 journal contains an invalid state transition #{prior.inspect} -> #{state}") unless
          JOURNAL_TRANSITIONS.fetch(prior, []).include?(state)
        prior = state
        state
      end
      states
    end

    def read_journal_bytes!
      Util.fail!("journal is unavailable") unless @journal
      @journal_io ||= File.open(@journal, File::RDWR | File::APPEND | File::NOFOLLOW)
      @journal_identity ||= file_identity(@journal)
      assert_identity!(@journal, @journal_identity, "V90 journal path")
      assert_open_identity!(@journal, @journal_io, "V90 journal")
      @journal_io.flush
      size = @journal_io.stat.size
      size.zero? ? "" : @journal_io.pread(size, 0)
    end

    def journal_has_exact_terminal_record?(state, anywhere: false)
      states = parse_journal_bytes!(read_journal_bytes!)
      anywhere ? states.include?(state) : states.last == state
    end

    def publish_owned_pointer!(path, contents)
      parent = File.dirname(path)
      basename = File.basename(path)
      temporary = File.join(parent, ".#{basename}.#{Process.pid}.#{SecureRandom.uuid}.tmp")
      temp_identity = nil
      begin
        write_durable(temporary, contents, 0o600, exclusive: true) do |identity|
          temp_identity = identity
          yield identity if block_given?
        end
        assert_identity!(temporary, temp_identity, "temporary pointer")
        Util.fail!("temporary pointer bytes changed") unless File.binread(temporary) == contents
        Util.fail!("pointer destination already exists") if path_present?(path)
        exclusive_rename(temporary, path)
        assert_identity!(path, temp_identity, "published pointer")
        Util.fail!("published pointer bytes changed") unless File.binread(path) == contents
        strict_fsync_directory!(parent, "pointer parent")
        temp_identity
      rescue Exception => original # rubocop:disable Lint/RescueException
        Thread.handle_interrupt(Interrupt => :never) do
          final_owned = temp_identity && identity_matches?(path, temp_identity)
          temp_owned = temp_identity && identity_matches?(temporary, temp_identity)
          if final_owned
            Util.fail!("published pointer bytes are not exact after error") unless File.binread(path) == contents
            strict_fsync_directory!(parent, "pointer parent reconciliation")
            return temp_identity
          end
          if temp_owned
            actual = File.binread(temporary)
            Util.fail!("temporary pointer contains foreign bytes") unless contents.start_with?(actual)
            unlink_exact!(temporary, temp_identity)
          elsif path_present?(temporary)
            Util.fail!("unowned temporary pointer appeared")
          end
          Util.fail!("unowned pointer destination appeared") if path_present?(path)
        end
        raise original
      end
    end

    def file_identity(path)
      stat = File.lstat(path)
      [stat.dev, stat.ino, stat.ftype]
    rescue Errno::ENOENT
      Util.fail!("filesystem identity target is missing: #{path}")
    end

    def attempt_cleanup(errors, label)
      yield
    rescue Exception => error # rubocop:disable Lint/RescueException
      errors << "#{label}: #{error.message}"
      false
    end

    def retain_rollback_safety_failure
      yield
      true
    rescue Failure => error
      @route_monitor_failure ||= error
      false
    end

    def path_present?(path)
      File.lstat(path)
      true
    rescue Errno::ENOENT
      false
    end

    def identity_matches?(path, expected)
      return false unless expected && path && path_present?(path)
      actual = file_identity(path)
      actual[0, expected.length] == expected
    end

    def assert_identity!(path, expected, label)
      Util.fail!("#{label} filesystem identity changed") unless identity_matches?(path, expected)
      true
    end

    def unlink_exact!(path, identity, expected_contents: nil)
      return true unless path_present?(path)
      assert_identity!(path, identity, path)
      stat = File.lstat(path)
      Util.fail!("refusing to unlink non-file #{path}") unless stat.file? || stat.symlink?
      if expected_contents
        Util.fail!("owned file contents changed: #{path}") unless stat.file? && File.binread(path) == expected_contents
      end
      File.unlink(path)
      strict_fsync_directory!(File.dirname(path), "unlink parent")
      true
    end

    def remove_tree_exact!(path, identity)
      allowed = if path == @staged_app
                  File.dirname(Pins::LIVE_APP)
                elsif path == @transaction
                  Pins::V90_UPDATE_ROOT
                end
      Util.fail!("refusing unapproved recursive cleanup target: #{path}") unless allowed && File.dirname(path) == allowed
      assert_identity!(path, identity, path)
      root = File.lstat(path)
      Util.fail!("recursive cleanup root is not a real directory: #{path}") unless root.directory?
      remove_tree_contents!(path, root.dev)
      Dir.rmdir(path)
      strict_fsync_directory!(File.dirname(path), "recursive cleanup parent")
      true
    end

    def remove_tree_contents!(directory, root_device)
      Dir.each_child(directory) do |name|
        Util.fail!("unsafe cleanup entry name") if name.match?(/[\x00-\x1f\x7f]/)
        child = File.join(directory, name)
        stat = File.lstat(child)
        Util.fail!("cleanup tree crosses filesystems: #{child}") unless stat.dev == root_device
        if stat.directory?
          remove_tree_contents!(child, root_device)
          Dir.rmdir(child)
        elsif stat.file? || stat.symlink?
          File.unlink(child)
        else
          Util.fail!("cleanup tree contains unsupported file type: #{child}")
        end
      end
    end

    def remove_empty_directory_exact!(path, identity)
      return true unless path_present?(path)
      assert_identity!(path, identity, path)
      Util.fail!("owned directory is not empty: #{path}") unless File.lstat(path).directory? && Dir.empty?(path)
      Dir.rmdir(path)
      strict_fsync_directory!(File.dirname(path), "directory removal parent")
      true
    end

    def remove_pending_pointer_if_owned!
      return true unless @pending_identity
      unlink_exact!(Pins::V90_PENDING_POINTER, @pending_identity, expected_contents: "#{@transaction}\n")
      @pending_identity = nil
      true
    end

    def remove_lock_if_owned!
      return true unless @lock_identity
      remove_empty_directory_exact!(Pins::V90_LOCK, @lock_identity)
      @lock_identity = nil
      true
    end

    def remove_provisional_active_pointer!
      if @active_pointer_identity
        unlink_exact!(Pins::V90_ACTIVE_POINTER, @active_pointer_identity, expected_contents: "#{@transaction}\n")
        @active_pointer_identity = nil
      elsif path_present?(Pins::V90_ACTIVE_POINTER)
        Util.fail!("unowned V90 active pointer appeared during rollback")
      end
      true
    end

    def archive_candidate_exact!(identity, locations, archive, label)
      Util.fail!("#{label} identity was not recorded") unless identity
      if identity_matches?(archive, identity)
        Util.fail!("#{label} appears in multiple locations") if locations.any? { |path| identity_matches?(path, identity) }
        return true
      end
      matches = locations.compact.select { |path| identity_matches?(path, identity) }
      Util.fail!("#{label} exact object is missing or duplicated") unless matches.length == 1
      Util.fail!("#{label} archive path already exists") if path_present?(archive)
      exclusive_rename(matches.first, archive)
      assert_identity!(archive, identity, "archived #{label}")
      true
    end

    def restore_predecessor_exact!(live, backup, expected_identity, label)
      live_matches = identity_matches?(live, expected_identity)
      backup_matches = identity_matches?(backup, expected_identity)
      Util.fail!("#{label} appears in both live and rollback locations") if live_matches && backup_matches
      if backup_matches
        Util.fail!("#{label} live destination is occupied") if path_present?(live)
        exclusive_rename(backup, live)
      elsif !live_matches
        Util.fail!("#{label} exact object is unavailable for rollback")
      end
      assert_identity!(live, expected_identity, label)
      true
    end

    def restore_display_if_needed!
      return true if current_display_mode == Pins::LIVE_DISPLAY_MODE
      selector = helper_path("select-live-display-mode-v23")
      command!(selector, Pins::LIVE_DISPLAY_MODE)
      true
    end

    def verify_route_monitor_tools!
      Util.exact_file!(
        Pins::ROUTE_MONITOR_SOURCE,
        Pins::ROUTE_MONITOR_SOURCE_SHA256,
        "V90 route-monitor source",
        mode: 0o644,
        owner: Process.euid
      )
      compiler_link = File.lstat(Pins::SWIFTC)
      Util.fail!("pinned swiftc path is not the reviewed symlink") unless
        compiler_link.symlink? && compiler_link.uid == Process.euid && compiler_link.nlink == 1 &&
        File.readlink(Pins::SWIFTC) == Pins::SWIFTC_LINK_TARGET
      compiler = File.realpath(Pins::SWIFTC)
      compiler_stat = Util.regular_file!(compiler, "pinned swiftc executable", mode: 0o755, owner: Process.euid, links: 1)
      Util.fail!("pinned swiftc filesystem identity changed") unless
        [compiler_stat.dev, compiler_stat.ino] == Pins::SWIFTC_IDENTITY
      Util.fail!("pinned swiftc executable digest mismatch") unless Util.sha256(Pins::SWIFTC) == Pins::SWIFTC_SHA256
      sdk_link = File.lstat(Pins::MACOS_SDK)
      Util.fail!("pinned macOS SDK path is not the reviewed symlink") unless
        sdk_link.symlink? && sdk_link.uid == Process.euid && sdk_link.nlink == 1 &&
        File.readlink(Pins::MACOS_SDK) == Pins::MACOS_SDK_LINK_TARGET
      sdk = File.realpath(Pins::MACOS_SDK)
      sdk_stat = Util.directory!(sdk, "pinned macOS SDK", mode: 0o755, owner: Process.euid)
      Util.fail!("pinned macOS SDK filesystem identity changed") unless
        [sdk_stat.dev, sdk_stat.ino] == Pins::MACOS_SDK_IDENTITY
      Util.exact_file!(
        File.join(Pins::MACOS_SDK, "SDKSettings.json"),
        Pins::MACOS_SDK_SETTINGS_SHA256,
        "pinned macOS SDK settings",
        mode: 0o644,
        owner: Process.euid
      )
      true
    rescue Errno::ENOENT
      Util.fail!("pinned route-monitor compiler is missing")
    end

    def start_route_monitor!
      Util.fail!("route monitor already exists") if @route_monitor
      verify_routes!
      verify_route_monitor_tools!
      monitor_source = File.join(@transaction, "sticky-coreaudio-route-monitor.swift")
      binary = File.join(@transaction, "sticky-coreaudio-route-monitor")
      module_cache = File.join(@transaction, "sticky-coreaudio-module-cache")
      compiler_tmp = File.join(@transaction, "sticky-coreaudio-compiler-tmp")
      @route_monitor_module_cache_path = module_cache
      @route_monitor_compiler_tmp_path = compiler_tmp
      event_path = File.join(@transaction, "sticky-coreaudio-route-events.log")
      stdout_path = File.join(@transaction, "sticky-coreaudio-route-monitor.stdout")
      stderr_path = File.join(@transaction, "sticky-coreaudio-route-monitor.stderr")
      write_durable(
        monitor_source,
        File.binread(Pins::ROUTE_MONITOR_SOURCE),
        0o400,
        exclusive: true
      ) { |identity| @route_monitor_source_identity = identity }
      create_owned_directory!(
        module_cache,
        0o700,
        "V90 transaction after route-monitor module-cache creation"
      ) { |identity| @route_monitor_module_cache_identity = identity }
      create_owned_directory!(
        compiler_tmp,
        0o700,
        "V90 transaction after route-monitor TMPDIR creation"
      ) { |identity| @route_monitor_compiler_tmp_identity = identity }
      command_with_environment!(
        {
          "TMPDIR" => compiler_tmp,
          "CLANG_MODULE_CACHE_PATH" => module_cache,
          "SWIFT_MODULECACHE_PATH" => module_cache
        },
        Pins::SWIFTC,
        "-sdk", Pins::MACOS_SDK,
        "-module-cache-path", module_cache,
        monitor_source,
        "-O",
        "-framework", "CoreAudio",
        "-framework", "Foundation",
        "-o", binary
      )
      assert_identity!(module_cache, @route_monitor_module_cache_identity, "route-monitor module cache")
      assert_identity!(compiler_tmp, @route_monitor_compiler_tmp_identity, "route-monitor compiler TMPDIR")
      assert_identity!(monitor_source, @route_monitor_source_identity, "staged route-monitor source")
      Util.exact_file!(
        monitor_source,
        Pins::ROUTE_MONITOR_SOURCE_SHA256,
        "staged route-monitor source",
        mode: 0o400,
        owner: Process.euid,
        links: 1
      )
      File.chmod(0o500, binary)
      binary_identity = file_identity(binary)
      Util.regular_file!(binary, "compiled V90 route monitor", mode: 0o500, owner: Process.euid, links: 1)
      command!("/usr/bin/codesign", "--verify", "--strict", "--verbose=1", binary)
      binary_sha = Util.sha256(binary)
      [event_path, stdout_path, stderr_path].each do |path|
        write_durable(path, "", 0o600, exclusive: true)
      end
      reader, writer = IO.pipe
      stdout_file = File.open(stdout_path, File::WRONLY | File::APPEND)
      stderr_file = File.open(stderr_path, File::WRONLY | File::APPEND)
      pid = Process.spawn(
        binary,
        event_path,
        "BlackHole2ch_UID",
        "BuiltInSpeakerDevice",
        "BuiltInSpeakerDevice",
        in: reader,
        out: stdout_file,
        err: stderr_file,
        close_others: true
      )
      reader.close
      stdout_file.close
      stderr_file.close
      @route_monitor = {
        pid: pid,
        stdin: writer,
        status: nil,
        source: monitor_source,
        source_identity: @route_monitor_source_identity,
        binary: binary,
        binary_identity: binary_identity,
        binary_sha: binary_sha,
        event: event_path,
        event_identity: file_identity(event_path),
        stdout: stdout_path,
        stdout_identity: file_identity(stdout_path),
        stderr: stderr_path,
        stderr_identity: file_identity(stderr_path)
      }
      wait_until!(15, "sticky CoreAudio monitor did not arm") do
        monitor_reap_nonblocking!
        Util.fail!("sticky CoreAudio monitor exited before READY") if @route_monitor[:status]
        File.binread(stdout_path) == "#{Pins::ROUTE_MONITOR_READY}\n"
      end
      route_monitor_clean!
      true
    rescue Exception # rubocop:disable Lint/RescueException
      writer.close if defined?(writer) && writer && !writer.closed?
      reader.close if defined?(reader) && reader && !reader.closed?
      stdout_file.close if defined?(stdout_file) && stdout_file && !stdout_file.closed?
      stderr_file.close if defined?(stderr_file) && stderr_file && !stderr_file.closed?
      raise
    end

    def monitor_reap_nonblocking!
      return @route_monitor[:status] if @route_monitor[:status]
      waited = Process.waitpid2(@route_monitor.fetch(:pid), Process::WNOHANG)
      @route_monitor[:status] = waited.last if waited
      @route_monitor[:status]
    rescue Errno::ECHILD
      @route_monitor[:status] || Util.fail!("sticky CoreAudio monitor wait identity was lost")
    end

    def verify_route_monitor_files!
      {
        source: [0o400, @route_monitor.fetch(:source_identity)],
        binary: [0o500, @route_monitor.fetch(:binary_identity)],
        event: [0o600, @route_monitor.fetch(:event_identity)],
        stdout: [0o600, @route_monitor.fetch(:stdout_identity)],
        stderr: [0o600, @route_monitor.fetch(:stderr_identity)]
      }.each do |name, (mode, identity)|
        path = @route_monitor.fetch(name)
        assert_identity!(path, identity, "route monitor #{name}")
        Util.regular_file!(path, "route monitor #{name}", mode: mode, owner: Process.euid, links: 1)
      end
      Util.fail!("staged route-monitor source bytes changed") unless
        Util.sha256(@route_monitor.fetch(:source)) == Pins::ROUTE_MONITOR_SOURCE_SHA256
      Util.fail!("compiled route-monitor bytes changed") unless
        Util.sha256(@route_monitor.fetch(:binary)) == @route_monitor.fetch(:binary_sha)
      true
    end

    def route_monitor_clean!(allow_failure: false)
      Util.fail!("sticky CoreAudio route monitor is unavailable") unless @route_monitor
      if @route_monitor_stopped
        raise @route_monitor_failure if @route_monitor_failure && !allow_failure
        return @route_monitor_failure.nil?
      end
      verify_route_monitor_files!
      monitor_reap_nonblocking!
      Util.fail!("sticky CoreAudio monitor exited prematurely") if @route_monitor[:status]
      Util.fail!("sticky CoreAudio route event was observed") unless File.zero?(@route_monitor.fetch(:event))
      Util.fail!("sticky CoreAudio monitor stderr is nonempty") unless File.zero?(@route_monitor.fetch(:stderr))
      Util.fail!("sticky CoreAudio monitor readiness proof changed") unless
        File.binread(@route_monitor.fetch(:stdout)) == "#{Pins::ROUTE_MONITOR_READY}\n"
      verify_routes!
      true
    rescue Failure => error
      raise unless allow_failure
      @route_monitor_failure ||= error
      false
    end

    def stop_route_monitor!(allow_failure: false)
      return true unless @route_monitor
      if @route_monitor_stopped
        raise @route_monitor_failure if @route_monitor_failure && !allow_failure
        return @route_monitor_failure.nil?
      end
      begin
        @route_monitor.fetch(:stdin).write("STOP\n")
        @route_monitor.fetch(:stdin).flush
      rescue IOError, Errno::EPIPE => error
        @route_monitor_failure ||= Failure.new("could not stop sticky CoreAudio monitor: #{error.message}")
      ensure
        @route_monitor.fetch(:stdin).close unless @route_monitor.fetch(:stdin).closed?
      end
      begin
        wait_until!(15, "sticky CoreAudio monitor did not stop") do
          !monitor_reap_nonblocking!.nil?
        end
      rescue Failure => error
        @route_monitor_failure ||= error
      end
      unless @route_monitor[:status]
        begin
          Process.kill("TERM", @route_monitor.fetch(:pid))
          wait_until!(3, "sticky CoreAudio monitor ignored TERM") do
            !monitor_reap_nonblocking!.nil?
          end
        rescue Failure, Errno::ESRCH => error
          @route_monitor_failure ||= Failure.new("forced route-monitor teardown failed: #{error.message}")
        end
      end
      unless @route_monitor[:status]
        begin
          Process.kill("KILL", @route_monitor.fetch(:pid))
          wait_until!(3, "sticky CoreAudio monitor ignored KILL") do
            !monitor_reap_nonblocking!.nil?
          end
        rescue Failure, Errno::ESRCH => error
          @route_monitor_failure ||= Failure.new("route-monitor reap failed: #{error.message}")
        end
      end
      begin
        verify_route_monitor_files!
        status = @route_monitor[:status]
        expected_stdout = "#{Pins::ROUTE_MONITOR_READY}\n#{Pins::ROUTE_MONITOR_RESULT}\n"
        Util.fail!("sticky CoreAudio monitor did not exit successfully") unless status&.success?
        Util.fail!("sticky CoreAudio route notifications were observed") unless File.zero?(@route_monitor.fetch(:event))
        Util.fail!("sticky CoreAudio monitor teardown emitted stderr") unless File.zero?(@route_monitor.fetch(:stderr))
        Util.fail!("sticky CoreAudio monitor proof mismatch") unless
          File.binread(@route_monitor.fetch(:stdout)) == expected_stdout
        verify_routes!
      rescue Failure => error
        @route_monitor_failure ||= error
      ensure
        @route_monitor_stopped = true
      end
      raise @route_monitor_failure if @route_monitor_failure && !allow_failure
      @route_monitor_failure.nil?
    end

    def verify_fresh_namespace!
      [Pins::V90_UPDATE_ROOT, Pins::V90_PENDING_POINTER, Pins::V90_ACTIVE_POINTER, Pins::V90_LOCK].each do |path|
        Util.fail!("V90 namespace is not fresh: #{path}") if File.exist?(path) || File.symlink?(path)
      end
      application_names = Dir.children(File.dirname(Pins::LIVE_APP)).grep(/\A\.opensteamer-paired-v90-/)
      launch_names = Dir.children(File.dirname(Pins::LAUNCH_AGENT)).grep(/\A\.org\.example\.opensteamer\.worldwide\.v(?:86|90)-/)
      pointer_temps = Dir.children(Pins::RUNTIME_ROOT).grep(
        /\A\.(?:pending|active)-paired-host-update-v90\.[0-9]+\.[0-9a-f-]+\.tmp\z/
      )
      Util.fail!("V90 staging namespace contains prior artifacts") unless
        application_names.empty? && launch_names.empty? && pointer_temps.empty?
    end

    def verify_origins!
      verify_pointer!(Pins::V89_POINTER, Pins::V89_POINTER_SHA256, Pins::V89_EVIDENCE, Pins::V89_EVIDENCE_IDENTITY, "V89")
      Util.exact_file!(File.join(Pins::V89_EVIDENCE, "journal.log"), Pins::V89_JOURNAL_SHA256, "V89 journal", mode: 0o600, owner: 501)
      Util.exact_file!(File.join(Pins::V89_EVIDENCE, "result.txt"), Pins::V89_RESULT_SHA256, "V89 result", mode: 0o600, owner: 501)
      Util.fail!("V89 terminal state mismatch") unless File.readlines(File.join(Pins::V89_EVIDENCE, "journal.log"), chomp: true).last == Pins::V89_TERMINAL
      Util.fail!("V89 result mismatch") unless File.binread(File.join(Pins::V89_EVIDENCE, "result.txt")) == Pins::V89_RESULT

      verify_pointer!(Pins::V86_POINTER, Pins::V86_POINTER_SHA256, Pins::V86_EVIDENCE, Pins::V86_EVIDENCE_IDENTITY, "V86")
      exact = {
        "journal.log" => Pins::V86_JOURNAL_SHA256,
        "result.txt" => Pins::V86_RESULT_SHA256,
        "provenance.txt" => Pins::V86_PROVENANCE_SHA256,
        "v86-candidate-app-manifest.txt" => Pins::V86_APP_MANIFEST_SHA256,
        "cutover-routes-before.txt" => Pins::V86_ROUTE_SHA256
      }
      exact.each { |relative, sha| Util.exact_file!(File.join(Pins::V86_EVIDENCE, relative), sha, "V86 #{relative}", owner: 501) }
      journal = File.readlines(File.join(Pins::V86_EVIDENCE, "journal.log"), chomp: true)
      Util.fail!("V86 terminal state mismatch") unless journal.last.end_with?(Pins::V86_TERMINAL)
      provenance = File.binread(File.join(Pins::V86_EVIDENCE, "provenance.txt"))
      Util.fail!("V86 source identity mismatch") unless provenance.include?(Pins::V86_SOURCE_COMMIT) && provenance.include?(Pins::V86_SOURCE_TREE)
      Pins::V86_HELPERS.each do |relative, sha|
        path = File.join(Pins::V86_EVIDENCE, relative)
        Util.exact_file!(path, sha, "V86 helper #{relative}", mode: 0o500, owner: 501)
      end
      true
    end

    def verify_pointer!(path, sha, evidence, identity, label)
      Util.exact_file!(path, sha, "#{label} pointer", mode: 0o600, owner: 501)
      Util.fail!("#{label} pointer targets unpinned evidence") unless File.binread(path) == "#{evidence}\n"
      stat = Util.directory!(evidence, "#{label} evidence", mode: 0o700, owner: 501)
      Util.fail!("#{label} evidence identity changed") unless [stat.dev, stat.ino] == identity
    end

    def verify_capsule_code!(capsule)
      @capsule_root = capsule.root
      @candidate_executable_sha = capsule.payload.fetch("candidateExecutableSHA256")
      @candidate_framework_sha = capsule.payload.fetch("candidateMediaFrameworkExecutableSHA256")
      @candidate_info_sha = capsule.payload.fetch("candidateInfoPlistSHA256")
      @candidate_plist_sha = capsule.payload.fetch("candidateLaunchPlistSHA256")
      @candidate_cdhash = capsule.identity.fetch("executableCDHash")
      @capsule_candidate_copy_manifest = capsule.paths.fetch(:candidate_copy_manifest)
      @reference_path = capsule.paths.fetch(:reference)
      @payload_sha = Util.sha256(File.join(capsule.root, "v90-deployment-payload-manifest.json"))
      @handoff_sha = capsule.payload.fetch("handoffSHA256")
      verifier = File.join(capsule.root, "source/macOS/scripts/verify-mac-host-bundle.sh")
      command_with_environment!({ "OPENSTEAMER_EXPECTED_ARCHITECTURES" => "arm64" }, verifier, capsule.paths.fetch(:candidate), Pins::TEAM_ID, capsule.paths.fetch(:reference))
      true
    end

    def stage_post_stop_evidence!(capsule)
      readiness_source = File.join(capsule.root, "source/macOS/scripts/verify-v90-secondary-viewer-readiness.sh")
      Util.regular_file!(readiness_source, "V90 readiness observer", mode: 0o500, owner: Process.euid, links: 1)
      @post_stop_readiness_sha = Util.sha256(readiness_source)
      @post_stop_readiness = File.join(@transaction, "verify-v90-secondary-viewer-readiness.sh")
      write_durable(
        @post_stop_readiness,
        File.binread(readiness_source),
        0o500,
        exclusive: true
      ) { |identity| @post_stop_readiness_identity = identity }

      @post_stop_copy_manifest = File.join(@transaction, "v90-candidate-app-copy-manifest.txt")
      write_durable(
        @post_stop_copy_manifest,
        File.binread(capsule.paths.fetch(:candidate_copy_manifest)),
        0o600,
        exclusive: true
      ) { |identity| @post_stop_copy_manifest_identity = identity }

      @post_stop_reference = File.join(@transaction, "approved-predecessor-reference-CaptureServer")
      write_durable(
        @post_stop_reference,
        File.binread(capsule.paths.fetch(:reference)),
        0o755,
        exclusive: true
      ) { |identity| @post_stop_reference_identity = identity }
      helpers_root = File.join(@transaction, "pinned-v86-observer-tools")
      @post_stop_helpers_root = helpers_root
      create_owned_directory!(
        helpers_root,
        0o700,
        "V90 transaction after observer-tools creation"
      ) { |identity| @post_stop_helpers_root_identity = identity }
      @post_stop_helpers = {}
      Pins::V86_HELPERS.each do |name, digest|
        source = File.join(Pins::V86_EVIDENCE, name)
        destination = File.join(helpers_root, name)
        identity = nil
        write_durable(destination, File.binread(source), 0o500, exclusive: true) do |created_identity|
          identity = created_identity
        end
        @post_stop_helpers[name] = { path: destination, identity: identity, digest: digest }
      end
      verify_post_stop_evidence!(capsule)
      true
    end

    def verify_post_stop_evidence!(capsule)
      readiness_source = File.join(capsule.root, "source/macOS/scripts/verify-v90-secondary-viewer-readiness.sh")
      Util.exact_file!(
        readiness_source,
        @post_stop_readiness_sha,
        "capsule V90 readiness observer",
        mode: 0o500,
        owner: Process.euid
      )
      assert_identity!(@post_stop_readiness, @post_stop_readiness_identity, "staged V90 readiness observer")
      Util.exact_file!(
        @post_stop_readiness,
        @post_stop_readiness_sha,
        "staged V90 readiness observer",
        mode: 0o500,
        owner: Process.euid
      )
      copy_sha = capsule.payload.fetch("candidateAppCopyManifestSHA256")
      Util.exact_file!(
        capsule.paths.fetch(:candidate_copy_manifest),
        copy_sha,
        "capsule candidate copy manifest",
        mode: 0o600,
        owner: Process.euid
      )
      assert_identity!(@post_stop_copy_manifest, @post_stop_copy_manifest_identity, "staged candidate copy manifest")
      Util.exact_file!(
        @post_stop_copy_manifest,
        copy_sha,
        "staged candidate copy manifest",
        mode: 0o600,
        owner: Process.euid
      )
      reference_sha = capsule.payload.fetch("designatedRequirementReferenceSHA256")
      Util.exact_file!(
        capsule.paths.fetch(:reference),
        reference_sha,
        "capsule predecessor reference",
        mode: 0o755,
        owner: Process.euid
      )
      assert_identity!(@post_stop_reference, @post_stop_reference_identity, "staged predecessor reference")
      Util.exact_file!(
        @post_stop_reference,
        reference_sha,
        "staged predecessor reference",
        mode: 0o755,
        owner: Process.euid
      )
      PredecessorReferenceFingerprint.verify!(
        capsule.paths.fetch(:reference),
        label: "capsule predecessor reference"
      )
      PredecessorReferenceFingerprint.verify!(
        @post_stop_reference,
        label: "staged predecessor reference"
      )
      Pins::V86_HELPERS.each do |name, digest|
        source = File.join(Pins::V86_EVIDENCE, name)
        Util.exact_file!(source, digest, "V86 helper #{name}", mode: 0o500, owner: Process.euid)
        staged = @post_stop_helpers.fetch(name)
        assert_identity!(staged.fetch(:path), staged.fetch(:identity), "staged V86 helper #{name}")
        Util.exact_file!(
          staged.fetch(:path),
          digest,
          "staged V86 helper #{name}",
          mode: 0o500,
          owner: Process.euid
        )
      end
      true
    end

    def helper_path(name)
      staged = @post_stop_helpers && @post_stop_helpers[name]
      staged ? staged.fetch(:path) : File.join(Pins::V86_EVIDENCE, name)
    end

    def verify_live_v86!(prior_session)
      verify_installed_v86_bytes!
      pid, runs = launch_identity
      Util.fail!("live launch identity differs from pinned V86") unless [pid, runs] == [Pins::LIVE_PID, 1]
      verify_dynamic_process!(pid, expected_start: Pins::LIVE_PROCESS_START, expected_cdhash: Pins::V86_CDHASH)
      Util.fail!("live lock differs from pinned V86 generation") unless
        strict_lock_record(require_pinned_identity: true) == { pid: Pins::LIVE_PID, nonce: Pins::LIVE_NONCE }
      verify_routes!
      Util.fail!("live display selection differs from pinned V86") unless current_display_mode == Pins::LIVE_DISPLAY_MODE
      SessionFence.observe!(Pins::LAUNCH_STDOUT, Pins::LIVE_PID, Pins::LIVE_NONCE, prior: prior_session)
    end

    def verify_installed_v86_bytes!
      Pins::LIVE_V86_IDENTITIES.each do |path, expected|
        stat = File.lstat(path)
        Util.fail!("live V86 filesystem identity changed: #{path}") unless [stat.dev, stat.ino] == expected
      end
      launch_stat = File.lstat(Pins::LAUNCH_AGENT)
      Util.fail!("live V86 launch-plist identity changed") unless [launch_stat.dev, launch_stat.ino] == Pins::LAUNCH_AGENT_V86_IDENTITY
      Util.exact_file!(Pins::LIVE_EXECUTABLE, Pins::V86_EXECUTABLE_SHA256, "live V86 executable", mode: 0o755, owner: 501)
      Util.exact_file!(Pins::LIVE_FRAMEWORK, Pins::V86_FRAMEWORK_SHA256, "live V86 framework", mode: 0o755, owner: 501)
      Util.exact_file!(Pins::LIVE_INFO_PLIST, Pins::V86_INFO_PLIST_SHA256, "live V86 Info.plist", mode: 0o644, owner: 501)
      Util.exact_file!(Pins::LAUNCH_AGENT, Pins::LAUNCH_AGENT_SHA256, "live V86 launch plist", mode: 0o600, owner: 501)
      LaunchContract.verify!(Pins::LAUNCH_AGENT)
      verifier = helper_path("verify-media-v1-host-bundle.sh")
      reference = @post_stop_reference || @reference_path
      command_with_environment!(
        { "OPENSTEAMER_EXPECTED_ARCHITECTURES" => "arm64" },
        verifier,
        "--installed-runtime",
        "--media-integration-v1",
        Pins::LIVE_APP,
        Pins::TEAM_ID,
        reference
      ) if reference
      metadata = combined_capture!("/usr/bin/codesign", "--display", "--verbose=4", Pins::LIVE_EXECUTABLE)
      Util.fail!("live V86 code identifier mismatch") unless
        Util.exact_prefixed_values(metadata, "Identifier=") == [Pins::EXECUTABLE_IDENTIFIER]
      Util.fail!("live V86 TeamIdentifier mismatch") unless
        Util.exact_prefixed_values(metadata, "TeamIdentifier=") == [Pins::TEAM_ID]
      cdhashes = Util.exact_prefixed_values(metadata, "CDHash=")
      Util.fail!("live V86 CDHash mismatch") unless
        cdhashes.length == 1 && cdhashes.first.match?(/\A[0-9A-Fa-f]+\z/n) &&
          cdhashes.first.downcase == Pins::V86_CDHASH
      requirement_output = combined_capture!("/usr/bin/codesign", "--display", "--requirements", "-", Pins::LIVE_EXECUTABLE)
      requirement = requirement_output.b.lines.map { |line| line.strip.sub(/\A# /n, "") }
                                      .find { |line| line.start_with?("designated =>") }
      Util.fail!("live V86 designated requirement mismatch") unless requirement == "designated => #{Pins::V86_DESIGNATED_REQUIREMENT}"
      true
    end

    def verify_staged_candidate!(capsule)
      staged_executable = File.join(@staged_app, "Contents/MacOS/CaptureServer")
      staged_framework = File.join(@staged_app, "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")
      staged_info = File.join(@staged_app, "Contents/Info.plist")
      Util.exact_file!(staged_executable, @candidate_executable_sha, "staged V90 executable", mode: 0o755, owner: Process.euid)
      Util.exact_file!(staged_framework, @candidate_framework_sha, "staged V90 framework", mode: 0o755, owner: Process.euid)
      Util.exact_file!(staged_info, @candidate_info_sha, "staged V90 Info.plist", mode: 0o644, owner: Process.euid)
      Util.exact_file!(@staged_plist, @candidate_plist_sha, "staged V90 launch plist", mode: 0o600, owner: Process.euid)
      CopyManifest.new(@staged_app).verify!(capsule.paths.fetch(:candidate_copy_manifest))
      LaunchContract.verify!(@staged_plist)
      verifier = File.join(capsule.root, "source/macOS/scripts/verify-mac-host-bundle.sh")
      command_with_environment!({ "OPENSTEAMER_EXPECTED_ARCHITECTURES" => "arm64" }, verifier, @staged_app, Pins::TEAM_ID, capsule.paths.fetch(:reference))
    end

    def verify_installed_candidate_bytes!
      Util.exact_file!(Pins::LIVE_EXECUTABLE, @candidate_executable_sha, "installed V90 executable", mode: 0o755, owner: 501)
      Util.exact_file!(Pins::LIVE_FRAMEWORK, @candidate_framework_sha, "installed V90 framework", mode: 0o755, owner: 501)
      Util.exact_file!(Pins::LIVE_INFO_PLIST, @candidate_info_sha, "installed V90 Info.plist", mode: 0o644, owner: 501)
      Util.exact_file!(Pins::LAUNCH_AGENT, @candidate_plist_sha, "installed V90 launch plist", mode: 0o600, owner: 501)
      CopyManifest.new(Pins::LIVE_APP).verify!(@post_stop_copy_manifest)
      LaunchContract.verify!(Pins::LAUNCH_AGENT)
      true
    end

    def launch_identity
      output = Util.capture!("/bin/launchctl", "print", Pins::LAUNCH_LABEL)
      pids = output.scan(/^\s*pid = ([1-9][0-9]*)\s*$/).flatten.map(&:to_i)
      runs = output.scan(/^\s*runs = ([1-9][0-9]*)\s*$/).flatten.map(&:to_i)
      Util.fail!("launch state has ambiguous pid/runs") unless pids.length == 1 && runs.length == 1
      [pids.first, runs.first]
    end

    def verify_dynamic_process!(pid, expected_start: nil, expected_cdhash:)
      process_set = Util.capture!("/usr/bin/pgrep", "-x", "CaptureServer").strip
      Util.fail!("unexpected CaptureServer process set") unless process_set == pid.to_s
      command = Util.capture!("/bin/ps", "-p", pid.to_s, "-ww", "-o", "command=").strip
      Util.fail!("host command differs from ten-argument contract") unless command == Pins::LAUNCH_ARGUMENTS.join(" ")
      start = Util.capture!("/bin/ps", "-p", pid.to_s, "-o", "lstart=").split.join(" ")
      Util.fail!("host process-start identity mismatch") if expected_start && start != expected_start
      command!("/usr/bin/codesign", "--verify", "--strict", "--verbose=1", "+#{pid}")
      metadata_stdout, metadata_stderr, metadata_status = Open3.capture3(
        "/usr/bin/codesign", "--display", "--verbose=4", "+#{pid}"
      )
      Util.fail!("could not read live process code identity") unless metadata_status.success?
      metadata = metadata_stdout + metadata_stderr
      identifier = metadata.lines.grep(/\AIdentifier=/).map { |line| line.split("=", 2).last.strip }
      team = metadata.lines.grep(/\ATeamIdentifier=/).map { |line| line.split("=", 2).last.strip }
      cdhash = metadata.lines.grep(/\ACDHash=/).map { |line| line.split("=", 2).last.strip.downcase }
      Util.fail!("live process code identity is ambiguous") unless identifier == [Pins::EXECUTABLE_IDENTIFIER] && team == [Pins::TEAM_ID] && cdhash == [expected_cdhash]
      text = Util.capture!("/usr/sbin/lsof", "-a", "-p", pid.to_s, "-d", "txt", "-Fn")
      Util.fail!("live process text mapping differs") unless text.lines.map(&:chomp).count("n#{Pins::LIVE_EXECUTABLE}") == 1
      mappings = Util.capture!("/usr/sbin/lsof", "-a", "-p", pid.to_s, "-Fn")
      Util.fail!("live process lacks pinned media-framework mapping") unless mappings.lines.map(&:chomp).include?("n#{Pins::LIVE_FRAMEWORK}")
      true
    end

    def strict_lock_record(require_pinned_identity: false)
      directory_stat = File.lstat(File.dirname(Pins::LIVE_LOCK_PATH))
      Util.fail!("host lock-directory identity changed") unless [directory_stat.dev, directory_stat.ino] == Pins::LIVE_LOCK_DIRECTORY_IDENTITY
      Util.regular_file!(Pins::LIVE_LOCK_PATH, "host generation lock", mode: 0o600, owner: 501, links: 1)
      lock_stat = File.lstat(Pins::LIVE_LOCK_PATH)
      if require_pinned_identity
        Util.fail!("host lock identity changed") unless [lock_stat.dev, lock_stat.ino] == Pins::LIVE_LOCK_IDENTITY
      end
      match = File.binread(Pins::LIVE_LOCK_PATH).match(/\AOPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=([1-9][0-9]*)\nnonce=([0-9a-f]{64})\n\z/)
      Util.fail!("host generation lock is malformed") unless match
      { pid: match[1].to_i, nonce: match[2] }
    end

    def verify_routes!
      tool = helper_path("SwitchAudioSource")
      Pins::ROUTES.each do |type, expected|
        actual = Util.capture!(tool, "-c", "-t", type, "-f", "json").strip
        Util.fail!("#{type} audio route changed") unless actual == expected
      end
      true
    end

    def readiness_generation!
      output = Util.capture!(@post_stop_readiness, Pins::LIVE_EXECUTABLE, @candidate_executable_sha)
      pattern = /\AV90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK candidateSHA256=#{Regexp.escape(@candidate_executable_sha)} pid=#{@new_pid} managerGeneration=(0|[1-9][0-9]*) probes=2\n?\z/
      match = output.match(pattern)
      Util.fail!("V90 secondary-viewer readiness proof is malformed or mismatched") unless match
      Integer(match[1], 10)
    end

    def observe_candidate_session!(prior)
      SessionFence.observe!(Pins::LAUNCH_STDOUT, @new_pid, @new_nonce, prior: prior)
    end

    def establish_candidate_stability_baseline!
      pid, runs = launch_identity
      Util.fail!("V90 launch identity is not a fresh single run") unless runs == 1 && pid != Pins::LIVE_PID
      @new_pid = pid
      record = strict_lock_record
      Util.fail!("V90 generation lock is not fresh") unless
        record.fetch(:pid) == pid && record.fetch(:nonce) != Pins::LIVE_NONCE
      @new_nonce = record.fetch(:nonce)
      verify_dynamic_process!(pid, expected_cdhash: @candidate_cdhash)
      verify_installed_candidate_bytes!
      @candidate_manager_generation = readiness_generation!
      Util.fail!("V90 display mode did not settle") unless current_display_mode == Pins::LIVE_DISPLAY_MODE
      @candidate_session = observe_candidate_session!(@session)
      verify_routes!
      route_monitor_clean!
      true
    end

    def verify_candidate_stability_sample!
      Util.fail!("candidate stability baseline is unavailable") unless
        @new_pid && @new_nonce && !@candidate_manager_generation.nil? && @candidate_session
      Util.fail!("V90 launch identity changed during stability proof") unless
        launch_identity == [@new_pid, 1]
      Util.fail!("V90 host generation changed during stability proof") unless
        strict_lock_record == { pid: @new_pid, nonce: @new_nonce }
      verify_dynamic_process!(@new_pid, expected_cdhash: @candidate_cdhash)
      verify_installed_candidate_bytes!
      Util.fail!("secondary-viewer manager generation changed during stability proof") unless
        readiness_generation! == @candidate_manager_generation
      Util.fail!("V90 display mode changed during stability proof") unless
        current_display_mode == Pins::LIVE_DISPLAY_MODE
      @candidate_session = observe_candidate_session!(@candidate_session)
      verify_routes!
      route_monitor_clean!
      true
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def stability_sleep(seconds)
      sleep(seconds)
    end

    def run_candidate_stability_window!(duration: 31)
      started = monotonic_now
      1.upto(duration) do |second|
        deadline = started + second
        remaining = deadline - monotonic_now
        stability_sleep(remaining) if remaining.positive?
        Util.fail!("monotonic stability clock did not reach second #{second}") if monotonic_now < deadline
        verify_candidate_stability_sample!
      end
      Util.fail!("candidate stability window was shorter than #{duration} seconds") if
        monotonic_now < started + duration
      true
    end

    def current_display_mode
      tool = helper_path("verify-live-display-topology-v23")
      topology = Util.capture!(tool, "--opensteamer-any")
      lines = topology.lines.map(&:chomp)
      Util.fail!("display topology is malformed") unless lines.length >= 3 && lines.first.match?(/\Adisplay=[1-9][0-9]* online=1 main=1 vendor=6f73 product=1718\z/)
      current = lines[1][/\Acurrent=(.+)\z/, 1]
      Util.fail!("display topology lacks current selection") unless current && lines.drop(2).count(current) == 1
      current
    end

    def runtime_absent?
      _out, _err, status = Open3.capture3("/bin/launchctl", "print", Pins::LAUNCH_LABEL)
      return false if status.success?
      pids, = Open3.capture3("/usr/bin/pgrep", "-x", "CaptureServer")
      return false unless pids.strip.empty?
      lock_probe = helper_path("probe-worldwide-lock-v23")
      topology = helper_path("verify-live-display-topology-v23")
      _a, _b, lock_status = Open3.capture3(lock_probe, "--unowned")
      _c, _d, topology_status = Open3.capture3(topology, "--headless")
      lock_status.success? && topology_status.success?
    end

    def ensure_same_filesystem!(staged, destination)
      source_dev = File.lstat(staged).dev
      destination_dev = File.lstat(destination).dev
      Util.fail!("transaction cannot use same-filesystem rename") unless source_dev == destination_dev
    end

    def exclusive_rename(source, destination)
      Util.fail!("rename source is missing") unless File.exist?(source) || File.symlink?(source)
      Util.fail!("rename destination already exists") if File.exist?(destination) || File.symlink?(destination)
      Util.fail!("rename crosses filesystems") unless File.lstat(source).dev == File.lstat(File.dirname(destination)).dev
      result = DarwinRename.renamex_np(source, destination, 0x00000004) # RENAME_EXCL
      Util.fail!("exclusive rename failed for #{source}") unless result.zero?
      strict_fsync_directory!(File.dirname(destination), "exclusive rename parent")
    end

    def wait_until!(seconds, diagnostic)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return true if yield
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      Util.fail!(diagnostic)
    end

    def command!(*args)
      Util.capture!(*args)
      true
    end

    def command_with_environment!(environment, *args)
      stdout, stderr, status = Open3.capture3(environment, *args)
      Util.fail!("command failed: #{args.shelljoin}: #{stderr.strip}") unless status.success?
      stdout
    end

    def combined_capture!(*args)
      stdout, stderr, status = Open3.capture3(*args)
      Util.fail!("command failed: #{args.shelljoin}: #{stderr.strip}") unless status.success?
      stdout.b + stderr.b
    end

    def write_durable(path, contents, mode, exclusive:)
      flags = File::WRONLY | File::CREAT | File::NOFOLLOW
      flags |= File::EXCL if exclusive
      Thread.handle_interrupt(Interrupt => :never) do
        File.open(path, flags, mode) do |file|
          after_file_create_before_identity!(path)
          stat = file.stat
          identity = [stat.dev, stat.ino, stat.ftype]
          yield identity if block_given?
          set_durable_mode!(file, mode, "durable file #{path}")
          write_all!(file, contents, "durable file #{path}")
          file.flush
          strict_fsync_io!(file, "durable file #{path}")
          assert_open_identity!(path, file, "durable file #{path}")
          Util.fail!("durable file mode differs: #{path}") unless
            (file.stat.mode & 0o7777) == mode
        end
      end
      strict_fsync_directory!(File.dirname(path), "durable file parent")
      true
    rescue Errno::ELOOP => error
      Util.fail!("durable file path is a symlink: #{path}: #{error.message}")
    end

  end

  class FakeCapsule
    attr_reader :verify_count

    def initialize(fail_verify_at: nil)
      @verify_count = 0
      @fail_verify_at = fail_verify_at
    end

    def verify!
      @verify_count += 1
      raise Failure, "capsule drift" if @fail_verify_at == @verify_count
      true
    end
  end

  class FakeHost
    attr_reader :events, :states, :active_pointer

    def initialize(fail_at: nil, namespace_fresh: true)
      @events = []
      @states = []
      @fail_at = fail_at
      @namespace_fresh = namespace_fresh
      @active_pointer = false
      @pending_pointer = false
      @transaction_lock = false
      @prepared_artifacts = false
      @route_safety_failure = false
      @committed_unverified = false
    end

    def preflight!(_capsule)
      observe(:preflight)
      raise Failure, "V90 namespace is not fresh" unless @namespace_fresh
    end

    def prepare!(_capsule)
      mutate(:prepare)
      @pending_pointer = true
      @transaction_lock = true
      @prepared_artifacts = true
      journal!("BEGUN")
      observe(:initial_durability_barrier)
      observe(:initial_topology_barrier)
      journal!("INPUTS_VERIFIED")
    end

    def revalidate_immediately_before_stop!(_capsule)
      observe(:revalidate)
      observe(:final_durability_barrier)
      observe(:final_topology_barrier)
    end

    def stop_predecessor!
      mutate(:stop_predecessor)
      journal!("V86_STOPPED")
    end

    def hold_predecessor!
      mutate(:rename_v86_app_to_hold)
      mutate(:rename_v86_plist_to_hold)
      journal!("V86_HELD")
    end

    def publish_candidate!
      mutate(:rename_v90_app_to_live)
      mutate(:rename_v90_plist_to_live)
      journal!("V90_PUBLISHED")
    end

    def start_candidate!
      mutate(:start_candidate)
      journal!("V90_BOOTSTRAPPED")
    end

    def verify_candidate_ready!
      observe(:verify_candidate_ready)
    end

    def prepare_irreversible_commit!
      mutate(:write_pending_result)
      mutate(:publish_active_pointer)
      @active_pointer = true
      mutate(:unlink_pending_pointer)
      @pending_pointer = false
      mutate(:remove_transaction_lock)
      @transaction_lock = false
      observe(:pre_irreversible_safety_replay)
    end

    def finalize_postcommit!
      @route_safety_failure = true if @fail_at == :stop_route_monitor
      mutate(:stop_route_monitor)
      observe(:final_route_readback)
      mutate(:write_final_result)
    end

    def abort_before_stop!
      mutate(:abort_before_stop)
      @active_pointer = false
      @pending_pointer = false
      @transaction_lock = false
      @prepared_artifacts = false
    end

    def journal!(state)
      if @fail_at == :journal_stop_after_persist && state == "STOP_INTENT"
        @events << [:mutate, :"journal:#{state}"]
        @states << state
        raise JournalPersistenceUnverified, "injected uncertain durable #{state}"
      end
      if @fail_at == :journal_irreversible_after_persist && state == "V90_COMMIT_IRREVERSIBLE"
        @events << [:mutate, :"journal:#{state}"]
        @states << state
        raise Failure, "injected durable #{state} acknowledgement failure"
      end
      mutate("journal:#{state}".to_sym)
      @states << state
    end

    def irreversible_on_disk?
      @states.include?("V90_COMMIT_IRREVERSIBLE")
    end

    def stop_intent_on_disk?
      @states.include?("STOP_INTENT")
    end

    def record_committed_unverified!(_original)
      mutate(:record_committed_unverified)
      @committed_unverified = true
      @states << "COMMITTED_V90_UNVERIFIED" unless @states.last == "COMMITTED_V90_UNVERIFIED"
      true
    end

    def rollback_exact_v86!
      %w[ROLLBACK_STARTED V90_STOPPED FAILED_V90_ARCHIVED V86_RESTORED V86_BOOTSTRAPPED].each do |state|
        journal!(state)
      end
      mutate(:rollback_exact_v86)
      @active_pointer = false
      @pending_pointer = false
      @transaction_lock = false
      @prepared_artifacts = false
      raise Failure, "retained route-monitor safety failure" if @route_safety_failure
      journal!("ROLLED_BACK_EXACT_V86")
    end

    def rollback_clean?
      !@active_pointer && !@pending_pointer && !@transaction_lock && !@prepared_artifacts
    end

    def commit_clean?
      @active_pointer && !@pending_pointer && !@transaction_lock && @prepared_artifacts
    end

    def committed_unverified?
      @committed_unverified && @active_pointer && !@pending_pointer && !@transaction_lock
    end

    def abort_clean?
      !@active_pointer && !@pending_pointer && !@transaction_lock && !@prepared_artifacts
    end

    private

    def observe(event)
      @events << [:observe, event]
      raise Failure, "injected #{event}" if @fail_at == event
      true
    end

    def mutate(event)
      @events << [:mutate, event]
      raise Failure, "injected #{event}" if @fail_at == event
      true
    end
  end

  module SelfTest
    extend self

    def assert(label)
      raise Failure, "self-test failed: #{label}" unless yield
    end

    def expect_failure(label)
      begin
        yield
      rescue Failure
        return true
      end
      raise Failure, "self-test failed: #{label} unexpectedly succeeded"
    end

    def expect_exception(label)
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        return true
      end
      raise Failure, "self-test failed: #{label} unexpectedly succeeded"
    end

    def create_copy_manifest_fixture(root)
      framework = File.join(root, "Contents/Frameworks/LiveKitWebRTC.framework")
      version = File.join(framework, "Versions/A")
      ["Headers", "Modules", "Resources"].each do |name|
        FileUtils.mkdir_p(File.join(version, name), mode: 0o755)
      end
      executable = File.join(version, "LiveKitWebRTC")
      File.binwrite(executable, "fixture-framework-binary\n")
      File.chmod(0o755, executable)
      {
        "Headers" => "Versions/Current/Headers",
        "LiveKitWebRTC" => "Versions/Current/LiveKitWebRTC",
        "Modules" => "Versions/Current/Modules",
        "Resources" => "Versions/Current/Resources"
      }.each do |name, target|
        File.symlink(target, File.join(framework, name))
      end
      File.symlink("A", File.join(framework, "Versions/Current"))
      true
    end

    def verify_copy_stable_manifest_fixture!
      source_parent = Dir.mktmpdir("v90-copy-source-", "/Volumes/t7")
      destination_parent = Dir.mktmpdir("v90-copy-destination-")
      source = File.join(source_parent, "Fixture.app")
      destination = File.join(destination_parent, "Fixture.app")
      Dir.mkdir(source, 0o755)
      File.chmod(0o755, source)
      create_copy_manifest_fixture(source)
      source_manifest, source_aliases = CopyManifest.new(source).render
      FileUtils.cp_r(source, destination, preserve: true)
      destination_manifest, destination_aliases = CopyManifest.new(destination).render
      assert("copy fixture crosses filesystems") { File.lstat(source).dev != File.lstat(destination).dev }
      assert("copy-stable manifest ignores copy-variant directory metadata") do
        source_manifest == destination_manifest && source_aliases == destination_aliases
      end
      manifest = Tempfile.new("v90-copy-manifest")
      begin
        manifest.write(source_manifest)
        manifest.flush
        CopyManifest.new(source).verify!(manifest.path)
        CopyManifest.new(destination).verify!(manifest.path)
        File.open(File.join(destination, "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC"), "ab") do |file|
          file.write("drift")
        end
        expect_failure("copy-stable manifest byte drift") do
          CopyManifest.new(destination).verify!(manifest.path)
        end
      ensure
        manifest.close!
      end
    ensure
      FileUtils.remove_entry(source_parent) if source_parent && File.exist?(source_parent)
      FileUtils.remove_entry(destination_parent) if destination_parent && File.exist?(destination_parent)
    end

    def verify_real_journal_state_machine!
      Dir.mktmpdir("v90-journal-self-test-") do |root|
        success_host = RealHost.new
        success_journal = File.join(root, "success.log")
        File.binwrite(success_journal, "#{Pins::V90_JOURNAL_HEADER}\n")
        success_host.instance_variable_set(:@journal, success_journal)
        RealHost::SUCCESS_STATES.each { |state| success_host.journal!(state) }
        expect_failure("journal rejects states after committed terminal") do
          success_host.journal!("ROLLBACK_STARTED")
        end

        rollback_origins = %w[
          STOP_INTENT INSTALL_HOLDS_VERIFIED V86_STOPPED V86_HELD V90_PUBLISHED
          V90_BOOTSTRAPPED READY_VERIFIED COMMIT_INTENT
        ]
        rollback_origins.each_with_index do |origin, index|
          host = RealHost.new
          journal = File.join(root, "rollback-#{index}.log")
          File.binwrite(journal, "#{Pins::V90_JOURNAL_HEADER}\n")
          host.instance_variable_set(:@journal, journal)
          RealHost::SUCCESS_STATES.each do |state|
            host.journal!(state)
            break if state == origin
          end
          RealHost::ROLLBACK_STATES.each { |state| host.journal!(state) }
          states = File.readlines(journal, chomp: true).drop(1).map { |line| line.split.last }
          assert("real rollback journal terminal #{origin}") do
            states.last(RealHost::ROLLBACK_STATES.length) == RealHost::ROLLBACK_STATES
          end
        end
      end
    end

    def verify_predecessor_signature_layout_fixture!
      data_offset = 56
      data_size = 8
      header = [
        PredecessorReferenceFingerprint::MH_MAGIC_64,
        PredecessorReferenceFingerprint::CPU_TYPE_ARM64,
        0,
        2,
        2,
        24,
        0,
        0
      ].pack("V8")
      ordinary_command = [0x2, 8].pack("V2")
      signature_command = [
        PredecessorReferenceFingerprint::LC_CODE_SIGNATURE,
        16,
        data_offset,
        data_size
      ].pack("V4")
      valid = header + ordinary_command + signature_command + ("s" * data_size)
      assert("predecessor Mach-O signature layout parses") do
        PredecessorReferenceFingerprint.signature_layout(valid) == [data_offset, data_size]
      end

      mutations = {
        "truncated header" => valid.byteslice(0, 31),
        "wrong magic" => ([0, PredecessorReferenceFingerprint::CPU_TYPE_ARM64] +
          [0, 2, 2, 24, 0, 0]).pack("V8") + valid.byteslice(32..),
        "wrong architecture" => ([PredecessorReferenceFingerprint::MH_MAGIC_64, 7] +
          [0, 2, 2, 24, 0, 0]).pack("V8") + valid.byteslice(32..),
        "missing signature" => ([
          PredecessorReferenceFingerprint::MH_MAGIC_64,
          PredecessorReferenceFingerprint::CPU_TYPE_ARM64,
          0, 2, 1, 8, 0, 0
        ].pack("V8") + ordinary_command + ("s" * data_size)),
        "duplicate signature" => ([
          PredecessorReferenceFingerprint::MH_MAGIC_64,
          PredecessorReferenceFingerprint::CPU_TYPE_ARM64,
          0, 2, 2, 32, 0, 0
        ].pack("V8") + signature_command + signature_command + ("s" * data_size)),
        "invalid signature command size" => (header + ordinary_command + [
          PredecessorReferenceFingerprint::LC_CODE_SIGNATURE, 8
        ].pack("V2") + ("s" * 16))
      }
      mutations.each do |label, bytes|
        expect_failure("predecessor Mach-O parser rejects #{label}") do
          PredecessorReferenceFingerprint.signature_layout(bytes)
        end
      end
    end

    def verify_predecessor_codesign_metadata_fixture!
      parser = PredecessorReferenceFingerprint
      metadata = (
        "Executable=/fixture/CaptureServer\n" \
        "Identifier=com.example.expected\n" \
        "Signed Time=Sep 19, 2026 at 10:02:48 \xE2\x80\xAFPM\n"
      ).dup.force_encoding(Encoding::US_ASCII)
      assert("predecessor codesign metadata field parses on pinned system Ruby") do
        parser.send(
          :exact_field!,
          metadata,
          "Identifier=",
          "com.example.expected",
          "fixture predecessor"
        )
        true
      end
      expect_failure("predecessor codesign metadata rejects duplicate fields") do
        parser.send(
          :exact_field!,
          metadata + "Identifier=com.example.expected\n",
          "Identifier=",
          "com.example.expected",
          "fixture predecessor"
        )
      end
      expect_failure("predecessor codesign metadata rejects mismatched fields") do
        parser.send(
          :exact_field!,
          metadata,
          "Identifier=",
          "com.example.hostile",
          "fixture predecessor"
        )
      end
    end

    def close_journal!(host)
      io = host.instance_variable_get(:@journal_io)
      io.close if io && !io.closed?
    end

    def seed_journal!(host, states)
      states.each { |state| host.journal!(state) }
      host
    end

    def verify_journal_fault_reconciliation!
      scenarios = {
        "STOP_INTENT" => %w[BEGUN INPUTS_VERIFIED],
        "V90_COMMIT_IRREVERSIBLE" => %w[
          BEGUN INPUTS_VERIFIED STOP_INTENT INSTALL_HOLDS_VERIFIED V86_STOPPED V86_HELD
          V90_PUBLISHED V90_BOOTSTRAPPED READY_VERIFIED COMMIT_INTENT
        ],
        "COMMITTED_V90" => RealHost::SUCCESS_STATES[0...-1],
        "ROLLED_BACK_EXACT_V86" => %w[
          BEGUN INPUTS_VERIFIED STOP_INTENT INSTALL_HOLDS_VERIFIED V86_STOPPED
          ROLLBACK_STARTED V90_STOPPED FAILED_V90_ARCHIVED V86_RESTORED V86_BOOTSTRAPPED
        ]
      }
      Dir.mktmpdir("v90-journal-faults-") do |root|
        scenarios.each_with_index do |(target, prior), index|
          path = File.join(root, "journal-#{index}.log")
          File.binwrite(path, "#{Pins::V90_JOURNAL_HEADER}\n")
          host = RealHost.new
          host.instance_variable_set(:@journal, path)
          host.instance_variable_set(:@journal_identity, host.send(:file_identity, path))
          seed_journal!(host, prior)
          base = host.method(:strict_fsync_io!)
          injected = false
          host.define_singleton_method(:strict_fsync_io!) do |io, label|
            base.call(io, label)
            if !injected && label == "V90 journal #{target}"
              injected = true
              raise Errno::EIO, "injected post-fsync acknowledgement failure"
            end
            true
          end
          expect_failure("full visible journal fsync error #{target}") { host.journal!(target) }
          states = host.send(:parse_journal_bytes!, host.send(:read_journal_bytes!))
          assert("full journal record advances conservatively #{target}") { states == prior + [target] }
          assert("full journal record advances memory conservatively #{target}") do
            host.instance_variable_get(:@last_journal_state) == target
          end
          if %w[V90_COMMIT_IRREVERSIBLE COMMITTED_V90].include?(target)
            expect_failure("rollback rejected after #{target}") { host.journal!("ROLLBACK_STARTED") }
          end
          close_journal!(host)
        end


        path = File.join(root, "prefsync-eio.log")
        File.binwrite(path, "#{Pins::V90_JOURNAL_HEADER}\n")
        host = RealHost.new
        host.instance_variable_set(:@journal, path)
        host.instance_variable_set(:@journal_identity, host.send(:file_identity, path))
        prior = RealHost::SUCCESS_STATES.take_while { |state| state != "V90_COMMIT_IRREVERSIBLE" }
        seed_journal!(host, prior)
        base = host.method(:strict_fsync_io!)
        injected = false
        host.define_singleton_method(:strict_fsync_io!) do |io, label|
          if !injected && label == "V90 journal V90_COMMIT_IRREVERSIBLE"
            injected = true
            raise Errno::EIO, "injected true pre-fsync failure"
          end
          base.call(io, label)
        end
        expect_failure("true pre-fsync EIO is never success") do
          host.journal!("V90_COMMIT_IRREVERSIBLE")
        end
        assert("pre-fsync EIO forbids rollback conservatively") do
          host.send(:irreversible_on_disk?) &&
            host.instance_variable_get(:@last_journal_state) == "V90_COMMIT_IRREVERSIBLE"
        end
        close_journal!(host)

        path = File.join(root, "torn.log")
        File.binwrite(path, "#{Pins::V90_JOURNAL_HEADER}\n")
        host = RealHost.new
        host.instance_variable_set(:@journal, path)
        host.instance_variable_set(:@journal_identity, host.send(:file_identity, path))
        seed_journal!(host, %w[BEGUN INPUTS_VERIFIED])
        before = host.send(:read_journal_bytes!)
        base_write = host.method(:write_all!)
        injected = false
        host.define_singleton_method(:write_all!) do |io, bytes, label|
          if !injected && label == "V90 journal STOP_INTENT"
            injected = true
            io.write(bytes.byteslice(0, bytes.bytesize / 2))
            io.flush
            raise Failure, "injected torn append"
          end
          base_write.call(io, bytes, label)
        end
        expect_failure("torn journal record") { host.journal!("STOP_INTENT") }
        assert("torn journal record is truncated exactly") { host.send(:read_journal_bytes!) == before }
        assert("torn record does not advance memory state") do
          host.instance_variable_get(:@last_journal_state) == "INPUTS_VERIFIED"
        end
        close_journal!(host)

        path = File.join(root, "replacement.log")
        moved = File.join(root, "replacement.original.log")
        File.binwrite(path, "#{Pins::V90_JOURNAL_HEADER}\n")
        host = RealHost.new
        host.instance_variable_set(:@journal, path)
        host.instance_variable_set(:@journal_identity, host.send(:file_identity, path))
        seed_journal!(host, %w[BEGUN INPUTS_VERIFIED STOP_INTENT])
        File.rename(path, moved)
        File.binwrite(path, "#{Pins::V90_JOURNAL_HEADER}\n")
        expect_failure("journal pathname replacement") { host.send(:irreversible_on_disk?) }
        close_journal!(host)
      end
    end

    def verify_atomic_pointer_fixture!
      Dir.mktmpdir("v90-pointer-") do |root|
        path = File.join(root, "pointer")
        contents = "/private/txn-v90\n"
        host = RealHost.new
        identity = host.send(:publish_owned_pointer!, path, contents)
        assert("atomic pointer exact bytes") { File.binread(path) == contents }
        assert("atomic pointer mode") { (File.lstat(path).mode & 0o7777) == 0o600 }
        assert("atomic pointer identity") { host.send(:identity_matches?, path, identity) }
        File.unlink(path)

        host = RealHost.new
        base_write = host.method(:write_durable)
        injected = false
        host.define_singleton_method(:write_durable) do |target, bytes, mode, exclusive:, &identity_block|
          if !injected && File.basename(target).include?(".pointer.")
            injected = true
            flags = File::WRONLY | File::CREAT | File::EXCL
            File.open(target, flags, mode) do |file|
              stat = file.stat
              identity_block&.call([stat.dev, stat.ino, stat.ftype])
              file.write(bytes.byteslice(0, bytes.bytesize / 2))
              file.flush
              file.fsync
            end
            raise Failure, "injected partial pointer write"
          end
          base_write.call(target, bytes, mode, exclusive: exclusive, &identity_block)
        end
        expect_failure("partial pointer write") { host.send(:publish_owned_pointer!, path, contents) }
        assert("partial pointer never becomes public") { !File.exist?(path) }
        assert("partial pointer temporary is removed") { Dir.children(root).empty? }

        host = RealHost.new
        base_sync = host.method(:strict_fsync_directory!)
        injected = false
        host.define_singleton_method(:strict_fsync_directory!) do |directory, label|
          base_sync.call(directory, label)
          if !injected && label == "exclusive rename parent"
            injected = true
            raise Failure, "injected post-rename parent fsync acknowledgement failure"
          end
          true
        end
        identity = host.send(:publish_owned_pointer!, path, contents)
        assert("post-rename pointer error reconciles exact final inode") do
          host.send(:identity_matches?, path, identity) && File.binread(path) == contents
        end
        assert("post-rename reconciliation leaves no temporary") { Dir.children(root) == ["pointer"] }
      end
    end

    def verify_real_inode_recovery_fixture!
      2.times do |variant|
        Dir.mktmpdir("v90-inode-recovery-") do |root|
          host = RealHost.new
          live_app = File.join(root, "live.app")
          backup_app = File.join(root, "backup.app")
          staged_app = File.join(root, "staged.app")
          failed_app = File.join(root, "failed.app")
          live_plist = File.join(root, "live.plist")
          backup_plist = File.join(root, "backup.plist")
          staged_plist = File.join(root, "staged.plist")
          failed_plist = File.join(root, "failed.plist")
          Dir.mkdir(live_app)
          File.binwrite(File.join(live_app, "v86"), "v86")
          File.binwrite(live_plist, "v86-plist")
          Dir.mkdir(staged_app)
          File.binwrite(File.join(staged_app, "v90"), "v90")
          File.binwrite(staged_plist, "v90-plist")
          v86_app = host.send(:file_identity, live_app)
          v86_plist = host.send(:file_identity, live_plist)
          v90_app = host.send(:file_identity, staged_app)
          v90_plist = host.send(:file_identity, staged_plist)

          host.send(:exclusive_rename, live_app, backup_app)
          if variant == 1
            host.send(:exclusive_rename, live_plist, backup_plist)
            host.send(:exclusive_rename, staged_app, live_app)
          end
          host.send(:archive_candidate_exact!, v90_app, [live_app, staged_app], failed_app, "fixture V90 app")
          host.send(:archive_candidate_exact!, v90_plist, [live_plist, staged_plist], failed_plist, "fixture V90 plist")
          host.send(:restore_predecessor_exact!, live_app, backup_app, v86_app, "fixture V86 app")
          host.send(:restore_predecessor_exact!, live_plist, backup_plist, v86_plist, "fixture V86 plist")
          assert("real recovery restores V86 app variant #{variant}") do
            host.send(:identity_matches?, live_app, v86_app)
          end
          assert("real recovery restores V86 plist variant #{variant}") do
            host.send(:identity_matches?, live_plist, v86_plist)
          end
          assert("real recovery archives V90 app variant #{variant}") do
            host.send(:identity_matches?, failed_app, v90_app)
          end
          assert("real recovery archives V90 plist variant #{variant}") do
            host.send(:identity_matches?, failed_plist, v90_plist)
          end
          host.send(:archive_candidate_exact!, v90_app, [live_app, staged_app], failed_app, "fixture V90 app")
          host.send(:restore_predecessor_exact!, live_app, backup_app, v86_app, "fixture V86 app")
        end
      end

      Dir.mktmpdir("v90-inode-collision-") do |root|
        host = RealHost.new
        staged = File.join(root, "staged.plist")
        live = File.join(root, "live.plist")
        archive = File.join(root, "failed.plist")
        File.binwrite(staged, "candidate")
        File.link(staged, live)
        identity = host.send(:file_identity, staged)
        expect_failure("duplicate candidate inode locations") do
          host.send(:archive_candidate_exact!, identity, [live, staged], archive, "duplicate fixture")
        end
      end


      %i[app plist].each do |kind|
        Dir.mktmpdir("v90-reported-rename-") do |root|
          host = RealHost.new
          source = File.join(root, kind == :app ? "candidate.app" : "candidate.plist")
          live = File.join(root, kind == :app ? "live.app" : "live.plist")
          failed = File.join(root, kind == :app ? "failed.app" : "failed.plist")
          kind == :app ? Dir.mkdir(source) : File.binwrite(source, "candidate")
          identity = host.send(:file_identity, source)
          base = host.method(:strict_fsync_directory!)
          injected = false
          host.define_singleton_method(:strict_fsync_directory!) do |directory, label|
            base.call(directory, label)
            if !injected && label == "exclusive rename parent"
              injected = true
              raise Failure, "injected post-rename sync acknowledgement failure"
            end
            true
          end
          expect_failure("reported #{kind} publish rename failure") do
            host.send(:exclusive_rename, source, live)
          end
          assert("reported #{kind} rename moved exact inode") do
            host.send(:identity_matches?, live, identity) && !File.exist?(source)
          end
          host.send(:archive_candidate_exact!, identity, [live, source], failed, "reported #{kind}")
          assert("reported #{kind} rename recovers exact inode") do
            host.send(:identity_matches?, failed, identity)
          end
        end
      end
    end

    def verify_recursive_fsync_fixture!
      Dir.mktmpdir("v90-fsync-tree-") do |root|
        app = File.join(root, "Fixture.app")
        nested = File.join(app, "Contents/Deep")
        FileUtils.mkdir_p(nested)
        top_file = File.join(app, "top")
        deep_file = File.join(nested, "deep")
        sentinel = File.join(root, "external-sentinel")
        File.binwrite(top_file, "top")
        File.binwrite(deep_file, "deep")
        File.binwrite(sentinel, "outside")
        File.symlink(sentinel, File.join(nested, "alias"))
        host = RealHost.new
        regular = host.method(:strict_fsync_regular!)
        directory = host.method(:strict_fsync_directory!)
        events = []
        host.define_singleton_method(:strict_fsync_regular!) do |path, label|
          events << [:file, path]
          regular.call(path, label)
        end
        host.define_singleton_method(:strict_fsync_directory!) do |path, label|
          events << [:dir, path]
          directory.call(path, label)
        end
        host.send(:durably_sync_tree!, app)
        assert("fsync barrier covers each real file once") do
          events.count([:file, top_file]) == 1 && events.count([:file, deep_file]) == 1
        end
        assert("fsync barrier never follows symlink target") { !events.include?([:file, sentinel]) }
        assert("fsync barrier orders child directory before root") do
          events.index([:dir, nested]) < events.index([:dir, app]) && events.last == [:dir, app]
        end

        host = RealHost.new
        regular = host.method(:strict_fsync_regular!)
        host.define_singleton_method(:strict_fsync_regular!) do |path, label|
          raise Failure, "injected deep-file fsync failure" if path == deep_file
          regular.call(path, label)
        end
        expect_failure("strict recursive fsync failure") { host.send(:durably_sync_tree!, app) }

        invalid = Object.new
        invalid.define_singleton_method(:fsync) { raise Errno::EINVAL, "injected unsupported fsync" }
        expect_failure("strict fsync rejects EINVAL") do
          RealHost.new.send(:strict_fsync_io!, invalid, "fixture strict fsync")
        end
      end
    end

    def verify_full_durability_barrier_fixture!
      Dir.mktmpdir("v90-full-fsync-barrier-") do |root|
        app = File.join(root, "Fixture.app")
        plist = File.join(root, "candidate.plist")
        Dir.mkdir(app)
        payload = File.join(app, "payload")
        File.binwrite(payload, "original")
        File.binwrite(plist, "plist")
        host = RealHost.new
        host.instance_variable_set(:@staged_app, app)
        host.instance_variable_set(:@staged_plist, plist)
        events = []
        verifies = 0
        host.define_singleton_method(:verify_staged_candidate!) do |_capsule|
          verifies += 1
          events << :verify
          raise Failure, "mutation detected by final replay" if verifies == 2 && File.binread(payload) != "original"
          true
        end
        host.define_singleton_method(:durably_sync_tree!) do |_path|
          events << :tree
          File.binwrite(payload, "mutated")
          true
        end
        host.define_singleton_method(:strict_fsync_directory!) do |_path, label|
          events << label
          true
        end
        host.define_singleton_method(:strict_fsync_regular!) do |_path, label|
          events << label
          true
        end
        expect_failure("mutation between fsync and replay") do
          host.send(:durably_sync_staged_candidate!, Object.new)
        end
        assert("durability barrier orders verify-sync-parent-plist-parent-verify") do
          events == [
            :verify,
            :tree,
            "staged candidate parent",
            "staged V90 launch plist",
            "staged launch-plist parent",
            :verify
          ]
        end
      end
    end

    def configure_topology_fixture!(host, runtime_root)
      update_root = File.join(runtime_root, "updates")
      lock_path = File.join(runtime_root, "lock")
      transaction = File.join(update_root, "transaction")
      helpers = File.join(transaction, "helpers")
      module_cache = File.join(transaction, "module-cache")
      compiler_tmp = File.join(transaction, "compiler-tmp")
      [update_root, lock_path].each { |path| Dir.mkdir(path, 0o700) }
      Dir.mkdir(transaction, 0o700)
      [helpers, module_cache, compiler_tmp].each { |path| Dir.mkdir(path, 0o700) }
      {
        update_root: update_root,
        lock_path: lock_path,
        transaction: transaction,
        helpers: helpers,
        module_cache: module_cache,
        compiler_tmp: compiler_tmp
      }.tap do |paths|
        host.instance_variable_set(:@update_root_identity, host.send(:file_identity, update_root))
        host.instance_variable_set(:@lock_identity, host.send(:file_identity, lock_path))
        host.instance_variable_set(:@transaction, transaction)
        host.instance_variable_set(:@transaction_identity, host.send(:file_identity, transaction))
        host.instance_variable_set(:@post_stop_helpers_root, helpers)
        host.instance_variable_set(:@post_stop_helpers_root_identity, host.send(:file_identity, helpers))
        host.instance_variable_set(:@route_monitor_module_cache_path, module_cache)
        host.instance_variable_set(
          :@route_monitor_module_cache_identity,
          host.send(:file_identity, module_cache)
        )
        host.instance_variable_set(:@route_monitor_compiler_tmp_path, compiler_tmp)
        host.instance_variable_set(
          :@route_monitor_compiler_tmp_identity,
          host.send(:file_identity, compiler_tmp)
        )
      end
    end

    def verify_transaction_topology_fixture!
      Dir.mktmpdir("v90-topology-") do |runtime_root|
        host = RealHost.new
        paths = configure_topology_fixture!(host, runtime_root)
        base = host.method(:strict_fsync_directory!)
        events = []
        host.define_singleton_method(:strict_fsync_directory!) do |path, label|
          events << [path, label]
          base.call(path, label)
        end
        host.send(
          :durably_sync_transaction_topology!,
          runtime_root: runtime_root,
          update_root: paths.fetch(:update_root),
          lock_path: paths.fetch(:lock_path)
        )
        indices = events.each_with_index.to_h
        child_events = %i[helpers module_cache compiler_tmp].map do |name|
          events.find { |path, _label| path == paths.fetch(name) }
        end
        transaction_event = events.find { |path, _label| path == paths.fetch(:transaction) }
        update_event = events.find { |path, _label| path == paths.fetch(:update_root) }
        lock_event = events.find { |path, _label| path == paths.fetch(:lock_path) }
        runtime_event = events.find { |path, _label| path == runtime_root }
        assert("transaction topology covers every required directory exactly once") do
          required = child_events + [transaction_event, update_event, lock_event, runtime_event]
          required.none?(&:nil?) && required.all? { |event| events.count(event) == 1 }
        end
        assert("transaction topology is synced child to parent") do
          child_events.all? { |event| indices.fetch(event) < indices.fetch(transaction_event) } &&
            indices.fetch(transaction_event) < indices.fetch(update_event) &&
            indices.fetch(update_event) < indices.fetch(runtime_event) &&
            indices.fetch(lock_event) < indices.fetch(runtime_event)
        end
      end

      Dir.mktmpdir("v90-topology-fault-") do |runtime_root|
        host = RealHost.new
        paths = configure_topology_fixture!(host, runtime_root)
        base = host.method(:strict_fsync_directory!)
        events = []
        host.define_singleton_method(:strict_fsync_directory!) do |path, label|
          events << path
          raise Failure, "injected update-root sync failure" if path == paths.fetch(:update_root)
          base.call(path, label)
        end
        expect_failure("transaction topology parent fsync failure") do
          host.send(
            :durably_sync_transaction_topology!,
            runtime_root: runtime_root,
            update_root: paths.fetch(:update_root),
            lock_path: paths.fetch(:lock_path)
          )
        end
        assert("topology failure cannot reach runtime-root certification") do
          !events.include?(runtime_root)
        end
      end
    end

    def verify_write_durable_mode_fixture!
      Dir.mktmpdir("v90-write-durable-") do |root|
        path = File.join(root, "executable")
        host = RealHost.new
        base_mode = host.method(:set_durable_mode!)
        base_sync = host.method(:strict_fsync_io!)
        events = []
        host.define_singleton_method(:set_durable_mode!) do |io, mode, label|
          events << [:chmod, label]
          base_mode.call(io, mode, label)
        end
        host.define_singleton_method(:strict_fsync_io!) do |io, label|
          events << [:fsync, label]
          base_sync.call(io, label)
        end
        host.send(:write_durable, path, "payload", 0o755, exclusive: true)
        label = "durable file #{path}"
        assert("durable chmod precedes file fsync") do
          events.index([:chmod, label]) < events.index([:fsync, label])
        end
        assert("durable file has exact requested mode") { (File.lstat(path).mode & 0o7777) == 0o755 }
      end

      Dir.mktmpdir("v90-write-durable-chmod-fault-") do |root|
        path = File.join(root, "file")
        host = RealHost.new
        identity = nil
        host.define_singleton_method(:set_durable_mode!) do |_io, _mode, _label|
          raise Failure, "injected chmod failure"
        end
        expect_failure("durable chmod failure") do
          host.send(:write_durable, path, "payload", 0o755, exclusive: true) do |created|
            identity = created
          end
        end
        assert("chmod failure records ownership before failing") do
          identity && host.send(:identity_matches?, path, identity)
        end
      end

      Dir.mktmpdir("v90-write-durable-fsync-fault-") do |root|
        path = File.join(root, "file")
        host = RealHost.new
        base = host.method(:strict_fsync_io!)
        host.define_singleton_method(:strict_fsync_io!) do |io, label|
          raise Failure, "injected file fsync failure" if label == "durable file #{path}"
          base.call(io, label)
        end
        expect_failure("durable file fsync failure") do
          host.send(:write_durable, path, "payload", 0o600, exclusive: true)
        end
      end
    end

    def verify_creation_signal_gap_fixture!
      Dir.mktmpdir("v90-directory-signal-") do |root|
        path = File.join(root, "owned")
        entered = Queue.new
        release = Queue.new
        host = RealHost.new
        host.define_singleton_method(:after_directory_create_before_identity!) do |_created|
          entered << true
          release.pop
          true
        end
        identity = nil
        worker_error = nil
        worker = Thread.new do
          Thread.current.report_on_exception = false
          begin
            host.send(:create_owned_directory!, path, 0o700, "fixture parent") do |created|
              identity = created
            end
          rescue Exception => error # rubocop:disable Lint/RescueException
            worker_error = error
          end
        end
        entered.pop
        worker.raise(Interrupt, "injected create gap interrupt")
        release << true
        worker.join(5)
        assert("directory create-gap worker exits") { !worker.alive? && worker_error.is_a?(Interrupt) }
        assert("directory ownership is published before deferred interrupt") do
          identity && host.send(:identity_matches?, path, identity)
        end
        host.send(:remove_empty_directory_exact!, path, identity)
        assert("directory create-gap residue is exactly removable") { !File.exist?(path) }
      ensure
        worker.kill if worker&.alive?
      end

      Dir.mktmpdir("v90-file-signal-") do |root|
        path = File.join(root, "owned")
        entered = Queue.new
        release = Queue.new
        host = RealHost.new
        host.define_singleton_method(:after_file_create_before_identity!) do |_created|
          entered << true
          release.pop
          true
        end
        identity = nil
        worker_error = nil
        worker = Thread.new do
          Thread.current.report_on_exception = false
          begin
            host.send(:write_durable, path, "payload", 0o600, exclusive: true) do |created|
              identity = created
            end
          rescue Exception => error # rubocop:disable Lint/RescueException
            worker_error = error
          end
        end
        entered.pop
        worker.raise(Interrupt, "injected file create gap interrupt")
        release << true
        worker.join(5)
        assert("file create-gap worker exits") { !worker.alive? && worker_error.is_a?(Interrupt) }
        assert("file ownership is published before deferred interrupt") do
          identity && host.send(:identity_matches?, path, identity)
        end
        host.send(:unlink_exact!, path, identity, expected_contents: "payload")
        assert("file create-gap residue is exactly removable") { !File.exist?(path) }
      ensure
        worker.kill if worker&.alive?
      end
    end

    def write_session_fence_log(path, pid, nonce)
      File.binwrite(
        path,
        "fixture-marker=A\n" \
        "Worldwide paired-device availability is online pid=#{pid} nonce=#{nonce}\n" \
        "Worldwide peer returned to idle\n"
      )
      File.chmod(0o600, path)
      true
    end

    def verify_session_fence_fixture!
      pid = 12_345
      nonce = "f" * 64
      Dir.mktmpdir("v90-session-fence-") do |root|
        path = File.join(root, "host.log")
        write_session_fence_log(path, pid, nonce)
        baseline = SessionFence.observe!(path, pid, nonce)
        File.open(path, "ab") { |file| file.write("health sample\n") }
        advanced = SessionFence.observe!(path, pid, nonce, prior: baseline)
        assert("session fence accepts append-only quiescent evidence") do
          advanced.size > baseline.size && advanced.last_reset_offset == baseline.last_reset_offset
        end

        File.open(path, "ab") do |file|
          file.write("Worldwide authenticated media route selected\n")
          file.write("Worldwide peer returned to idle\n")
        end
        expect_failure("session fence rejects a new reset boundary") do
          SessionFence.observe!(path, pid, nonce, prior: advanced)
        end
      end

      Dir.mktmpdir("v90-session-rewrite-") do |root|
        path = File.join(root, "host.log")
        write_session_fence_log(path, pid, nonce)
        baseline = SessionFence.observe!(path, pid, nonce)
        File.open(path, "r+b") do |file|
          offset = File.binread(path).index("A")
          file.pwrite("B", offset)
          file.flush
        end
        expect_failure("session fence rejects same-size historical rewrite") do
          SessionFence.observe!(path, pid, nonce, prior: baseline)
        end
      end
    end

    def stability_harness(fail_probe: nil, fail_call: nil)
      host = RealHost.new
      counters = Hash.new(0)
      clock = [0.0]
      fail_now = lambda do |probe|
        counters[probe] += 1
        counters[probe] == fail_call && probe == fail_probe
      end
      pid = 12_345
      nonce = "a" * 64
      host.instance_variable_set(:@candidate_cdhash, "b" * 40)
      host.define_singleton_method(:launch_identity) do
        bad = fail_now.call(:launch)
        bad ? [pid + 1, 1] : [pid, 1]
      end
      host.define_singleton_method(:strict_lock_record) do |**_arguments|
        bad = fail_now.call(:lock)
        bad ? { pid: pid, nonce: "c" * 64 } : { pid: pid, nonce: nonce }
      end
      host.define_singleton_method(:verify_dynamic_process!) do |_pid, **_arguments|
        raise Failure, "process drift" if fail_now.call(:process)
        true
      end
      host.define_singleton_method(:verify_installed_candidate_bytes!) do
        raise Failure, "byte drift" if fail_now.call(:bytes)
        true
      end
      host.define_singleton_method(:readiness_generation!) do
        bad = fail_now.call(:readiness)
        bad ? 8 : 7
      end
      host.define_singleton_method(:current_display_mode) do
        bad = fail_now.call(:display)
        bad ? "drifted" : Pins::LIVE_DISPLAY_MODE
      end
      host.define_singleton_method(:observe_candidate_session!) do |_prior|
        raise Failure, "session drift" if fail_now.call(:session)
        Object.new
      end
      host.define_singleton_method(:verify_routes!) do
        raise Failure, "route drift" if fail_now.call(:routes)
        true
      end
      host.define_singleton_method(:route_monitor_clean!) do |**_arguments|
        raise Failure, "sticky monitor drift" if fail_now.call(:monitor)
        true
      end
      host.define_singleton_method(:monotonic_now) { clock.first }
      host.define_singleton_method(:stability_sleep) { |seconds| clock[0] += seconds }
      [host, counters, clock]
    end

    def verify_stability_fixture!
      host, counters, clock = stability_harness
      host.send(:establish_candidate_stability_baseline!)
      host.send(:run_candidate_stability_window!)
      %i[launch lock process bytes readiness display session routes monitor].each do |probe|
        assert("stability samples baseline plus 31 #{probe}") { counters[probe] == 32 }
      end
      assert("stability reaches full monotonic window") { clock.first >= 31.0 }

      %i[launch lock process bytes readiness display session routes monitor].each do |probe|
        [2, 17, 32].each do |call|
          host, = stability_harness(fail_probe: probe, fail_call: call)
          host.send(:establish_candidate_stability_baseline!)
          expect_failure("#{probe} drift at sample #{call - 1}") do
            host.send(:run_candidate_stability_window!)
          end
        end
      end
    end

    def verify_second_signal_deferral!
      %i[rollback abort].each do |mode|
        entered = Queue.new
        release = Queue.new
        host_class = Class.new(FakeHost) do
          attr_reader :cleanup_completed
        end
        host = host_class.new
        if mode == :rollback
          host.define_singleton_method(:verify_candidate_ready!) { raise Interrupt, "first interrupt" }
          base_cleanup = host.method(:rollback_exact_v86!)
          host.define_singleton_method(:rollback_exact_v86!) do
            entered << true
            release.pop
            base_cleanup.call
            @cleanup_completed = true
          end
        else
          host.define_singleton_method(:revalidate_immediately_before_stop!) do |_capsule|
            raise Interrupt, "first interrupt"
          end
          base_cleanup = host.method(:abort_before_stop!)
          host.define_singleton_method(:abort_before_stop!) do
            entered << true
            release.pop
            base_cleanup.call
            @cleanup_completed = true
          end
        end
        worker_error = nil
        worker = Thread.new do
          Thread.current.report_on_exception = false
          begin
            Coordinator.new(host, FakeCapsule.new).execute!
          rescue Exception => error # rubocop:disable Lint/RescueException
            worker_error = error
          end
        end
        entered.pop
        worker.raise(Interrupt, "second interrupt")
        release << true
        worker.join(5)
        assert("second signal worker exits #{mode}") { !worker.alive? && worker_error }
        assert("second signal cannot truncate #{mode}") { host.cleanup_completed }
        assert("second signal leaves clean namespace #{mode}") do
          mode == :rollback ? host.rollback_clean? : host.abort_clean?
        end
        if mode == :rollback
          assert("second signal preserves rollback terminal") { host.states.last == "ROLLED_BACK_EXACT_V86" }
        end
      ensure
        worker.kill if worker&.alive?
      end
    end

    def run!
      assert("sealed framework identity preserves the public bundle path") do
        Pins::LIVE_FRAMEWORK_IDENTITY_PATH ==
          "/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" &&
          Pins::LIVE_FRAMEWORK_IDENTITY_PATH != Pins::LIVE_FRAMEWORK
      end
      assert("V86 verification preserves the sealed media-integration contract") do
        Pins::V86_HELPERS["verify-media-v1-host-bundle.sh"] ==
          "e8a486a8e7360e5d3c8517e237e046fc21b3ccc2a3eb5e14ccd5d40135742e0c" &&
          !Pins::V86_HELPERS.key?("verify-mac-host-bundle.sh")
      end

      capsule = FakeCapsule.new
      host = FakeHost.new
      Coordinator.new(host, capsule).preflight!
      assert("preflight is mutation-free") { host.events.all? { |kind, _| kind == :observe } }

      capsule = FakeCapsule.new
      host = FakeHost.new
      Coordinator.new(host, capsule).execute!
      assert("required journal states") do
        host.states == %w[
          BEGUN INPUTS_VERIFIED STOP_INTENT INSTALL_HOLDS_VERIFIED V86_STOPPED V86_HELD
          V90_PUBLISHED V90_BOOTSTRAPPED READY_VERIFIED COMMIT_INTENT
          V90_COMMIT_IRREVERSIBLE COMMITTED_V90
        ]
      end
      assert("terminal journal is last") { host.events.last == [:mutate, :"journal:COMMITTED_V90"] }
      assert("transitive capsule replay") { capsule.verify_count == 2 }
      assert("committed namespace has only active pointer") { host.commit_clean? }
      assert("initial topology barrier precedes INPUTS_VERIFIED") do
        host.events.index([:observe, :initial_topology_barrier]) <
          host.events.index([:mutate, :"journal:INPUTS_VERIFIED"])
      end
      assert("final topology barrier immediately precedes STOP_INTENT") do
        host.events.index([:observe, :final_topology_barrier]) <
          host.events.index([:mutate, :"journal:STOP_INTENT"])
      end

      host = FakeHost.new(fail_at: :verify_candidate_ready)
      expect_failure("candidate failure") { Coordinator.new(host, FakeCapsule.new).execute! }
      assert("pre-commit rollback") { host.events.count([:mutate, :rollback_exact_v86]) == 1 }
      assert("no commit after candidate failure") { !host.states.include?("COMMIT_INTENT") }
      assert("candidate failure rollback is clean") { host.rollback_clean? }
      assert("rollback terminal is last") { host.states.last == "ROLLED_BACK_EXACT_V86" }
      assert("required rollback journal topology") do
        host.states.last(6) == %w[
          ROLLBACK_STARTED V90_STOPPED FAILED_V90_ARCHIVED V86_RESTORED V86_BOOTSTRAPPED
          ROLLED_BACK_EXACT_V86
        ]
      end

      %i[
        write_pending_result publish_active_pointer unlink_pending_pointer remove_transaction_lock
        pre_irreversible_safety_replay
      ].each do |boundary|
        host = FakeHost.new(fail_at: boundary)
        expect_failure("pre-irreversible boundary #{boundary}") do
          Coordinator.new(host, FakeCapsule.new).execute!
        end
        assert("pre-irreversible rollback #{boundary}") do
          host.events.count([:mutate, :rollback_exact_v86]) == 1
        end
        assert("pre-irreversible cleanup #{boundary}") { host.rollback_clean? }
        assert("pre-irreversible rollback terminal #{boundary}") do
          host.states.last == "ROLLED_BACK_EXACT_V86"
        end
      end

      host = FakeHost.new(fail_at: :"journal:V90_COMMIT_IRREVERSIBLE")
      expect_failure("pre-persist irreversible journal failure") do
        Coordinator.new(host, FakeCapsule.new).execute!
      end
      assert("pre-persist irreversible failure rolls back") do
        host.events.count([:mutate, :rollback_exact_v86]) == 1 && host.rollback_clean?
      end

      post_irreversible = %i[
        journal_irreversible_after_persist stop_route_monitor final_route_readback
        write_final_result journal:COMMITTED_V90
      ]
      post_irreversible.each do |boundary|
        host = FakeHost.new(fail_at: boundary)
        expect_failure("post-irreversible boundary #{boundary}") do
          Coordinator.new(host, FakeCapsule.new).execute!
        end
        assert("post-irreversible boundary never rolls back #{boundary}") do
          host.events.none? { |event| event == [:mutate, :rollback_exact_v86] }
        end
        assert("post-irreversible boundary retains V90 #{boundary}") { host.committed_unverified? }
        assert("post-irreversible evidence is explicit #{boundary}") do
          host.states.include?("V90_COMMIT_IRREVERSIBLE") &&
            host.states.last == "COMMITTED_V90_UNVERIFIED" &&
            !host.states.include?("COMMITTED_V90")
        end
      end

      host = FakeHost.new(namespace_fresh: false)
      expect_failure("nonfresh namespace") { Coordinator.new(host, FakeCapsule.new).execute! }
      assert("nonfresh namespace fails before mutation") { host.events.all? { |kind, _| kind == :observe } }

      %i[
        prepare initial_durability_barrier initial_topology_barrier
        revalidate final_durability_barrier final_topology_barrier journal:STOP_INTENT
      ].each do |boundary|
        host = FakeHost.new(fail_at: boundary)
        expect_failure("pre-stop boundary #{boundary}") do
          Coordinator.new(host, FakeCapsule.new).execute!
        end
        assert("pre-stop boundary aborts once #{boundary}") do
          host.events.count([:mutate, :abort_before_stop]) == 1
        end
        assert("pre-stop boundary leaves no namespace residue #{boundary}") { host.abort_clean? }
        if %i[initial_durability_barrier initial_topology_barrier].include?(boundary)
          assert("initial fsync failure precedes INPUTS_VERIFIED") do
            !host.states.include?("INPUTS_VERIFIED")
          end
        elsif %i[final_durability_barrier final_topology_barrier].include?(boundary)
          assert("final fsync failure precedes STOP_INTENT") { !host.states.include?("STOP_INTENT") }
        end
      end

      %i[journal:INSTALL_HOLDS_VERIFIED stop_predecessor].each do |boundary|
        host = FakeHost.new(fail_at: boundary)
        expect_failure("post-intent boundary #{boundary}") do
          Coordinator.new(host, FakeCapsule.new).execute!
        end
        assert("post-intent boundary rolls back once #{boundary}") do
          host.events.count([:mutate, :rollback_exact_v86]) == 1
        end
        assert("post-intent boundary restores exact V86 #{boundary}") { host.rollback_clean? }
      end

      host = FakeHost.new(fail_at: :journal_stop_after_persist)
      expect_failure("visible STOP_INTENT fsync failure") do
        Coordinator.new(host, FakeCapsule.new).execute!
      end
      assert("visible STOP_INTENT failure uses rollback, never pre-stop abort") do
        host.events.count([:mutate, :rollback_exact_v86]) == 1 &&
          host.events.none? { |event| event == [:mutate, :abort_before_stop] } &&
          host.states.last == "ROLLED_BACK_EXACT_V86"
      end

      host = FakeHost.new
      expect_failure("last-moment capsule mutation") { Coordinator.new(host, FakeCapsule.new(fail_verify_at: 2)).execute! }
      assert("capsule mutation rejected before stop") { !host.states.include?("STOP_INTENT") }
      assert("pre-stop abort cleans prepared transaction") { host.events.include?([:mutate, :abort_before_stop]) }
      assert("pre-stop abort leaves no namespace residue") { host.abort_clean? }

      %i[
        rename_v86_app_to_hold rename_v86_plist_to_hold
        rename_v90_app_to_live rename_v90_plist_to_live
      ].each do |boundary|
        host = FakeHost.new(fail_at: boundary)
        expect_failure("rename boundary #{boundary}") { Coordinator.new(host, FakeCapsule.new).execute! }
        assert("single rollback at #{boundary}") { host.events.count([:mutate, :rollback_exact_v86]) == 1 }
        assert("no commit at #{boundary}") { !host.states.include?("COMMIT_INTENT") }
        assert("rename-boundary cleanup #{boundary}") { host.rollback_clean? }
      end

      duplicate = Tempfile.new("v90-duplicate-json")
      begin
        duplicate.write('{"schema":"x","schema":"x"}')
        duplicate.flush
        expect_failure("duplicate JSON key") { Util.strict_json(duplicate.path, ["schema"], "x") }
      ensure
        duplicate.close!
      end

      verify_copy_stable_manifest_fixture!
      verify_predecessor_signature_layout_fixture!
      verify_predecessor_codesign_metadata_fixture!
      verify_real_journal_state_machine!
      verify_journal_fault_reconciliation!
      verify_atomic_pointer_fixture!
      verify_real_inode_recovery_fixture!
      verify_recursive_fsync_fixture!
      verify_full_durability_barrier_fixture!
      verify_transaction_topology_fixture!
      verify_write_durable_mode_fixture!
      verify_creation_signal_gap_fixture!
      verify_session_fence_fixture!
      verify_stability_fixture!
      verify_second_signal_deferral!
      # This is read-only: it exercises the exact pinned compiler/SDK/source metadata path without
      # compiling or starting the CoreAudio observer.
      RealHost.new.send(:verify_route_monitor_tools!)

      puts "opensteamer V90 cutover self-test: PASS"
      true
    end
  end

  module CLI
    extend self

    SELF_TEST = "--self-test-v90-cutover"
    PREFLIGHT = "--verify-v90-cutover-preflight"
    EXECUTE = "--execute-authorized-v90-cutover"

    def run(argv)
      mode = argv.shift
      case mode
      when SELF_TEST
        Util.fail!("self-test accepts no arguments") unless argv.empty?
        SelfTest.run!
      when PREFLIGHT, EXECUTE
        Util.fail!("mode requires capsule root and exactly two external digests") unless argv.length == 3
        Util.fail!("live V90 modes require the independently pinned launcher") unless
          ENV["OPENSTEAMER_V90_LAUNCHER_ATTESTATION"] == Pins::LAUNCHER_ATTESTATION
        Util.fail!("live V90 modes require the pinned uid/euid 501 account") unless Process.uid == 501 && Process.euid == 501
        ToolingProof.verify_launcher_environment!(ToolingProof.verify!)
        capsule = Capsule.new(argv[0], argv[1], argv[2])
        coordinator = Coordinator.new(RealHost.new, capsule)
        if mode == PREFLIGHT
          coordinator.preflight!
          puts "v90_cutover_preflight=pass"
        else
          previous = {}
          %w[HUP INT TERM].each do |signal|
            previous[signal] = Signal.trap(signal) { raise Interrupt, "received #{signal}" }
          end
          begin
            coordinator.execute!
            puts "v90_cutover=committed"
          ensure
            previous.each { |signal, handler| Signal.trap(signal, handler) }
          end
        end
      else
        Util.fail!("usage: controller #{SELF_TEST} | #{PREFLIGHT} <capsule> <handoff-sha256> <payload-sha256> | #{EXECUTE} <capsule> <handoff-sha256> <payload-sha256>")
      end
      0
    rescue Failure => error
      warn "opensteamer-host-v90-cutover-controller: #{error.message}"
      1
    end
  end
end

exit(OpenSteamerV90Cutover::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
