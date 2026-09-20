#!/usr/bin/env ruby
# Native diagnostic supervisor. Importing this file never touches Core Audio.
require 'digest'
require 'json'
require 'optparse'
require 'securerandom'

module TapStartupAB
  class Invalid < StandardError; end
  # No background reaper: an unreaped child PID cannot be reused between our
  # alive? check and signal. Only this supervisor calls waitpid for these PIDs.
  class ChildExitHandle
    attr_reader :pid
    def initialize(pid); @pid, @status = pid, nil; end
    def alive?
      return false if @status
      result = Process.waitpid2(@pid, Process::WNOHANG)
      @status = result.last if result
      @status.nil?
    end
    def join(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      while alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.01
      end
      self
    end
    def value
      raise Invalid, 'owned child still alive' if alive?
      @status
    end
  end
  EVENT_NAMES = %w[ready begin end measurement checked teardown final guard_failed].freeze
  STAGES = %w[reader reader_teardown input_start input_uid_after_start input_callbacks input_frames
              input_valid_timestamps input_advancing_timestamps writer_start tap_start
              tap_auto_start_readback owner selectors_unchanged preflight idle runtime_identity_or_selectors
              writer_callbacks tap_callbacks foreign_output_observed input_callback_error supervisor_identity
              default_selectors host_identity driver_identity endpoint_identity clock_identity public_tap_set
              process_output_scan driver_snapshot preexisting_active_client foreign_active_client peer_identity
              driver_hash host_hash endpoint_format selector_listener microphone_permission
              host_process_list host_unnamed_live_process host_pid_or_ambiguity host_path host_bsd_metadata
              host_start_tuple host_file_identity host_presence host_public_process_metadata_unknown
              production_aligned reader_included production_forwarding writer_uid_before_start
              writer_uid_after_start input_uid_before_start input_voice_processing_disabled
              input_error_domain input_engine_start input_setup input_only_after_start
              input_callbacks_drained writer_format_after_start writer_callback_error
              own_output_observed peer_output_observed
              input_node_format_rate input_node_format_channels input_node_format_common
              input_hardware_format_status input_hardware_format_rate input_hardware_format_channels input_hardware_format_flags
              input_unit_format_status input_unit_format_rate input_unit_format_channels input_unit_format_flags
              input_format_after_prepare input_format_after_start tap_retirement tap_only
              writer_callbacks_before_tap_retirement writer_callbacks_after_tap_retirement
              writer_uid_before_tap_retirement writer_uid_after_tap_retirement
              writer_format_before_tap_retirement writer_format_after_tap_retirement
              writer_continued_during_tap_retirement].freeze
  def self.value(events, event, stage)
    found = events.select { |e| e['event'] == event && e['stage'] == stage }
    found.length == 1 ? found.first['value'] : nil
  end
  def self.input_outcome(arm)
    return 'invalid' unless arm[:passive_after] && arm[:clean_exit] && !arm[:killed] && !arm[:failure] &&
      arm[:events].none? { |e| e['event'] == 'guard_failed' }
    owner = arm[:events].select { |e| e['pid'] == arm[:owner_pid] }
    reader = arm[:events].select { |e| e['pid'] == arm[:reader_pid] }
    return 'invalid' unless value(owner, 'teardown', 'owner') == 1 && value(reader, 'teardown', 'reader') == 1 &&
      value(owner, 'final', 'selectors_unchanged') == 1 && value(reader, 'final', 'selectors_unchanged') == 1 &&
      value(owner, 'checked', 'tap_auto_start_readback') == arm[:auto_start] && value(owner, 'end', 'writer_start') == 0 &&
      value(owner, 'begin', 'tap_start') == arm[:auto_start] && value(reader, 'begin', 'input_start') == 0 &&
      (value(owner, 'measurement', 'writer_callbacks') || 0) > 0 &&
      !value(owner, 'measurement', 'tap_callbacks').nil? &&
      [owner, reader].all? { |events| [0, 1].include?(value(events, 'measurement', 'foreign_output_observed')) }
    if arm[:production_aligned]
      return 'invalid' unless arm[:owner_exit_status] == 0 &&
        [owner, reader].all? { |events| value(events, 'checked', 'production_aligned') == 1 } &&
        value(owner, 'checked', 'reader_included') == 1 && value(owner, 'end', 'tap_start') == 0 &&
        value(owner, 'checked', 'writer_uid_before_start') == 1 && value(owner, 'checked', 'writer_uid_after_start') == 1 &&
        value(owner, 'checked', 'writer_format_after_start') == 1 && value(owner, 'measurement', 'writer_callback_error') == 0 &&
        value(reader, 'checked', 'input_uid_before_start') == 1 && value(reader, 'checked', 'input_voice_processing_disabled') == 1 &&
        value(reader, 'end', 'input_setup') == 0 && value(reader, 'checked', 'input_callbacks_drained') == 1 &&
        value(reader, 'checked', 'input_hardware_format_status') == 0 &&
        value(reader, 'checked', 'input_hardware_format_rate') == 48000 &&
        value(reader, 'checked', 'input_hardware_format_channels') == 1 &&
        [9, 41].include?(value(reader, 'checked', 'input_hardware_format_flags')) &&
        value(reader, 'checked', 'input_format_after_prepare') == 1 &&
        value(reader, 'begin', 'input_engine_start') == 0 &&
        value(owner, 'ready', 'production_forwarding') == 1 &&
        [owner, reader].all? { |events| %w[own_output_observed peer_output_observed].all? { |stage| [0, 1].include?(value(events, 'measurement', stage)) } }
      ordered = [[owner, 'end', 'tap_start'], [owner, 'begin', 'writer_start'],
                 [owner, 'end', 'writer_start'], [owner, 'ready', 'production_forwarding'],
                 [reader, 'begin', 'input_start']].map do |events, event, stage|
        matches = events.select { |e| e['event'] == event && e['stage'] == stage }
        matches.length == 1 ? matches.first['monotonicNS'] : nil
      end
      return 'invalid' unless ordered.all? { |time| time.is_a?(Integer) && time > 0 } &&
        ordered.each_cons(2).all? { |before, after| before < after }
    end
    status = value(reader, 'end', 'input_start')
    return 'invalid' if status.nil?
    if arm[:production_aligned]
      return 'invalid' unless value(reader, 'end', 'input_engine_start') == status &&
        arm[:reader_exit_status] == (status == 0 ? 0 : 1) &&
        (status == 0 ? value(reader, 'checked', 'input_error_domain') == 0 : [1, 2, 3, 4].include?(value(reader, 'checked', 'input_error_domain')))
      return 'invalid' if status == 0 && (value(reader, 'checked', 'input_only_after_start') != 1 ||
        value(reader, 'checked', 'input_format_after_start') != 1)
    end
    return 'invalid' if arm[:tap_retirement_requested] && status != 0
    return 'input_start_error' unless status == 0
    return 'invalid' unless value(reader, 'checked', 'input_uid_after_start') == 1 && value(reader, 'measurement', 'input_callback_error') == 0
    callbacks = value(reader, 'measurement', 'input_callbacks')
    frames = value(reader, 'measurement', 'input_frames')
    advancing = value(reader, 'measurement', 'input_advancing_timestamps')
    return 'invalid' if [callbacks, frames, advancing].any?(&:nil?)
    progressed = callbacks >= 2 && frames > 0 && advancing > 0
    if arm[:tap_retirement_requested]
      return 'invalid' unless arm[:production_aligned] && progressed &&
        value(owner, 'begin', 'tap_retirement') == 0 && value(owner, 'end', 'tap_retirement') == 0 &&
        value(owner, 'teardown', 'tap_only') == 1 && value(owner, 'measurement', 'tap_callbacks') == 0 &&
        %w[writer_uid_before_tap_retirement writer_uid_after_tap_retirement writer_format_before_tap_retirement
           writer_format_after_tap_retirement writer_continued_during_tap_retirement].all? { |stage| value(owner, 'checked', stage) == 1 }
      before = value(owner, 'measurement', 'writer_callbacks_before_tap_retirement')
      after = value(owner, 'measurement', 'writer_callbacks_after_tap_retirement')
      return 'invalid' unless before.is_a?(Integer) && before > 0 && after.is_a?(Integer) && after >= before + 2
      started = reader.find { |e| e['event'] == 'begin' && e['stage'] == 'input_engine_start' }['monotonicNS']
      returned = reader.find { |e| e['event'] == 'end' && e['stage'] == 'input_engine_start' }['monotonicNS']
      retired = owner.find { |e| e['event'] == 'begin' && e['stage'] == 'tap_retirement' }['monotonicNS']
      return 'invalid' unless retired - started >= 15_000_000_000 && returned >= retired && returned - retired <= 5_000_000_000
      return 'input_pending_until_tap_retirement'
    end
    progressed ? 'input_callbacks_progressed' : 'input_did_not_progress'
  end
  def self.early_stop_reason(arms)
    return nil unless arms.any? { |arm| arm[:production_aligned] }
    return 'invalid_or_incomplete' unless arms.all? { |arm| arm[:production_aligned] && input_outcome(arm) != 'invalid' }
    return 'non_cold_playback_observed_inconclusive' if arms.any? { |arm| arm[:events].any? { |e| e['stage'] == 'foreign_output_observed' && e['value'] == 1 } }
    return 'reader_output_observed_inconclusive' if arms.any? do |arm|
      arm[:events].any? { |e| e['event'] == 'measurement' && e['value'] == 1 &&
        ((e['pid'] == arm[:reader_pid] && e['stage'] == 'own_output_observed') ||
         (e['pid'] == arm[:owner_pid] && e['stage'] == 'peer_output_observed')) }
    end
    if arms.length == 1 && arms.first[:auto_start] == 1 && input_outcome(arms.first) == 'input_callbacks_progressed'
      return 'baseline_did_not_reproduce_input_failure'
    end
    nil
  end
  def self.verdict(arms)
    early = early_stop_reason(arms)
    return early if early
    return 'invalid_or_incomplete' unless arms.length == 4 && arms.map { |a| a[:auto_start] } == [1, 0, 0, 1]
    outcomes = arms.map { |a| input_outcome(a) }
    return 'invalid_or_incomplete' if outcomes.include?('invalid')
    return 'non_cold_playback_observed_inconclusive' if arms.any? { |a| a[:events].any? { |e| e['stage'] == 'foreign_output_observed' && e['value'] == 1 } }
    return 'no_input_start_failure_observed' if outcomes.all? { |v| v == 'input_callbacks_progressed' }
    if [0, 3].all? { |i| outcomes[i] != 'input_callbacks_progressed' } && [1, 2].all? { |i| outcomes[i] == 'input_callbacks_progressed' }
      return 'input_start_differential_observed_not_causal_proof'
    end
    'no_repeatable_auto_start_specific_input_differential'
  end

  class Supervisor
    def initialize(options)
      @options, @children, @passive_checks = options, [], []
    end
    def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
    def spawn_worker(mode, run_id, auto_start, other_pid = 0)
      raise Invalid, 'native binary hash changed' unless Digest::SHA256.file(@options.fetch(:native)).hexdigest == @options.fetch(:native_sha256)
      args = {
        'mode' => mode, 'supervisor-pid' => Process.pid, 'driver-sha256' => @options.fetch(:driver_sha256),
        'driver-instance' => @options.fetch(:driver_instance), 'clock-uid' => @options.fetch(:clock_uid),
        'input-uid' => @options.fetch(:input_uid), 'output-uid' => @options.fetch(:output_uid),
        'system-output-uid' => @options.fetch(:system_output_uid), 'run-id' => run_id,
        'other-pid' => other_pid, 'tap-auto-start' => auto_start, 'host-pid' => @options.fetch(:host_pid),
        'host-start-seconds' => @options.fetch(:host_start_seconds), 'host-start-microseconds' => @options.fetch(:host_start_microseconds),
        'host-sha256' => @options.fetch(:host_sha256), 'audio-capture-permission-confirmed' => 'already-authorized'
      }
      args['production-aligned'] = 1 if @options[:production_aligned]
      child_input, input = IO.pipe
      output, child_output = IO.pipe
      error, child_error = IO.pipe
      begin
        pid = Process.spawn(@options.fetch(:native), '--live-opt-in', *args.flat_map { |k, v| ["--#{k}", v.to_s] },
                            in: child_input, out: child_output, err: child_error, close_others: true)
      ensure
        [child_input, child_output, child_error].each(&:close)
      end
      waiter = ChildExitHandle.new(pid)
      child = {input: input, output: output, error: error, waiter: waiter, pid: waiter.pid, buffer: '', events: [], stderr_bytes: 0, bytes: 0, killed: false}
      @children << child
      child
    end
    def pump(children, duration = 0.05)
      streams = children.flat_map { |c| [c[:output], c[:error]] }.reject(&:closed?)
      return if streams.empty?
      ready = IO.select(streams, nil, nil, duration)
      return unless ready
      ready.first.each do |stream|
        child = children.find { |c| c[:output] == stream || c[:error] == stream }
        bytes = stream.read_nonblock(4096, exception: false)
        if bytes.nil?
          stream.close
        elsif bytes != :wait_readable
          child[:bytes] += bytes.bytesize
          raise Invalid, 'worker output exceeded metadata bound' if child[:bytes] > 65536
          if child[:error] == stream
            child[:stderr_bytes] += bytes.bytesize # Never retain arbitrary native/TCC log text.
          else
            child[:buffer] << bytes
            while (line = child[:buffer].slice!(/\A[^\n]*\n/))
              event = JSON.parse(line)
              valid = event.keys.sort == %w[event monotonicNS pid schema stage value].sort && event['schema'] == 1 &&
                event['pid'] == child[:pid] && EVENT_NAMES.include?(event['event']) && STAGES.include?(event['stage']) &&
                event['value'].is_a?(Integer) && event['monotonicNS'].is_a?(Integer) && event['monotonicNS'] > 0
              raise Invalid, 'invalid native event' unless valid
              child[:events] << event
              raise Invalid, "runtime guard failed: #{event['stage']}" if event['event'] == 'guard_failed'
            end
          end
        end
      end
    rescue JSON::ParserError
      raise Invalid, 'invalid native JSON'
    end
    def wait_for(children, deadline)
      until yield
        raise Invalid, 'native stage deadline exceeded' if now >= deadline
        pump(children)
        raise Invalid, 'worker exited before required stage' if children.any? { |c| !c[:waiter].alive? && c[:output].closed? }
      end
    end
    def stop(children)
      # Only retained, unreaped child handles can be signalled; never process names/groups.
      children.each { |c| Process.kill('TERM', c[:pid]) if c[:waiter].alive? }
      deadline = now + 3
      while children.any? { |c| c[:waiter].alive? } && now < deadline
        begin; pump(children); rescue Invalid; break; end
      end
      children.each do |c|
        if c[:waiter].alive?
          Process.kill('KILL', c[:pid])
          c[:killed] = true
        end
        c[:waiter].join(1)
        raise Invalid, 'owned child did not reap after deadline' if c[:waiter].alive?
      end
      3.times { pump(children, 0) }
    ensure
      children.each { |c| c[:input].close unless c[:input].closed? }
    end
    def passive_check(run_id)
      child = spawn_worker('check', run_id, 0)
      failure = nil
      deadline = now + 5
      begin
        while child[:waiter].alive? && now < deadline
          pump([child])
        end
        failure = 'passive check deadline exceeded' if child[:waiter].alive?
      rescue Invalid => error
        failure = error.message
      ensure
        begin
          stop([child]) if child[:waiter].alive?
          3.times { pump([child], 0) }
        rescue Invalid => error
          failure ||= error.message
        end
      end
      success = !failure && !child[:killed] && !child[:waiter].alive? && child[:waiter].value.success? &&
        TapStartupAB.value(child[:events], 'checked', 'idle') == 1 &&
        TapStartupAB.value(child[:events], 'final', 'selectors_unchanged') == 1
      @passive_checks << {run_id: run_id, events: child[:events], failure: failure, passed: success,
                          killed: child[:killed], stderr_bytes: child[:stderr_bytes]}
      success
    end
    def arm(auto_start)
      run_id = SecureRandom.uuid.upcase
      raise Invalid, 'passive idle preflight failed' unless passive_check(run_id)
      children = []
      result = {auto_start: auto_start, production_aligned: !!@options[:production_aligned], run_id: run_id, events: [], passive_after: false, clean_exit: false, killed: false}
      begin
        reader = spawn_worker('reader', run_id, auto_start)
        children << reader
        wait_for(children, now + 5) { TapStartupAB.value(reader[:events], 'ready', 'reader') == 0 }
        owner = spawn_worker('owner', run_id, auto_start, reader[:pid])
        children << owner
        result[:reader_pid], result[:owner_pid] = reader[:pid], owner[:pid]
        if @options[:production_aligned]
          wait_for(children, now + 8) { TapStartupAB.value(owner[:events], 'ready', 'production_forwarding') == 1 }
        else
          wait_for(children, now + 8) { TapStartupAB.value(owner[:events], 'begin', 'tap_start') == auto_start }
        end
        # Aligned mode waits for the tap and writer; legacy mode deliberately races tap start.
        reader[:input].puts("start #{owner[:pid]}"); reader[:input].flush
        begin
          wait_for(children, now + (@options[:production_aligned] ? 18 : 20)) { TapStartupAB.value(reader[:events], 'ready', 'reader_teardown') == 0 }
        rescue Invalid => error
          # A prospectively bounded tap-only intervention is not a timeout bypass:
          # setup must already be proven, both workers alive, and native input start
          # still pending. Every cleanup, callback and unchanged-writer proof follows.
          raise unless @options[:production_aligned] && error.message == 'native stage deadline exceeded' &&
            children.all? { |child| child[:waiter].alive? } &&
            TapStartupAB.value(reader[:events], 'end', 'input_setup') == 0 &&
            TapStartupAB.value(reader[:events], 'begin', 'input_engine_start') == 0 &&
            !reader[:events].any? { |event| event['event'] == 'end' && event['stage'] == 'input_engine_start' }
          result[:tap_retirement_requested] = true
          owner[:input].puts('retire-tap'); owner[:input].flush
          wait_for(children, now + 8) do
            TapStartupAB.value(owner[:events], 'teardown', 'tap_only') == 1 &&
              TapStartupAB.value(reader[:events], 'ready', 'reader_teardown') == 0
          end
        end
      rescue Invalid => error
        result[:failure] = error.message
      ensure
        begin; stop(children); rescue Invalid => error; result[:failure] ||= error.message; end
        result[:events] = children.flat_map { |c| c[:events] }.sort_by { |e| e['monotonicNS'] }
        result[:stderr_bytes] = children.sum { |c| c[:stderr_bytes] }
        result[:killed] = children.any? { |c| c[:killed] }
        result[:clean_exit] = children.length == 2 && children.all? { |c| !c[:waiter].alive? && c[:waiter].value.exited? }
        result[:owner_exit_status] = owner[:waiter].value.exitstatus if owner && !owner[:waiter].alive?
        result[:reader_exit_status] = reader[:waiter].value.exitstatus if reader && !reader[:waiter].alive?
      end
      # Private taps are invisible to other processes. A killed owner cannot furnish
      # destruction acknowledgements, so NEVER start another arm after a killed worker.
      result[:passive_after] = passive_check(run_id) unless result[:killed]
      result[:outcome] = TapStartupAB.input_outcome(result)
      result
    end
    def run
      arms = []
      failure = nil
      begin
        [1, 0, 0, 1].each do |auto_start|
          arms << arm(auto_start)
          break if arms.last[:outcome] == 'invalid' || arms.last[:failure]
          break if TapStartupAB.early_stop_reason(arms)
        end
      rescue Invalid => error
        failure = error.message
      end
      {schema: 1, verdict: TapStartupAB.verdict(arms), arms: arms, passive_checks: @passive_checks, failure: failure,
       limitations: ['Private foreign taps cannot be enumerated; observed public exclusivity is not absolute exclusivity.',
                     '100 ms monitoring can miss transient foreign activity.',
                     (@options[:production_aligned] ? 'AVAudioEngine is a native reader, not the Codex dictation service; explicit device binding differs from default discovery.' : 'Audio Queue is a native reader, not the Codex dictation service.'),
                     'Only silent writer PCM is generated. No PCM bytes are read, retained, or logged; acoustic correctness is untested.']}
    ensure
      stop(@children.select { |c| c[:waiter].alive? }) unless @children.empty?
    end
  end

  def self.main(argv)
    options = {}
    parser = OptionParser.new do |p|
      p.banner = 'Explicit opt-in native A/B probe; read Probes/TapStartupProbe.md before running.'
      p.on('--live-opt-in') { options[:live] = true }
      p.on('--audio-capture-permission-confirmed') { options[:audio_capture_permission_confirmed] = true }
      p.on('--production-aligned') { options[:production_aligned] = true }
      %w[native native-sha256 driver-sha256 driver-instance clock-uid input-uid output-uid system-output-uid report].each do |key|
        p.on("--#{key} VALUE") { |v| options[key.tr('-', '_').to_sym] = v }
      end
      p.on('--host-absent') { options[:host_absent] = true }
      %w[host-pid host-start-seconds host-start-microseconds host-sha256].each do |key|
        p.on("--#{key} VALUE") { |v| options[key.tr('-', '_').to_sym] = v }
      end
    end
    parser.parse!(argv)
    required = %i[live audio_capture_permission_confirmed native native_sha256 driver_sha256 driver_instance clock_uid input_uid output_uid system_output_uid report]
    raise Invalid, 'explicit live opt-in and every identity/default/report flag are required' unless argv.empty? && required.all? { |k| options[k] }
    host_keys = %i[host_pid host_start_seconds host_start_microseconds host_sha256]
    if options[:host_absent]
      raise Invalid, 'choose host absent OR a fully pinned running host' if host_keys.any? { |k| options[k] }
      options.merge!(host_pid: '0', host_start_seconds: '0', host_start_microseconds: '0', host_sha256: '0' * 64)
    else
      raise Invalid, 'pin the quiescent running host or explicitly require its absence' unless host_keys.all? { |k| options[k] }
    end
    %i[native_sha256 driver_sha256 host_sha256].each { |k| raise Invalid, "invalid #{k}" unless /\A[0-9a-f]{64}\z/.match?(options[k]) }
    %i[driver_instance host_pid host_start_seconds host_start_microseconds].each { |k| raise Invalid, "invalid #{k}" unless /\A[0-9]{1,19}\z/.match?(options[k]) }
    raise Invalid, 'invalid driver instance or host PID' unless options[:driver_instance].to_i > 0 && (options[:host_absent] || options[:host_pid].to_i > 1)
    raise Invalid, 'native executable and report paths must be absolute' unless options[:native].start_with?('/') && options[:report].start_with?('/')
    raise Invalid, 'native executable must be an existing regular nonsymlink executable' unless File.file?(options[:native]) && !File.symlink?(options[:native]) && File.executable?(options[:native])
    File.open(options[:report], File::WRONLY | File::CREAT | File::EXCL, 0600) do |report|
      result = Supervisor.new(options).run
      result[:pins] = options.reject { |k, _| %i[live report].include?(k) }
      report.write(JSON.pretty_generate(result) + "\n")
      puts JSON.generate(verdict: result[:verdict], report: options[:report], live_audio_proof: false)
      return result[:verdict] == 'invalid_or_incomplete' ? 2 : 0
    end
  rescue Invalid, OptionParser::ParseError, SystemCallError => error
    warn "TapStartupAB refused/aborted: #{error.message}"
    2
  end
end

exit(TapStartupAB.main(ARGV)) if $PROGRAM_NAME == __FILE__
