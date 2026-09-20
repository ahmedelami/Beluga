#!/bin/bash
set -euo pipefail
exec /usr/bin/ruby - "$0" "$@" <<'RUBY'
require 'digest'
require 'fileutils'
require 'json'
require 'rexml/document'
require 'set'
require 'tmpdir'

REQUIRED_CLASSES = %w[
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests
  CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests
  CaptureServerTests.WorldwideScreenVideoAdaptationPolicyTests
  CaptureServerTests.WorldwideScreenVideoStartupRampTests
  CaptureServerTests.WorldwideScreenVideoRTTFreshnessTests
  CaptureServerTests.WorldwideScreenVideoSamplingCadenceTests
  CaptureServerTests.WorldwideScreenVideoPromotionCapacityTests
  CaptureServerTests.WorldwideScreenVideoProbeCadenceTests
  CaptureServerTests.WorldwideScreenColdFloorRecoveryTests
  CaptureServerTests.WorldwideScreenFloorRecoveryTests
  CaptureServerTests.WorldwideScreenFloorRecoveryDiagnosticsTests
  CaptureServerTests.WorldwideScreenProbeDemandTests
  CaptureServerTests.WorldwideScreenCapacityProbeDiagnosticsTests
  CaptureServerTests.WorldwideScreenRoundTripTimeDiagnosticsTests
  CaptureServerTests.WorldwideScreenFormatRenegotiationSupersessionTests
  CaptureServerTests.WorldwideRemoteInputScaleTransitionTests
  WebRTCTransportTests.WebRTCScreenVideoStatisticsReportTests
  WebRTCTransportTests.WebRTCRoundTripTimeObservationTests
  WebRTCTransportTests.WebRTCStatisticsParserTests
  WebRTCTransportTests.WebRTCVideoStartupStatisticsTests
  CaptureServerTests.StartupVideoDatagramSchedulerTests
].freeze
# Renaming or deleting a pinned safety method requires intentional gate review.
REQUIRED_METHODS = %w[
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testShowKeepsExistingTrafficCeilingsButStartsWithFullPixels
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testExplicitLowCeilingDoesNotAcquireSpeculativeFullPixels
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testQualifiedModerateBandwidthDoesNotFreezeMotionAtColdStartFPS
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testNewRequestWithStaleOrMissingNativeReportCannotApplyNegativeEvidence
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testFreshFastRTTAfterMalformedOrdinaryReportStillFailsClosed
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testFreshFastRTTBridgeCannotOutlivePrimaryLeaseOrProbeDeadline
  CaptureServerTests.WorldwideScreenStartupSpatialPolicyTests/testRejectedNativeApplyRetainsOnlyExactShowTerminalDisproof
  CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests/testSeededSequencesPreserveNonFPSStateAcrossSourceFrameRates
  CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests/testConfiguredCapAndSourceFPSMatrixGivesUncertaintyNoAuthority
  CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests/testProbeExpiryAndStaleInterleavingCannotResurrectBudgetOrBlurShow
  CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests/testFailedApplyOwnershipCannotCopyPositiveAuthorityOrCrossBoundaries
  WebRTCTransportTests.WebRTCScreenVideoStatisticsReportTests/testRepeatedDiagnosticCopiesNeverPromoteFallbackRouteToNativeEvidence
].freeze
NATIVE_METHODS = %w[
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testDelayedNetworkBlackoutPreventsDirectICEBypass
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testDenseProductionPolicyDelayedNetworkWithDynamicFrameRateCharacterization
].freeze
NATIVE_OPT_IN = 'OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT'
CAPACITY_METHODS = %w[
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedAmpleColdStill
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedAmpleWarmStill
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedWeakColdStill
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedWeakWarmStill
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedAmpleColdMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedAmpleWarmMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedWeakColdMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedWeakWarmMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedAmpleShapedMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedWeakShapedMoving
  CaptureServerTests.WebRTCStartupClarityExperimentTests/testSerializedMovingCapacityDropAndRecovery
].freeze

def fail_gate(message)
  raise RuntimeError, message
end

