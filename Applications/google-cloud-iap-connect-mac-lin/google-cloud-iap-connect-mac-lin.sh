#!/bin/bash
:<<'WINDOWS_STUB'
@echo off
echo Google Cloud IAP Connect [Mac] [Lin] is not for Windows. Use "Google IAP Desktop [Win]".
exit /b 0
WINDOWS_STUB
# ============================================================================
#  Google Cloud IAP Connect [Mac] [Lin]
#  Datto RMM deployment component. Runs as root on macOS and Linux.
#
#  Installs the Google Cloud CLI system-wide and places a double-click launcher on
#  every user's desktop that opens an IAP TCP tunnel to one Compute Engine VM,
#  starts the Remote Desktop client against it, and closes the tunnel when the
#  RDP session ends. Nothing on the VM is touched and no user is signed in here:
#  each user signs in with their Google account the first time they run it.
#
#  Input variables (all arrive as strings):
#    gcpProject       required   GCP project id that owns the VM
#    vmInstance       required   Compute Engine instance name
#    vmZone           required   zone, e.g. us-central1-c
#    connectionLabel  optional   name shown to users (default: Cloud Server)
#    localPort        optional   local listener port (default: 13389)
#    gcloudVersion    optional   pin a gcloud release, e.g. 540.0.0 (default: latest)
#    macPythonVersion optional   python.org release installed on Macs with no Python 3.10+
#                                (default: 3.13.16; ignored on Linux)
#
#  Exit codes: 0 ok · 1 gcloud install failed · 2 launcher write failed
#              3 invalid input · 4 unsupported OS/arch or missing prerequisite
#  Source of truth: https://github.com/TechCollective/DattoRMM_Components
# ============================================================================
set -u

# ---------------------------------------------------------------- inputs ---
PROJECT="${gcpProject:-}"; INSTANCE="${vmInstance:-}"; ZONE="${vmZone:-}"
LABEL="${connectionLabel:-Cloud Server}"; PORT="${localPort:-13389}"; GCV="${gcloudVersion:-}"
MACPY="${macPythonVersion:-3.13.16}"
ok_id='^[a-z][-a-z0-9]{0,62}$'
[[ "$PROJECT" =~ $ok_id ]]  || { echo "ERROR: gcpProject '$PROJECT' is not a valid project id"; exit 3; }
[[ "$INSTANCE" =~ $ok_id ]] || { echo "ERROR: vmInstance '$INSTANCE' is not a valid instance name"; exit 3; }
ok_zone='^[a-z]+-[a-z]+[0-9]-[a-z]$'
[[ "$ZONE" =~ $ok_zone ]] || { echo "ERROR: vmZone '$ZONE' is not a zone like us-central1-c"; exit 3; }
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || { echo "ERROR: localPort must be 1024-65535"; exit 3; }
ok_label='^[A-Za-z0-9 ._-]{1,40}$'
[[ "$LABEL" =~ $ok_label ]] || { echo "ERROR: connectionLabel may only contain letters, digits, space . _ -"; exit 3; }
ok_ver='^[0-9]+\.[0-9]+\.[0-9]+$'
[ -z "$GCV" ] || [[ "$GCV" =~ $ok_ver ]] || { echo "ERROR: gcloudVersion must look like 540.0.0"; exit 3; }
[[ "$MACPY" =~ $ok_ver ]] || { echo "ERROR: macPythonVersion must look like 3.13.16"; exit 3; }

# ------------------------------------------------------------ platform -----
OS=$(uname -s); ARCH=$(uname -m)
case "$OS/$ARCH" in
    Darwin/arm64)          TARBALL_ARCH="darwin-arm" ;;
    Darwin/x86_64)         TARBALL_ARCH="darwin-x86_64" ;;
    Linux/x86_64)          TARBALL_ARCH="linux-x86_64" ;;
    Linux/aarch64|Linux/arm64) TARBALL_ARCH="linux-arm" ;;
    *) echo "ERROR: unsupported platform $OS/$ARCH"; exit 4 ;;
esac
if [ "$OS" = "Linux" ] && ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for the Google Cloud CLI on Linux and is not installed"; exit 4
fi

SDK_DIR="/opt/google-cloud-sdk"
SHARE_DIR="/usr/local/share/iap-connect"
LAUNCHER="$SHARE_DIR/iap-connect.sh"

