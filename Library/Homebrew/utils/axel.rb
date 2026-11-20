# typed: strict
# frozen_string_literal: true

require "fileutils"
require "utils/shell"

module Utils
  # Multi-connection file downloads using `axel` when available.
  module Axel
    extend T::Helpers

    requires_ancestor { Kernel }

    DEFAULT_CONNECTIONS = 4
    MAX_CONNECTIONS = 64
    # `axel` v2.17.x uses `char[1024]` (`MAX_STRING`), `vsnprintf(..., sizeof(s) - 3, ...)`
    # for HTTP lines (1020 bytes before CRLF), and `MAX_ADD_HEADERS = 10` (1 slot for `User-Agent`).
    MAX_STRING_BYTES = 1024
    MAX_HEADER_BYTES = 1020
    # `"GET #{url} HTTP/1.0"` is formatted through `http_addheader` when proxied.
    REQUEST_LINE_OVERHEAD = 13
    MAX_CUSTOM_HEADERS = 9
    SUPPORTED_SCHEMES = %w[http:// https:// ftp:// ftps://].freeze
    STAT_BLOCK_SIZE = 512
    NO_PROGRESS_TIMEOUT = 60
    POLL_INTERVAL = 0.2
    TERMINATE_GRACE_PERIOD = 1.0
    private_constant :DEFAULT_CONNECTIONS, :MAX_CONNECTIONS, :MAX_STRING_BYTES, :MAX_HEADER_BYTES,
                     :REQUEST_LINE_OVERHEAD, :MAX_CUSTOM_HEADERS, :SUPPORTED_SCHEMES,
                     :STAT_BLOCK_SIZE, :NO_PROGRESS_TIMEOUT, :POLL_INTERVAL, :TERMINATE_GRACE_PERIOD

    module_function

    sig { returns(T.nilable(Pathname)) }
    def executable
      [
        HOMEBREW_PREFIX/"opt/axel/bin/axel",
        HOMEBREW_PREFIX/"bin/axel",
        Utils::Shell.which("axel"),
        Utils::Shell.which("axel", ORIGINAL_PATHS),
      ].compact.find { |path| path.file? && path.executable? }
    end

    sig { params(path: T.any(Pathname, String)).returns(Pathname) }
    def state_file(path)
      Pathname.new("#{path}.st")
    end

    sig { params(path: Pathname, total_size: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def fetched_size(path, total_size: nil)
      stat = begin
        File.stat(path)
      rescue Errno::ENOENT
        nil
      end
      return if stat.nil?

      blocks = stat.blocks
      return if blocks.nil?

      bytes = blocks * STAT_BLOCK_SIZE
      total_size ? [bytes, total_size].min : bytes
    end

    sig { returns(Integer) }
    def connections
      value = Homebrew::EnvConfig.axel_connections.to_i
      value.positive? ? value.clamp(1, MAX_CONNECTIONS) : DEFAULT_CONNECTIONS
    end

    sig {
      params(
        url:                 String,
        to:                  T.any(Pathname, String),
        timeout:             T.nilable(T.any(Integer, Float)),
        expected_size:       T.nilable(Integer),
        allow_unknown_size:  T::Boolean,
        last_modified:       T.nilable(Time),
        headers:             T::Array[String],
        cookies:             T.nilable(T::Hash[T.any(String, Symbol), String]),
        referer:             T.nilable(String),
        user:                T.nilable(String),
        user_agent:          T.nilable(T.any(String, Symbol)),
        quiet:               T::Boolean,
        verbose:             T::Boolean,
        no_progress_timeout: T.any(Integer, Float),
      ).returns(T::Boolean)
    }
    def download(
      url,
      to:,
      timeout: nil,
      expected_size: nil,
      allow_unknown_size: false,
      last_modified: nil,
      headers: [],
      cookies: nil,
      referer: nil,
      user: nil,
      user_agent: nil,
      quiet: false,
      verbose: false,
      no_progress_timeout: NO_PROGRESS_TIMEOUT
    )
      destination = Pathname(to)
      state = state_file(destination)

      axel = eligible_executable(
        url:, state:, expected_size:, allow_unknown_size:, headers:, user:, user_agent:,
      )
      if axel.nil?
        discard_axel_partial(destination, state)
        return false
      end

      resolved_ua = resolve_user_agent(user_agent)
      request_headers = build_headers(headers:, cookies:, referer:)
      unless headers_supported?(request_headers:, user_agent: resolved_ua)
        discard_axel_partial(destination, state)
        return false
      end

      args = build_args(
        url:,
        destination:,
        timeout:,
        request_headers:,
        user_agent:        resolved_ua,
        disable_redirects: cookies.present? || headers.present?,
        quiet:,
        verbose:,
      )

      destination.dirname.mkpath
      if destination.exist? && !state.exist?
        # Preserve non-empty contiguous `curl` partials so retries can resume via `--continue-at -`.
        return false if destination.size?

        # `axel` refuses to start if an empty output file exists without its `.st` state file.
        FileUtils.rm_f(destination)
      end

      succeeded = run_process(
        axel,
        args:,
        destination:,
        show_output:         !quiet && $stdout.tty?,
        show_error:          verbose && !quiet,
        timeout:,
        no_progress_timeout:,
      )

      # `axel` v2.17.14 exits 0 on write errors (`ready = -1` -> `ret = ready ? 0 : 2`),
      # leaving its `.st` file behind. Only normal completion (`ready == 1`) unlinks `.st`.
      if succeeded && destination.exist? && !state.exist? &&
         (expected_size.nil? || destination.size == expected_size)
        FileUtils.touch(destination, mtime: last_modified) if last_modified
        return true
      end

      # Remove sparse partial output before falling back so `curl --continue-at -` cannot corrupt it.
      FileUtils.rm_f([destination, state])
      false
    rescue Timeout::Error
      FileUtils.rm_f([destination, state]) if destination && state
      raise
    end

    sig {
      params(
        url:                String,
        state:              Pathname,
        expected_size:      T.nilable(Integer),
        allow_unknown_size: T::Boolean,
        headers:            T::Array[String],
        user:               T.nilable(String),
        user_agent:         T.nilable(T.any(String, Symbol)),
      ).returns(T.nilable(Pathname))
    }
    def eligible_executable(url:, state:, expected_size:, allow_unknown_size:, headers:, user:, user_agent:)
      return if Homebrew::EnvConfig.no_axel?
      return if Homebrew::EnvConfig.curlrc.present?
      return if Homebrew::EnvConfig.no_insecure_redirect?
      return if user.present?
      return if user_agent == :curl
      return if expected_size ? !expected_size.positive? : !allow_unknown_size
      return unless url.start_with?(*SUPPORTED_SCHEMES)
      return if url.bytesize > MAX_HEADER_BYTES - REQUEST_LINE_OVERHEAD
      return if url.include?(EnvSensitive::DEFERRED_PLACEHOLDER_PREFIX)
      return if headers.any? { |header| header.include?(EnvSensitive::DEFERRED_PLACEHOLDER_PREFIX) }
      return if state.to_s.bytesize >= MAX_STRING_BYTES
      return if insecure_config?

      executable
    end
    private_class_method :eligible_executable

    sig { params(request_headers: T::Array[String], user_agent: T.nilable(String)).returns(T::Boolean) }
    def headers_supported?(request_headers:, user_agent:)
      return false if request_headers.length > MAX_CUSTOM_HEADERS
      return false if request_headers.any? { |header| header.match?(/\AAuthorization:/i) }
      return false if request_headers.any? { |header| header.bytesize > MAX_HEADER_BYTES }
      return false if user_agent && "User-Agent: #{user_agent}".bytesize > MAX_HEADER_BYTES

      true
    end
    private_class_method :headers_supported?

    sig { returns(T::Boolean) }
    def insecure_config?
      config_paths = [Pathname("/etc/axelrc"), HOMEBREW_PREFIX/"etc/axelrc"]
      begin
        config_paths << (Pathname(Dir.home)/".axelrc")
      rescue ArgumentError
        nil
      end

      config_paths.uniq.any? do |path|
        next false unless path.file?

        path.each_line(encoding: Encoding::BINARY).any? do |line|
          stripped = line.sub(/#.*/, "").strip
          next false unless stripped.include?("=")

          key, value = stripped.split("=", 2)
          key&.strip == "insecure" && !value&.strip.to_i.zero?
        end
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end
    private_class_method :insecure_config?

    sig { params(destination: Pathname, state: Pathname).void }
    def discard_axel_partial(destination, state)
      # Only remove partials owned by `axel` (paired with `.st`) so contiguous `curl` partials remain resumable.
      FileUtils.rm_f([destination, state]) if state.exist?
    end
    private_class_method :discard_axel_partial

    sig {
      params(
        axel:                Pathname,
        args:                T::Array[String],
        destination:         Pathname,
        show_output:         T::Boolean,
        show_error:          T::Boolean,
        timeout:             T.nilable(T.any(Integer, Float)),
        no_progress_timeout: T.any(Integer, Float),
      ).returns(T::Boolean)
    }
    def run_process(axel, args:, destination:, show_output:, show_error:, timeout:, no_progress_timeout:)
      # Keep `axel` in the foreground group when writing directly to a TTY to avoid `SIGTTOU` under `stty tostop`.
      pgroup = !show_output
      pid = begin
        Process.spawn(
          axel.to_s,
          *args,
          pgroup:,
          in:     File::NULL,
          out:    show_output ? :out : File::NULL,
          err:    show_error ? :err : File::NULL,
        )
      rescue SystemCallError
        nil
      end
      return false if pid.nil?

      reaped = T.let(false, T::Boolean)
      begin
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = now + timeout if timeout
        last_progress_at = now
        last_progress = progress_snapshot(destination)

        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          if status
            reaped = true
            return status.success? == true
          end

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if deadline && now >= deadline
            terminate_process(pid, pgroup:)
            reaped = true
            raise Timeout::Error, "execution expired"
          end

          snapshot = progress_snapshot(destination)
          if snapshot != last_progress
            last_progress = snapshot
            last_progress_at = now
          elsif now - last_progress_at >= no_progress_timeout
            terminate_process(pid, pgroup:)
            reaped = true
            return false
          end

          sleep POLL_INTERVAL
        end
      rescue Interrupt
        terminate_process(pid, signal: "INT", pgroup:)
        reaped = true
        raise
      ensure
        terminate_process(pid, pgroup:) unless reaped
      end
    end
    private_class_method :run_process

    sig { params(path: Pathname).returns(T.nilable([T.nilable(Integer), Integer, Time])) }
    def progress_snapshot(path)
      stat = File.stat(path)
      [stat.blocks, stat.size, stat.mtime]
    rescue Errno::ENOENT
      nil
    end
    private_class_method :progress_snapshot

    sig { params(pid: Integer, signal: String, pgroup: T::Boolean).void }
    def terminate_process(pid, signal: "TERM", pgroup: false)
      kill_process(pid, signal, pgroup:)
      grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERMINATE_GRACE_PERIOD
      begin
        loop do
          return if Process.waitpid2(pid, Process::WNOHANG)
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

          sleep 0.05
        end
      rescue Interrupt
        # Escalate immediately so a worker cancellation cannot leave `axel` writing past `DownloadLock#unlock`.
      end
      kill_process(pid, "KILL", pgroup:)
      begin
        Process.waitpid2(pid)
      rescue Interrupt
        retry
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    private_class_method :terminate_process

    sig { params(pid: Integer, signal: String, pgroup: T::Boolean).void }
    def kill_process(pid, signal, pgroup:)
      Process.kill(signal, pgroup ? -pid : pid)
    rescue Errno::ESRCH
      Process.kill(signal, pid) if pgroup
    end
    private_class_method :kill_process

    sig {
      params(
        headers: T::Array[String],
        cookies: T.nilable(T::Hash[T.any(String, Symbol), String]),
        referer: T.nilable(String),
      ).returns(T::Array[String])
    }
    def build_headers(headers:, cookies:, referer:)
      result = ["Accept-Language: en"]
      if cookies.present?
        cookie_header = cookies.map { |key, value| "#{key}=#{value}" }.join(";")
        result << "Cookie: #{cookie_header}"
      end
      result << "Referer: #{referer}" if referer.present?
      result.concat(headers.map(&:strip))
    end
    private_class_method :build_headers

    sig {
      params(
        url:               String,
        destination:       Pathname,
        timeout:           T.nilable(T.any(Integer, Float)),
        request_headers:   T::Array[String],
        user_agent:        T.nilable(String),
        disable_redirects: T::Boolean,
        quiet:             T::Boolean,
        verbose:           T::Boolean,
      ).returns(T::Array[String])
    }
    def build_args(url:, destination:, timeout:, request_headers:, user_agent:, disable_redirects:, quiet:, verbose:)
      args = ["-n", connections.to_s, "-o", destination.to_s]

      args << "-U" << user_agent if user_agent
      request_headers.each { |header| args << "-H" << header }
      args << "--max-redirect=0" if disable_redirects

      args << if quiet || !$stdout.tty?
        "-q"
      elsif verbose
        "-v"
      else
        "-a"
      end

      if timeout
        io_timeout = [timeout.to_i, 1].max
        args << "-T" << io_timeout.to_s
      end

      args << "--" << url
    end
    private_class_method :build_args

    sig { params(user_agent: T.nilable(T.any(String, Symbol))).returns(T.nilable(String)) }
    def resolve_user_agent(user_agent)
      case user_agent
      when :curl
        nil
      when :browser, :fake
        HOMEBREW_USER_AGENT_FAKE_SAFARI
      when :default, nil
        HOMEBREW_USER_AGENT_CURL
      when String
        user_agent
      else
        raise TypeError, ":user_agent must be :browser/:fake, :default, :curl, or a String"
      end
    end
    private_class_method :resolve_user_agent
  end
end
