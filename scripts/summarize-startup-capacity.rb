#!/usr/bin/env ruby
# Read only completed, assertion-passing characterization phases. Does not turn a
# partial matrix, sender geometry, or requested FPS into production acceptance.
require 'json'

abort 'usage: ruby scripts/summarize-startup-capacity.rb ABSOLUTE_GATE_EVIDENCE_DIRECTORY' unless ARGV.length == 1 && ARGV[0].start_with?('/')
directory = File.realpath(ARGV[0])
manifest_path = File.join(directory, 'test-manifest.json')
manifest = File.file?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}
expected_phases = manifest.fetch('capacity', []).length * manifest.fetch('capacity_rounds', 0) +
  manifest.fetch('spatial_recovery', []).length * manifest.fetch('spatial_recovery_rounds', 0)
result_paths = Dir.glob(File.join(directory, 'capacity-*-*.results.json')) +
  Dir.glob(File.join(directory, 'spatial-recovery-*-*.results.json'))
rows = result_paths.sort_by do |path|
  [File.basename(path).start_with?('capacity-') ? 0 : 1, *File.basename(path).scan(/\d+/).map(&:to_i)]
end.map do |result_path|
  result = JSON.parse(File.read(result_path))
  abort "invalid phase result: #{result_path}" unless result.fetch('passed').length == 1
  log = result_path.sub('.results.json', '.log')
  records = File.foreach(log).map do |line|
    JSON.parse(line.delete_prefix('STARTUP_CAPACITY_EXPERIMENT ')) if line.start_with?('STARTUP_CAPACITY_EXPERIMENT ')
  end.compact
  abort "expected exactly one characterization: #{log}" unless records.length == 1
  record = records.first
  frames = record.fetch('decoded')
  trace = record.fetch('trace')
  sharp = ->(frame) { frame.fetch('width') == 1080 && frame.fetch('height') == 1920 && frame.fetch('contrast') > 0.9 }
  first_sharp = frames.find(&sharp)
  ending = record.fetch('observationDurationMs') { record.fetch('capacityDropAndRecovery') ? 16_000.0 : 12_000.0 }
  restored_at = record['restoredAtMs']
  recovered = restored_at && frames.find { |frame| frame['elapsedMs'] >= restored_at && sharp.call(frame) }
  next_drop = record.fetch('capacityChanges', []).find { |change| change['stage'] == 3 }
  recovered_interval_end = next_drop ? next_drop.fetch('mutationStartedMs') : ending
  recovered_blurry_frames = recovered && frames.count do |frame|
    frame['elapsedMs'] >= recovered['elapsedMs'] && frame['elapsedMs'] < recovered_interval_end && !sharp.call(frame)
  end
  blurry_after_sharp = frames.each_with_index.sum do |frame, index|
    next 0.0 unless first_sharp && frame['elapsedMs'] >= first_sharp['elapsedMs'] && !sharp.call(frame)
    [0.0, (frames[index + 1]&.fetch('elapsedMs') || ending) - frame['elapsedMs']].max
  end
  queue_samples = trace.each_cons(2).map do |before, after|
    next unless [before['packets'], after['packets'], before['totalPacketSendDelay'], after['totalPacketSendDelay']].all? { |v| v.is_a?(Numeric) }
    packets = after['packets'] - before['packets']
    delay = after['totalPacketSendDelay'] - before['totalPacketSendDelay']
    delay * 1000 / packets if packets > 0 && delay >= 0
  end.compact
  warmup_observed_frames = record.fetch('warmup').map { |entry| entry['encodedFrames'] }
  {
    phase: File.basename(log, '.log'), test: result['passed'].first.split('/').last,
    spatial_recovery_enabled: record['spatialRecoveryEnabled'],
    spatial_recovery_required: record['requiresSpatialRecovery'],
    second_capacity_drop: record['secondCapacityDrop'],
    observation_duration_ms: ending,
    capacity_changes: record['capacityChanges'],
    restoration_lower_bound_ms: restored_at,
    recovery_first_sharp_ms: recovered && recovered['elapsedMs'],
    recovery_latency_upper_bound_ms: recovered && recovered['elapsedMs'] - restored_at,
    recovery_deadline_ms: record['recoveryDeadlineMs'],
    required_sustained_recovery_ms: record['requiredSustainedRecoveryMs'],
    requires_sharp_until_next_capacity_drop: record['requiresSharpUntilNextCapacityDrop'],
    recovered_interval_end_ms: recovered_interval_end,
    blurry_recovered_frames_before_next_drop: recovered_blurry_frames,
    final_spatial_recovery_phase: trace.last['spatialRecoveryPhase'],
    final_spatial_recovery_attempt_count: trace.last['spatialRecoveryAttemptCount'],
    final_tier: trace.last['tier'],
    final_current_total_cap_bps: trace.last['currentTotalCapBps'],
    final_ordinary_total_cap_bps: trace.last['ordinaryTotalCapBps'],
    final_rtt_disposition: trace.last['rttDisposition'],
    maximum_policy_ordinary_packet_delay_ms: trace.map { |entry| entry['lastOrdinaryPacketDelayMs'] }.compact.max,
    first_frame_ms: record['firstFrameFromCaptureMs'], first_sharp_ms: first_sharp&.fetch('elapsedMs'),
    first_frame_from_ready_ms: record['firstFrameFromTransportReadyMs'],
    blurry_after_first_sharp_ms: blurry_after_sharp,
    final_decoded_fps: record['finalDecodedFPS'], decoded_frames: frames.length,
    final_decoded_width: frames.last['width'], final_decoded_height: frames.last['height'],
    final_contrast: frames.last['contrast'],
    maximum_decoded_gap_ms: frames.each_cons(2).map { |a, b| b['elapsedMs'] - a['elapsedMs'] }.max,
    last_window_changed_frames: frames.count { |f| f['elapsedMs'] >= ending - 2000 && f['motionPhaseChanged'] && f['sameGeometry'] && f['densePixelDifference'] > 4 },
    maximum_sender_packet_delay_ms: queue_samples.max,
    maximum_relay_queued_bytes: trace.map { |s| s['queuedBytes'] }.max,
    maximum_relay_lateness_ms: trace.map { |s| s['maximumDeliveryLatenessNs'] }.compact.max.to_f / 1_000_000,
    maximum_release_batch_bytes: trace.map { |s| s['maximumReleaseBatchBytes'] }.compact.max,
    maximum_native_rtt_ms: trace.map { |s| s['rtt'] }.compact.max.to_f * 1000,
    final_keyframes: trace.last['keyFramesEncoded'], final_huge_frames: trace.last['hugeFramesSent'],
    final_expired: trace.last['expiredDatagrams'], final_overflow: trace.last['overflowDatagrams'],
    warmup_encoded_frames_observed: warmup_observed_frames.compact.uniq,
    warmup_missing_encoder_samples: warmup_observed_frames.count(nil)
  }
end
puts JSON.pretty_generate(completed_phases: rows.length, expected_phases: expected_phases, rows: rows)
