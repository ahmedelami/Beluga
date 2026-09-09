#!/usr/bin/ruby
# Compiler-only oracle; never runs an app or dispatches a native media command.
require 'digest'
require 'json'
require 'pathname'

module NativeMediaCallbackIsolation
  TIMEOUT_SECONDS = 15
  TOTAL_TIMEOUT_SECONDS = 45
  MAX_LOG_BYTES = 262_144
  MAX_SIL_BYTES = 2_097_152

  def self.require!(condition, message)
    raise message unless condition
  end

  def self.one!(text, pattern, description)
    matches = text.to_enum(:scan, pattern).map { Regexp.last_match }
    require!(matches.length == 1, "source shape changed: #{description}")
    matches.first
  end

  def self.method!(source, signature)
    start = one!(source, /^#{Regexp.escape(signature)}$/, signature).begin(0)
    finish = source.index("\n    }\n", start)
    require!(!finish.nil?, "missing method end: #{signature}")
    source[start...(finish + "\n    }\n".length)]
  end

  def self.extract!(source)
    one!(source, /^@preconcurrency import MediaPlayer$/, 'MediaPlayer import')
    one!(source, /^import UIKit$/, 'UIKit import')
    owner = one!(source, /^@MainActor\nfinal class BackgroundPlaybackCoordinator \{$/, 'MainActor owner')
    owner_end = source.index("\n}\n", owner.end(0))
    require!(!owner_end.nil?, 'missing coordinator class end')
    owned_source = source[owner.end(0)...owner_end]
    one!(source, /^final class RemoteMediaCommandDispatchGate: @unchecked Sendable \{$/, 'Sendable command gate')
    publication = method!(owned_source, '    private func publishCurrentRemoteMedia(advancingElapsed: Bool) {')
    installation = method!(owned_source, '    private func installCommandTargetsIfNeeded() {')
    require!(source.scan('MPMediaItemArtwork(').length == 1, 'artwork registration shape changed')
    require!(source.scan('nativeCommand.addTarget').length == 1, 'command registration shape changed')
    artwork = one!(publication,
      /^            info\[MPMediaItemPropertyArtwork\] = (MPMediaItemArtwork\(boundsSize: image\.size\) \{ @Sendable _ in image \})$/,
      'immutable artwork callback')[1]
    command = one!(installation,
      /^            let gate = commandGate\n(            let target = nativeCommand\.addTarget \{ @Sendable _ in\n                gate\.dispatch\(command\) \? \.success : \.commandFailed\n            \})$/,
      'synchronous native command callback')[1]
    { 'artwork' => artwork, 'command' => command }
  end

  def self.probe(fragments)
    <<~SWIFT
      @preconcurrency import MediaPlayer
      import UIKit

      final class FixtureGate: @unchecked Sendable {
          func dispatch(_ command: Int) -> Bool { command >= 0 }
      }

      @MainActor
      final class CallbackIsolationProbe {
          func artwork(_ image: UIImage) -> MPMediaItemArtwork {
              return #{fragments.fetch('artwork')}
          }

          func command(_ nativeCommand: MPRemoteCommand, gate: FixtureGate, command: Int) -> Any {
      #{fragments.fetch('command')}
              return target
          }
      }
    SWIFT
  end

  def self.closure!(sil, name)
    signature = name == 'artwork' ? 'artwork(_:)' : 'command(_:gate:command:)'
    marker = "// closure #1 in CallbackIsolationProbe.#{signature}\n"
    require!(sil.scan(marker).length == 1, "unexpected SIL closure shape: #{name}")
    start = sil.index(marker)
    ending = /^} \/\/ end sil function '[^']+'\n/.match(sil, start)
    require!(!ending.nil?, "missing SIL closure end: #{name}")
    sil[start...ending.end(0)]
  end

  def self.check_closure!(sil, name, isolated:)
    body = closure!(sil, name)
    if isolated
      require!(body.include?("// Isolation: global_actor. type: MainActor\n"), "mutant did not infer MainActor: #{name}")
      check = /%(\d+) = function_ref @[^\n:]*(?:_checkExpectedExecutor|swift_task_isCurrentExecutor|swift_task_checkIsolated|swift_task_reportUnexpectedExecutor)/.match(body)
      require!(check && body.match?(/= apply %#{Regexp.escape(check[1])}\(/), "mutant lacks executed executor assertion: #{name}")
      'MainActor with executed executor assertion'
    else
      require!(body.include?("// Isolation: nonisolated\n"), "callback is not nonisolated: #{name}")
      require!(body.include?('@Sendable'), "callback lost Sendable type: #{name}")
      require!(!body.match?(/_checkExpectedExecutor|swift_task_isCurrentExecutor|swift_task_checkIsolated|swift_task_reportUnexpectedExecutor|MainActor\.shared/), "callback retains executor assertion: #{name}")
      'nonisolated Sendable with no executor assertion'
    end
  end

  def self.write_new!(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
  end

  def self.compile!(arguments, output:, developer:, run_deadline:)
    log_path = File.join(output, File.basename(arguments.last, '.sil') + '.log')
    write_new!(log_path, '')
    environment = {
      'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG' => 'C',
      'HOME' => ENV.fetch('HOME'), 'TMPDIR' => output, 'DEVELOPER_DIR' => developer
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pid = Process.spawn(environment, *arguments, chdir: output, pgroup: true,
                        unsetenv_others: true, out: log_path, err: [:child, :out])
    status = nil
    begin
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        if waited
          status = waited.last
          break
        end
        require!(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < TIMEOUT_SECONDS,
                 "compiler deadline exceeded; see #{log_path}")
        require!(Process.clock_gettime(Process::CLOCK_MONOTONIC) < run_deadline, 'total compiler run deadline exceeded')
        require!(File.size(log_path) <= MAX_LOG_BYTES, 'compiler diagnostic output exceeded bound')
        require!(!File.exist?(arguments.last) || File.size(arguments.last) <= MAX_SIL_BYTES,
                 'compiler SIL output exceeded bound')
        sleep 0.05
      end
    ensure
      unless status
        begin
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH
          # The isolated compiler process group already exited.
        end
        Process.waitpid(pid)
      end
    end
    require!(status.success?, "compiler failed (#{status.exitstatus}); see #{log_path}")
    require!(File.size(log_path) <= MAX_LOG_BYTES, 'compiler diagnostic output exceeded bound')
    require!(File.file?(arguments.last) && File.size(arguments.last) <= MAX_SIL_BYTES, 'missing or oversized SIL')
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def self.main(arguments)
    require!(arguments.length == 2, "usage: #{$PROGRAM_NAME} EMPTY_PRIVATE_OUTPUT_DIRECTORY DEVELOPER_DIRECTORY")
    output, developer = arguments
    require!(Pathname.new(output).absolute? && File.realpath(output) == output, 'output must be an existing canonical absolute directory')
    metadata = File.lstat(output)
    require!(metadata.directory? && !metadata.symlink? && metadata.uid == Process.uid && (metadata.mode & 0o777) == 0o700,
             'output must be a private mode-700 directory owned by this user')
    require!(Dir.children(output).empty?, 'output directory must be empty; never reuse an evidence run')
    require!(Pathname.new(developer).absolute? && File.realpath(developer) == developer, 'developer directory must be canonical and absolute')
    compiler = File.join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc')
    sdk = File.join(developer, 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk')
    require!(File.executable?(compiler) && File.directory?(sdk), 'missing selected Swift compiler or iOS SDK')
    source_path = File.expand_path('../iOS/opensteamer/Sources/App/BackgroundPlaybackCoordinator.swift', __dir__)
    source = File.binread(source_path)
    fragments = extract!(source)
    variants = { 'current' => fragments }
    %w[artwork command].each do |name|
      require!(fragments.fetch(name).scan('@Sendable ').length == 1, "ambiguous mutation: #{name}")
      variants["without_#{name}_sendable"] = fragments.merge(name => fragments.fetch(name).sub('@Sendable ', ''))
    end
    evidence = {
      'schema' => 'OPENSTEAMER_NATIVE_CALLBACK_ISOLATION_V1',
      'source_path' => source_path, 'source_sha256' => Digest::SHA256.hexdigest(source),
      'script_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
      'developer_directory' => developer, 'sdk' => sdk, 'variants' => [],
      'limits' => 'SIL-only: no app execution, native command delivery, signing, or installed-device proof. Gate is an immutable fixture; callbacks are extracted production source.'
    }
    run_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TOTAL_TIMEOUT_SECONDS
    { 'silgen' => ['-emit-silgen'], 'optimized' => ['-O', '-emit-sil'] }.each do |mode, options|
      variants.each do |variant, selected|
        label = mode + '_' + variant
        swift_path = File.join(output, label + '.swift')
        sil_path = File.join(output, label + '.sil')
        write_new!(swift_path, probe(selected))
        command = [compiler, '-swift-version', '6', '-target', 'arm64-apple-ios17.0', '-sdk', sdk,
                   '-module-cache-path', File.join(output, 'module-cache'), *options,
                   '-module-name', 'NativeMediaCallbackIsolation', swift_path, '-o', sil_path]
        seconds = compile!(command, output: output, developer: developer, run_deadline: run_deadline)
        sil = File.binread(sil_path)
        checks = %w[artwork command].to_h do |name|
          [name, check_closure!(sil, name, isolated: variant == "without_#{name}_sendable")]
        end
        evidence['variants'] << { 'mode' => mode, 'variant' => variant, 'arguments' => command, 'seconds' => seconds,
                                  'swift_sha256' => Digest::SHA256.file(swift_path).hexdigest,
                                  'sil_sha256' => Digest::SHA256.hexdigest(sil), 'checks' => checks }
        puts "PASS #{label}: #{checks.map { |name, result| "#{name}=#{result}" }.join('; ')}"
      end
    end
    require!(File.binread(source_path) == source, 'production source changed during compiler verification')
    write_new!(File.join(output, 'evidence.json'), JSON.pretty_generate(evidence) + "\n")
    puts 'PASS: 6 compiler variants, 12 closure checks, 2 independent annotation-removal mutants in SILGen and optimized Swift 6. No app or media command executed.'
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    NativeMediaCallbackIsolation.main(ARGV)
  rescue StandardError => error
    warn "FAIL native media callback isolation: #{error.message}"
    exit 1
  end
end