# ------------------------------------------------- macOS Python bootstrap --
# Google's install.sh is a wrapper that needs an existing Python 3.10+ to run install.py; the
# --install-python option lives inside install.py and cannot bootstrap. macOS ships no Python,
# only an Xcode stub at /usr/bin/python3 that pops Apple's installer dialog when called, so that
# path is never tried. If no real Python is present, install the official python.org package
# (signed by the Python Software Foundation) silently and use it. Verified 2026-10-06.
mac_find_python() {
    local p v
    for p in /opt/google-cloud-sdk/platform/bundledpythonunix/bin/python3 \
             /Library/Frameworks/Python.framework/Versions/3.*/bin/python3 \
             /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        [ -x "$p" ] || continue
        case "$p" in /usr/bin/*) continue ;; esac
        v=$("$p" -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null) || continue
        [ "${v:-0}" -ge 310 ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
mac_install_python() {
    local url tmp pkg
    url="https://www.python.org/ftp/python/${MACPY}/python-${MACPY}-macos11.pkg"
    tmp=$(mktemp -d) || return 1
    pkg="$tmp/python.pkg"
    echo "No Python 3.10+ found; installing Python ${MACPY} from python.org"
    curl -fsSL --retry 3 -o "$pkg" "$url" || { echo "ERROR: Python download failed ($url)"; rm -rf "$tmp"; return 1; }
    if ! pkgutil --check-signature "$pkg" 2>/dev/null | grep -q "Python Software Foundation"; then
        echo "ERROR: Python package is not signed by the Python Software Foundation; refusing to install"
        rm -rf "$tmp"; return 1
    fi
    installer -pkg "$pkg" -target / >"$tmp/installer.log" 2>&1 || { echo "ERROR: Python installer failed:"; tail -n 10 "$tmp/installer.log"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}
BOOT_PY=""
if [ "$OS" = "Darwin" ]; then
    BOOT_PY=$(mac_find_python) || { mac_install_python || exit 1; BOOT_PY=$(mac_find_python) || { echo "ERROR: Python installed but not found"; exit 1; }; }
    echo "Using Python at $BOOT_PY for the Google Cloud CLI installer"
fi

# -------------------------------------------------------- gcloud install ---
install_gcloud() {
    if [ -z "$GCV" ]; then
        url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${TARBALL_ARCH}.tar.gz"
    else
        url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCV}-${TARBALL_ARCH}.tar.gz"
    fi
    tmp=$(mktemp -d) || return 1
    echo "Downloading Google Cloud CLI: $url"
    curl -fsSL --retry 3 -o "$tmp/gcloud.tgz" "$url" || { echo "ERROR: download failed"; rm -rf "$tmp"; return 1; }
    rm -rf "$SDK_DIR.new" && mkdir -p "$SDK_DIR.new" || return 1
    tar -xzf "$tmp/gcloud.tgz" -C "$SDK_DIR.new" --strip-components=1 || { echo "ERROR: extract failed"; rm -rf "$tmp" "$SDK_DIR.new"; return 1; }
    rm -rf "$tmp"
    # Datto's agent may not set HOME, and install.sh writes under it.
    export HOME="${HOME:-/var/root}"
    export CLOUDSDK_CORE_DISABLE_PROMPTS=1
    # Run the installer with a Python we chose, never the system stub. On macOS that is the
    # bootstrap Python found or installed above; the tarball's own bundled copy wins if present.
    bp="$SDK_DIR.new/platform/bundledpythonunix/bin/python3"
    if [ -x "$bp" ]; then export CLOUDSDK_PYTHON="$bp"
    elif [ -n "$BOOT_PY" ]; then export CLOUDSDK_PYTHON="$BOOT_PY"; fi
    log="$SDK_DIR.new/install.log"
    if ! "$SDK_DIR.new/install.sh" --quiet --usage-reporting=false --path-update=false --bash-completion=false > "$log" 2>&1; then
        echo "ERROR: gcloud install.sh failed. Last 15 lines of its output:"; tail -n 15 "$log"
        mkdir -p /var/log/techcollective && cp "$log" /var/log/techcollective/gcloud-install.log 2>/dev/null
        rm -rf "$SDK_DIR.new"; return 1
    fi
    rm -rf "$SDK_DIR" && mv "$SDK_DIR.new" "$SDK_DIR" || return 1
    chmod -R a+rX "$SDK_DIR"
    ln -sf "$SDK_DIR/bin/gcloud" /usr/local/bin/gcloud 2>/dev/null || true
}

# `gcloud version` has no "version" field to format, so read the first line
# instead: "Google Cloud SDK 540.0.0" (found by the Tier 1 test).
gcloud_version() { "$SDK_DIR/bin/gcloud" version 2>/dev/null | awk '/^Google Cloud SDK /{print $4; exit}'; }
have_ver=""
[ -x "$SDK_DIR/bin/gcloud" ] && have_ver=$(gcloud_version || true)
if [ -n "$have_ver" ] && { [ -z "$GCV" ] || [ "$have_ver" = "$GCV" ]; }; then
    echo "Google Cloud CLI $have_ver already installed at $SDK_DIR"
else
    install_gcloud || exit 1
    echo "Google Cloud CLI $(gcloud_version) installed at $SDK_DIR"
fi

# ---------------------------------------------------------- launcher -------
mkdir -p "$SHARE_DIR" || { echo "ERROR: cannot create $SHARE_DIR"; exit 2; }
cat > "$LAUNCHER" <<'LAUNCHER_EOF' || { echo "ERROR: cannot write launcher"; exit 2; }
#!/bin/bash
# iap-connect.sh - opens a Google Cloud IAP tunnel to one VM, launches Remote Desktop, and
# closes the tunnel when the session ends. Installed by TechCollective via Datto RMM.
# Runs as the signed-in user. No admin rights needed.
PROJECT="__PROJECT__"; INSTANCE="__INSTANCE__"; ZONE="__ZONE__"; LOCAL_PORT=__PORT__; LABEL="__LABEL__"
set -u
OS=$(uname -s)
CFG="$HOME/.config/iap-connect"; LOG="$CFG/iap-connect.log"; mkdir -p "$CFG"
say_() { printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
pause_exit() { read -r -p "Press Return to close." _; exit "${1:-1}"; }

GCLOUD=""
for c in /opt/google-cloud-sdk/bin/gcloud "$(command -v gcloud 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && GCLOUD="$c" && break
done
[ -n "$GCLOUD" ] || { say_ "Google Cloud CLI is not installed. Please contact support."; pause_exit 1; }
if [ "$OS" = "Darwin" ]; then
    # Point gcloud at a real Python so it never falls through to the Xcode stub at /usr/bin/python3.
    for p in /opt/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /Library/Frameworks/Python.framework/Versions/3.*/bin/python3; do
        [ -x "$p" ] && { export CLOUDSDK_PYTHON="$p"; break; }
    done
fi

if [ "$OS" = "Darwin" ]; then
    listening() { lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; }
    established() { lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:ESTABLISHED 2>/dev/null | grep -qv '^COMMAND'; }
    [ -d "/Applications/Windows App.app" ] || { say_ "Microsoft Windows App is not installed. Install it from the App Store, then run this again."; pause_exit 1; }
else
    listening() { ss -Hltn "sport = :$LOCAL_PORT" 2>/dev/null | grep -q .; }
    established() { ss -Htn state established "( sport = :$LOCAL_PORT or dport = :$LOCAL_PORT )" 2>/dev/null | grep -q .; }
    if command -v xfreerdp3 >/dev/null 2>&1; then RDP=xfreerdp3
    elif command -v xfreerdp >/dev/null 2>&1; then RDP=xfreerdp
    elif command -v remmina >/dev/null 2>&1; then RDP=remmina
    else say_ "No Remote Desktop client found. Install freerdp (xfreerdp) or remmina, then run this again."; pause_exit 1; fi
fi

if ! "$GCLOUD" auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
    say_ "First-time setup: a browser window will open. Sign in with your work Google account."
    "$GCLOUD" auth login --brief || { say_ "Sign-in did not complete."; pause_exit 1; }
fi

TUNNEL_PID=""
if listening; then
    say_ "Tunnel already running; reusing it."
else
    say_ "Opening secure tunnel to $LABEL ..."
    "$GCLOUD" compute start-iap-tunnel "$INSTANCE" 3389 --project="$PROJECT" --zone="$ZONE" \
        --local-host-port="localhost:$LOCAL_PORT" >> "$LOG" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 40); do
        listening && break
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            say_ "The tunnel could not be opened. Last lines of the log:"; tail -n 5 "$LOG"; pause_exit 1
        fi
        sleep 0.5
    done
    listening || { say_ "The tunnel did not start in time."; kill "$TUNNEL_PID" 2>/dev/null; pause_exit 1; }
