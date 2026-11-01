#!/bin/bash
#
# Endlessh (skeeto/endlessh) installer — SSH tarpit
# https://github.com/skeeto/endlessh
#
# Usage: endlessh.sh [PORT] [VERSION]
#   PORT     listening port, default 22 (use "auto" for 22)
#   VERSION  upstream git tag, default latest (use "auto" for latest)
#
# Before installing, the target port (22 by default) is checked. If it is
# already in use (e.g. by a real sshd), the script warns and exits so that
# you do not lock yourself out — move your real SSH daemon to another port
# first, then re-run this installer.

GREEN_BG='\033[42;30m'   # Green background, black text
RED_BG='\033[41;97m'     # Red background, white text
WHITE_BG='\033[47;30m'   # White background, black text
NORMAL='\033[0m'         # Reset formatting

# Check if the script is being run as root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED_BG}This script requires root privileges.${NORMAL} Please run as root or use sudo."
  exit 1
fi

# Install GNU grep if BusyBox ver grep found
is_busybox_grep() {
  grep --version 2>&1 | grep -q BusyBox
}
if is_busybox_grep; then
  echo -e "${GREEN_BG}[Requirements] BusyBox grep detected. Installing GNU grep.${NORMAL}"
  if command -v apk >/dev/null; then
    apk add grep
  elif command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y grep
  elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm grep
  else
    echo -e "${RED_BG}[ERROR] Unsupported package manager.${NORMAL} Please install GNU grep manually."
    exit 1
  fi
fi

# Function to detect the package manager and install missing packages
install_packages() {
  if command -v apk &> /dev/null; then
    apk update && apk add build-base curl make
  elif command -v apt-get &> /dev/null; then
    apt-get update && apt-get install -y build-essential curl make
  elif command -v pacman &> /dev/null; then
    pacman -Syu --noconfirm base-devel curl make
  elif command -v dnf &> /dev/null; then
    dnf install -y gcc make curl
  elif command -v zypper &> /dev/null; then
    zypper install -y gcc make curl
  elif command -v yum &> /dev/null; then
    yum install -y gcc make curl
  else
    echo -e "${RED_BG}[ERROR] Unsupported package manager.${NORMAL} Please install a C compiler, make, and curl manually."
    exit 1
  fi
}

# Install build tools if missing (Endlessh ships no binaries; build from source)
need_build_deps=0
command -v curl &> /dev/null || need_build_deps=1
command -v make &> /dev/null || need_build_deps=1
{ command -v cc &> /dev/null || command -v gcc &> /dev/null; } || need_build_deps=1
if [[ $need_build_deps -eq 1 ]]; then
  echo -e "${GREEN_BG}[Requirements] Installing missing build dependencies...${NORMAL}"
  install_packages
fi

### Determine listening port (default 22)
if [ -z "$1" ] || [ "$1" = "auto" ]; then
  port=22
else
  port=$1
fi
if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo -e "${RED_BG}Invalid port: $port${NORMAL} Port must be an integer between 1 and 65535."
  exit 1
fi

### Check whether the target port is already in use
is_port_in_use() {
  local p=$1
  if command -v ss &> /dev/null; then
    [ -n "$(ss -Htln "sport = :$p" 2>/dev/null)" ]
  elif command -v netstat &> /dev/null; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
  elif [ -r /proc/net/tcp ]; then
    # Fallback: parse /proc/net/tcp{,6}; state 0A == LISTEN, port is hex
    local hexp
    hexp=$(printf '%04X' "$p")
    awk -v p="$hexp" '$2 ~ (":" p "$") && $4 == "0A" { found=1 } END { exit !found }' \
      /proc/net/tcp /proc/net/tcp6 2>/dev/null
  else
    echo -e "${WHITE_BG}[WARN] Unable to check port state (no ss/netstat/proc). Proceeding.${NORMAL}" >&2
    return 1
  fi
}

if is_port_in_use "$port"; then
  echo -e "${RED_BG}Port $port is already in use.${NORMAL}"
  if [ "$port" = "22" ]; then
    echo -e "Port 22 is likely occupied by your real SSH daemon (sshd)."
    echo -e "Endlessh is meant to replace SSH on this port as a tarpit."
    echo -e "Move your real sshd to another port first, e.g.:"
    echo -e "  ${WHITE_BG}sed -i 's/^#\\?Port .*/Port 2200/' /etc/ssh/sshd_config && systemctl restart sshd${NORMAL}"
    echo -e "then reconnect on the new port and re-run this installer."
  else
    echo -e "Choose a free port and re-run: ${WHITE_BG}$0 <PORT>${NORMAL}"
  fi
  echo -e "${RED_BG}Aborting to avoid a port conflict.${NORMAL}"
  exit 1
fi

### Resolve version (git tag)
if [ -z "$2" ] || [ "$2" = "auto" ]; then
  version=$(curl -s "https://api.github.com/repos/skeeto/endlessh/releases/latest" 2>/dev/null \
    | grep -oP '(?<="tag_name": ")[^"]+')
  if [ -z "$version" ]; then
    # API unavailable / rate-limited: fall back to the newest git tag
    version=$(curl -s "https://api.github.com/repos/skeeto/endlessh/tags" 2>/dev/null \
      | grep -oP '(?<="name": ")[^"]+' | head -n1)
  fi
  if [ -z "$version" ]; then
    echo -e "${WHITE_BG}[WARN] Unable to fetch latest version from GitHub. Falling back to 1.1.${NORMAL}"
    version="1.1"
  fi
