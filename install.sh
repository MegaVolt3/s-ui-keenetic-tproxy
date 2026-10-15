#!/bin/sh
# install.sh -- install / uninstall the s-ui-keenetic-tproxy glue on a
# Keenetic / Netcraze router running Entware.
#
# Run ON THE ROUTER, as root, from the unpacked repository directory:
#     ./install.sh                 # install files (no firewall changes yet)
#     ./install.sh --start         # install and apply the firewall rules now
#     ./install.sh --with-public-ip
#     ./install.sh uninstall
#     ./install.sh status
#
# Destination prefix defaults to /opt. A different prefix implies a test run:
# the root check and the Entware check are skipped, so the layout can be
# rehearsed anywhere (PREFIX=/tmp/fake-opt ./install.sh).

PREFIX="${PREFIX:-/opt}"
DIR=$(cd "$(dirname "$0")" && pwd)
TEST_MODE=0
[ "$PREFIX" != "/opt" ] && TEST_MODE=1

ACTION=install
DO_START=0
WITH_PUBLIC_IP=0
PURGE=0

BIN="$PREFIX/sbin/sui-tproxy"
UPDATE="$PREFIX/sbin/sui-update"
CONF_DIR="$PREFIX/etc/sui-tproxy"
CONF="$CONF_DIR/sui-tproxy.conf"
INIT="$PREFIX/etc/init.d/S99sui-tproxy"
PANEL_INIT="$PREFIX/etc/init.d/S90s-ui"
HOOK_DIR="$PREFIX/etc/ndm/netfilter.d"
HOOK="$HOOK_DIR/sui-tproxy.sh"
PUBIP_HOOK="$HOOK_DIR/zz-public-ip-local.sh"
BACKUP_DIR="$CONF_DIR/backup"

