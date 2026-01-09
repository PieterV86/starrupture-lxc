#!/usr/bin/env bash
# -------------------------------------------------------------
# Proxmox VE Helper Script (Community-Scripts style, v2)
# StarRupture Dedicated Server (APPID 3809400)
# Debian 12 LXC + Wine + Xvfb + SteamCMD + systemd
# Persistent mounts: /srv/starrupture/server + /srv/starrupture/savegame
# Optional Advanced Settings + Repair Mode
# -------------------------------------------------------------
set -euo pipefail

# -----------------------------
# UI Helpers (tteck-style)
# -----------------------------
YW='\033[33m'  # yellow
BL='\033[36m'  # blue
GN='\033[32m'  # green
RD='\033[31m'  # red
CL='\033[0m'   # clear
BOLD='\033[1m'
DIM='\033[2m'

function header_info() {
  clear
  echo -e "${BOLD}${BL}"
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │               StarRupture Dedicated Server                │"
  echo "  │            Debian 12 LXC + Wine + SteamCMD                │"
  echo "  │                 Proxmox Community Script                  │"
  echo "  └──────────────────────────────────────────────────────────┘"
  echo -e "${CL}"
}

function msg_info()    { echo -e "${BL}[INFO]${CL} $*"; }
function msg_ok()      { echo -e "${GN}[OK]${CL}   $*"; }
function msg_warn()    { echo -e "${YW}[WARN]${CL} $*"; }
function msg_error()   { echo -e "${RD}[ERR]${CL}  $*"; }
function die()         { msg_error "$*"; exit 1; }

function check_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this script as root."
}

function check_pve() {
  command -v pveversion >/dev/null 2>&1 || die "Not a Proxmox VE host."
  pveversion | grep -q "pve-manager" || die "Not a Proxmox VE host."
}

function need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

function ask() {
  local prompt="$1"
  local default="$2"
  local var
  read -rp "$prompt [$default]: " var || true
  echo "${var:-$default}"
}

function ask_yn() {
  local prompt="$1"
  local default="$2" # y or n
  local var
  local d
  d="$default"
  [[ "$d" == "y" ]] && prompt="$prompt (Y/n)" || prompt="$prompt (y/N)"
  read -rp "$prompt: " var || true
  var="${var:-$d}"
  [[ "${var,,}" == "y" ]] && echo "y" || echo "n"
}

function section() {
  echo -e "\n${BOLD}${BL}▶ $*${CL}"
}

function indent() { sed 's/^/    /'; }

function countdown() {
  local sec=${1:-2}
  while [ "$sec" -gt 0 ]; do
    echo -ne "${DIM}Starting in ${sec}s...${CL}\r"
    sleep 1
    sec=$((sec-1))
  done
  echo ""
}

# -----------------------------
# Defaults
# -----------------------------
APP="StarRupture Dedicated Server"
CT_NAME="starrupture"
STEAMAPPID="3809400"
TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR==2 {print $1}' | tr -d '\r' | xargs)"
TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n 1 | tr -d '\r' | xargs)"
OSTEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"


CORES_DEFAULT="2"
MEMORY_DEFAULT="4096"
DISK_DEFAULT="16"

# Host storage paths
HOST_BASE="/srv/starrupture"
HOST_SERVER="${HOST_BASE}/server"
HOST_SAVE="${HOST_BASE}/savegame"

# Container paths
CT_SERVER="/share/starrupture/server"
CT_SAVE="/share/starrupture/savegame"

# Server settings
SERVER_IP_DEFAULT="192.168.1.208"
SERVER_PORT_DEFAULT="7777"

# Optional extra ports (not firewall-related here)
QUERY_PORT_DEFAULT="27015"
BEACON_PORT_DEFAULT="7778"

# systemd behavior
RESTART_SEC_DEFAULT="10"

# -----------------------------
# Auto-detect Storage / Bridge
# -----------------------------
function detect_storage() {
  local s
  s="$(pvesm status -content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
  echo "${s:-local-lvm}"
}

function list_storages() {
  pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print " - " $1 " (" $2 ")"}'
}

function detect_bridge() {
  local b
  b="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vmbr[0-9]+' | head -n1 || true)"
  echo "${b:-vmbr0}"
}

function list_bridges() {
  ip -o link show | awk -F': ' '{print $2}' | grep -E '^vmbr[0-9]+' || true
}


function ensure_template() {
  section "Template"
  msg_info "Ensuring Debian 12 template exists..."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  pveam update >/dev/null
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi
  msg_ok "Template ready."
}

