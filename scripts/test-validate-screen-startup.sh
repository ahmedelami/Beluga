#!/bin/bash
set -euo pipefail
exec /usr/bin/ruby - "$0" "$@" <<'RUBY'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

abort 'usage: scripts/test-validate-screen-startup.sh' unless ARGV.length == 1
abort 'runner self-tests require Darwin/macOS' unless RUBY_PLATFORM.include?('darwin')
source = File.join(File.dirname(File.realpath(ARGV.shift)), 'validate-screen-startup.sh')
runner_source = File.read(source)
required = runner_source[/REQUIRED_CLASSES = %w\[(.*?)\]/m, 1].split
pinned_methods = runner_source[/REQUIRED_METHODS = %w\[(.*?)\]/m, 1].split
native = runner_source[/NATIVE_METHODS = %w\[(.*?)\]/m, 1].split
raise 'invariant sequence class is absent from the gate' unless required.include?('CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests')
raise 'expected the two explicit native methods' unless native.length == 2

def assert(condition, message)
  raise message unless condition
end

Dir.mktmpdir('startup-runner-selftest-') do |temporary|
  root = File.join(temporary, 'repository')
  FileUtils.mkdir_p(File.join(root, 'scripts'))
  FileUtils.mkdir_p(File.join(root, 'shared/Sources/WebRTCTransport'))
  runner = File.join(root, 'scripts/validate-screen-startup.sh')
  FileUtils.cp(source, runner)
  File.write(File.join(root, 'Package.swift'), '// fixture manifest; never compiled\n')
  mutable_source = File.join(root, 'shared/Sources/WebRTCTransport/Fixture.swift')
  File.write(mutable_source, '// source identity fixture\n')
  developer = File.join(temporary, 'Reviewed Xcode.app/Contents/Developer')
  swift = File.join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift')
  FileUtils.mkdir_p(File.dirname(swift))
  FileUtils.mkdir_p(File.join(developer, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'))
  extra = 'CaptureServerTests.WorldwideScreenStartupAdditionalRegressionTests/testFutureCoverage'
  unrelated = 'CaptureServerTests.UnrelatedTests/testNotSelected'
  all_methods = required.map { |class_name| class_name + '/testFixture' } + pinned_methods + native + [extra, unrelated]
  manifest = File.join(temporary, 'fake-methods.json')
  File.write(manifest, JSON.generate(all_methods))
  File.write(swift, <<~'FAKE')
    #!/usr/bin/ruby
    require 'json'
    mode = ENV.fetch('STARTUP_GATE_FAKE_MODE')
    trace = ENV.fetch('STARTUP_GATE_FAKE_TRACE')
    File.open(trace, 'a') { |file| file.puts JSON.generate(pid: Process.pid, argv: ARGV, native: ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT']) }
    methods = JSON.parse(File.read(ENV.fetch('STARTUP_GATE_FAKE_MANIFEST')))
    if ARGV.include?('--list-tests')
      sleep 5 if mode == 'timeout'
      exit 7 if mode == 'compile_failure'
      exit 0 if mode == 'no_match'
      methods.reject! { |id| id.include?('InvariantSequenceTests') } if mode == 'missing_class'
      methods.reject! { |id| id.include?('testShowKeepsExistingTrafficCeilingsButStartsWithFullPixels') } if mode == 'missing_method'
      methods.reject! { |id| id.include?('testConfiguredCapAndSourceFPSMatrixGivesUncertaintyNoAuthority') } if mode == 'missing_sequence_method'
      methods.reject! { |id| id.include?('testDelayedNetworkBlackout') } if mode == 'missing_native'
      if mode == 'source_change'
        File.open(ENV.fetch('STARTUP_GATE_FAKE_SOURCE'), 'a') { |file| file.puts '// changed while compiling' }
      end
      puts methods
      exit 0
    end
    filter = Regexp.new(ARGV.fetch(ARGV.index('--filter') + 1))
    selected = methods.select { |id| filter.match?(id) }
    native = selected.any? { |id| id.include?('WebRTCStartupClarityExperimentTests/') }
    exit 8 if mode == 'nonzero' || (mode == 'native_nonzero' && native)
    exit 0 if mode == 'false_green'
    if mode.start_with?('log_')
      if mode == 'log_swift_testing_only'
        puts '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
        exit 0
      end
      selected = [] if mode == 'log_no_cases'
      selected = selected.drop(1) if mode == 'log_omitted_case'
      selected << selected.first if mode == 'log_duplicate'
      selected << methods.find { |id| id.include?('UnrelatedTests/') } if mode == 'log_unexpected'
      puts "Test Suite 'Selected tests' started at 2026-09-19 11:20:48.308."
      selected.each_with_index do |id, index|
        class_name, name = id.split('/')
        prefix = "Test Case '-[#{class_name} #{name}]'"
        puts "#{prefix} started." unless mode == 'log_missing_start' && index.zero?
        skipped = native && (mode == 'log_skipped_native' || ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT'] != '1')
        state = skipped ? 'skipped' : mode == 'log_failed' ? 'failed' : 'passed'
        state = 'unrecognized' if mode == 'log_unrecognized_case'
        puts "#{prefix} #{state} (0.001 seconds)." unless mode == 'log_unfinished_case' && index == selected.length - 1
      end
      unless mode == 'log_missing_suite_end'
        repetitions = mode == 'log_duplicate_footer' ? 2 : 1
        repetitions.times do
          puts "Test Suite 'Selected tests' passed at 2026-09-19 11:20:52.295."
          next if mode == 'log_truncated_footer'
          count = selected.length + (mode == 'log_wrong_count' ? 1 : 0)
          skipped = mode == 'log_skipped_summary' ? '1 test skipped and ' : ''
          failures = mode == 'log_failed_summary' ? '1' : '0'
          puts "\t Executed #{count} tests, with #{skipped}#{failures} failures (0 unexpected) in 3.975 (3.987) seconds"
        end
      end
      if mode == 'log_case_after_footer'
        class_name, name = selected.first.split('/')
        puts "Test Case '-[#{class_name} #{name}]' started."
      end
      puts 'NATIVE_FIXTURE_DIAGNOSTIC scalar=1'
      puts '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
      exit(mode == 'log_nonzero' ? 8 : 0)
    end
    selected = [] if mode == 'empty_native' && native
    selected = selected.drop(1) if mode == 'omitted_case' && !native
    selected << selected.first if mode == 'duplicate_results'
    selected << methods.find { |id| id.include?('UnrelatedTests/') } if mode == 'unexpected_result'
    xml = ARGV.fetch(ARGV.index('--xunit-output') + 1)
    File.open(xml, 'w') do |file|
      file.puts '<testsuites><testsuite>'
      selected.each do |id|
        class_name, name = id.split('/')
        file.puts %Q{<testcase classname="#{class_name}" name="#{name}">}
        skipped = native && (mode == 'skipped_native' || ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT'] != '1')
        skipped ||= mode == 'skipped_default' && !native
        file.puts '<skipped message="required opt-in absent"/>' if skipped
        file.puts '<failure message="fixture failure"/>' if mode == 'xml_failure'
        file.puts '</testcase>'
      end
      file.puts '</testsuite></testsuites>'
    end
  FAKE
  FileUtils.chmod(0755, swift)
  cases = 0
  run = lambda do |mode, native_enabled: false, expected_failure: nil, extra_args: [], omit_developer: false, scratch: nil, jobs: '2', inherited_native: '1'|
    cases += 1
    scratch ||= File.join(temporary, "scratch-#{cases}")
    trace = File.join(temporary, "trace-#{cases}.jsonl")
    environment = {
      'DEVELOPER_DIR' => omit_developer ? nil : developer,
      'STARTUP_GATE_FAKE_MODE' => mode,
      'STARTUP_GATE_FAKE_TRACE' => trace,
      'STARTUP_GATE_FAKE_MANIFEST' => manifest,
      'STARTUP_GATE_FAKE_SOURCE' => mutable_source,
      'OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT' => inherited_native,
    }
    args = ['/bin/bash', runner, '--scratch-path', scratch, '--jobs', jobs]
    args << '--native' if native_enabled
    output, status = Open3.capture2e(environment, *(args + extra_args))
    if expected_failure
      assert(!status.success?, "#{mode} unexpectedly passed: #{output}")
      assert(output.include?(expected_failure), "#{mode} lacked expected rejection #{expected_failure.inspect}: #{output}")
    else
      assert(status.success? && output.include?('screen-startup: PASS'), "#{mode} failed: #{output}")
    end
    calls = File.file?(trace) ? File.readlines(trace).map { |line| JSON.parse(line) } : []
    [calls, scratch, output]
  end

  run.call('no_match', expected_failure: 'empty selected test discovery')
  run.call('missing_class', expected_failure: 'required test class missing')
  run.call('missing_method', expected_failure: 'required safety method missing')
  run.call('missing_sequence_method', expected_failure: 'required safety method missing')
  run.call('missing_native', native_enabled: true, expected_failure: 'required native method missing')
  run.call('compile_failure', expected_failure: 'discover-and-build exited unsuccessfully')
  run.call('nonzero', expected_failure: 'deterministic exited unsuccessfully')
  run.call('native_nonzero', native_enabled: true, expected_failure: 'native-1 exited unsuccessfully')
  run.call('skipped_native', native_enabled: true, expected_failure: 'required test skipped')
  run.call('skipped_default', expected_failure: 'required test skipped')
  run.call('empty_native', native_enabled: true, expected_failure: 'empty selected test results')
  run.call('omitted_case', expected_failure: 'required tests missing from results')
  run.call('duplicate_results', expected_failure: 'duplicate test results')
  run.call('unexpected_result', expected_failure: 'unexpected test result')
  run.call('false_green', expected_failure: 'missing or duplicate Selected tests start record')
  run.call('xml_failure', expected_failure: 'required test failed')
  run.call('source_change', expected_failure: 'source changed during this invocation')
  run.call('timeout', expected_failure: 'exceeded its process deadline', extra_args: ['--timeout-seconds', '1'])
  run.call('log_success')
  run.call('log_success', native_enabled: true, inherited_native: '0')
  run.call('log_swift_testing_only', expected_failure: 'missing or duplicate Selected tests start record')
  run.call('log_no_cases', expected_failure: 'empty selected XCTest results')
  run.call('log_omitted_case', expected_failure: 'required tests missing from results')
  run.call('log_duplicate', expected_failure: 'duplicate XCTest start')
  run.call('log_unexpected', expected_failure: 'unexpected test result')
  run.call('log_skipped_native', native_enabled: true, expected_failure: 'required test skipped')
  run.call('log_failed', expected_failure: 'required test failed')
  run.call('log_missing_start', expected_failure: 'XCTest pass without matching start')
  run.call('log_unfinished_case', expected_failure: 'unfinished XCTest case')
  run.call('log_missing_suite_end', expected_failure: 'missing or duplicate Selected tests passed record')
  run.call('log_truncated_footer', expected_failure: 'missing or malformed Selected tests count footer')
  run.call('log_wrong_count', expected_failure: 'count footer disagrees with required method manifest')
  run.call('log_skipped_summary', expected_failure: 'footer reports skips or failures')
  run.call('log_failed_summary', expected_failure: 'footer reports skips or failures')
  run.call('log_duplicate_footer', expected_failure: 'missing or duplicate Selected tests passed record')
  run.call('log_case_after_footer', expected_failure: 'case record outside Selected tests suite')
  run.call('log_unrecognized_case', expected_failure: 'unrecognized XCTest case record')
  run.call('log_nonzero', expected_failure: 'deterministic exited unsuccessfully')
  calls, = run.call('success', expected_failure: 'set DEVELOPER_DIR explicitly', omit_developer: true)
  assert(calls.empty?, 'missing developer directory invoked Swift')
  calls, = run.call('success', expected_failure: 'unrecognized argument', extra_args: ['--unknown'])
  assert(calls.empty?, 'unrecognized option invoked Swift')
  calls, = run.call('success', expected_failure: '--jobs must be 1 or 2', jobs: '3')
  assert(calls.empty?, 'invalid jobs invoked Swift')
  ['/', Dir.home, root].each do |broad_path|
    calls, = run.call('success', scratch: broad_path, expected_failure: 'dedicated')
    assert(calls.empty?, 'broad scratch path invoked Swift')
  end
  calls, = run.call('success', scratch: 'relative-scratch', expected_failure: 'absolute dedicated build directory')
  assert(calls.empty?, 'relative scratch path invoked Swift')

  calls, scratch = run.call('success')
  assert(calls.length == 2, 'default invocation did not discover/build once and execute once')
  assert(calls.all? { |call| call['native'].nil? }, 'ambient native opt-in leaked into default phases')
  filter = Regexp.new(calls.last['argv'].fetch(calls.last['argv'].index('--filter') + 1))
  assert(filter.match?(extra), 'future WorldwideScreenStartup prefix coverage was omitted')
  assert(!filter.match?(unrelated), 'unrelated test entered the gate')
  marker = File.join(scratch, 'existing-build-cache-marker')
  File.write(marker, 'keep')
  run.call('success', scratch: scratch)
  assert(File.read(marker) == 'keep', 'reusing the scratch path deleted its cache')
  assert(Dir.glob(File.join(scratch, 'validation-runs/startup-*')).length == 2, 'evidence paths were reused')

  calls, = run.call('success', native_enabled: true, inherited_native: '0')
  assert(calls.length == 4, 'native invocation must have one build and three execution phases')
  assert(!calls.first['argv'].include?('--skip-build'), 'first phase improperly skipped its build')
  assert(calls.drop(1).all? { |call| call['argv'].include?('--skip-build') }, 'same-invocation artifact was rebuilt')
  assert(calls.map { |call| call['pid'] }.uniq.length == 4, 'native methods shared a process')
  assert(calls.take(2).all? { |call| call['native'].nil? }, 'native opt-in leaked into build/default phase')
  assert(calls.drop(2).all? { |call| call['native'] == '1' }, 'native opt-in was not enforced')
  calls.drop(2).zip(native).each do |call, method|
    selection = Regexp.new(call['argv'].fetch(call['argv'].index('--filter') + 1))
    assert(all_methods.select { |id| selection.match?(id) } == [method], 'native phase did not select exactly its required method')
  end
  puts "screen-startup runner self-tests: PASS (#{cases} scenarios; fake Swift only)"
end
RUBY