usage() {
    cat <<EOF
Usage: $0 [install|uninstall|status] [options]

  install              copy scripts in place (default); existing config kept
  uninstall            stop the glue and remove scripts (configs are kept)
  status               show what is installed and what the firewall looks like

Options:
  --start              run "sui-tproxy start" right after install
  --with-public-ip     also install examples/zz-public-ip-local.sh
  --purge              with uninstall: remove configs and backups too
  -h, --help           this text

Environment:
  PREFIX=/opt           destination prefix (a non-/opt value implies a dry run)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[ + ] $*"; }
warn() { echo "[ ! ] $*" >&2; }

backup_existing() {
    # Note: no "local" here on purpose (plain POSIX sh) - use unique names,
    # otherwise this clobbers put()'s own variables.
    bs_path="$1"
    [ -f "$bs_path" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
    bs_stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
    cp -f "$bs_path" "$BACKUP_DIR/$(basename "$bs_path").$bs_stamp" 2>/dev/null || true
}

put() {
    src="$1"; dst="$2"; mode="$3"
    [ -f "$DIR/$src" ] || die "missing source file: $src"
    mkdir -p "$(dirname "$dst")"
    backup_existing "$dst"
    cp -f "$DIR/$src" "$dst" || die "failed to copy $src -> $dst"
    chmod "$mode" "$dst" || die "failed to chmod $dst"
    info "installed $dst (mode $mode)"
}

check_environment() {
    [ "$TEST_MODE" = 1 ] && { info "PREFIX=$PREFIX: test mode, skipping root/Entware checks"; return 0; }
    [ "$(id -u)" = "0" ] || die "run this installer as root on the router"
    [ -d "$PREFIX/etc/init.d" ] || die "Entware not found at $PREFIX (install Entware first)"
    for c in iptables ipset awk; do
        command -v "$c" >/dev/null 2>&1 || warn "command not found: $c  (opkg install ipset iptables iproute2)"
    done
    command -v ndmc >/dev/null 2>&1 || warn "command not found: ndmc (required to read the policy mark at runtime)"
}

do_install() {
    check_environment
    mkdir -p "$CONF_DIR" "$HOOK_DIR" "$PREFIX/var/log"

    put "sbin/sui-tproxy" "$BIN" 755
    put "sbin/sui-update" "$UPDATE" 755
    put "etc/init.d/S99sui-tproxy" "$INIT" 755

    # The panel's own init script: never overwrite one that is already there
    # (for example the one shipped by the s-ui-keenetic wrapper s-ui.sh).
    if [ -e "$PANEL_INIT" ]; then
        info "keeping existing $PANEL_INIT (panel init script)"
    else
        put "etc/init.d/S90s-ui" "$PANEL_INIT" 755
    fi

    if [ -f "$CONF" ]; then
        info "keeping existing config $CONF"
    else
        put "etc/sui-tproxy/sui-tproxy.conf.example" "$CONF" 644
        info "edit $CONF before/after starting: policy description, ports, bypass nets"
    fi

    if [ "$WITH_PUBLIC_IP" = 1 ]; then
        put "examples/zz-public-ip-local.sh" "$PUBIP_HOOK" 755
        if [ ! -f "$CONF_DIR/zz-public-ip-local.conf" ]; then
            cp -f "$DIR/examples/zz-public-ip-local.conf.example" "$CONF_DIR/zz-public-ip-local.conf" 2>/dev/null \
                && info "installed $CONF_DIR/zz-public-ip-local.conf (set PUBLIC_IP there)"
        else
            info "keeping existing config $CONF_DIR/zz-public-ip-local.conf"
        fi
    fi

    echo
    info "files installed. Next steps:"
    echo "      1. install or update the s-ui binary itself:"
    echo "           $UPDATE --check      # report version / update availability"
    echo "           $UPDATE              # install the latest release"
    echo "      2. create/choose a Keenetic policy and set its description to"
    echo "         POLICY_DESCRIPTION from $CONF (default: SUI-TProxy),"
    echo "         then put the client devices into that policy;"
    echo "      3. make sure the s-ui panel listens on the redirect/tproxy ports;"
    echo "      4. apply the firewall glue:  $PREFIX/etc/init.d/S99sui-tproxy start"
    echo "      5. check:                    $PREFIX/etc/init.d/S99sui-tproxy status"

    if [ "$DO_START" = 1 ]; then
        [ "$TEST_MODE" = 1 ] && { warn "--start ignored in test mode"; return 0; }
        echo
        info "applying firewall rules"
        "$BIN" start || warn "sui-tproxy start reported a problem - see $PREFIX/var/log/sui-tproxy-*.log"
    fi
}

do_uninstall() {
    [ "$TEST_MODE" = 1 ] || [ "$(id -u)" = "0" ] || die "run this installer as root on the router"
    if [ -x "$BIN" ]; then
        "$BIN" stop >/dev/null 2>&1 || warn "sui-tproxy stop reported a problem"
    fi
    for f in "$BIN" "$UPDATE" "$INIT" "$HOOK" "$PUBIP_HOOK"; do
        if [ -e "$f" ]; then rm -f "$f" && info "removed $f"; fi
    done
    if [ -e "$PANEL_INIT" ]; then
        if grep -q "Minimal Entware init script" "$PANEL_INIT" 2>/dev/null; then
            rm -f "$PANEL_INIT" && info "removed $PANEL_INIT"
        else
            info "keeping $PANEL_INIT (not installed by this project)"
        fi
    fi
    if [ "$PURGE" = 1 ]; then
        rm -rf "$CONF_DIR" && info "removed $CONF_DIR"
    else
        info "configs kept in $CONF_DIR (use --purge to remove them as well)"
    fi
}

do_status() {
    echo "prefix: $PREFIX"
    for f in "$BIN" "$UPDATE" "$INIT" "$CONF" "$PANEL_INIT" "$HOOK" "$PUBIP_HOOK"; do
        if [ -e "$f" ]; then echo "present: $f"; else echo "absent : $f"; fi
    done
    echo
    if [ -x "$BIN" ]; then
        "$BIN" status
    else
        echo "sui-tproxy is not installed at $BIN"
    fi
}

[ $# -gt 0 ] && case "$1" in
    install|uninstall|status) ACTION="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --start) DO_START=1 ;;
        --with-public-ip) WITH_PUBLIC_IP=1 ;;
        --purge) PURGE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
    *) usage; exit 2 ;;
esac
