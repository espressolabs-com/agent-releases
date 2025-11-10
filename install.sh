#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]; then
  abort "Bash is required to interpret this script."
fi

# Check if script is run with force-interactive mode in CI
if [[ -n "${CI-}" && -n "${INTERACTIVE-}" ]]; then
  abort "Cannot run force-interactive mode in CI."
fi

# Check if both `INTERACTIVE` and `NONINTERACTIVE` are set
# Always use single-quoted strings with `exp` expressions
# shellcheck disable=SC2016
if [[ -n "${INTERACTIVE-}" && -n "${NONINTERACTIVE-}" ]]; then
  abort 'Both `$INTERACTIVE` and `$NONINTERACTIVE` are set. Please unset at least one variable and try again.'
fi

# Check if script is run in POSIX mode
if [[ -n "${POSIXLY_CORRECT+1}" ]]; then
  abort 'Bash must not run in POSIX mode. Please unset POSIXLY_CORRECT and try again.'
fi

# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")" >&2
}

usage() {
  cat <<EOS
EspressoLabs Agent Installer
Usage: [NONINTERACTIVE=1] [CI=1] install.sh [options]
    --backend-host   The backend that the agent will connect to.
    --token          The token that the agent will use to authenticate.
    --extension      Install the Chrome Extension
    --bitdefender    Install Bitdefender (default: do not install Bitdefender)
    --no-jq          Do not install jq (default: install jq)
    -h, --help       Display this message.
    NONINTERACTIVE   Install without prompting for user input
    CI               Install in CI mode (e.g. do not prompt for user input)
EOS
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help) usage ;;
  --backend-host=*)
    BACKEND_HOST="${1#*=}"
    shift
    ;;
  --backend-host)
    BACKEND_HOST="$2"
    shift 2
    ;;
  --token=*)
    TOKEN="${1#*=}"
    shift
    ;;
  --token)
    TOKEN="$2"
    shift 2
    ;;
  --no-jq)
    NO_JQ=1
    shift
    ;;
  --extension)
    INSTALL_EXTENSION=1
    shift
    ;;
  --bitdefender)
    INSTALL_BITDEFENDER=1
    shift
    ;;
  *)
    warn "Unrecognized option: '$1'"
    usage 1
    ;;
  esac
done

# Check if script is run non-interactively (e.g. CI)
# If it is run non-interactively we should not prompt for passwords.
# Always use single-quoted strings with `exp` expressions
# shellcheck disable=SC2016
if [[ -z "${NONINTERACTIVE-}" ]]; then
  if [[ -n "${CI-}" ]]; then
    warn 'Running in non-interactive mode because `$CI` is set.'
    NONINTERACTIVE=1
  elif [[ ! -t 0 ]]; then
    if [[ -z "${INTERACTIVE-}" ]]; then
      warn 'Running in non-interactive mode because `stdin` is not a TTY.'
      NONINTERACTIVE=1
    else
      warn 'Running in interactive mode despite `stdin` not being a TTY because `$INTERACTIVE` is set.'
    fi
  fi
else
  ohai 'Running in non-interactive mode because `$NONINTERACTIVE` is set.'
fi

# USER isn't always set so provide a fall back for the installer and subprocesses.
if [[ -z "${USER-}" ]]; then
  USER="$(chomp "$(id -un)")"
  export USER
fi

# First check OS.
OS="$(uname)"
if [[ "${OS}" != "Darwin" ]]; then
  abort "EspressoLabs Agent is only supported on macOS."
fi

if [[ -z "${NONINTERACTIVE-}" ]]; then
  ohai "Let's get started!"
  # Prompt user if values are missing
  if [[ -z "$BACKEND_HOST" ]]; then
    read -rp "Enter backend host: " BACKEND_HOST
    BACKEND_HOST="${BACKEND_HOST//['\"']/}"
  fi

  if [[ -z "$TOKEN" ]]; then
    read -rp "Enter token: " TOKEN
    TOKEN="${TOKEN//['\"']/}"
  fi
fi

if [[ -z "$BACKEND_HOST" || -z "$TOKEN" ]]; then
  abort "both --backend-host and --token must be set."
fi

