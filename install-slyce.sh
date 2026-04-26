#!/usr/bin/env sh
# Install the `slyce` CLI from the release CDN (same layout as worker / worker-cli).
# Requires Node.js (for platform detection and optional SHA-256 verify) and curl.
#
# Stable one-liner (tracks main; pin a commit SHA in production if you need immutability):
#   curl -fsSL https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.sh | sh
#
# Or with a custom base URL:
#   SLYCE_RELEASE_BASE_URL=https://example.com curl -fsSL ... | sh
#
# Installs to $INSTALL_DIR (default: runtime root bin directory):
#   macOS: ~/Library/Application Support/Slyce/bin
#   Linux: /var/lib/slyce/bin
#   Windows (when run via sh): C:\ProgramData\Slyce\bin

set -eu

if ! command -v node >/dev/null 2>&1; then
  echo "install-slyce: Node.js is required (for platform detection)." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "install-slyce: curl is required." >&2
  exit 1
fi

BASE="${SLYCE_RELEASE_BASE_URL:-${WORKER_UPDATE_BASE_URL:-https://slyce.moiste.la}}"
default_install_dir=$(node -e '
const os = require("node:os");
const path = require("node:path");
if (process.platform === "win32") {
  const programData = process.env.ProgramData || "C:\\ProgramData";
  process.stdout.write(path.join(programData, "Slyce", "bin"));
} else if (process.platform === "darwin") {
  process.stdout.write(path.join(os.homedir(), "Library", "Application Support", "Slyce", "bin"));
} else {
  process.stdout.write("/var/lib/slyce/bin");
}
')
INSTALL_DIR="${INSTALL_DIR:-$default_install_dir}"

platform_arch=$(node -e "console.log(process.platform+' '+process.arch)")
platform=${platform_arch%% *}
arch=${platform_arch#* }

remove_legacy_user_scoped_slyce_binaries() {
  home_dir="${HOME:-}"
  if [ -z "$home_dir" ]; then
    return
  fi

  target_path="${INSTALL_DIR}/slyce${ext}"
  legacy_candidates="
$home_dir/.local/bin/slyce
$home_dir/.local/bin/slyce.new
$home_dir/.slyce/bin/slyce
$home_dir/.slyce/bin/slyce.new
$home_dir/.local/bin/slyce.exe
$home_dir/.local/bin/slyce.new.exe
$home_dir/.slyce/bin/slyce.exe
$home_dir/.slyce/bin/slyce.new.exe
"

  old_ifs=$IFS
  IFS='
'
  for candidate in $legacy_candidates; do
    [ -n "$candidate" ] || continue
    if [ "$candidate" = "$target_path" ]; then
      continue
    fi
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      if rm -f "$candidate"; then
        echo "install-slyce: removed legacy user binary $candidate"
      else
        echo "install-slyce: warning - could not remove legacy user binary $candidate" >&2
      fi
    fi
  done
  IFS=$old_ifs
}
LATEST_URL="${BASE}/slyce/${platform}/${arch}/latest.json"
echo "install-slyce: reading ${LATEST_URL}"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSL "$LATEST_URL" -o "$tmp_dir/latest.json"
version=$(node -e "const j=require('fs').readFileSync(process.argv[1],'utf8');const o=JSON.parse(j);if(typeof o.version!=='string')process.exit(1);console.log(o.version)" "$tmp_dir/latest.json")

ext=""
case "$platform" in
  win32) ext=".exe" ;;
esac

BIN_URL="${BASE}/slyce/${platform}/${arch}/${version}/slyce${ext}"
echo "install-slyce: downloading ${BIN_URL}"

tmp_bin="$tmp_dir/slyce${ext}"
curl -fsSL "$BIN_URL" -o "$tmp_bin"

tmp_sum="$tmp_dir/slyce.sha256"
set +e
curl -fsSL "${BIN_URL}.sha256" -o "$tmp_sum" 2>/dev/null
sum_st=$?
set -e

if [ "$sum_st" -eq 0 ] && [ -s "$tmp_sum" ]; then
  echo "install-slyce: verifying SHA-256"
  expected=$(node -e "const fs=require('fs');const s=fs.readFileSync(process.argv[1],'utf8').trim().split(/\\s+/)[0];if(!/^[a-f0-9]{64}$/i.test(s))process.exit(1);console.log(s.toLowerCase())" "$tmp_sum")
  actual=$(node -e "const c=require('crypto'),fs=require('fs');console.log(c.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'))" "$tmp_bin")
  if [ "$expected" != "$actual" ]; then
    echo "install-slyce: checksum mismatch (expected $expected, got $actual)" >&2
    exit 1
  fi
else
  echo "install-slyce: no .sha256 sidecar found; skipping checksum verify"
fi

mkdir -p "$INSTALL_DIR"
mv -f "$tmp_bin" "$INSTALL_DIR/slyce${ext}"
chmod +x "$INSTALL_DIR/slyce${ext}"
remove_legacy_user_scoped_slyce_binaries

echo "install-slyce: installed to ${INSTALL_DIR}/slyce${ext}"
