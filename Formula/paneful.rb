class Paneful < Formula
  desc "Put terminal tabs, splits and agent sessions back after a restart"
  homepage "https://github.com/mikeyfarina/paneful"
  license "MIT"
  head "https://github.com/mikeyfarina/paneful.git", branch: "main"

  # Until the first tagged release this is head-only, so installs are:
  #   brew install --HEAD mikeyfarina/tap/paneful
  # On tagging v0.2.0, add above the `head` line:
  #   url "https://github.com/mikeyfarina/paneful/archive/refs/tags/v0.2.0.tar.gz"
  #   sha256 "<shasum -a 256 of that tarball>"

  depends_on "jq"
  depends_on :macos

  def install
    # bin/paneful resolves its own path and looks for ../libexec/lib,
    # so the payload has to sit together under libexec.
    libexec.install "lib", "shell"
    bin.install "bin/paneful"
  end

  def caveats
    <<~EOS
      Finish setting up with:
        paneful install
        paneful doctor

      That adds one line to your shell rc and registers the Claude Code hooks
      that keep snapshots fresh. `paneful uninstall` reverses it.
    EOS
  end

  test do
    assert_match "paneful", shell_output("#{bin}/paneful version")
    assert_match "simulate", shell_output("#{bin}/paneful help")
  end
end
