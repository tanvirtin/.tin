#!/bin/sh
set -eu

REPO="tanvirtin/.tin"
TAG="${1:-}"
OUT="${2:-Formula/tin.rb}"

die() { echo "[update-formula] ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"

if [ -z "$TAG" ]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
fi
[ -n "$TAG" ] || die "could not determine the latest release tag; pass one explicitly"

BASE="https://github.com/$REPO/releases/download/$TAG"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tin-formula.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

digest() {
    asset="$1"
    if ! curl -fsSL "$BASE/$asset.sha256" -o "$WORK/$asset.sha256"; then
        die "missing checksum sidecar for $asset at $TAG"
    fi
    awk 'NR==1 {print $1}' "$WORK/$asset.sha256"
}

SHA_MACOS_ARM="$(digest tin-darwin-aarch64.tar.gz)"
SHA_MACOS_X86="$(digest tin-darwin-x86_64.tar.gz)"
SHA_LINUX_ARM="$(digest tin-linux-aarch64.tar.gz)"
SHA_LINUX_X86="$(digest tin-linux-x86_64.tar.gz)"

for s in "$SHA_MACOS_ARM" "$SHA_MACOS_X86" "$SHA_LINUX_ARM" "$SHA_LINUX_X86"; do
    printf '%s' "$s" | grep -Eq '^[0-9a-f]{64}$' || die "invalid checksum: $s"
done

mkdir -p "$(dirname "$OUT")"

{
printf 'class Tin < Formula\n'
printf '  desc "Developer environment as code"\n'
printf '  homepage "https://github.com/%s"\n' "$REPO"
printf '\n'
printf '  on_macos do\n'
printf '    on_arm do\n'
printf '      url "%s/tin-darwin-aarch64.tar.gz"\n' "$BASE"
printf '      sha256 "%s"\n' "$SHA_MACOS_ARM"
printf '    end\n'
printf '\n'
printf '    on_intel do\n'
printf '      url "%s/tin-darwin-x86_64.tar.gz"\n' "$BASE"
printf '      sha256 "%s"\n' "$SHA_MACOS_X86"
printf '    end\n'
printf '  end\n'
printf '\n'
printf '  on_linux do\n'
printf '    on_arm do\n'
printf '      url "%s/tin-linux-aarch64.tar.gz"\n' "$BASE"
printf '      sha256 "%s"\n' "$SHA_LINUX_ARM"
printf '    end\n'
printf '\n'
printf '    on_intel do\n'
printf '      url "%s/tin-linux-x86_64.tar.gz"\n' "$BASE"
printf '      sha256 "%s"\n' "$SHA_LINUX_X86"
printf '    end\n'
printf '  end\n'
printf '\n'
printf '  def install\n'
printf '    root = Dir["tin-*"].first || "."\n'
printf '    odie "unexpected release layout" unless File.exist?("#{root}/tinrc.yml")\n'
printf '\n'
printf '    libexec.install "#{root}/bin", "#{root}/environment", "#{root}/engine",\n'
printf '                    "#{root}/tinrc.yml", "#{root}/.tin-revision"\n'
printf '\n'
printf '    (bin/"tin").write <<~SH\n'
printf '      #!/bin/sh\n'
printf '      export TIN_DIR="#{opt_libexec}"\n'
printf '      export TIN_MANAGED_BY="homebrew"\n'
printf '      exec "#{opt_libexec}/bin/tin" "$@"\n'
printf '    SH\n'
printf '  end\n'
printf '\n'
printf '  test do\n'
printf '    assert_match "developer environment", shell_output("#{bin}/tin help")\n'
printf '  end\n'
printf 'end\n'
} > "$OUT"

echo "[update-formula] wrote $OUT for $TAG"