# -----------------------------
# CT Create / Repair
# -----------------------------
function create_container() {
  local ctid="$1"
  local name="$2"
  local storage="$3"
  local bridge="$4"
  local cores="$5"
  local mem="$6"
  local disk="$7"
  local ip_cidr="$8"
  local gw="$9"
  local unpriv="${10}"

  section "Create Container"
  msg_info "Creating LXC ${ctid} (${name})..."

  local net0="name=eth0,bridge=${bridge},ip=${ip_cidr},gw=${gw}"
  local pass
  pass="$(openssl rand -base64 18)"

  pct create "$ctid" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$name" \
    --cores "$cores" \
    --memory "$mem" \
    --swap 0 \
    --rootfs "${storage}:${disk}" \
    --net0 "$net0" \
    --onboot 1 \
    --unprivileged "$unpriv" \
    --features "nesting=1" \
    --password "$pass" \
    >/dev/null

  msg_ok "Container created."
  msg_info "A random root password was set. Use console or set your own if needed."
}

function add_mounts() {
  local ctid="$1"

  section "Storage Mounts"
  msg_info "Creating persistent host directories..."
  mkdir -p "$HOST_SERVER" "$HOST_SAVE"
  msg_ok "Host dirs ensured:"
  echo "  $HOST_SERVER"
  echo "  $HOST_SAVE"

  msg_info "Adding mountpoints to container..."
  pct set "$ctid" -mp0 "${HOST_SERVER},mp=${CT_SERVER}"
  pct set "$ctid" -mp1 "${HOST_SAVE},mp=${CT_SAVE}"
  msg_ok "Mountpoints added."
}

function start_ct() {
  local ctid="$1"
  section "Start Container"
  msg_info "Starting container..."
  pct start "$ctid" >/dev/null || true
  sleep 3
  msg_ok "Container is running."
}

# -----------------------------
# Provision inside container
# -----------------------------
function pct_exec() {
  local ctid="$1"
  shift
  pct exec "$ctid" -- bash -lc "$*"
}

