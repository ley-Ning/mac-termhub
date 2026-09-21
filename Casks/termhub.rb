cask "termhub" do
  version "0.1.0"
  sha256 "a012d1641733b976eeefff289fec93c2febcc5feda1836f2b3595d42f08e3621"

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
