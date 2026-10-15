# Homebrew cask. Publish it in a tap repo named homebrew-trail, then:
#   brew install --cask uneasymusings/trail/trail
# Update version and sha256 (shasum -a 256 Trail-x.y.z.dmg) for each release.
cask "trail" do
  version "0.3.0"
  sha256 "30484bd892440dc4a85222ad714087ab038984641366ad351aed51f779550419"

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
