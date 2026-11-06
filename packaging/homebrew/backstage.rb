# The formula for the owner's tap, filled in at each release: a source build, since the app is signed on the Mac it
# runs on. `backstage setup` then installs it into Applications with this Mac's certificate, so macOS keeps its
# permissions across upgrades; Homebrew itself never writes outside its prefix or asks for a permission.
class Backstage < Formula
  desc "Let AI agents use your Mac's apps in the background"
  homepage "https://github.com/padmk/backstage"
  url "https://github.com/padmk/backstage/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_AT_RELEASE"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    system "make", "app"
    libexec.install "build/Backstage.app"
    bin.write_exec_script libexec/"Backstage.app/Contents/Helpers/backstage"
  end

  def caveats
    <<~EOS
      Install the app and grant its permissions, after this install and after every upgrade:
        backstage setup
      Restart your agent sessions afterwards, so they load the new version.

      Before `brew uninstall backstage`, remove the app from Applications and its registrations:
        backstage uninstall
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/backstage version").strip
  end
end