# Search for the given executable in PATH (avoids a dependency on the `which` command)
which() {
  # Alias to Bash built-in command `type -P`
  type -P "$@"
}

UNAME_MACHINE="$(/usr/bin/uname -m)"
INSTALLER=$(which installer)

ohai "Using the following values:"
echo "    Backend Host: $BACKEND_HOST"
echo "           Token: $TOKEN"

REQUIRED_CURL_VERSION=7.41.0

have_sudo_access() {
  if [[ ! -x "/usr/bin/sudo" ]]; then
    return 1
  fi

  local -a SUDO=("/usr/bin/sudo")
  if [[ -n "${SUDO_ASKPASS-}" ]]; then
    SUDO+=("-A")
  elif [[ -n "${NONINTERACTIVE-}" ]]; then
    SUDO+=("-n")
  fi

  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]; then
    if [[ -n "${NONINTERACTIVE-}" ]]; then
      "${SUDO[@]}" -l mkdir &>/dev/null
    else
      "${SUDO[@]}" -v && "${SUDO[@]}" -l mkdir &>/dev/null
    fi
    HAVE_SUDO_ACCESS="$?"
  fi

  if [[ -n "${HOMEBREW_ON_MACOS-}" ]] && [[ "${HAVE_SUDO_ACCESS}" -ne 0 ]]; then
    abort "Need sudo access on macOS (e.g. the user ${USER} needs to be an Administrator)!"
  fi

  return "${HAVE_SUDO_ACCESS}"
}

execute() {
  if ! "$@"; then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

retry() {
  local tries="$1" n="$1" pause=2
  shift
  if ! "$@"; then
    while [[ $((--n)) -gt 0 ]]; do
      warn "$(printf "Trying again in %d seconds: %s" "${pause}" "$(shell_join "$@")")"
      sleep "${pause}"
      ((pause *= 2))
      if "$@"; then
        return
      fi
    done
    abort "$(printf "Failed %d times doing: %s" "${tries}" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if [[ "${EUID:-${UID}}" != "0" ]] && have_sudo_access; then
    if [[ -n "${SUDO_ASKPASS-}" ]]; then
      args=("-A" "${args[@]}")
    fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

getc() {
  local save_state
  save_state="$(/bin/stty -g)"
  /bin/stty raw -echo
  IFS='' read -r -n 1 -d '' "$@"
  /bin/stty "${save_state}"
}

ring_bell() {
  # Use the shell's audible bell.
  if [[ -t 1 ]]; then
    printf "\a"
  fi
}

wait_for_user() {
  local c
  echo
  echo "Press ${tty_bold}RETURN${tty_reset}/${tty_bold}ENTER${tty_reset} to continue or any other key to abort:"
  getc c
  # we test for \r and \n because some stuff does \r instead
  if ! [[ "${c}" == $'\r' || "${c}" == $'\n' ]]; then
    exit 1
  fi
}

major_minor() {
  echo "${1%%.*}.$(
    x="${1#*.}"
    echo "${x%%.*}"
  )"
}

version_gt() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -gt "${2#*.}" ]]
}
version_ge() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -ge "${2#*.}" ]]
}
version_lt() {
  [[ "${1%.*}" -lt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -lt "${2#*.}" ]]
}

test_curl() {
  if [[ ! -x "$1" ]]; then
    return 1
  fi

  if [[ "$1" == "/snap/bin/curl" ]]; then
    warn "Ignoring $1 (curl snap is too restricted)"
    return 1
  fi

  local curl_version_output curl_name_and_version
  curl_version_output="$("$1" --version 2>/dev/null)"
  curl_name_and_version="${curl_version_output%% (*}"
  version_ge "$(major_minor "${curl_name_and_version##* }")" "$(major_minor "${REQUIRED_CURL_VERSION}")"
}

# shellcheck disable=SC2016
ohai 'Checking for `sudo` access (which may request your password)...'

if [[ "${EUID:-${UID}}" != "0" ]] && ! have_sudo_access; then
  abort "$(
    cat <<EOABORT
Insufficient permissions to install the EspressoLabs Agent.

Try again as an Adminstrator or user with sudo access.
EOABORT
  )"
fi