def source_identity(root)
  paths = %w[Package.swift Package.resolved scripts/validate-screen-startup.sh]
  %w[macOS/Sources macOS/Tests shared/Sources shared/Tests].each do |directory|
    paths.concat(Dir.glob(File.join(root, directory, '**', '*')).select do |path|
      File.file?(path) && path.match?(/\.(swift|h|hpp|c|cc|cpp|m|mm|metal|modulemap|rs|toml|json)$/)
    end.map { |path| path.delete_prefix(root + '/') })
  end
  paths = paths.uniq.sort.select { |path| File.file?(File.join(root, path)) }
  entries = paths.map { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
  [Digest::SHA256.hexdigest(JSON.generate(entries)), entries]
end

def check_source(root, expected)
  fail_gate('source changed during this invocation; rebuild in a fresh invocation') unless source_identity(root)[0] == expected
end

def terminate_owned_group(pid)
  reaped = false
  begin
    Process.kill('TERM', -pid)
    sleep 0.15
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH
  rescue Errno::EPERM
    # Darwin may report EPERM when the terminated group has only its zombie
    # leader left. Confirm and reap that exact child before accepting this case.
    reaped = !Process.waitpid(pid, Process::WNOHANG).nil?
    raise unless reaped
  ensure
    begin
      Process.waitpid(pid) unless reaped
    rescue Errno::ECHILD
    end
  end
end

def run_command(label, argv, environment, root, evidence, timeout)
  log = File.join(evidence, label + '.log')
  puts "screen-startup: #{label} (deadline #{timeout}s; log #{log})"
  pid = Process.spawn(environment, *argv, chdir: root, out: log, err: [:child, :out], pgroup: true)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    finished = Process.waitpid2(pid, Process::WNOHANG)
    if finished
      pid = nil
      fail_gate("#{label} exited unsuccessfully; inspect #{log}") unless finished[1].success?
      return log
    end
    fail_gate("#{label} exceeded its process deadline; inspect #{log}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
ensure
  terminate_owned_group(pid) if pid
end

def validate_xunit_results(path, expected)
  fail_gate("missing xUnit results: #{path}") unless File.file?(path)
  document = REXML::Document.new(File.read(path))
  cases = REXML::XPath.match(document, '//testcase')
  fail_gate("empty selected test results: #{path}") if cases.empty?
  aliases = expected.group_by { |id| id.split('.').last }
  observed = []
  cases.each do |test_case|
    name = test_case.attributes['name'].to_s
    class_name = test_case.attributes['classname'].to_s
    candidate = class_name + '/' + name
    if !expected.include?(candidate)
      short = class_name.split('.').last.to_s + '/' + name
      matches = aliases[short] || []
      candidate = matches.first if matches.length == 1
    end
    fail_gate("unexpected test result #{candidate}") unless expected.include?(candidate)
    status = test_case.attributes['status'].to_s.downcase
    if test_case.elements['skipped'] || %w[skipped disabled notrun].include?(status)
      fail_gate("required test skipped: #{candidate}")
    end
    if test_case.elements['failure'] || test_case.elements['error']
      fail_gate("required test failed: #{candidate}")
    end
    fail_gate("unrecognized test status for #{candidate}: #{status}") unless ['', 'run', 'passed', 'success'].include?(status)
    observed << candidate
  end
  fail_gate('duplicate test results') unless observed.uniq.length == observed.length
  missing = expected - observed
  fail_gate("required tests missing from results: #{missing.join(', ')}") unless missing.empty?
end

def validate_xctest_log(path, expected)
  lines = File.readlines(path).map(&:chomp)
  timestamp = '\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+'
  suite_start = /\ATest Suite 'Selected tests' started at #{timestamp}\.\z/
  suite_pass = /\ATest Suite 'Selected tests' passed at #{timestamp}\.\z/
  starts = lines.each_index.select { |index| suite_start.match?(lines[index]) }
  finishes = lines.each_index.select { |index| suite_pass.match?(lines[index]) }
  fail_gate('missing or duplicate Selected tests start record') unless starts.length == 1
  fail_gate('missing or duplicate Selected tests passed record') unless finishes.length == 1
  fail_gate('Selected tests records are out of order') unless starts.first < finishes.first

  case_record = /\ATest Case '-\[([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*) (test[A-Za-z0-9_]+)\]' (started\.|(passed|skipped|failed) \([0-9]+(?:\.[0-9]+)? seconds\)\.)\z/
  started = Set.new
  passed = Set.new
  active = nil
  lines.each_with_index do |line, index|
    fail_gate('XCTest suite reported failure or skip') if line.match?(/\ATest Suite '.+' (?:failed|skipped) at /)
    next unless line.start_with?('Test Case ')
    record = case_record.match(line)
    fail_gate('unrecognized XCTest case record') unless record
    fail_gate('XCTest case record outside Selected tests suite') unless index > starts.first && index < finishes.first
    id = record[1] + '/' + record[2]
    fail_gate("unexpected test result #{id}") unless expected.include?(id)
    if record[3] == 'started.'
      fail_gate("duplicate XCTest start: #{id}") if started.include?(id)
      fail_gate('interleaved XCTest starts in serial run') if active
      started << id
      active = id
    else
      fail_gate("required test skipped: #{id}") if record[4] == 'skipped'
      fail_gate("required test failed: #{id}") if record[4] == 'failed'
      fail_gate("duplicate XCTest pass: #{id}") if passed.include?(id)
      fail_gate("XCTest pass without matching start: #{id}") unless active == id
      passed << id
      active = nil
    end
  end
  fail_gate('empty selected XCTest results') if started.empty?
  fail_gate("unfinished XCTest case: #{active}") if active
  missing = expected - passed.to_a
  fail_gate("required tests missing from results: #{missing.join(', ')}") unless missing.empty?
  footer = lines[finishes.first + 1].to_s
  summary = /\A[ \t]*Executed ([0-9]+) tests?, with (?:([0-9]+) (?:tests? )?skipped and )?([0-9]+) failures? \(([0-9]+) unexpected\) in [0-9]+(?:\.[0-9]+)? \([0-9]+(?:\.[0-9]+)?\) seconds\z/.match(footer)
  fail_gate('missing or malformed Selected tests count footer') unless summary
  fail_gate('Selected tests footer reports skips or failures') unless summary[2].to_i.zero? && summary[3].to_i.zero? && summary[4].to_i.zero?
  fail_gate('Selected tests count footer disagrees with required method manifest') unless summary[1].to_i == expected.length
end

def validate_results(xml, log, expected)
  if File.file?(xml)
    validate_xunit_results(xml, expected)
    'xunit'
  else
    # Serial XCTest in the reviewed Xcode may ignore --xunit-output. Only its
    # complete, anchored per-case records and Selected tests footer may substitute.
    validate_xctest_log(log, expected)
    'darwin-xctest-log'
  end
end

script = File.realpath(ARGV.shift)
root = File.dirname(File.dirname(script))
options = { native: false, jobs: 1, timeout: 900 }
seen = Set.new
usage = <<~HELP
  Usage: DEVELOPER_DIR=/reviewed/Xcode.app/Contents/Developer \
    scripts/validate-screen-startup.sh --scratch-path /dedicated/startup-build [--jobs 1|2] [--native] [--capacity-experiment] [--timeout-seconds 1..3600]

  Builds/discovers once, then runs the deterministic startup manifest. --native also
  runs blackout and delayed dynamic-FPS methods in separate fresh processes.
  --capacity-experiment additionally characterizes the serialized-link matrix in three
  fresh-process rounds. It includes --native; characterization is not production acceptance.
  Existing scratch caches are reused; fresh logs, method manifests, and available xUnit files
  are retained in SCRATCH/validation-runs. Source identity is checked between phases.
  Coordinate with other tasks: do not run another build concurrently or share scratch.
  This is a contributor gate, not installed-host, iPhone, or Internet validation.
HELP

begin
  $stdout.sync = true
  while (argument = ARGV.shift)
    if argument == '--help'
      fail_gate('--help must be used alone') unless ARGV.empty? && seen.empty?
      puts usage
      exit 0
    end
    fail_gate("duplicate argument: #{argument}") if seen.include?(argument)
    seen << argument
    case argument
    when '--native'
      options[:native] = true
    when '--capacity-experiment'
      options[:native] = true
      options[:capacity] = true
    when '--scratch-path', '--jobs', '--timeout-seconds'
      value = ARGV.shift
      fail_gate("missing value for #{argument}") if value.nil? || value.start_with?('--')
      case argument
      when '--scratch-path' then options[:scratch] = value
      when '--jobs'
        fail_gate('--jobs must be 1 or 2') unless %w[1 2].include?(value)
        options[:jobs] = value.to_i
      when '--timeout-seconds'
        fail_gate('--timeout-seconds must be an integer from 1 through 3600') unless value.match?(/\A[0-9]+\z/) && (1..3600).cover?(value.to_i)
        options[:timeout] = value.to_i
      end
    else
      fail_gate("unrecognized argument: #{argument}")
    end
  end
  fail_gate('this gate requires Darwin/macOS') unless RUBY_PLATFORM.include?('darwin')
  developer = ENV['DEVELOPER_DIR']
  fail_gate('set DEVELOPER_DIR explicitly to the reviewed Xcode developer directory') unless developer && developer.start_with?('/') && File.directory?(developer)
  developer = File.realpath(developer)
  swift = File.join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift')
  sdk = File.join(developer, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk')
  fail_gate('DEVELOPER_DIR must contain the Xcode Swift executable and macOS SDK') unless File.executable?(swift) && File.directory?(sdk)
  scratch = options[:scratch]
  fail_gate('--scratch-path must explicitly name an absolute dedicated build directory') unless scratch && scratch.start_with?('/')
  scratch = File.expand_path(scratch)
  fail_gate('scratch path must be dedicated, not a repository, home, or developer root') if [root, Dir.home, developer, '/'].include?(scratch) || root.start_with?(scratch + '/')
  FileUtils.mkdir_p(scratch, mode: 0700)
  scratch = File.realpath(scratch)
  fail_gate('resolved scratch path is not dedicated') if [root, Dir.home, developer, '/'].include?(scratch) || root.start_with?(scratch + '/')
  fail_gate('package manifest is missing') unless File.file?(File.join(root, 'Package.swift'))
  lock = File.open(File.join(scratch, '.screen-startup-validation.lock'), File::RDWR | File::CREAT, 0600)
  fail_gate('another startup validation invocation owns this scratch path') unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  runs = File.join(scratch, 'validation-runs')
  FileUtils.mkdir_p(runs, mode: 0700)
  evidence = Dir.mktmpdir('startup-', runs)
  expected_source, covered_sources = source_identity(root)
  File.write(File.join(evidence, 'source-manifest.json'), JSON.pretty_generate(
    source_sha256: expected_source, files: covered_sources, developer_directory: developer, swift: swift
  ))
  %w[INT TERM].each { |signal| Signal.trap(signal) { raise Interrupt } }
  environment = { 'DEVELOPER_DIR' => developer, 'SDKROOT' => nil, 'TOOLCHAINS' => nil, NATIVE_OPT_IN => nil }
  base = [swift, 'test', '--package-path', root, '--scratch-path', scratch, '--jobs', options[:jobs].to_s]
  discovery_log = run_command('discover-and-build', base + ['--list-tests'], environment, root, evidence, options[:timeout])
  check_source(root, expected_source)
  discovered = File.readlines(discovery_log).map(&:strip).select { |line| line.match?(/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+\z/) }
  fail_gate('empty selected test discovery') if discovered.empty?
  fail_gate('duplicate discovered method identities') unless discovered.uniq.length == discovered.length
  REQUIRED_CLASSES.each do |class_name|
    fail_gate("required test class missing from discovery: #{class_name}") unless discovered.any? { |id| id.start_with?(class_name + '/') }
  end
  REQUIRED_METHODS.each do |id|
    fail_gate("required safety method missing from discovery: #{id}") unless discovered.include?(id)
  end
  selected = discovered.select do |id|
    REQUIRED_CLASSES.include?(id.split('/').first) || id.start_with?('CaptureServerTests.WorldwideScreenStartup')
  end.sort
  fail_gate('empty deterministic selection') if selected.empty?
  if options[:native]
    NATIVE_METHODS.each { |id| fail_gate("required native method missing from discovery: #{id}") unless discovered.include?(id) }
  end
  if options[:capacity]
    CAPACITY_METHODS.each { |id| fail_gate("required capacity method missing from discovery: #{id}") unless discovered.include?(id) }
  end
  File.write(File.join(evidence, 'test-manifest.json'), JSON.pretty_generate(
    deterministic: selected, native: options[:native] ? NATIVE_METHODS : [],
    capacity: options[:capacity] ? CAPACITY_METHODS : [], capacity_rounds: options[:capacity] ? 3 : 0,
    jobs: options[:jobs], source_sha256: expected_source
  ))
  phases = [['deterministic', selected, environment]]
  if options[:native]
    NATIVE_METHODS.each_with_index do |id, index|
      phases << ["native-#{index + 1}", [id], environment.merge(NATIVE_OPT_IN => '1')]
    end
  end
  if options[:capacity]
    3.times do |round|
      CAPACITY_METHODS.each_with_index do |id, index|
        phases << ["capacity-#{round + 1}-#{index + 1}", [id], environment.merge(NATIVE_OPT_IN => '1')]
      end
    end
  end
  phases.each do |label, methods, phase_environment|
    check_source(root, expected_source)
    filter = '^(?:' + methods.map { |id| Regexp.escape(id) }.join('|') + ')$'
    xml = File.join(evidence, label + '.xml')
    log = run_command(label, base + ['--skip-build', '--filter', filter, '--xunit-output', xml], phase_environment, root, evidence, options[:timeout])
    check_source(root, expected_source)
    format = validate_results(xml, log, methods)
    File.write(File.join(evidence, label + '.results.json'), JSON.pretty_generate(format: format, passed: methods))
    puts "screen-startup: #{label} passed #{methods.length} required methods without skips (#{format})"
  end
  check_source(root, expected_source)
  puts "screen-startup: PASS (#{options[:native] ? 'deterministic + native' : 'deterministic'}); evidence #{evidence}"
rescue Interrupt
  warn 'screen-startup: FAIL: interrupted; owned subprocess group terminated'
  exit 130
rescue StandardError => error
  warn "screen-startup: FAIL: #{error.message}"
  exit 1
ensure
  lock.close if defined?(lock) && lock
end
RUBY
