class Tin < Formula
  desc "Developer environment as code"
  homepage "https://github.com/tanvirtin/.tin"

  on_macos do
    on_arm do
      url "https://github.com/tanvirtin/.tin/releases/download/v0.1.3/tin-darwin-aarch64.tar.gz"
      sha256 "0a12430bf696d306cf71c9fdd0e00ecb2c21c48fe6e4b437831c575d2b11b659"
    end

    on_intel do
      url "https://github.com/tanvirtin/.tin/releases/download/v0.1.3/tin-darwin-x86_64.tar.gz"
      sha256 "c980e5bf05bbe8074077a82c2f57edace3964a73b69f9727a98482915a0295a6"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/tanvirtin/.tin/releases/download/v0.1.3/tin-linux-aarch64.tar.gz"
      sha256 "ae8d35fd2c4b67fe3db63a9aeb78832e6eceba74c23862b6be3f45f6baae2631"
    end

    on_intel do
      url "https://github.com/tanvirtin/.tin/releases/download/v0.1.3/tin-linux-x86_64.tar.gz"
      sha256 "34c10a00bdfe1b1c53f6d739f7638157b3374b8afaea1d56af554279102480b1"
    end
  end

  def install
    root = Dir["tin-*"].first || "."
    odie "unexpected release layout" unless File.exist?("#{root}/tinrc.yml")

    libexec.install "#{root}/bin", "#{root}/environment", "#{root}/engine",
                    "#{root}/tinrc.yml", "#{root}/.tin-revision"

    (bin/"tin").write <<~SH
      #!/bin/sh
      export TIN_DIR="#{opt_libexec}"
      export TIN_MANAGED_BY="homebrew"
      exec "#{opt_libexec}/bin/tin" "$@"
    SH
  end

  test do
    assert_match "developer environment", shell_output("#{bin}/tin help")
  end
end
