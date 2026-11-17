cask "side-eye" do
  version "0.16.0"
  sha256 :no_check

  url "https://github.com/Jan-ebb/side-eye/releases/download/v#{version}/SideEye-#{version}.zip"
  name "Side Eye"
  desc "Edge sidebar that lists agent chats from Codex, Claude Code, Cursor and Grok Bot"
  homepage "https://github.com/Jan-ebb/side-eye"

  depends_on macos: ">= :sonoma"

  app "Side Eye.app"

  zap trash: [
    "~/Library/Preferences/io.github.jan-ebb.side-eye.plist",
  ]
end
