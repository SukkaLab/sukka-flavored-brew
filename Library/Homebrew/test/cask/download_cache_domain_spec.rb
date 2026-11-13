# typed: strict
# frozen_string_literal: true

require "cask/download"

RSpec.describe Cask::Download do
  describe "#downloader" do
    sig { returns(AbstractDownloadStrategy) }
    subject(:downloader) { described_class.new(cask).downloader }

    # Keep each Sorbet signature with its let declaration.
    # rubocop:disable RSpec/ScatteredLet
    sig { returns(String) }
    let(:url_to_s) { "https://example.com/app.dmg" }

    sig { returns(T::Hash[Symbol, String]) }
    let(:url_specs) { {} }

    sig { returns(String) }
    let(:cache_url) { "https://cache.example/#{url_to_s}" }

    sig { returns(Cask::Cask) }
    let(:cask) do
      cask_url = url_to_s
      cask_url_specs = url_specs
      Cask::Cask.new("example-cask") do
        version "1.2.3"
        url cask_url, **cask_url_specs
      end
    end

    sig { returns(T::Array[String]) }
    let(:download_urls) do
      strategy = downloader
      strategy.is_a?(CurlDownloadStrategy) ? [strategy.url, *strategy.mirrors] : [strategy.url]
    end
    # rubocop:enable RSpec/ScatteredLet

    it "downloads from the original URL without `$HOMEBREW_CASK_CACHE_DOMAIN`" do
      expect(download_urls).to eq([url_to_s])
    end

    context "with `$HOMEBREW_CASK_CACHE_DOMAIN` set" do
      before { ENV["HOMEBREW_CASK_CACHE_DOMAIN"] = "https://cache.example/" }

      it "downloads from the cache before falling back to the original URL" do
        expect(download_urls).to eq([cache_url, url_to_s])
      end

      context "with a Git URL" do
        # Keep each Sorbet signature with its let declaration.
        # rubocop:disable RSpec/ScatteredLet
        sig { returns(String) }
        let(:url_to_s) { "https://github.com/example/fonts.git" }

        sig { returns(T::Hash[Symbol, String]) }
        let(:url_specs) { { branch: "main" } }
        # rubocop:enable RSpec/ScatteredLet

        it "downloads from the original URL" do
          expect(download_urls).to eq([url_to_s])
        end
      end

      context "when the cache redirects to a URL containing the original host" do
        sig { returns(String) }
        let(:url_to_s) { "https://downloads.example.com/tool" }

        it "names the download after the original URL" do
          strategy = downloader
          raise "Expected a curl download for #{url_to_s}" unless strategy.is_a?(CurlDownloadStrategy)

          allow(strategy).to receive(:curl_headers).and_return(
            responses: [
              { headers: { "location" => "https://mirror.example/https/downloads.example.com/tool" } },
              { headers: {} },
            ],
          )

          expect(strategy.basename.to_s).to eq("tool")
        end
      end

      context "with `$HOMEBREW_CASK_CACHE_DOMAIN_NO_FALLBACK` set" do
        before { ENV["HOMEBREW_CASK_CACHE_DOMAIN_NO_FALLBACK"] = "1" }

        it "downloads only from the cache" do
          expect(download_urls).to eq([cache_url])
        end
      end
    end
  end
end
