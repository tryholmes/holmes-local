# Homebrew cask template. Publish a tap (e.g. github.com/<org>/homebrew-holmes)
# and copy this file in as Casks/holmes.rb, filling in the url and sha256 from
# dist/Holmes-<version>.dmg.sha256 after each release.
#
#   brew tap <org>/holmes
#   brew install --cask holmes

cask "holmes" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_dist/Holmes-#{version}.dmg.sha256"

  url "https://github.com/<org>/holmes-ollama/releases/download/v#{version}/Holmes-#{version}.dmg"
  name "Holmes"
  desc "Local first autonomous desktop agent that drafts and never sends"
  homepage "https://github.com/<org>/holmes-ollama"

  depends_on macos: ">= :sonoma"

  app "Holmes.app"

  zap trash: [
    "~/Library/Application Support/Holmes",
    "~/Library/Preferences/com.zeroprompt.holmes.local.plist",
  ]
end
