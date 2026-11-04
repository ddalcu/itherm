cask "itherm" do
  version "26.11.1"
  sha256 "1e82b1464c621ed372ab99dce4c732fbca85885dc2c6e7bac2f82952e1d83e0d"

  url "https://github.com/ddalcu/itherm/releases/download/v#{version}/iTherm.dmg"
  name "iTherm"
  desc "Terminal for benchmarking: live temps, power and fans, and no GPU use"
  homepage "https://github.com/ddalcu/itherm"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "iTherm.app"

  zap trash: "~/Library/Preferences/com.dalcu.itherm.plist"
end