else
  version="$2"
fi

### Build and install Endlessh from source
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

url="https://codeload.github.com/skeeto/endlessh/tar.gz/refs/tags/${version}"
echo -e "${GREEN_BG}Downloading Endlessh ${version} source...${NORMAL} $url"
if ! curl -fsSL -o "$build_dir/endlessh.tar.gz" "$url"; then
  echo -e "${RED_BG}Failed to download Endlessh ${version}.${NORMAL} Check the version/tag and your connection."
  exit 1
fi

tar -xzf "$build_dir/endlessh.tar.gz" -C "$build_dir" || {
  echo -e "${RED_BG}Failed to extract source archive.${NORMAL}"; exit 1; }

src_dir=$(find "$build_dir" -maxdepth 1 -type d -name 'endlessh-*' | head -n1)
if [ -z "$src_dir" ]; then
  echo -e "${RED_BG}Source directory not found after extraction.${NORMAL}"
  exit 1
fi

echo -e "${GREEN_BG}Compiling Endlessh...${NORMAL}"
if ! make -C "$src_dir" endlessh > /dev/null; then
  echo -e "${RED_BG}Compilation failed.${NORMAL}"
  exit 1
fi

install -d /usr/local/bin
install -m 755 "$src_dir/endlessh" /usr/local/bin/endlessh
install -d /usr/local/share/man/man1
[ -f "$src_dir/endlessh.1" ] && install -m 644 "$src_dir/endlessh.1" /usr/local/share/man/man1/
echo -e "${GREEN_BG}Endlessh installed to /usr/local/bin/endlessh${NORMAL}"

### Generate configuration
mkdir -p /etc/endlessh
cat <<EOF > /etc/endlessh/config
# Endlessh configuration — see man endlessh(1)

# The port on which to listen for new SSH connections.
Port $port

# The endless banner is sent one line at a time. Delay (ms) between lines.
Delay 5000

# Maximum length of each randomized banner line.
MaxLineLength 32

# Maximum number of simultaneous connections to accept.
MaxClients 32768

# Log detail: 0 = quiet, 1 = standard, 2 = debug.
LogLevel 1
EOF
echo -e "${GREEN_BG}Configuration written to /etc/endlessh/config${NORMAL} (Port $port)"

### Install the system service
echo -e "${GREEN_BG}Installing system service...${NORMAL}"
init_system=$(cat /proc/1/comm)
if [[ "$init_system" == "systemd" ]]; then
  # The service runs as root so it can bind privileged ports (e.g. 22) with
  # no capability juggling. We deliberately avoid namespace-based hardening
  # (PrivateUsers/ProtectSystem/InaccessiblePaths/PrivateTmp/...): those fail
  # with status=226/NAMESPACE on container-based VPS (OpenVZ/LXC) or kernels
  # that restrict user namespaces. A tarpit's attack surface is tiny, so the
  # namespace-free settings below are a sensible default. Optional hardening
  # for hosts that support it is listed, commented, at the end of the unit.
  cat <<EOF > /etc/systemd/system/endlessh.service
[Unit]
Description=Endlessh SSH Tarpit — on :$port
Documentation=man:endlessh(1) https://github.com/skeeto/endlessh
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/endlessh -f /etc/endlessh/config
Restart=always
RestartSec=30s
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
StandardInput=null

# Namespace-free hardening (safe on containers too)
NoNewPrivileges=true

# Optional hardening — enable ONLY on hosts whose kernel supports these
# namespaces. On OpenVZ/LXC VPS or with restricted user namespaces they
# cause the service to fail with status=226/NAMESPACE.
#DynamicUser=true
#AmbientCapabilities=CAP_NET_BIND_SERVICE
#PrivateTmp=true
#PrivateDevices=true
#ProtectSystem=strict
#ProtectHome=true
#ProtectKernelTunables=true
#ProtectKernelModules=true
#ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable endlessh
  systemctl restart endlessh
  echo -e "${WHITE_BG}TO REMOVE THIS SERVICE:${NORMAL} systemctl disable --now endlessh && rm /etc/systemd/system/endlessh.service && rm -rf /etc/endlessh /usr/local/bin/endlessh"

elif [[ "$init_system" == "init" || "$init_system" == "openrc" ]]; then
  cat <<EOF > /etc/init.d/endlessh
#!/sbin/openrc-run

name="Endlessh SSH Tarpit — on :$port"
description="Endlessh SSH Tarpit — on :$port"
command="/usr/local/bin/endlessh"
command_args="-f /etc/endlessh/config"
command_background=true
pidfile="/var/run/endlessh.pid"
output_log="/var/log/endlessh.log"
error_log="/var/log/endlessh.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/endlessh
  rc-update add endlessh default
  rc-service endlessh restart
  echo -e "${WHITE_BG}TO REMOVE THIS SERVICE:${NORMAL} rc-service endlessh stop && rc-update del endlessh default && rm /etc/init.d/endlessh && rm -rf /etc/endlessh /usr/local/bin/endlessh"

else
  echo -e "${RED_BG}Unsupported init system: $init_system.${NORMAL}"
  echo -e "Endlessh is installed. Start it manually: /usr/local/bin/endlessh -f /etc/endlessh/config"
  exit 1
fi

echo -e "${GREEN_BG}Endlessh ${version} installed and listening on port $port.${NORMAL}"
echo -e "${GREEN_BG}Watch it trap clients:${NORMAL} journalctl -u endlessh -f   (or tail /var/log/endlessh.log)"