if [[ "${UNAME_MACHINE}" != "arm64" ]] && [[ "${UNAME_MACHINE}" != "x86_64" ]]; then
  abort "The EspressoLabs Agent is only supported on Intel and ARM processors!"
fi

ohai "This script will install:"
echo "    - espresso-agent"
echo "    - com.espressolabs.agent service"
if [[ -z "${NO_JQ-}" ]]; then
  echo "    - jq"
fi
if [[ -n "${INSTALL_EXTENSION-}" ]]; then
  echo "    - Chrome Extension"
fi
if [[ -n "${INSTALL_BITDEFENDER-}" ]]; then
  echo "    - Bitdefender"
fi

if [[ -z "${NONINTERACTIVE-}" ]]; then
  ring_bell
  wait_for_user
fi

if ! command -v curl >/dev/null; then
  abort "$(
    cat <<EOABORT
You must install cURL before installing the EspressoLabs Agent. See:
  ${tty_underline}https://docs.brew.sh/Installation${tty_reset}
EOABORT
  )"
fi

get_latest_release() {
  pkg_asset_url=$(curl --silent "https://api.github.com/repos/espressolabs-com/agent-releases/releases/latest" |
    grep -o '"browser_download_url": "[^"]*pkg"' |
    sed -E 's/.*"browser_download_url": "(.*)".*/\1/')

  if [[ -n "$pkg_asset_url" ]]; then
    # Extract filename from the URL (e.g., "espresso-agent-0.11.0.pkg")
    filename=$(basename "$pkg_asset_url")
    LOCAL_PKG_PATH="/tmp/$filename"
    AGENT_VERSION=$(echo "$filename" | sed -E 's/.*-([0-9]+\.[0-9]+\.[0-9]+)\.pkg/\1/')

    # Download the file to /tmp using the extracted filename
    echo "Downloading pkg: $pkg_asset_url"
    curl -L --progress-bar "$pkg_asset_url" -o "$LOCAL_PKG_PATH"
    echo "Downloaded to $LOCAL_PKG_PATH"
  else
    abort "No asset found for the latest release."
  fi
}

JQ_PATH="/usr/local/bin/jq"
get_latest_jq() {
  ARCH=$(uname -m)

  if [ "$ARCH" == "x86_64" ]; then
    JQ_URL="https://github.com/jqlang/jq/releases/latest/download/jq-macos-amd64"
  elif [ "$ARCH" == "arm64" ]; then
    JQ_URL="https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64"
  fi
  TMP_JQ_PATH="/tmp/jq"

  echo "Installing jq from: $JQ_URL"

  curl -L --progress-bar "$JQ_URL" -o "$TMP_JQ_PATH"
  execute_sudo mkdir -p "$(dirname "$JQ_PATH")"
  execute_sudo mv "$TMP_JQ_PATH" "$JQ_PATH"
  execute_sudo chmod +x "$JQ_PATH"

  echo "Installed jq to $JQ_PATH"
}

if [[ -z "${NO_JQ-}" ]]; then
  ohai "Checking for jq..."
  if [[ ! -f "$JQ_PATH" ]]; then
    get_latest_jq
  else
    echo "JQ found in path"
  fi
fi

ohai "Downloading the latest release..."
get_latest_release

execute_sudo "$INSTALLER" "-pkg" "$LOCAL_PKG_PATH" "-target" "/"

execute_sudo "/Library/EspressoLabs/espresso-agent/reconfigure.sh" "$BACKEND_HOST" "$TOKEN"

check_espresso_agent_version() {
  local expected_version="$1"

  # Check if 'espresso-agent' is available in the PATH
  if ! command -v espresso-agent &>/dev/null; then
    abort "espresso-agent is not installed or not available in the PATH."
  fi

  # Run 'espresso-agent --version' and capture the output
  version_output=$(espresso-agent --version)

  # Check if the output contains the expected version number
  if [[ "$version_output" == *"$expected_version"* ]]; then
    echo "Version check passed: $version_output"
  else
    abort "Version mismatch: expected $expected_version, but got $version_output"
  fi
}

ohai "Checking espresso-agent version..."
check_espresso_agent_version "$AGENT_VERSION"

ohai "Installation successful!"