function provision_container() {
  local ctid="$1"
  local server_ip="$2"
  local server_port="$3"
  local query_port="$4"
  local beacon_port="$5"
  local add_ports="$6"         # y/n
  local update_on_start="$7"   # true/false
  local restart_sec="$8"

  section "Provision Container"
  msg_info "Installing packages (Wine/Xvfb/SteamCMD deps)..."
  pct_exec "$ctid" "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl tar bash \
      xvfb xauth x11-xserver-utils \
      wine wine32 wine64 \
      lib32gcc-s1 lib32stdc++6 \
      tmux
    rm -rf /var/lib/apt/lists/*
  "
  msg_ok "Packages installed."

  msg_info "Installing SteamCMD to /opt/steamcmd..."
  pct_exec "$ctid" "
    set -e
    mkdir -p /opt/steamcmd
    curl -4 -fL --retry 8 --retry-delay 2 --connect-timeout 15 \
      https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      -o /tmp/steamcmd.tgz
    tar -xzf /tmp/steamcmd.tgz -C /opt/steamcmd
    rm -f /tmp/steamcmd.tgz
    chmod +x /opt/steamcmd/steamcmd.sh
    /opt/steamcmd/steamcmd.sh +quit || true
  "
  msg_ok "SteamCMD installed."

  msg_info "Writing /start.sh and systemd unit..."
  pct_exec "$ctid" "
    cat > /start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STEAMAPPID=${STEAMAPPID}
SERVER_PORT=${server_port}
SERVER_IP='${server_ip}'

UPDATE_ON_START=\"\${UPDATE_ON_START:-${update_on_start}}\"

STEAMCMD=\"/opt/steamcmd/steamcmd.sh\"
SERVER_DIR=\"${CT_SERVER}\"
SAVE_DIR=\"${CT_SAVE}\"

export WINEPREFIX=\"/opt/wineprefix\"

mkdir -p \"\$SERVER_DIR\" \"\$SAVE_DIR\" \"\$WINEPREFIX\"

steam_update_with_retry() {
  local tries=6
  local n=1

  while [ \"\$n\" -le \"\$tries\" ]; do
    echo \"[SteamCMD] Update attempt \$n/\$tries\"

    rm -rf \"\$SERVER_DIR/steamapps/downloading\" \\
           \"\$SERVER_DIR/steamapps/temp\" 2>/dev/null || true

    set +e
    \"\$STEAMCMD\" \\
      +@ShutdownOnFailedCommand 1 \\
      +@NoPromptForPassword 1 \\
      +@sSteamCmdForcePlatformType windows \\
      +force_install_dir \"\$SERVER_DIR\" \\
      +login anonymous \\
      +app_update \"\$STEAMAPPID\" validate \\
      +quit
    rc=\$?
    set -e

    if [ \"\$rc\" -eq 0 ]; then
      echo \"[SteamCMD] Update OK\"
      return 0
    fi

    echo \"[SteamCMD] Failed (rc=\$rc) – retry in \$((n*5))s\"
    sleep \$((n*5))
    n=\$((n+1))
  done

  echo \"[SteamCMD] Update FAILED\"
  exit 1
}

if [ \"\$UPDATE_ON_START\" = \"true\" ]; then
  steam_update_with_retry
else
  echo \"[SteamCMD] Skipping update\"
fi

# Savegames externalize
mkdir -p \"\$SERVER_DIR/StarRupture/Saved\"
rm -rf \"\$SERVER_DIR/StarRupture/Saved/SaveGames\"
ln -s \"\$SAVE_DIR\" \"\$SERVER_DIR/StarRupture/Saved/SaveGames\"

EXE=\"\$SERVER_DIR/StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe\"
if [ ! -f \"\$EXE\" ]; then
  echo \"[ERROR] EXE not found at \$EXE\"
  find \"\$SERVER_DIR\" -maxdepth 6 -type f -iname \"StarRuptureServerEOS*.exe\" | head -n 20
  exit 1
fi

# Optional port args (some games use query/beacon ports)
EXTRA_ARGS=()
EOF
  "

  if [[ "$add_ports" == "y" ]]; then
    pct_exec "$ctid" "
      cat >> /start.sh <<'EOF'
EXTRA_ARGS+=(\"-QueryPort=${query_port}\")
EXTRA_ARGS+=(\"-BeaconPort=${beacon_port}\")
EOF
    "
  fi

  pct_exec "$ctid" "
    cat >> /start.sh <<'EOF'

echo \"[StarRupture] STARTING SERVER VIA WINE\"
exec xvfb-run --auto-servernum \
  wine \"\$EXE\" -Log -port=\"\$SERVER_PORT\" -multihome=\"\$SERVER_IP\" \"\${EXTRA_ARGS[@]}\"
EOF

chmod +x /start.sh

cat > /etc/systemd/system/starrupture.service <<'EOF'
[Unit]
Description=StarRupture Dedicated Server (Wine + SteamCMD)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=UPDATE_ON_START=${update_on_start}
ExecStart=/start.sh
Restart=always
RestartSec=${restart_sec}
KillSignal=SIGINT
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now starrupture
  "
  msg_ok "Service installed and started."
}

function post_info() {
  local ctid="$1"
  local server_ip="$2"
  local server_port="$3"
  local add_ports="$4"
  local query_port="$5"
  local beacon_port="$6"

  section "Complete"
  echo -e "${BOLD}${GN}✅ Installation Complete!${CL}\n"
  echo -e "${BOLD}Container:${CL} ${ctid} (${CT_NAME})"
  echo -e "${BOLD}Server:${CL}    ${server_ip}:${server_port}"
  if [[ "$add_ports" == "y" ]]; then
    echo -e "${BOLD}Extra:${CL}     QueryPort=${query_port}, BeaconPort=${beacon_port}"
  fi
  echo -e "${BOLD}AppID:${CL}     ${STEAMAPPID}"
  echo -e "${BOLD}Mounts:${CL}"
  echo -e "  ${HOST_SERVER} → ${CT_SERVER}"
  echo -e "  ${HOST_SAVE}   → ${CT_SAVE}\n"

  echo -e "${BOLD}Logs:${CL}"
  echo -e "  pct exec ${ctid} -- journalctl -u starrupture -f\n"

  echo -e "${BOLD}Service Control:${CL}"
  echo -e "  pct exec ${ctid} -- systemctl restart starrupture"
  echo -e "  pct exec ${ctid} -- systemctl stop starrupture"
  echo -e "  pct exec ${ctid} -- systemctl start starrupture\n"

  echo -e "${DIM}Note: This script does not modify Proxmox firewall rules (as requested).${CL}"
}

# -----------------------------
# Main Menu / Flow
# -----------------------------
header_info
check_root
check_pve
need_cmd pct
need_cmd pvesm
need_cmd pveam
need_cmd openssl
need_cmd ip

section "Mode"
echo "1) Create new StarRupture LXC"
echo "2) Repair/Reinstall inside existing CT (keeps CT + mounts)"
echo ""
MODE="$(ask "Select" "1")"
[[ "$MODE" == "1" || "$MODE" == "2" ]] || die "Invalid selection."

# Advanced settings?
section "Settings"
ADV="$(ask_yn "Enable Advanced Settings" "n")"

# Detect defaults
STORAGE_DEFAULT="$(detect_storage)"
BRIDGE_DEFAULT="$(detect_bridge)"

if [[ "$MODE" == "1" ]]; then
  CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  CTID="${CTID:-100}"
  CTID="$(ask "CTID" "$CTID")"
  CT_NAME="$(ask "Container Name" "$CT_NAME")"

  msg_info "Available storages:"
  list_storages | indent || true
  STORAGE="$(ask "Storage" "$STORAGE_DEFAULT")"

  msg_info "Detected bridges:"
  list_bridges | indent || true
  BRIDGE="$(ask "Bridge" "$BRIDGE_DEFAULT")"

  CORES="$CORES_DEFAULT"
  MEMORY="$MEMORY_DEFAULT"
  DISK="$DISK_DEFAULT"
  UNPRIV="1"

  if [[ "$ADV" == "y" ]]; then
    CORES="$(ask "Cores" "$CORES_DEFAULT")"
    MEMORY="$(ask "RAM (MB)" "$MEMORY_DEFAULT")"
    DISK="$(ask "Disk Size (GB)" "$DISK_DEFAULT")"
    UNPRIV="$(ask "Unprivileged (1=yes,0=no)" "1")"
    [[ "$UNPRIV" == "0" || "$UNPRIV" == "1" ]] || die "Unprivileged must be 0 or 1"
  fi

  # Static IP required
  SERVER_IP="$(ask "Server bind IP (multihome)" "$SERVER_IP_DEFAULT")"
  IP_CIDR="$(ask "Static IP CIDR (e.g. 192.168.1.208/24)" "${SERVER_IP}/24")"
  GW="$(ask "Gateway (e.g. 192.168.1.1)" "192.168.1.1")"

else
  # Repair mode
  CTID="$(ask "Existing CTID to repair" "100")"
  pct status "$CTID" >/dev/null 2>&1 || die "CTID $CTID not found."
  SERVER_IP="$(ask "Server bind IP (multihome)" "$SERVER_IP_DEFAULT")"
fi

SERVER_PORT="$(ask "Server Port" "$SERVER_PORT_DEFAULT")"

ADD_PORTS="n"
QUERY_PORT="$QUERY_PORT_DEFAULT"
BEACON_PORT="$BEACON_PORT_DEFAULT"

if [[ "$ADV" == "y" ]]; then
  ADD_PORTS="$(ask_yn "Add optional Query/Beacon ports as launch args" "n")"
  if [[ "$ADD_PORTS" == "y" ]]; then
    QUERY_PORT="$(ask "QueryPort" "$QUERY_PORT_DEFAULT")"
    BEACON_PORT="$(ask "BeaconPort" "$BEACON_PORT_DEFAULT")"
  fi
fi

UPDATE_ON_START="true"
RESTART_SEC="$RESTART_SEC_DEFAULT"

if [[ "$ADV" == "y" ]]; then
  UPDATE_ON_START="$(ask "UPDATE_ON_START (true/false)" "true")"
  RESTART_SEC="$(ask "systemd RestartSec (seconds)" "$RESTART_SEC_DEFAULT")"
fi

# Summary
section "Summary"
echo "  Mode:        $([[ "$MODE" == "1" ]] && echo "Create" || echo "Repair")"
echo "  CTID:        $CTID"
echo "  Name:        $CT_NAME"
echo "  Storage:     ${STORAGE_DEFAULT} (default)  | chosen: ${STORAGE:-n/a}"
echo "  Bridge:      ${BRIDGE_DEFAULT} (default)   | chosen: ${BRIDGE:-n/a}"
echo "  Server bind: $SERVER_IP"
echo "  Server port: $SERVER_PORT"
if [[ "$ADV" == "y" && "$ADD_PORTS" == "y" ]]; then
  echo "  Query/Beacon: QueryPort=$QUERY_PORT, BeaconPort=$BEACON_PORT"
fi
echo "  Host mounts: $HOST_SERVER , $HOST_SAVE"
echo ""

PROCEED="$(ask_yn "Proceed" "y")"
[[ "$PROCEED" == "y" ]] || die "Aborted."

countdown 2

ensure_template

if [[ "$MODE" == "1" ]]; then
  create_container "$CTID" "$CT_NAME" "$STORAGE" "$BRIDGE" "$CORES" "$MEMORY" "$DISK" "$IP_CIDR" "$GW" "$UNPRIV"
  add_mounts "$CTID"
  start_ct "$CTID"
else
  # Repair mode: ensure mounts exist (best effort), then start
  msg_warn "Repair mode: not modifying CT network/rootfs. Ensuring mounts exist on host."
  mkdir -p "$HOST_SERVER" "$HOST_SAVE"
  start_ct "$CTID"
fi

provision_container "$CTID" "$SERVER_IP" "$SERVER_PORT" "$QUERY_PORT" "$BEACON_PORT" "$ADD_PORTS" "$UPDATE_ON_START" "$RESTART_SEC"
post_info "$CTID" "$SERVER_IP" "$SERVER_PORT" "$ADD_PORTS" "$QUERY_PORT" "$BEACON_PORT"
