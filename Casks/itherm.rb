cask "itherm" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ddalcu/itherm/releases/download/v#{version}/iTherm.dmg"
  name "iTherm"
  desc "Terminal for benchmarking: live temps, power and fans, and no GPU use"
  homepage "https://github.com/ddalcu/itherm"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "iTherm.app"

  zap trash: "~/Library/Preferences/com.dalcu.itherm.plist"
end
