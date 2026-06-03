#!/usr/bin/env bash
# =============================================================================
# Witcher PHP 8.4 — one-click installer
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --prefix DIR      Install PHP to DIR            (default: /usr/local)
#   --source DIR      Extract / build in DIR        (default: /phpsrc8)
#   --php-ver VER     PHP 8.4.x point release       (default: 8.4.21)
#   --xdebug-ver VER  Xdebug 3.x version            (default: 3.4.7)
#   --debug           Build with -DWITCHER_DEBUG=1
#   --jobs N          Parallel make jobs             (default: nproc)
#   --skip-download   Reuse existing source in --source DIR
#   --skip-deps       Skip apt-get dependency install
#   -h, --help        Show this help
#
# Examples:
#   ./install.sh
#   ./install.sh --prefix /opt/php84 --source /build/php8
#   ./install.sh --debug --jobs 4
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PHP_VER="8.4.21"
XDEBUG_VER="3.4.7"
PREFIX="/usr/local"
SOURCE_DIR="/phpsrc8"
WITCHER_DEBUG=0
JOBS=$(nproc)
SKIP_DOWNLOAD=0
SKIP_DEPS=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)      PREFIX="$2";       shift 2 ;;
        --source)      SOURCE_DIR="$2";   shift 2 ;;
        --php-ver)     PHP_VER="$2";      shift 2 ;;
        --xdebug-ver)  XDEBUG_VER="$2";  shift 2 ;;
        --debug)       WITCHER_DEBUG=1;   shift   ;;
        --jobs)        JOBS="$2";         shift 2 ;;
        --skip-download) SKIP_DOWNLOAD=1; shift   ;;
        --skip-deps)   SKIP_DEPS=1;       shift   ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

PHP_TARBALL="php-${PHP_VER}.tar.xz"
PHP_URL="https://www.php.net/distributions/${PHP_TARBALL}"
PHP_SHA256_URL="https://www.php.net/releases/index.php?json&version=${PHP_VER}"
XDEBUG_URL="https://api.github.com/repos/xdebug/xdebug/tarball/${XDEBUG_VER}"

CYAN='\033[36m'; GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[Witcher]${RESET} $*"; }
ok()    { echo -e "${GREEN}[Witcher] OK${RESET} $*"; }
die()   { echo -e "${RED}[Witcher] ERROR${RESET} $*" >&2; exit 1; }

# ── /bin/sh safety: use bash for configure (Widash workaround) ───────────────
# On Witcher hosts, /bin/sh is a modified dash (Widash) that crashes autoconf
# configure scripts. We always force bash for configure.
export CONFIG_SHELL=/bin/bash

# =============================================================================
info "=== Witcher PHP ${PHP_VER} installer ==="
info "  prefix     : ${PREFIX}"
info "  source dir : ${SOURCE_DIR}"
info "  xdebug     : ${XDEBUG_VER}"
info "  debug build: ${WITCHER_DEBUG}"
info "  jobs       : ${JOBS}"
echo ""

# ── Step 1: Dependencies ──────────────────────────────────────────────────────
if [[ $SKIP_DEPS -eq 0 ]]; then
    info "Installing build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        build-essential autoconf automake libtool bison \
        libxml2-dev libssl-dev zlib1g-dev libpng-dev libjpeg-dev \
        libfreetype6-dev libzip-dev libonig-dev libsqlite3-dev \
        libicu-dev apache2-dev curl wget
    ok "Dependencies installed."
fi

# ── Step 2: Download & verify PHP source ─────────────────────────────────────
TARBALL_PATH="/tmp/${PHP_TARBALL}"

