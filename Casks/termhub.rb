cask "termhub" do
  version "0.3.0"
  sha256 "3243ac26af0fa592c7c7928885d95c89602b3e7b513f9b5c0b9a63849433da5c"

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
