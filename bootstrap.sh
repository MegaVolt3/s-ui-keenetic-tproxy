#!/bin/sh
# bootstrap.sh -- one-line install of s-ui + transparent-proxy glue on a
# Keenetic / Netcraze router with Entware.
#
# On the router, as root (note: BusyBox wget on some Keenetic builds is broken
# and cannot do HTTPS - use the Entware one or curl if you have it):
#
#   /opt/bin/wget -qO- https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main/bootstrap.sh | sh -s --
#   curl -fsSL https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main/bootstrap.sh | sh -s -- --sui-version 1.6.5
#
# Options:
#   --sui-version V|latest   s-ui version to install (default: latest)
#   --skip-sui               do not touch the s-ui binary (glue only)
#   --no-glue                install files but do not apply the firewall glue
#   --policy-desc NAME       Keenetic policy description to bind to (default SUI-TProxy)
#   --repo-tarball URL       take the project from another tarball URL
#   --from-file FILE         install the project from a local tarball (offline)
#   --keep N                 keep N old s-ui binaries as backups (default 2)
#   --allow-busybox-wget     last resort: use BusyBox wget if no curl/GNU wget
#   --dry-run                print the plan, change nothing
#
# What it does: installs the Entware packages the glue needs, unpacks this
# project, installs its files (install.sh), installs/updates the s-ui binary
# from upstream (sui-update), starts the panel and the glue, then verifies the
# result and prints the next steps.

PREFIX="${PREFIX:-/opt}"
TEST_MODE=0
[ "$PREFIX" != "/opt" ] && TEST_MODE=1
PROJECT="s-ui-keenetic-proxy"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main}"
TARBALL_URL="${TARBALL_URL:-https://codeload.github.com/MegaVolt3/s-ui-keenetic-tproxy/tar.gz/refs/heads/main}"
TMP="$PREFIX/tmp/bootstrap.$$"

SUI_VERSION="latest"
SKIP_SUI=0
NO_GLUE=0
POLICY_DESC="SUI-TProxy"
FROM_FILE=""
KEEP=2
DRY_RUN=0
BUSYBOX_WGET=0

usage() {
    sed -n '2,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }
info() { echo "[ + ] $*"; }
warn() { echo "[ ! ] $*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --sui-version) shift; SUI_VERSION="$1" ;;
        --skip-sui) SKIP_SUI=1 ;;
        --no-glue) NO_GLUE=1 ;;
        --policy-desc) shift; POLICY_DESC="$1" ;;
        --repo-tarball) shift; TARBALL_URL="$1" ;;
        --from-file) shift; FROM_FILE="$1" ;;
        --keep) shift; KEEP="$1" ;;
        --allow-busybox-wget) BUSYBOX_WGET=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- environment -----------------------------------------------------------

if [ "$TEST_MODE" = 0 ]; then
    [ "$(id -u)" = "0" ] || die "run as root on the router"
    [ -d "$PREFIX/etc" ] || die "Entware not found at $PREFIX - install Entware on the router first"
    [ -x "$PREFIX/bin/opkg" ] || command -v opkg >/dev/null 2>&1 || die "opkg not found - install Entware first"
else
    info "PREFIX=$PREFIX: test mode (no root/Entware checks)"
fi

detect_downloader() {
    DL_CURL=""; DL_WGET=""
    if dl_c=$(command -v curl 2>/dev/null); then
        DL_CURL="$dl_c"
        return 0
    fi
    # Never accept a bare "wget" blindly: on Keenetic it is often BusyBox's,
    # which has no TLS (and is reported to segfault on some builds).
    for dl_w in /opt/bin/wget /opt/libexec/wget-ssl /opt/usr/bin/wget /usr/bin/wget wget; do
        dl_path=$(command -v "$dl_w" 2>/dev/null) || continue
        if "$dl_path" --version 2>&1 | grep -q 'GNU Wget'; then
            DL_WGET="$dl_path"
            return 0
        fi
    done
    return 1
}

detect_tar() {
    # BusyBox tar cannot create archives and differs in flags; prefer GNU tar.
    TAR=""
    for dt_c in "$PREFIX/bin/tar" "$PREFIX/usr/bin/tar" tar; do
        if command -v "$dt_c" >/dev/null 2>&1 && "$dt_c" --version >/dev/null 2>&1; then
            TAR="$dt_c"
            return 0
        fi
    done
    if command -v tar >/dev/null 2>&1; then
        TAR=tar
        return 0
    fi
    return 1
}