if [[ $SKIP_DOWNLOAD -eq 0 ]]; then
    info "Downloading PHP ${PHP_VER}..."
    curl -# -L "${PHP_URL}" -o "${TARBALL_PATH}"

    info "Verifying checksum..."
    EXPECTED=$(curl -sL "${PHP_SHA256_URL}" | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('source', []):
    if s.get('filename','').endswith('.tar.xz'):
        print(s.get('sha256',''))
        break
")
    ACTUAL=$(sha256sum "${TARBALL_PATH}" | awk '{print $1}')
    [[ "$EXPECTED" == "$ACTUAL" ]] || die "Checksum mismatch! Expected ${EXPECTED}, got ${ACTUAL}"
    ok "Checksum verified."

    info "Extracting to ${SOURCE_DIR}..."
    sudo mkdir -p "${SOURCE_DIR}"
    sudo chown "$(id -u):$(id -g)" "${SOURCE_DIR}"
    tar -xJf "${TARBALL_PATH}" -C "${SOURCE_DIR}" --strip-components=1
    ok "Extracted."
fi

[[ -f "${SOURCE_DIR}/configure.ac" ]] || die "PHP source not found at ${SOURCE_DIR}"

# ── Step 3: Copy Witcher files ────────────────────────────────────────────────
info "Copying Witcher trace files..."
cp "${SCRIPT_DIR}/zend_witcher_trace.c" "${SOURCE_DIR}/Zend/"
cp "${SCRIPT_DIR}/zend_witcher_trace.h" "${SOURCE_DIR}/Zend/"
ok "Trace files copied."

# ── Step 4: Apply Witcher patch ───────────────────────────────────────────────
info "Applying Witcher patch..."
cd "${SOURCE_DIR}"

# Detect patch tool
if command -v patch &>/dev/null; then
    patch -p1 --forward < "${SCRIPT_DIR}/php-8.4-witcher.patch" || \
        { info "Patch already applied or partially applied — continuing."; }
else
    die "GNU patch not found. Install with: sudo apt-get install patch"
fi
ok "Patch applied."

# ── Step 5: buildconf ─────────────────────────────────────────────────────────
info "Running buildconf..."
cd "${SOURCE_DIR}"
bash buildconf --force
ok "buildconf done."

# ── Step 6: configure ────────────────────────────────────────────────────────
info "Configuring (prefix=${PREFIX})..."

APXS=""
for a in /usr/bin/apxs2 /usr/bin/apxs /usr/sbin/apxs2 /usr/sbin/apxs; do
    [[ -x "$a" ]] && { APXS="$a"; break; }
done

CONFIGURE_ARGS=(
    "--prefix=${PREFIX}"
    "--enable-cgi"
    "--enable-ftp"
    "--enable-mbstring"
    "--enable-gd"
    "--with-jpeg"
    "--with-freetype"
    "--with-openssl"
    "--with-mysqli"
    "--with-pdo-mysql"
    "--with-zlib"
    "--with-zip"
    "--enable-intl"
)
[[ -n "$APXS" ]] && CONFIGURE_ARGS+=("--with-apxs2=${APXS}")

bash configure "${CONFIGURE_ARGS[@]}"
ok "Configure done."

# ── Step 7: make ─────────────────────────────────────────────────────────────
info "Building (${JOBS} jobs)..."
if [[ $WITCHER_DEBUG -eq 1 ]]; then
    make -j"${JOBS}" EXTRA_CFLAGS="-DWITCHER_DEBUG=1"
else
    make -j"${JOBS}"
fi
ok "Build complete."

# ── Step 8: make install ──────────────────────────────────────────────────────
info "Installing to ${PREFIX}..."
sudo make install
ok "PHP ${PHP_VER} installed."

# ── Step 9: Xdebug ───────────────────────────────────────────────────────────
info "Building Xdebug ${XDEBUG_VER}..."
XDEBUG_SRC="${SOURCE_DIR}/ext/xdebug"
mkdir -p "${XDEBUG_SRC}"
curl -sL "${XDEBUG_URL}" | tar -xz -C "${XDEBUG_SRC}" --strip-components=1
cd "${XDEBUG_SRC}"
"${PREFIX}/bin/phpize"
bash configure --enable-xdebug --with-php-config="${PREFIX}/bin/php-config"
make -j"${JOBS}"
sudo make install
ok "Xdebug ${XDEBUG_VER} installed."

# ── Step 10: php.ini ─────────────────────────────────────────────────────────
info "Configuring php.ini..."
PHP_INI_SRC="${SOURCE_DIR}/php.ini-production"
PHP_INI_DEST="${PREFIX}/lib/php.ini"

if [[ ! -f "${PHP_INI_DEST}" ]]; then
    sudo cp "${PHP_INI_SRC}" "${PHP_INI_DEST}"
fi

# Detect xdebug extension path
EXT_DIR=$("${PREFIX}/bin/php-config" --extension-dir)
XDEBUG_SO="${EXT_DIR}/xdebug.so"

# Append Witcher / Xdebug settings (idempotent — skip if already present)
if ! grep -q "zend_extension.*xdebug" "${PHP_INI_DEST}" 2>/dev/null; then
    sudo tee -a "${PHP_INI_DEST}" >/dev/null <<EOF

; === Witcher / Xdebug (added by witcher install.sh) ===
zend_extension=${XDEBUG_SO}
xdebug.mode=coverage
EOF
fi

# Disable force_redirect so php-cgi can be called directly by AFL
# Delete any existing (commented or active) line, then always append the active setting.
sudo sed -i '/^\s*;*\s*cgi\.force_redirect\s*=/d' "${PHP_INI_DEST}"
echo "cgi.force_redirect = 0" | sudo tee -a "${PHP_INI_DEST}" >/dev/null

ok "php.ini configured at ${PHP_INI_DEST}"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
ok "=== Installation complete ==="
echo ""
echo "  PHP binary : ${PREFIX}/bin/php"
echo "  PHP-CGI    : ${PREFIX}/bin/php-cgi"
echo "  php.ini    : ${PHP_INI_DEST}"
echo "  Xdebug     : ${XDEBUG_SO}"
echo ""
echo "  Quick test:"
echo "    SCRIPT_FILENAME=/tmp/test.php ${PREFIX}/bin/php-cgi"
echo ""
echo "  Debug build:"
echo "    WITCHER_DEBUG=1 ./install.sh --skip-download --skip-deps"
