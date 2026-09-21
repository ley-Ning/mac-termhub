cask "termhub" do
  version "0.2.0"
  sha256 "dd9ed6094b45afdc4d9244ef633c897b913b7b8adb533a2737a62db1eb42dcc3"

  url "https://github.com/ley-Ning/mac-termhub/releases/download/v#{version}/TermHub-#{version}.dmg"
  name "TermHub"
  desc "macOS 原生 SSH 可视化管理客户端（终端/Docker/SFTP/资源监控/MCP）"
  homepage "https://github.com/ley-Ning/mac-termhub"

  app "TermHub.app"

  zap trash: [
    "~/Library/Application Support/TermHub",
    "~/Library/Preferences/com.termhub.app.plist",
  ]
end
