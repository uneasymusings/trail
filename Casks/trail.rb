# Homebrew cask. Publish it in a tap repo named homebrew-trail, then:
#   brew install --cask uneasymusings/trail/trail
# Update version and sha256 (shasum -a 256 Trail-x.y.z.dmg) for each release.
cask "trail" do
  version "0.2.0"
  sha256 "fdc761e96ca997cbe90725f22749808b1934afa4c15396acd39fdbfbcd3efa5e"

  url "https://github.com/uneasymusings/trail/releases/download/v#{version}/Trail-#{version}.dmg"
  name "Trail"
  desc "Private, on-device knowledge graph of the files on your Mac"
  homepage "https://github.com/uneasymusings/trail"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Trail.app"

  zap trash: [
    "~/Library/Application Support/Trail",
    "~/Library/Group Containers/*.trail",
  ]
end
