# typed: strict
# frozen_string_literal: true

require "cleanup"
require "download_strategy"
require "utils/aria2c"

RSpec.describe Utils::Aria2c do
  # Keep each Sorbet signature with its let declaration.
  # rubocop:disable RSpec/ScatteredLet
  sig { returns(Pathname) }
  let(:test_root) { mktmpdir }

  sig { returns(Pathname) }
  let(:destination) { test_root/"downloads/app.dmg.incomplete" }

  sig { returns(Pathname) }
  let(:fake_aria2c) do
    path = test_root/"opt/aria2/bin/aria2c"
    path.dirname.mkpath
    path.write <<~SH
      #!/bin/sh
      dir=""
      out=""
      for arg in "$@"; do
        case "$arg" in
          --dir=*) dir="${arg#--dir=}" ;;
          --out=*) out="${arg#--out=}" ;;
        esac
      done
      target="${dir}/${out}"
      printf 'payload' > "$target"
      rm -f "${target}.aria2"
      exit 0
    SH
    path.chmod(0755)
    path
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    ENV.delete("HOMEBREW_NO_ARIA2C")
    ENV.delete("HOMEBREW_ARIA2C_CONNECTIONS")
    ENV.delete("HOMEBREW_CURLRC")
    ENV.delete("HOMEBREW_NO_INSECURE_REDIRECT")
    ENV.delete("SSL_CERT_FILE")
    %w[http_proxy https_proxy ftp_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY].each do |var|
      ENV.delete(var)
    end
    stub_const("HOMEBREW_PREFIX", test_root)
    allow(Utils::Shell).to receive(:which).with("aria2c").and_return(nil)
    allow(Utils::Shell).to receive(:which).with("aria2c", ORIGINAL_PATHS).and_return(nil)
  end

  describe ".executable" do
    it "returns nil when aria2c is not installed" do
      expect(described_class.executable).to be_nil
    end

    it "ignores a directory at the aria2c executable path" do
      (test_root/"opt/aria2/bin/aria2c").mkpath

      expect(described_class.executable).to be_nil
    end

    it "finds aria2c under HOMEBREW_PREFIX/opt/aria2/bin" do
      fake_aria2c

      expect(described_class.executable).to eq(fake_aria2c)
    end

    it "falls back to ORIGINAL_PATHS when not in HOMEBREW_PREFIX" do
      external_aria2c = test_root/"external/aria2c"
      external_aria2c.dirname.mkpath
      external_aria2c.write "#!/bin/sh\nexit 0\n"
      external_aria2c.chmod(0755)
      allow(Utils::Shell).to receive(:which).with("aria2c", ORIGINAL_PATHS).and_return(external_aria2c)

      expect(described_class.executable).to eq(external_aria2c)
    end
  end

  describe ".connections" do
    it "defaults to 4" do
      expect(described_class.connections).to eq(4)
    end

    it "honours HOMEBREW_ARIA2C_CONNECTIONS" do
      ENV["HOMEBREW_ARIA2C_CONNECTIONS"] = "8"

      expect(described_class.connections).to eq(8)
    end

    it "clamps excessively large HOMEBREW_ARIA2C_CONNECTIONS values to 16" do
      ENV["HOMEBREW_ARIA2C_CONNECTIONS"] = "65536"

      expect(described_class.connections).to eq(16)
    end

    it "falls back to 4 when HOMEBREW_ARIA2C_CONNECTIONS is invalid" do
      ENV["HOMEBREW_ARIA2C_CONNECTIONS"] = "0"

      expect(described_class.connections).to eq(4)
    end
  end

  describe ".download" do
    before { fake_aria2c }

    it "returns false when HOMEBREW_NO_ARIA2C is set" do
      ENV["HOMEBREW_NO_ARIA2C"] = "1"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when expected_size is nil and unknown sizes are not allowed" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination)).to be(false)
    end

    it "returns false when expected_size is zero" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 0)).to be(false)
    end

    it "returns false when expected_size is zero even if allow_unknown_size is true" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download(
          "https://example.com/bottle.tar.gz", to: destination, expected_size: 0, allow_unknown_size: true
        ),
      ).to be(false)
    end

    it "allows nil expected_size when allow_unknown_size is true" do
      result = described_class.download(
        "https://example.com/bottle.tar.gz",
        to:                 destination,
        allow_unknown_size: true,
        quiet:              true,
      )
      expect([result, destination.read]).to eq([true, "payload"])
    end

    it "discards an existing aria2c sparse partial and .aria2 control file on early return" do
      ENV["HOMEBREW_NO_ARIA2C"] = "1"
      control = described_class.control_file(destination)
      destination.dirname.mkpath
      destination.write "sparse"
      control.write "control"

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)
      expect([result, destination.exist?, control.exist?]).to eq([false, false, false])
    end

    it "preserves a contiguous curl partial without .aria2 on early return" do
      ENV["HOMEBREW_NO_ARIA2C"] = "1"
      destination.dirname.mkpath
      destination.write "curl-partial"

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)
      expect([result, destination.exist?]).to eq([false, true])
    end

    it "returns false when HOMEBREW_CURLRC is set" do
      ENV["HOMEBREW_CURLRC"] = "1"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when HOMEBREW_NO_INSECURE_REDIRECT is set" do
      ENV["HOMEBREW_NO_INSECURE_REDIRECT"] = "1"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when user_agent is :curl" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, user_agent: :curl),
      ).to be(false)
    end

    it "returns false for unsupported schemes such as file:// and ftps://" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect([
        described_class.download("file:///tmp/app.dmg", to: destination, expected_size: 7),
        described_class.download("ftps://example.com/app.dmg", to: destination, expected_size: 7),
      ]).to eq([false, false])
    end

    it "returns false when the URL contains a deferred secret placeholder" do
      placeholder = "#{EnvSensitive::DEFERRED_PLACEHOLDER_PREFIX}TOKEN#{EnvSensitive::DEFERRED_PLACEHOLDER_SUFFIX}"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download("https://example.com/#{placeholder}/app.dmg", to: destination, expected_size: 7),
      ).to be(false)
    end

    it "returns false when basic auth user is set" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, user: "u:p"))
        .to be(false)
    end

    it "returns false when custom headers are provided" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download(
          "https://example.com/app.dmg", to: destination, expected_size: 7, headers: ["X-Test: yes"]
        ),
      ).to be(false)
    end

    it "returns false when cookies are provided" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download(
          "https://example.com/app.dmg", to: destination, expected_size: 7, cookies: { a: "1" }
        ),
      ).to be(false)
    end

    it "returns false when only an unsupported SOCKS proxy applies" do
      ENV["all_proxy"] = "socks5://127.0.0.1:7891"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when the effective proxy uses https:// or uppercase HTTP://" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      ENV["https_proxy"] = "https://proxy.example:8443"
      https_proxy_result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)
      ENV["https_proxy"] = "HTTP://proxy.example:8080"
      upper_scheme_result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)

      expect([https_proxy_result, upper_scheme_result]).to eq([false, false])
    end

    it "uses aria2c when http_proxy and https_proxy override unsupported all_proxy and clears all_proxy" do
      ENV["http_proxy"] = "http://127.0.0.1:7890"
      ENV["https_proxy"] = "http://127.0.0.1:7890"
      ENV["all_proxy"] = "socks5://127.0.0.1:7891"
      env_log = test_root/"env.log"
      fake_aria2c.write <<~SH
        #!/bin/sh
        printf 'https_proxy=%s\nall_proxy=%s\n' "${https_proxy:-}" "${all_proxy:-}" > "#{env_log}"
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        printf 'payload' > "${dir}/${out}"
        exit 0
      SH
      fake_aria2c.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, env_log.read]).to eq([true, "https_proxy=http://127.0.0.1:7890\nall_proxy=\n"])
    end

    it "returns false when only https_proxy is supported and all_proxy is SOCKS for an https URL" do
      ENV["https_proxy"] = "http://127.0.0.1:7890"
      ENV["all_proxy"] = "socks5://127.0.0.1:7891"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "forwards an uppercase HTTPS_PROXY with http:// into child https_proxy env" do
      ENV["HTTPS_PROXY"] = "http://127.0.0.1:7890"
      env_log = test_root/"env.log"
      fake_aria2c.write <<~SH
        #!/bin/sh
        printf 'https_proxy=%s\n' "${https_proxy:-}" > "#{env_log}"
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        printf 'payload' > "${dir}/${out}"
        exit 0
      SH
      fake_aria2c.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, env_log.read]).to eq([true, "https_proxy=http://127.0.0.1:7890\n"])
    end

    it "accepts a bare host:port proxy" do
      ENV["https_proxy"] = "127.0.0.1:7890"

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, destination.read]).to eq([true, "payload"])
    end

    it "returns false instead of crashing when Process.spawn raises SystemCallError" do
      allow(Process).to receive(:spawn).and_raise(Errno::ENOEXEC)

      expect(
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7),
      ).to be(false)
    end

    it "runs aria2c with expected flags, SSL_CERT_FILE, referer, and restores Last-Modified" do
      ENV["SSL_CERT_FILE"] = "/tmp/custom-ca.pem"
      args_log = test_root/"args.log"
      fake_aria2c.write <<~SH
        #!/bin/sh
        printf '%s\n' "$@" > "#{args_log}"
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        printf 'payload' > "${dir}/${out}"
        exit 0
      SH
      fake_aria2c.chmod(0755)
      mtime = Time.utc(2025, 1, 2, 3, 4, 5)

      result = described_class.download(
        "https://example.com/app.dmg",
        to:            destination,
        expected_size: 7,
        last_modified: mtime,
        referer:       "https://ref.example",
        quiet:         true,
      )
      logged_args = args_log.read.lines(chomp: true)
      expect([result, destination.read, destination.mtime.utc, logged_args]).to eq([
        true,
        "payload",
        mtime,
        [
          "--no-conf=true",
          "--no-netrc=true",
          "--check-certificate=true",
          "--file-allocation=none",
          "--disk-cache=0",
          "--auto-save-interval=5",
          "--allow-overwrite=true",
          "--auto-file-renaming=false",
          "--continue=true",
          "--remote-time=true",
          "--http-accept-gzip=false",
          "--follow-metalink=false",
          "--follow-torrent=false",
          "--parameterized-uri=false",
          "--download-result=hide",
          "--max-connection-per-server=4",
          "--split=4",
          "--min-split-size=1M",
          "--max-tries=3",
          "--retry-wait=2",
          "--connect-timeout=15",
          "--timeout=30",
          "--lowest-speed-limit=100",
          "--user-agent=#{HOMEBREW_USER_AGENT_CURL}",
          "--header=Accept-Language: en",
          "--ca-certificate=/tmp/custom-ca.pem",
          "--referer=https://ref.example",
          "--quiet=true",
          "--dir=#{destination.dirname}",
          "--out=#{destination.basename}",
          "--",
          "https://example.com/app.dmg",
        ],
      ])
    end

    it "clamps --connect-timeout and --timeout to the requested download timeout" do
      args_log = test_root/"args.log"
      fake_aria2c.write <<~SH
        #!/bin/sh
        printf '%s\n' "$@" > "#{args_log}"
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        printf 'payload' > "${dir}/${out}"
        exit 0
      SH
      fake_aria2c.chmod(0755)

      described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, timeout: 5,
                               quiet: true)
      logged_args = args_log.read.lines(chomp: true)
      expect(logged_args).to include("--connect-timeout=5", "--timeout=5")
    end

    it "selects console log and summary flags based on verbosity when writing to a TTY" do
      args_log = test_root/"args.log"
      fake_aria2c.write <<~SH
        #!/bin/sh
        printf '%s\n' "$@" > "#{args_log}"
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        printf 'payload' > "${dir}/${out}"
        exit 0
      SH
      fake_aria2c.chmod(0755)
      allow($stdout).to receive(:tty?).and_return(true)
      allow($stdout).to receive(:puts)

      described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, verbose: false)
      default_tty_args = args_log.read.lines(chomp: true)
      destination.delete
      described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, verbose: true)
      verbose_tty_args = args_log.read.lines(chomp: true)

      expect([
        default_tty_args & %w[--console-log-level=error --summary-interval=0 --quiet=true],
        verbose_tty_args & %w[--console-log-level=info --summary-interval=5 --quiet=true],
      ]).to eq([
        %w[--console-log-level=error --summary-interval=0],
        %w[--console-log-level=info --summary-interval=5],
      ])
    end

    it "preserves a non-empty curl partial without an .aria2 control file and falls back to curl" do
      destination.dirname.mkpath
      destination.write "stale curl partial"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      result = described_class.download(
        "https://example.com/app.dmg", to: destination, expected_size: 18, quiet: true
      )
      expect([result, destination.read]).to eq([false, "stale curl partial"])
    end

    it "removes an empty leftover partial file without an .aria2 control file before running aria2c" do
      destination.dirname.mkpath
      destination.write ""
      existed_flag = test_root/"existed"
      fake_aria2c.write <<~SH
        #!/bin/sh
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        target="${dir}/${out}"
        [ -e "$target" ] && touch "#{existed_flag}"
        printf 'fresh' > "$target"
        exit 0
      SH
      fake_aria2c.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 5, quiet: true)
      expect([result, existed_flag.exist?, destination.read]).to eq([true, false, "fresh"])
    end

    it "treats exit 0 with a surviving .aria2 file as failure and cleans up" do
      control = described_class.control_file(destination)
      fake_aria2c.write <<~SH
        #!/bin/sh
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        target="${dir}/${out}"
        printf 'partial' > "$target"
        printf 'control' > "${target}.aria2"
        exit 0
      SH
      fake_aria2c.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, destination.exist?, control.exist?]).to eq([false, false, false])
    end

    it "treats size mismatch on exit 0 as failure and cleans up" do
      result = described_class.download(
        "https://example.com/app.dmg",
        to:            destination,
        expected_size: 999,
        quiet:         true,
      )
      expect([result, destination.exist?]).to eq([false, false])
    end

    it "terminates aria2c and falls back when no progress is made within the watchdog window" do
      control = described_class.control_file(destination)
      fake_aria2c.write <<~SH
        #!/bin/sh
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        target="${dir}/${out}"
        printf 'stalled' > "$target"
        printf 'control' > "${target}.aria2"
        sleep 10
      SH
      fake_aria2c.chmod(0755)

      result = described_class.download(
        "https://example.com/app.dmg",
        to:                  destination,
        expected_size:       7,
        quiet:               true,
        no_progress_timeout: 0.3,
      )
      expect([result, destination.exist?, control.exist?]).to eq([false, false, false])
    end

    it "terminates and reaps aria2c on non-Interrupt exceptions" do
      pid_file = test_root/"aria2c.pid"
      fake_aria2c.write <<~SH
        #!/bin/sh
        echo $$ > "#{pid_file}"
        sleep 10
      SH
      fake_aria2c.chmod(0755)
      allow(described_class).to receive(:progress_snapshot).and_wrap_original do |orig, path|
        raise "boom" if pid_file.exist?

        orig.call(path)
      end

      expect do
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      end.to raise_error(RuntimeError, "boom")

      child_alive = begin
        Process.kill(0, pid_file.read.to_i)
        true
      rescue Errno::ESRCH
        false
      end
      expect(child_alive).to be(false)
    end

    it "cleans up partial and control files and re-raises on Timeout::Error" do
      control = described_class.control_file(destination)
      fake_aria2c.write <<~SH
        #!/bin/sh
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        target="${dir}/${out}"
        printf 'partial' > "$target"
        printf 'control' > "${target}.aria2"
        sleep 10
      SH
      fake_aria2c.chmod(0755)

      raised = begin
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, timeout: 0.3,
                                 quiet: true)
        false
      rescue Timeout::Error
        true
      end
      expect([raised, destination.exist?, control.exist?]).to eq([true, false, false])
    end

    it "preserves partial and control files for resume and re-raises on Interrupt" do
      control = described_class.control_file(destination)
      fake_aria2c.write <<~SH
        #!/bin/sh
        dir=""
        out=""
        for arg in "$@"; do
          case "$arg" in
            --dir=*) dir="${arg#--dir=}" ;;
            --out=*) out="${arg#--out=}" ;;
          esac
        done
        target="${dir}/${out}"
        printf 'partial' > "$target"
        printf 'control' > "${target}.aria2"
        sleep 10
      SH
      fake_aria2c.chmod(0755)
      allow(described_class).to receive(:progress_snapshot).and_wrap_original do |orig, path|
        raise Interrupt if control.exist?

        orig.call(path)
      end

      raised = begin
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
        false
      rescue Interrupt
        true
      end
      expect([raised, destination.exist?, control.exist?]).to eq([true, true, true])
    end
  end

  describe ".fetched_size" do
    it "returns nil when the file does not exist" do
      expect(described_class.fetched_size(destination)).to be_nil
    end

    it "clamps allocated disk blocks to total_size" do
      destination.dirname.mkpath
      destination.write "a" * 8192

      expect(described_class.fetched_size(destination, total_size: 100)).to eq(100)
    end
  end

  describe "cache discovery and cleanup with .incomplete.aria2" do
    it "does not adopt an .incomplete.aria2 sidecar as cached_location" do
      url = "https://example.com/app.dmg"
      strategy = CurlDownloadStrategy.new(url, "app", "1.0")
      allow(strategy).to receive(:resolve_url_basename_time_file_size)
        .and_return([url, "app.dmg", nil, 1024, "application/octet-stream", false])

      hash = Digest::SHA256.hexdigest(url)
      downloads_dir = HOMEBREW_CACHE/"downloads"
      downloads_dir.mkpath
      (downloads_dir/"#{hash}--app.dmg.incomplete").write "sparse"
      (downloads_dir/"#{hash}--app.dmg.incomplete.aria2").write "control"

      expect(strategy.cached_location).to eq(downloads_dir/"#{hash}--app.dmg")
    end

    it "recognises .incomplete.aria2 as an incomplete download in Cleanup" do
      expect(Homebrew::Cleanup.incomplete?(Pathname("foo.incomplete.aria2"))).to be(true)
    end

    it "skips deleting .incomplete.aria2 in Cleanup when its paired .incomplete lock is held" do
      downloads_dir = HOMEBREW_CACHE/"downloads"
      downloads_dir.mkpath
      partial = downloads_dir/"abc--app.dmg.incomplete"
      control = downloads_dir/"abc--app.dmg.incomplete.aria2"
      partial.write "sparse"
      control.write "control"

      lock = DownloadLock.new(partial)
      lock.lock
      begin
        Homebrew::Cleanup.new(cache: HOMEBREW_CACHE).cleanup_unreferenced_downloads
        expect([partial.exist?, control.exist?]).to eq([true, true])
      ensure
        lock.unlock(unlink: true)
      end
    end
  end

  describe "CurlDownloadStrategy integration" do
    sig { returns(CurlDownloadStrategy) }
    let(:strategy) { CurlDownloadStrategy.new("https://example.com/app.dmg", "app", "1.0") }

    before do
      fake_aria2c
      allow(strategy).to receive(:resolve_url_basename_time_file_size)
        .and_return(["https://example.com/app.dmg", "app.dmg", Time.utc(2025, 1, 2, 3, 4, 5), 7,
                     "application/octet-stream", false])
    end

    it "uses aria2c and skips curl_download when aria2c succeeds" do
      allow(strategy).to receive(:curl_download).and_raise("should not call curl_download")

      strategy.fetch
      expect([strategy.cached_location.read, strategy.cached_location.mtime.utc])
        .to eq(["payload", Time.utc(2025, 1, 2, 3, 4, 5)])
    end

    it "falls back to curl_download with remaining timeout when aria2c returns false" do
      allow(described_class).to receive(:download) do |_url, **_opts|
        sleep 0.2
        false
      end
      fallback_timeout = T.let(nil, T.nilable(T.any(Integer, Float)))
      allow(strategy).to receive(:curl_download) do |_url, to:, timeout:, **_opts|
        fallback_timeout = timeout
        Pathname(to).dirname.mkpath
        Pathname(to).write "from-curl"
        nil
      end

      strategy.fetch(timeout: 5.0)
      expect([strategy.cached_location.read, fallback_timeout.is_a?(Float) && fallback_timeout < 4.9])
        .to eq(["from-curl", true])
    end
  end
end
