# typed: strict
# frozen_string_literal: true

require "cleanup"
require "download_strategy"
require "utils/axel"

RSpec.describe Utils::Axel do
  # Keep each Sorbet signature with its let declaration.
  # rubocop:disable RSpec/ScatteredLet
  sig { returns(Pathname) }
  let(:test_root) { mktmpdir }

  sig { returns(Pathname) }
  let(:destination) { test_root/"downloads/app.dmg.incomplete" }

  sig { returns(Pathname) }
  let(:fake_axel) do
    path = test_root/"opt/axel/bin/axel"
    path.dirname.mkpath
    path.write <<~SH
      #!/bin/sh
      out=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) out="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      printf 'payload' > "$out"
      rm -f "${out}.st"
      exit 0
    SH
    path.chmod(0755)
    path
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    ENV.delete("HOMEBREW_NO_AXEL")
    ENV.delete("HOMEBREW_AXEL_CONNECTIONS")
    ENV.delete("HOMEBREW_CURLRC")
    ENV.delete("HOMEBREW_NO_INSECURE_REDIRECT")
    ENV["HOME"] = (test_root/"home").to_s
    (test_root/"home").mkpath
    stub_const("HOMEBREW_PREFIX", test_root)
    allow(Utils::Shell).to receive(:which).with("axel").and_return(nil)
    allow(Utils::Shell).to receive(:which).with("axel", ORIGINAL_PATHS).and_return(nil)
  end

  describe ".executable" do
    it "returns nil when axel is not installed" do
      expect(described_class.executable).to be_nil
    end

    it "ignores a directory at the axel executable path" do
      (test_root/"opt/axel/bin/axel").mkpath

      expect(described_class.executable).to be_nil
    end

    it "finds axel under HOMEBREW_PREFIX/opt/axel/bin" do
      fake_axel

      expect(described_class.executable).to eq(fake_axel)
    end

    it "falls back to ORIGINAL_PATHS when not in HOMEBREW_PREFIX" do
      external_axel = test_root/"external/axel"
      external_axel.dirname.mkpath
      external_axel.write "#!/bin/sh\nexit 0\n"
      external_axel.chmod(0755)
      allow(Utils::Shell).to receive(:which).with("axel", ORIGINAL_PATHS).and_return(external_axel)

      expect(described_class.executable).to eq(external_axel)
    end
  end

  describe ".connections" do
    it "defaults to 4" do
      expect(described_class.connections).to eq(4)
    end

    it "honours HOMEBREW_AXEL_CONNECTIONS" do
      ENV["HOMEBREW_AXEL_CONNECTIONS"] = "8"

      expect(described_class.connections).to eq(8)
    end

    it "clamps excessively large HOMEBREW_AXEL_CONNECTIONS values to 64" do
      ENV["HOMEBREW_AXEL_CONNECTIONS"] = "65536"

      expect(described_class.connections).to eq(64)
    end

    it "falls back to 4 when HOMEBREW_AXEL_CONNECTIONS is invalid" do
      ENV["HOMEBREW_AXEL_CONNECTIONS"] = "0"

      expect(described_class.connections).to eq(4)
    end
  end

  describe ".download" do
    before { fake_axel }

    it "returns false when HOMEBREW_NO_AXEL is set" do
      ENV["HOMEBREW_NO_AXEL"] = "1"
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

    it "discards an existing axel sparse partial and .st file on early return" do
      ENV["HOMEBREW_NO_AXEL"] = "1"
      state = described_class.state_file(destination)
      destination.dirname.mkpath
      destination.write "sparse"
      state.write "state"

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)
      expect([result, destination.exist?, state.exist?]).to eq([false, false, false])
    end

    it "preserves a contiguous curl partial without .st on early return" do
      ENV["HOMEBREW_NO_AXEL"] = "1"
      destination.dirname.mkpath
      destination.write "curl-partial"

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)
      expect([result, destination.exist?]).to eq([false, true])
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

    it "returns false for unsupported schemes such as file://" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("file:///tmp/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when the URL exceeds axel's request-line limit" do
      long_url = "https://example.com/#{"a" * 990}"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download(long_url, to: destination, expected_size: 7)).to be(false)
    end

    it "returns false when basic auth user is set" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, user: "u:p"))
        .to be(false)
    end

    it "returns false when headers contain a plain Authorization header" do
      allow(Process).to receive(:spawn).and_raise("should not spawn")
      headers = ["authorization: Bearer tok"]

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, headers:))
        .to be(false)
    end

    it "returns false when headers contain a deferred secret placeholder" do
      placeholder = "#{EnvSensitive::DEFERRED_PLACEHOLDER_PREFIX}TOKEN#{EnvSensitive::DEFERRED_PLACEHOLDER_SUFFIX}"
      header = "X-Token: #{placeholder}"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, headers: [header]),
      ).to be(false)
    end

    it "returns false when custom headers exceed axel's limit" do
      headers = Array.new(9) { |i| "X-Header-#{i}: val" }
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, headers:))
        .to be(false)
    end

    it "returns false when a header exceeds axel's 1020-byte HTTP buffer" do
      long_header = "X-Long: #{"a" * 1013}"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download(
          "https://example.com/app.dmg", to: destination, expected_size: 7, headers: [long_header]
        ),
      ).to be(false)
    end

    it "returns false when User-Agent exceeds axel's 1020-byte HTTP buffer" do
      long_ua = "a" * 1009
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(
        described_class.download(
          "https://example.com/app.dmg", to: destination, expected_size: 7, user_agent: long_ua
        ),
      ).to be(false)
    end

    it "returns false when ~/.axelrc enables insecure TLS" do
      (test_root/"home/.axelrc").write "insecure = 1\n"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      expect(described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7)).to be(false)
    end

    it "handles non-UTF-8 bytes in ~/.axelrc without raising" do
      (test_root/"home/.axelrc").binwrite("# \xFF\xFE comment\ninsecure = 0\n")

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, destination.read]).to eq([true, "payload"])
    end

    it "returns false instead of crashing when Process.spawn raises SystemCallError" do
      allow(Process).to receive(:spawn).and_raise(Errno::ENOEXEC)

      expect(
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7),
      ).to be(false)
    end

    it "runs axel with --max-redirect=0 for custom headers/cookies and restores Last-Modified" do
      args_log = test_root/"args.log"
      fake_axel.write <<~SH
        #!/bin/sh
        printf '%s\n' "$@" > "#{args_log}"
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'payload' > "$out"
        exit 0
      SH
      fake_axel.chmod(0755)
      mtime = Time.utc(2025, 1, 2, 3, 4, 5)

      result = described_class.download(
        "https://example.com/app.dmg",
        to:            destination,
        expected_size: 7,
        last_modified: mtime,
        headers:       ["X-Test: yes"],
        cookies:       { a: "1" },
        referer:       "https://ref.example",
        quiet:         true,
      )
      logged_args = args_log.read.lines(chomp: true)
      expect([result, destination.read, destination.mtime.utc, logged_args]).to eq([
        true,
        "payload",
        mtime,
        [
          "-n", "4", "-o", destination.to_s, "-U", HOMEBREW_USER_AGENT_CURL,
          "-H", "Accept-Language: en", "-H", "Cookie: a=1", "-H", "Referer: https://ref.example",
          "-H", "X-Test: yes", "--max-redirect=0", "-q", "--", "https://example.com/app.dmg"
        ],
      ])
    end

    it "preserves a non-empty curl partial without a .st state file and falls back to curl" do
      destination.dirname.mkpath
      destination.write "stale curl partial"
      allow(Process).to receive(:spawn).and_raise("should not spawn")

      result = described_class.download(
        "https://example.com/app.dmg", to: destination, expected_size: 18, quiet: true
      )
      expect([result, destination.read]).to eq([false, "stale curl partial"])
    end

    it "removes an empty leftover partial file without a .st state file before running axel" do
      destination.dirname.mkpath
      destination.write ""
      existed_flag = test_root/"existed"
      fake_axel.write <<~SH
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -e "$out" ] && touch "#{existed_flag}"
        printf 'fresh' > "$out"
        exit 0
      SH
      fake_axel.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 5, quiet: true)
      expect([result, existed_flag.exist?, destination.read]).to eq([true, false, "fresh"])
    end

    it "treats exit 0 with a surviving .st file as failure and cleans up" do
      state = described_class.state_file(destination)
      fake_axel.write <<~SH
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'partial' > "$out"
        printf 'state' > "${out}.st"
        exit 0
      SH
      fake_axel.chmod(0755)

      result = described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
      expect([result, destination.exist?, state.exist?]).to eq([false, false, false])
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

    it "terminates axel and falls back when no progress is made within the watchdog window" do
      state = described_class.state_file(destination)
      fake_axel.write <<~SH
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'stalled' > "$out"
        printf 'state' > "${out}.st"
        sleep 10
      SH
      fake_axel.chmod(0755)

      result = described_class.download(
        "https://example.com/app.dmg",
        to:                  destination,
        expected_size:       7,
        quiet:               true,
        no_progress_timeout: 0.3,
      )
      expect([result, destination.exist?, state.exist?]).to eq([false, false, false])
    end

    it "terminates and reaps axel on non-Interrupt exceptions" do
      pid_file = test_root/"axel.pid"
      fake_axel.write <<~SH
        #!/bin/sh
        echo $$ > "#{pid_file}"
        sleep 10
      SH
      fake_axel.chmod(0755)
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

    it "cleans up partial and state files and re-raises on Timeout::Error" do
      state = described_class.state_file(destination)
      fake_axel.write <<~SH
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'partial' > "$out"
        printf 'state' > "${out}.st"
        sleep 10
      SH
      fake_axel.chmod(0755)

      raised = begin
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, timeout: 0.3,
                                 quiet: true)
        false
      rescue Timeout::Error
        true
      end
      expect([raised, destination.exist?, state.exist?]).to eq([true, false, false])
    end

    it "preserves partial and state files for resume and re-raises on Interrupt" do
      state = described_class.state_file(destination)
      fake_axel.write <<~SH
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'partial' > "$out"
        printf 'state' > "${out}.st"
        sleep 10
      SH
      fake_axel.chmod(0755)
      allow(described_class).to receive(:progress_snapshot).and_wrap_original do |orig, path|
        raise Interrupt if state.exist?

        orig.call(path)
      end

      raised = begin
        described_class.download("https://example.com/app.dmg", to: destination, expected_size: 7, quiet: true)
        false
      rescue Interrupt
        true
      end
      expect([raised, destination.exist?, state.exist?]).to eq([true, true, true])
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

  describe "cache discovery and cleanup with .incomplete.st" do
    it "does not adopt an .incomplete.st sidecar as cached_location" do
      url = "https://example.com/app.dmg"
      strategy = CurlDownloadStrategy.new(url, "app", "1.0")
      allow(strategy).to receive(:resolve_url_basename_time_file_size)
        .and_return([url, "app.dmg", nil, 1024, "application/octet-stream", false])

      hash = Digest::SHA256.hexdigest(url)
      downloads_dir = HOMEBREW_CACHE/"downloads"
      downloads_dir.mkpath
      (downloads_dir/"#{hash}--app.dmg.incomplete").write "sparse"
      (downloads_dir/"#{hash}--app.dmg.incomplete.st").write "state"

      expect(strategy.cached_location).to eq(downloads_dir/"#{hash}--app.dmg")
    end

    it "recognises .incomplete.st as an incomplete download in Cleanup" do
      expect(Homebrew::Cleanup.incomplete?(Pathname("foo.incomplete.st"))).to be(true)
    end

    it "skips deleting .incomplete.st in Cleanup when its paired .incomplete lock is held" do
      downloads_dir = HOMEBREW_CACHE/"downloads"
      downloads_dir.mkpath
      partial = downloads_dir/"abc--app.dmg.incomplete"
      state = downloads_dir/"abc--app.dmg.incomplete.st"
      partial.write "sparse"
      state.write "state"

      lock = DownloadLock.new(partial)
      lock.lock
      begin
        Homebrew::Cleanup.new(cache: HOMEBREW_CACHE).cleanup_unreferenced_downloads
        expect([partial.exist?, state.exist?]).to eq([true, true])
      ensure
        lock.unlock(unlink: true)
      end
    end
  end

  describe "CurlDownloadStrategy integration" do
    sig { returns(CurlDownloadStrategy) }
    let(:strategy) { CurlDownloadStrategy.new("https://example.com/app.dmg", "app", "1.0") }

    before do
      fake_axel
      allow(strategy).to receive(:resolve_url_basename_time_file_size)
        .and_return(["https://example.com/app.dmg", "app.dmg", Time.utc(2025, 1, 2, 3, 4, 5), 7,
                     "application/octet-stream", false])
    end

    it "uses axel and skips curl_download when axel succeeds" do
      allow(strategy).to receive(:curl_download).and_raise("should not call curl_download")

      strategy.fetch
      expect([strategy.cached_location.read, strategy.cached_location.mtime.utc])
        .to eq(["payload", Time.utc(2025, 1, 2, 3, 4, 5)])
    end

    it "falls back to curl_download with remaining timeout when axel returns false" do
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
