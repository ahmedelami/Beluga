require 'minitest/autorun'
require 'rbconfig'
require_relative '../scripts/run-tap-startup-ab'

# These contracts exercise the report evaluator and refusal surface, not Core Audio.
class TapStartupProbeContractTests < Minitest::Test
  def event(pid, event, stage, value)
    {'pid' => pid, 'event' => event, 'stage' => stage, 'value' => value, 'schema' => 1, 'monotonicNS' => 100}
  end
  def arm(auto_start, input_status: 0)
    owner, reader = 501, 502
    events = [event(owner, 'checked', 'tap_auto_start_readback', auto_start),
              event(owner, 'begin', 'tap_start', auto_start), event(owner, 'end', 'writer_start', 0),
              event(owner, 'measurement', 'writer_callbacks', 100), event(owner, 'measurement', 'tap_callbacks', 0),
              event(owner, 'measurement', 'foreign_output_observed', 0), event(reader, 'measurement', 'foreign_output_observed', 0),
              event(reader, 'begin', 'input_start', 0), event(reader, 'end', 'input_start', input_status),
              event(reader, 'checked', 'input_uid_after_start', 1), event(reader, 'measurement', 'input_callback_error', 0),
              event(reader, 'measurement', 'input_callbacks', 20), event(reader, 'measurement', 'input_frames', 9600),
              event(reader, 'measurement', 'input_advancing_timestamps', 19),
              event(owner, 'teardown', 'owner', 1), event(reader, 'teardown', 'reader', 1),
              event(owner, 'final', 'selectors_unchanged', 1), event(reader, 'final', 'selectors_unchanged', 1)]
    {auto_start: auto_start, owner_pid: owner, reader_pid: reader, events: events,
     passive_after: true, clean_exit: true, killed: false}
  end
  def test_tap_start_timeout_is_not_input_failure
    # Deliberately no tap-start END and zero tap callbacks. Input is independently progressing.
    assert_equal 'input_callbacks_progressed', TapStartupAB.input_outcome(arm(1))
    assert_equal 'no_input_start_failure_observed', TapStartupAB.verdict([1, 0, 0, 1].map { |v| arm(v) })
  end
  def test_counterbalanced_native_differential_is_not_labeled_cause
    arms = [arm(1, input_status: 60), arm(0), arm(0), arm(1, input_status: 60)]
    assert_equal 'input_start_differential_observed_not_causal_proof', TapStartupAB.verdict(arms)
  end
  def test_playback_contaminates_cold_result
    arms = [1, 0, 0, 1].map { |v| arm(v) }
    arms[2][:events].find { |e| e['stage'] == 'foreign_output_observed' }['value'] = 1
    assert_equal 'non_cold_playback_observed_inconclusive', TapStartupAB.verdict(arms)
  end
  def test_fail_closed_negative_mutation_matrix
    mutations = {
      killed: ->(a) { a[:killed] = true },
      no_passive_proof: ->(a) { a[:passive_after] = false },
      no_exit: ->(a) { a[:clean_exit] = false },
      deadline: ->(a) { a[:failure] = 'native stage deadline exceeded' },
      guard: ->(a) { a[:events] << event(501, 'guard_failed', 'host_identity', 1) },
      wrong_auto_start: ->(a) { a[:events].find { |e| e['stage'] == 'tap_auto_start_readback' }['value'] = 0 },
      missing_owner_teardown: ->(a) { a[:events].reject! { |e| e['stage'] == 'owner' } },
      failed_reader_teardown: ->(a) { a[:events].find { |e| e['stage'] == 'reader' }['value'] = 0 },
      changed_selector: ->(a) { a[:events].find { |e| e['stage'] == 'selectors_unchanged' }['value'] = 0 },
      no_writer_progress: ->(a) { a[:events].find { |e| e['stage'] == 'writer_callbacks' }['value'] = 0 },
      missing_tap_measurement: ->(a) { a[:events].reject! { |e| e['stage'] == 'tap_callbacks' } },
      no_output_scan: ->(a) { a[:events].reject! { |e| e['stage'] == 'foreign_output_observed' } },
      duplicate_status: ->(a) { a[:events] << event(502, 'end', 'input_start', 0) },
      callback_error: ->(a) { a[:events].find { |e| e['stage'] == 'input_callback_error' }['value'] = -50 }
    }
    mutations.each do |name, mutate|
      sample = arm(1); mutate.call(sample)
      assert_equal 'invalid', TapStartupAB.input_outcome(sample), "negative mutant survived: #{name}"
    end
  end
  def test_no_advance_is_not_success
    sample = arm(1)
    sample[:events].find { |e| e['stage'] == 'input_advancing_timestamps' }['value'] = 0
    assert_equal 'input_did_not_progress', TapStartupAB.input_outcome(sample)
    assert_equal 'invalid_or_incomplete', TapStartupAB.verdict([sample])
  end
  def test_missing_opt_in_never_constructs_native_supervisor
    _out, err = capture_io { assert_equal 2, TapStartupAB.main([]) }
    assert_includes err, 'explicit live opt-in'
  end
  def test_native_source_preserves_no_control_and_metadata_contract
    source = File.read(File.expand_path('../Probes/TapStartupProbe.m', __dir__))
    refute_match(/AudioObjectSetPropertyData\s*\(/, source)
    refute_match(/requestAccess|TCCAccessSet|launchctl|killall|AudioFileCreateWithURL|ExtAudioFileCreateWithURL/, source.gsub(%r{//[^\n]*}, ''))
    assert_match(/memset\(output->mBuffers\[i\]\.mData, 0,/, source)
    assert_match(/kAudioAggregateDeviceTapAutoStartKey: @\(autoStart\)/, source)
    assert_match(/--permission-check/, source)
  end
  def test_real_owned_no_audio_child_is_killed_and_reaped_within_deadline
    # This worker only emits one metadata record then sleeps; no native/audio API.
    child_input, input = IO.pipe
    output, child_output = IO.pipe
    error, child_error = IO.pipe
    script = "require 'json'; trap('TERM') {}; STDOUT.sync = true; puts({schema: 1, event: 'ready', stage: 'reader', value: 0, monotonicNS: 1, pid: Process.pid}.to_json); loop { sleep 1 }"
    pid = Process.spawn(RbConfig.ruby, '-e', script, in: child_input, out: child_output, err: child_error, close_others: true)
    [child_input, child_output, child_error].each(&:close)
    child = {pid: pid, waiter: TapStartupAB::ChildExitHandle.new(pid), input: input, output: output,
             error: error, buffer: '', events: [], bytes: 0, stderr_bytes: 0, killed: false}
    supervisor = TapStartupAB::Supervisor.new({})
    supervisor.wait_for([child], supervisor.now + 5) { !child[:events].empty? }
    started = supervisor.now
    supervisor.stop([child])
    assert child[:killed]
    refute child[:waiter].alive?
    assert child[:waiter].value.signaled?
    assert_operator supervisor.now - started, :<, 5
  ensure
    if child && child[:waiter].alive?
      Process.kill('KILL', child[:pid]); child[:waiter].join(1)
    end
    [input, output, error].compact.each { |io| io.close unless io.closed? }
  end
end