fi
cleanup() { if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then kill "$TUNNEL_PID" 2>/dev/null; say_ "Tunnel closed."; fi; }
trap cleanup EXIT INT TERM

say_ "Opening Remote Desktop. Close the remote desktop window when you are done; this window closes by itself."
if [ "$OS" = "Darwin" ]; then
    RDP_FILE="$CFG/$LABEL.rdp"
    printf 'full address:s:localhost:%s\nprompt for credentials:i:1\nscreen mode id:i:2\nuse multimon:i:0\naudiomode:i:0\nredirectclipboard:i:1\nauthentication level:i:0\n' "$LOCAL_PORT" > "$RDP_FILE"
    open "$RDP_FILE"
else
    case "$RDP" in
        remmina)
            RDP_FILE="$CFG/$LABEL.remmina"
            printf '[remmina]\nname=%s\nprotocol=RDP\nserver=localhost:%s\nscale=1\nresolution_mode=2\n' "$LABEL" "$LOCAL_PORT" > "$RDP_FILE"
            remmina -c "$RDP_FILE" >/dev/null 2>&1 & ;;
        *)  "$RDP" /v:localhost:"$LOCAL_PORT" /dynamic-resolution /cert:tofu +clipboard >/dev/null 2>&1 & ;;
    esac
fi