fetch_stdout() {
    if [ -n "$DL_CURL" ]; then
        "$DL_CURL" -fsSL --max-time 300 "$1"
    elif [ -n "$DL_WGET" ]; then
        "$DL_WGET" -qO- -T 300 "$1"
    elif [ "$BUSYBOX_WGET" = 1 ]; then
        busybox wget -qO- -T 120 "$1"
    else
        return 1
    fi
}

fetch_file() {
    if [ -n "$DL_CURL" ]; then
        "$DL_CURL" -fsSL --max-time 900 -o "$2" "$1"
    elif [ -n "$DL_WGET" ]; then
        "$DL_WGET" -q -T 900 -O "$2" "$1"
    elif [ "$BUSYBOX_WGET" = 1 ]; then
        busybox wget -q -O "$2" -T 300 "$1"
    else
        return 1
    fi
}

port_listening() {
    pl_hex=$(printf '%04X' "$1")
    awk -v h="$pl_hex" 'NR > 1 && $2 ~ ":" h "$" && $4 == "0A" { f = 1 } END { exit !f }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

policy_mark() {
    pm_bin=$(command -v ndmc 2>/dev/null || echo "$PREFIX/bin/ndmc")
    [ -x "$pm_bin" ] || return 0
    "$pm_bin" -c "show ip policy" 2>/dev/null | awk -v d="$POLICY_DESC" '
        BEGIN { wanted = tolower(d) }
        /policy, name =/ { line = tolower($0); in_p = (line ~ ("description = " wanted ":") || line ~ ("description = " wanted "[ ]*$")) }
        in_p && /mark:/ { print $2; exit }
    '
}

# --- plan ------------------------------------------------------------------

info "bootstrap: s-ui-keenetic-tproxy -> $PREFIX"
echo "      s-ui version : $SUI_VERSION"
echo "      policy       : $POLICY_DESC"
echo "      source       : ${FROM_FILE:-$TARBALL_URL}"

if [ "$DRY_RUN" = 1 ]; then
    cat <<EOF

Would do:
  1. opkg update + install missing packages: wget-ssl curl ca-certificates ipset iptables
  2. unpack the project into $TMP and run its install.sh
  3. install/update the s-ui binary (sui-update --version $SUI_VERSION --keep $KEEP)
  4. start the panel and the proxy glue
  5. verify listeners, ipset, iptables chains and the policy mark
EOF
    exit 0
fi

[ -d "$PREFIX/etc/s-ui" ] || info "no $PREFIX/etc/s-ui yet - a fresh panel install will be created by sui-update"
mkdir -p "$TMP" || die "cannot create $TMP"

# --- packages --------------------------------------------------------------

detect_tar || die "tar not found on the router"

if ! detect_downloader; then
    if [ "$BUSYBOX_WGET" = 1 ]; then
        warn "no curl/GNU wget found - trying BusyBox wget (broken on some Keenetic builds)"
    elif [ "$TEST_MODE" = 1 ]; then
        die "test mode: no curl/GNU wget found - would install wget-ssl with opkg here"
    else
        info "no curl/GNU wget found - installing wget-ssl/curl with opkg (opkg downloads by itself)"
        opkg update >/dev/null 2>&1 || warn "opkg update failed (continuing)"
        opkg install wget-ssl curl || die "cannot install a downloader - run 'opkg install curl' manually"
        detect_downloader || die "still no usable downloader after installing wget-ssl/curl"
    fi
fi

NEED=""
for pkg in wget-ssl curl ca-certificates ipset iptables; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        NEED="$NEED $pkg"
    fi
done
if [ -n "$NEED" ] && [ "$TEST_MODE" = 0 ]; then
    info "installing missing packages:$NEED"
    opkg update >/dev/null 2>&1 || warn "opkg update failed (continuing)"
    # shellcheck disable=SC2086
    opkg install $NEED || warn "opkg install failed for some packages - continuing"
elif [ -n "$NEED" ]; then
    info "test mode: would install packages:$NEED"
else
    info "all required packages are already installed"
fi

# --- project files ---------------------------------------------------------

if [ -n "$FROM_FILE" ]; then
    [ -f "$FROM_FILE" ] || die "no such file: $FROM_FILE"
    cp -f "$FROM_FILE" "$TMP/project.tar.gz" || die "cannot copy $FROM_FILE"
else
    info "downloading the project tarball"
    fetch_file "$TARBALL_URL" "$TMP/project.tar.gz" || die "download failed: $TARBALL_URL"
fi
mkdir -p "$TMP/src"
"$TAR" -xzf "$TMP/project.tar.gz" -C "$TMP/src" || die "cannot unpack the project tarball"
PROJ_DIR=$(find "$TMP/src" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -n "$PROJ_DIR" ] || die "unexpected tarball layout"
[ -f "$PROJ_DIR/install.sh" ] || die "install.sh not found in the project"

info "installing project files"
( cd "$PROJ_DIR" && sh ./install.sh ) || die "install.sh failed"

if [ -f "$PREFIX/etc/sui-tproxy/sui-tproxy.conf" ]; then
    grep -q "^POLICY_DESCRIPTION=" "$PREFIX/etc/sui-tproxy/sui-tproxy.conf" &&
        sed -i "s|^POLICY_DESCRIPTION=.*|POLICY_DESCRIPTION=\"$POLICY_DESC\"|" "$PREFIX/etc/sui-tproxy/sui-tproxy.conf" &&
        info "policy description set to '$POLICY_DESC' in $PREFIX/etc/sui-tproxy/sui-tproxy.conf"
fi

# --- s-ui binary -----------------------------------------------------------

if [ "$SKIP_SUI" = 1 ]; then
    info "--skip-sui: leaving the s-ui binary alone"
else
    UPDATE="$PREFIX/sbin/sui-update"
    [ -x "$UPDATE" ] || die "sui-update was not installed by install.sh"
    info "installing s-ui ($SUI_VERSION)"
    if [ "$SUI_VERSION" = "latest" ]; then
        "$UPDATE" --keep "$KEEP" || die "s-ui install/update failed"
    else
        "$UPDATE" --version "$SUI_VERSION" --keep "$KEEP" || die "s-ui install/update failed"
    fi
fi

# --- start + verify --------------------------------------------------------

PANEL_INIT="$PREFIX/etc/init.d/S90s-ui"
GLUE_INIT="$PREFIX/etc/init.d/S99sui-tproxy"

if [ -x "$PANEL_INIT" ] && ! port_listening 2095; then
    info "starting the panel"
    "$PANEL_INIT" start || warn "panel init reported a problem"
fi

if [ "$NO_GLUE" = 1 ]; then
    info "--no-glue: not applying firewall rules"
else
    MARK=$(policy_mark)
    if [ -z "$MARK" ]; then
        warn "Keenetic policy '$POLICY_DESC' not found yet - the glue will pick it up as soon as it exists"
    else
        info "policy '$POLICY_DESC' mark: 0x$MARK"
    fi
    info "applying the firewall glue"
    "$GLUE_INIT" start || warn "glue reported a problem - see $PREFIX/var/log/sui-tproxy-init.log"
fi

echo
info "verification"
for port in 2095 7787; do
    if port_listening "$port"; then echo "      tcp/$port : listening"; else echo "      tcp/$port : NOT listening"; fi
done
if ipset list sui_tproxy_bypass4 >/dev/null 2>&1; then
    echo "      ipset    : sui_tproxy_bypass4 present ($(ipset list sui_tproxy_bypass4 | grep -c '^[0-9]') entries)"
else
    echo "      ipset    : sui_tproxy_bypass4 missing"
fi
if iptables -t nat -S 2>/dev/null | grep -q sui_tproxy_nat; then
    echo "      nat rule : sui_tproxy_nat -> REDIRECT 7787 present"
else
    echo "      nat rule : absent"
fi
if iptables -t mangle -S 2>/dev/null | grep -q sui_tproxy_mangle; then
    echo "      udp rule : sui_tproxy_mangle -> TPROXY 7788 present"
else
    echo "      udp rule : absent"
fi
MARK=$(policy_mark)
if [ -n "$MARK" ]; then
    echo "      policy   : 0x$MARK ('$POLICY_DESC')"
else
    echo "      policy   : not found ('$POLICY_DESC')"
fi
if [ -f "$PREFIX/etc/s-ui/sui" ]; then
    echo "      binary   : $PREFIX/etc/s-ui/sui ($(ls -l "$PREFIX/etc/s-ui/sui" | awk '{print $1}'), $(wc -c <"$PREFIX/etc/s-ui/sui") bytes)"
else
    echo "      binary   : not installed ($PREFIX/etc/s-ui/sui)"
fi

rm -rf "$TMP"

cat <<EOF

Next steps:
  * Keenetic UI -> create a policy (Policy) with the description "$POLICY_DESC",
    put the client devices into it. Until it exists the panel still works
    normally, but nothing is proxied.
  * panel:  http://<router-lan-ip>:2095/app/   (login/password of s-ui)
  * If the panel is reachable but nothing is proxied, run:
      $GLUE_INIT status

Useful one-liners from a workstation:
  ssh root@<router> $PREFIX/sbin/sui-update --check        # version + update check
  ssh root@<router> $PREFIX/sbin/sui-update                # update the s-ui binary
  ssh root@<router> $GLUE_INIT status                      # glue/firewall state
EOF
