cask "termhub" do
  version "0.3.1"
  sha256 :no_check  # 待 v0.3.1 产物落地后自动钉值

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
