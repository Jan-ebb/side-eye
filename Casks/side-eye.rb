cask "side-eye" do
  version "0.17.0"
  sha256 "1ac609dac241990c7da13c1495638d5ddf0021b16935b1900d459fee7b50985d"

  url "https://github.com/Jan-ebb/side-eye/releases/download/v#{version}/SideEye-#{version}.zip"
  name "Side Eye"
  desc "Edge sidebar that lists agent chats from Codex, Claude Code, Cursor and Grok Bot"
  homepage "https://github.com/Jan-ebb/side-eye"

  depends_on macos: ">= :sonoma"

  app "Side Eye.app"

  zap trash: [
    "~/Library/Preferences/io.github.jan-ebb.side-eye.plist",
  ]

  caveats <<~EOS
    Side Eye is not notarized by Apple yet, so macOS blocks it the first time
    you open it. Open it once, then click Open Anyway under
    System Settings > Privacy & Security.
  EOS
end