get_latest_extension() {
  extension_url=$(curl --silent https://expresso-agent-1.s3.us-east-1.amazonaws.com/chrome-extension/latest)

  filename=$(basename "$extension_url")
  local_extension_path="/tmp/$filename"
  EXTENSION_VERSION=$(echo "$extension_url" | sed -E 's/.*-([0-9]+\.[0-9]+\.[0-9]+)\.zip/\1/')
  EXTENSION_DESTINATION="/Library/Application Support/EspressoLabs"

  echo "Downloading extension: $extension_url"
  curl -L --progress-bar "$extension_url" -o "$local_extension_path"
  echo "Downloaded to $local_extension_path"

  execute_sudo mkdir -p "$EXTENSION_DESTINATION"
  execute_sudo unzip -qq -o "$local_extension_path" -d "$EXTENSION_DESTINATION"
  execute_sudo chmod -R 777 "$EXTENSION_DESTINATION/chrome-extension"
}

if [[ -n "${INSTALL_EXTENSION-}" ]]; then
  ohai "Downloading the latest extension..."
  get_latest_extension

  ohai "You can now enable the Chrome Extension"

  echo "    To enable the extension:"
  echo "     1. Open Chrome and navigate to 'chrome://extensions/'."
  echo "     2. Enable 'Developer mode' (toggle in the top-right corner)."
  echo "     3. Click 'Load unpacked' and select the folder: $EXTENSION_DESTINATION/chrome-extension"

fi

BITDEFENDER_PKGS=(
  "com.epsecurity.EndpointSecurityforMac.content_control"
  "com.epsecurity.EndpointSecurityforMac"
  "com.epsecurity.EndpointSecurityforMac.filescan"
  "com.epsecurity.EndpointSecurityforMac.sigs-arm64"
  "com.epsecurity.EndpointSecurityforMac.edr"
)

is_bitdefender_installed() {
  # Check main directories
  local bitdefender_path="/Library/oem/AVP/product/bin"
  if [[ -d "$bitdefender_path" ]]; then
    ohai "Bitdefender directory found: $bitdefender_path"
    return 0
  fi

  # Check package receipts
  for pkg in "${BITDEFENDER_PKGS[@]}"; do
    if pkgutil --pkgs | grep -q "$pkg"; then
      ohai "Bitdefender package receipt found: $pkg"
      return 0
    fi
  done
  ohai "Bitdefender not detected by package receipts or directories."
  return 1
}

install_bitdefender() {
  if [[ "${UNAME_MACHINE}" == "arm64" ]]; then
    bitdefender_url="https://expresso-agent-1.s3.us-east-1.amazonaws.com/bitdefender/darwin/endpoint-security.arm64.pkg"
  fi
  if [[ "${UNAME_MACHINE}" == "x86_64" ]]; then
    bitdefender_url="https://expresso-agent-1.s3.us-east-1.amazonaws.com/bitdefender/darwin/endpoint-security.intel.pkg"
  fi

  local_bitdefender_path="/tmp/endpoint-security.pkg"
  local_bitdefender_config_path="/tmp/installer.xml"

  echo "Downloading Bitdefender from: $bitdefender_url"
  curl -L --progress-bar "$bitdefender_url" -o "$local_bitdefender_path"
  echo "Downloaded to $local_bitdefender_path"

  # write the bitdefender config file next to the pkg
  cat <<EOF >"$local_bitdefender_config_path"
<?xml version="1.0" encoding="utf-8"?>
<config version="1.0">
  <features>
    <feature name="FileScan" action="1" />
    <feature name="UserControl" action="1" />
    <feature name="Antiphishing" action="1" />
    <feature name="TrafficScan" action="1" />
    <feature name="EventCorrelator" action="1" />
  </features>
</config>
EOF

  execute_sudo "$INSTALLER" "-pkg" "$local_bitdefender_path" "-target" "/"
}

if [[ -n "${INSTALL_BITDEFENDER-}" ]]; then
  if is_bitdefender_installed; then
    ohai "Bitdefender is already installed. Skipping installation."
  else
    ohai "Installing Bitdefender..."
    install_bitdefender
    ohai "Bitdefender installed successfully!"
  fi
fi

ring_bell
