# typed: strict
# frozen_string_literal: true

require "fileutils"
require "utils/shell"

module Utils
  # Multi-connection file downloads using `aria2c` when available.
  module Aria2c
    extend T::Helpers

    requires_ancestor { Kernel }

    DEFAULT_CONNECTIONS = 4
    # `aria2c` caps `--max-connection-per-server` at 16.
    MAX_CONNECTIONS = 16
    MIN_SPLIT_SIZE = "1M"
    MAX_TRIES = 3
    RETRY_WAIT_SECONDS = 2
    CONNECT_TIMEOUT_SECONDS = 15
    IO_TIMEOUT_SECONDS = 30
    MAX_ARIA2C_TIMEOUT_SECONDS = 600
    AUTO_SAVE_INTERVAL_SECONDS = 5
    LOWEST_SPEED_LIMIT_BYTES = 100
    SUPPORTED_SCHEMES = %w[http:// https:// ftp://].freeze
    PROXY_ENV_PAIRS = T.let({
      "https_proxy" => "HTTPS_PROXY",
      "ftp_proxy"   => "FTP_PROXY",
      "all_proxy"   => "ALL_PROXY",
    }.freeze, T::Hash[String, String])
    STAT_BLOCK_SIZE = 512
    NO_PROGRESS_TIMEOUT = 60
    POLL_INTERVAL = 0.2
    TERMINATE_GRACE_PERIOD = 1.0
    private_constant :DEFAULT_CONNECTIONS, :MAX_CONNECTIONS, :MIN_SPLIT_SIZE,
                     :MAX_TRIES, :RETRY_WAIT_SECONDS, :CONNECT_TIMEOUT_SECONDS,
                     :IO_TIMEOUT_SECONDS, :MAX_ARIA2C_TIMEOUT_SECONDS,
                     :AUTO_SAVE_INTERVAL_SECONDS, :LOWEST_SPEED_LIMIT_BYTES,
                     :SUPPORTED_SCHEMES, :PROXY_ENV_PAIRS, :STAT_BLOCK_SIZE,
                     :NO_PROGRESS_TIMEOUT, :POLL_INTERVAL, :TERMINATE_GRACE_PERIOD

    module_function

    sig { returns(T.nilable(Pathname)) }
    def executable
      [
        HOMEBREW_PREFIX/"opt/aria2/bin/aria2c",
        HOMEBREW_PREFIX/"bin/aria2c",
        Utils::Shell.which("aria2c"),
        Utils::Shell.which("aria2c", ORIGINAL_PATHS),
      ].compact.find { |path| path.file? && path.executable? }
    end

    sig { params(path: T.any(Pathname, String)).returns(Pathname) }
    def control_file(path)
      Pathname.new("#{path}.aria2")
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
      value = Homebrew::EnvConfig.aria2c_connections.to_i
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
      control = control_file(destination)

      aria2c = eligible_executable(
        url:, expected_size:, allow_unknown_size:, headers:, cookies:, user:, user_agent:,
      )
      if aria2c.nil?
        discard_aria2c_partial(destination, control)
        return false
      end

      destination.dirname.mkpath
      if destination.exist? && !control.exist?
        # Preserve non-empty contiguous `curl` partials so retries can resume via `--continue-at -`.
        return false if destination.size?

        FileUtils.rm_f(destination)
      end

      args = build_args(
        url:,
        destination:,
        timeout:,
        referer:,
        user_agent:  resolve_user_agent(user_agent),
        quiet:,
        verbose:,
      )

      succeeded = run_process(
        aria2c,
        args:,
        env:                 proxy_env_overrides,
        destination:,
        show_output:         !quiet && $stdout.tty?,
        show_error:          verbose && !quiet,
        timeout:,
        no_progress_timeout:,
      )

      if succeeded && destination.exist? && !control.exist? &&
         (expected_size.nil? || destination.size == expected_size)
        FileUtils.touch(destination, mtime: last_modified) if last_modified
        return true
      end

      # Remove sparse partial output before falling back so `curl --continue-at -` cannot corrupt it.
      FileUtils.rm_f([destination, control])
      false
    rescue Timeout::Error
      FileUtils.rm_f([destination, control]) if destination && control
      raise
    end

    sig {
      params(
        url:                String,
        expected_size:      T.nilable(Integer),
        allow_unknown_size: T::Boolean,
        headers:            T::Array[String],
        cookies:            T.nilable(T::Hash[T.any(String, Symbol), String]),
        user:               T.nilable(String),
        user_agent:         T.nilable(T.any(String, Symbol)),
      ).returns(T.nilable(Pathname))
    }
    def eligible_executable(url:, expected_size:, allow_unknown_size:, headers:, cookies:, user:, user_agent:)
      return if Homebrew::EnvConfig.no_aria2c?
      return if Homebrew::EnvConfig.curlrc.present?
      return if Homebrew::EnvConfig.no_insecure_redirect?
      return if user.present?
      return if user_agent == :curl
      # `aria2c` forwards `--header` across cross-host redirects and has no `--max-redirect=0`
      # or stdin header support, so keep custom-header and cookie requests on `curl`.
      return if headers.present? || cookies.present?
      return if expected_size && !expected_size.positive?
      return if expected_size.nil? && !allow_unknown_size
      return unless url.start_with?(*SUPPORTED_SCHEMES)
      return if url.include?(EnvSensitive::DEFERRED_PLACEHOLDER_PREFIX)
      return if unsupported_proxy?(url)

      executable
    end
    private_class_method :eligible_executable

    sig { params(value: String).returns(T::Boolean) }
    def supported_proxy_value?(value)
      # `aria2c` only enforces lowercase `http://` or bare `host:port` proxies;
      # it silently bypasses `socks*://`/`HTTP://` and downgrades `https://` to plain HTTP.
      value.exclude?("://") || value.start_with?("http://")
    end
    private_class_method :supported_proxy_value?

    sig { params(scheme: String).returns(T.nilable(String)) }
    def effective_proxy(scheme)
      candidates = case scheme
      when "http"
        %w[http_proxy all_proxy ALL_PROXY]
      when "https"
        %w[https_proxy HTTPS_PROXY all_proxy ALL_PROXY]
      when "ftp"
        %w[ftp_proxy FTP_PROXY all_proxy ALL_PROXY]
      else
        []
      end

      candidates.each do |var|
        value = ENV.fetch(var, nil)
        return value if value.present?
      end
      nil
    end
    private_class_method :effective_proxy

    sig { params(url: String).returns(T::Boolean) }
    def unsupported_proxy?(url)
      schemes = if url.start_with?("http://", "https://")
        %w[http https]
      elsif url.start_with?("ftp://")
        %w[ftp]
      else
        []
      end

      schemes.any? do |scheme|
        proxy = effective_proxy(scheme)
        proxy.present? && !supported_proxy_value?(proxy)
      end
    end
    private_class_method :unsupported_proxy?

    sig { returns(T::Hash[String, T.nilable(String)]) }
    def proxy_env_overrides
      env = T.let({}, T::Hash[String, T.nilable(String)])
      http_proxy = ENV.fetch("http_proxy", nil)
      env["http_proxy"] = nil if http_proxy.present? && !supported_proxy_value?(http_proxy)
      PROXY_ENV_PAIRS.each do |lower, upper|
        lower_val = ENV.fetch(lower, nil)
        if lower_val.present?
          env[lower] = nil unless supported_proxy_value?(lower_val)
          next
        end

        upper_val = ENV.fetch(upper, nil)
        env[lower] = upper_val if upper_val.present? && supported_proxy_value?(upper_val)
      end
      env
    end
    private_class_method :proxy_env_overrides

    sig { params(destination: Pathname, control: Pathname).void }
    def discard_aria2c_partial(destination, control)
      # Only remove partials owned by `aria2c` (paired with `.aria2`) so contiguous `curl` partials remain resumable.
      FileUtils.rm_f([destination, control]) if control.exist?
    end
    private_class_method :discard_aria2c_partial

    sig {
      params(
        aria2c:              Pathname,
        args:                T::Array[String],
        env:                 T::Hash[String, T.nilable(String)],
        destination:         Pathname,
        show_output:         T::Boolean,
        show_error:          T::Boolean,
        timeout:             T.nilable(T.any(Integer, Float)),
        no_progress_timeout: T.any(Integer, Float),
      ).returns(T::Boolean)
    }
    def run_process(aria2c, args:, env:, destination:, show_output:, show_error:, timeout:, no_progress_timeout:)
      # Keep `aria2c` in the foreground group when writing directly to a TTY to avoid `SIGTTOU` under `stty tostop`.
      pgroup = !show_output
      pid = begin
        Process.spawn(
          env,
          aria2c.to_s,
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
        # On a foreground TTY (`!pgroup`), Ctrl-C already sends SIGINT to `aria2c`;
        # avoid a second SIGINT that forces shutdown before `.aria2` flushes.
        terminate_process(pid, signal: pgroup ? "INT" : nil, pgroup:)
        reaped = true
        raise
      ensure
        terminate_process(pid, pgroup:) unless reaped
        $stdout.puts if show_output && !show_error
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

    sig { params(pid: Integer, signal: T.nilable(String), pgroup: T::Boolean).void }
    def terminate_process(pid, signal: "TERM", pgroup: false)
      kill_process(pid, signal, pgroup:) if signal
      grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERMINATE_GRACE_PERIOD
      begin
        loop do
          return if Process.waitpid2(pid, Process::WNOHANG)
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

          sleep 0.05
        end
      rescue Interrupt
        # Escalate immediately so a worker cancellation cannot leave `aria2c` writing past `DownloadLock#unlock`.
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
        url:         String,
        destination: Pathname,
        timeout:     T.nilable(T.any(Integer, Float)),
        referer:     T.nilable(String),
        user_agent:  String,
        quiet:       T::Boolean,
        verbose:     T::Boolean,
      ).returns(T::Array[String])
    }
    def build_args(url:, destination:, timeout:, referer:, user_agent:, quiet:, verbose:)
      conns = connections.to_s
      connect_timeout = CONNECT_TIMEOUT_SECONDS
      io_timeout = IO_TIMEOUT_SECONDS
      if timeout
        clamped = timeout.to_i.clamp(1, MAX_ARIA2C_TIMEOUT_SECONDS)
        connect_timeout = [connect_timeout, clamped].min
        io_timeout = [io_timeout, clamped].min
      end

      args = [
        "--no-conf=true",
        "--no-netrc=true",
        "--check-certificate=true",
        "--file-allocation=none",
        "--disk-cache=0",
        "--auto-save-interval=#{AUTO_SAVE_INTERVAL_SECONDS}",
        "--allow-overwrite=true",
        "--auto-file-renaming=false",
        "--continue=true",
        "--remote-time=true",
        "--http-accept-gzip=false",
        "--follow-metalink=false",
        "--follow-torrent=false",
        "--parameterized-uri=false",
        "--download-result=hide",
        "--max-connection-per-server=#{conns}",
        "--split=#{conns}",
        "--min-split-size=#{MIN_SPLIT_SIZE}",
        "--max-tries=#{MAX_TRIES}",
        "--retry-wait=#{RETRY_WAIT_SECONDS}",
        "--connect-timeout=#{connect_timeout}",
        "--timeout=#{io_timeout}",
        "--lowest-speed-limit=#{LOWEST_SPEED_LIMIT_BYTES}",
        "--user-agent=#{user_agent}",
        "--header=Accept-Language: en",
      ]

      ssl_cert_file = ENV.fetch("SSL_CERT_FILE", nil)
      args << "--ca-certificate=#{ssl_cert_file}" if ssl_cert_file.present?
      args << "--referer=#{referer}" if referer.present?

      if quiet || !$stdout.tty?
        args << "--quiet=true"
      elsif verbose
        args << "--console-log-level=info" << "--summary-interval=5"
      else
        args << "--console-log-level=error" << "--summary-interval=0"
      end

      args << "--dir=#{destination.dirname}" << "--out=#{destination.basename}" << "--" << url
    end
    private_class_method :build_args

    sig { params(user_agent: T.nilable(T.any(String, Symbol))).returns(String) }
    def resolve_user_agent(user_agent)
      case user_agent
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