for _ in $(seq 1 180); do established && break; sleep 0.5; done
established || { say_ "No remote desktop session was started. Closing."; exit 0; }
say_ "Connected."
idle=0
while [ "$idle" -lt 5 ]; do sleep 1; if established; then idle=0; else idle=$((idle+1)); fi; done
say_ "Remote desktop session ended."
exit 0
LAUNCHER_EOF
# Fill in the client values (sed delimiter | is excluded from every validated input above).
sed -i.bak -e "s|__PROJECT__|$PROJECT|" -e "s|__INSTANCE__|$INSTANCE|" -e "s|__ZONE__|$ZONE|" \
    -e "s|__PORT__|$PORT|" -e "s|__LABEL__|$LABEL|" "$LAUNCHER" && rm -f "$LAUNCHER.bak"
chmod 755 "$LAUNCHER"

# ------------------------------------------- per-user desktop shortcut -----
placed=0
if [ "$OS" = "Darwin" ]; then
    for home in /Users/*; do
        user=$(basename "$home"); [ -d "$home/Desktop" ] || continue
        uid=$(id -u "$user" 2>/dev/null || echo 0); [ "$uid" -ge 500 ] || continue
        f="$home/Desktop/Connect to $LABEL.command"
        printf '#!/bin/bash\nexec "%s"\n' "$LAUNCHER" > "$f" && chmod 755 "$f" && chown "$user" "$f" \
            && xattr -d com.apple.quarantine "$f" 2>/dev/null; placed=$((placed+1))
    done
else
    for home in /home/*; do
        user=$(basename "$home"); id "$user" >/dev/null 2>&1 || continue
        desk="$home/Desktop"; [ -d "$desk" ] || continue
        f="$desk/connect-to-$(printf '%s' "$LABEL" | tr ' ' '-' | tr '[:upper:]' '[:lower:]').desktop"
        printf '[Desktop Entry]\nType=Application\nName=Connect to %s\nComment=Remote desktop via Google Cloud IAP\nExec=%s\nTerminal=true\nIcon=network-server\nCategories=Network;RemoteAccess;\n' "$LABEL" "$LAUNCHER" > "$f" \
            && chmod 755 "$f" && chown "$user" "$f" && placed=$((placed+1))
        # GNOME marks new .desktop files untrusted until the user allows launching; mark it trusted where gio exists.
        command -v gio >/dev/null 2>&1 && sudo -u "$user" gio set "$f" metadata::trusted true 2>/dev/null || true
    done
fi

echo "Google Cloud IAP Connect deployed: launcher at $LAUNCHER, shortcut placed for $placed user(s), target $INSTANCE ($ZONE) as '$LABEL' on localhost:$PORT."
exit 0
