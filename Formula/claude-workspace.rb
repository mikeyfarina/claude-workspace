class ClaudeWorkspace < Formula
  desc "Put terminal tabs, splits and agent sessions back after a restart"
  homepage "https://github.com/mikeyfarina/claude-workspace"
  license "MIT"
  head "https://github.com/mikeyfarina/claude-workspace.git", branch: "main"

  # Until the first tagged release this is head-only, so installs are:
  #   brew install --HEAD mikeyfarina/tap/claude-workspace
  # On tagging v0.2.0, add above the `head` line:
  #   url "https://github.com/mikeyfarina/claude-workspace/archive/refs/tags/v0.2.0.tar.gz"
  #   sha256 "<shasum -a 256 of that tarball>"

  depends_on "jq"
  depends_on :macos

  def install
    # bin/claude-workspace resolves its own path and looks for ../libexec/lib,
    # so the payload has to sit together under libexec.
    libexec.install "lib", "shell"
    bin.install "bin/claude-workspace"
  end

  def caveats
    <<~EOS
      Finish setting up with:
        claude-workspace install
        claude-workspace doctor

      That adds one line to your shell rc and registers the Claude Code hooks
      that keep snapshots fresh. `claude-workspace uninstall` reverses it.
    EOS
  end

  test do
    assert_match "claude-workspace", shell_output("#{bin}/claude-workspace version")
    assert_match "simulate", shell_output("#{bin}/claude-workspace help")
  end
end
