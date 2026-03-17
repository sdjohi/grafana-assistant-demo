#!/usr/bin/env sh
# shellcheck shell=dash

set -eu
trap "exit 1" TERM
MY_PID=$$

log() {
  echo "$@" >&2
}

fatal() {
  log "$@"
  kill -s TERM "${MY_PID}"
}

safe_sudo() {
  SUDO=""
  SAFE_UID=$(id -u) # UID might already be set

  if [ "${SAFE_UID}" != 0 ]; then
    SUDO="sudo"
  fi

  ${SUDO} "$@"
}

detect_curl() {
  command -v curl >/dev/null 2>&1 || { fatal "Could not detect curl. Please install curl and re-run this script."; exit 1; }
}

detect_tee() {
  command -v tee >/dev/null 2>&1 || { fatal "Could not detect tee. Please install coreutils and re-run this script."; exit 1; }
}

# detect_arch tries to determine the cpu architecture. The output must be
# one of the supported build architectures for deb and rpm packages.
detect_arch() {
  uname_m=$(uname -m)
  case "${uname_m}" in
    amd64|x86_64)
      echo "amd64"
      return
      ;;
    aarch64|arm64*)
      echo "arm64"
      return
      ;;
    ppc64el|ppc64le)
      echo "${uname_m}"
      return
      ;;
    *)
      fatal "Unknown unsupported arch: ${uname_m}"
      ;;
  esac
}

# detect_package_system tries to detect the host distribution to determine if
# deb or rpm should be used for installing Alloy. Prints out either "deb"
# or "rpm". Calls fatal if the host OS is not supported.
detect_package_system() {
  command -v dpkg >/dev/null 2>&1 && { echo "deb"; return; }
  command -v rpm  >/dev/null 2>&1 && { echo "rpm"; return; }

  uname=$(uname)
  case "${uname}" in
    Darwin)
      fatal 'macOS not supported'
      ;;
    *)
      fatal "Unknown unsupported OS: ${uname}"
      ;;
  esac
}

SHA256_SUMS="
# BEGIN_SHA256_SUMS
607025bfb6be3263e926a1e1bc6662eb1e14db58afb685b1f9fb94b03be6d260  alloy-1.14.0-1.amd64.deb
5c1bc4236b0731af0d3ca36b36e36c7c2af39650dc3bdf812898ce34b8493d9a  alloy-1.14.0-1.amd64.rpm
307968ff21ad24c7aa8a92a23db13cb0bafb999075085027de671c9a952fbec0  alloy-1.14.0-1.arm64.deb
d52cbde8e5b243ac6707af25971a3c935b7b0689f221f2f0c7f6b1b396026007  alloy-1.14.0-1.arm64.rpm
535977fe03e6dc2dedfdc1ce9125dea516c18485cc4bf76616f0e534c81013d7  alloy-1.14.0-1.ppc64el.deb
86709898f6957f0780d8937c0036fc6d5b4a314f20ad34018a94da6b12b50bbe  alloy-1.14.0-1.ppc64le.rpm
d22e08f6a21cb86c08fee17b4c791cbd93225f9bddd2941fc69f742f72123333  alloy-1.14.0-1.s390x.deb
5274e547dcb4469525fbccf094d31d108dd4ea346c6919350ab950cd52d3f7ff  alloy-1.14.0-1.s390x.rpm
# END_SHA256_SUMS
"

CONFIG_SHA256_SUMS="
# BEGIN_CONFIG_SHA256_SUMS
0c73158198430ae2358a6c54f879ab5d436634dbce7a358d5eecd16da7faa7ad  config.alloy
# END_CONFIG_SHA256_SUMS
"

REMOTE_CONFIG_SHA256_SUMS="
# BEGIN_REMOTECONFIG_SHA256_SUMS
a5f1b2598c22fee9544b5d22e781a3bf56a8878ddd932cfa949417c021dc806c  config-fm.alloy
# END_REMOTECONFIG_SHA256_SUMS
"

HOSTNAME=$(uname -n)

#
# environment variables.
#
GCLOUD_HOSTED_METRICS_URL=${GCLOUD_HOSTED_METRICS_URL:=}           # Grafana Cloud Hosted Metrics url
GCLOUD_HOSTED_METRICS_ID=${GCLOUD_HOSTED_METRICS_ID:=}             # Grafana Cloud Hosted Metrics Instance ID
GCLOUD_SCRAPE_INTERVAL=${GCLOUD_SCRAPE_INTERVAL:=}                 # Grafana Cloud Hosted Metrics scrape interval
GCLOUD_HOSTED_LOGS_URL=${GCLOUD_HOSTED_LOGS_URL:=}                 # Grafana Cloud Hosted Logs url
GCLOUD_HOSTED_LOGS_ID=${GCLOUD_HOSTED_LOGS_ID:=}                   # Grafana Cloud Hosted Logs Instance ID
GCLOUD_FM_URL=${GCLOUD_FM_URL:=}                                   # Grafana Cloud Hosted Fleet Management url
GCLOUD_FM_POLL_FREQUENCY=${GCLOUD_FM_POLL_FREQUENCY:=}             # Grafana Cloud Hosted Fleet Management poll frequency
GCLOUD_FM_HOSTED_ID=${GCLOUD_FM_HOSTED_ID:=}                       # Grafana Cloud Hosted Fleet Management Instance ID
GCLOUD_RW_API_KEY=${GCLOUD_RW_API_KEY:=}                           # Grafana Cloud API key
GCLOUD_FM_LOCAL_ATTRIBUTES=${GCLOUD_FM_LOCAL_ATTRIBUTES:=}         # Grafana Cloud Fleet Management local attributes (JSON)

# Validate required environment variables
FM_ENABLED="false"
[ -z "${GCLOUD_RW_API_KEY}" ]  && fatal "Required environment variable \$GCLOUD_RW_API_KEY not set."
[ -z "${GCLOUD_HOSTED_LOGS_URL}" ] && fatal "Required environment variable \$GCLOUD_HOSTED_LOGS_URL not set."
[ -z "${GCLOUD_HOSTED_LOGS_ID}" ]  && fatal "Required environment variable \$GCLOUD_HOSTED_LOGS_ID not set."
[ -z "${GCLOUD_HOSTED_METRICS_URL}" ] && fatal "Required environment variable \$GCLOUD_HOSTED_METRICS_URL not set."
[ -z "${GCLOUD_HOSTED_METRICS_ID}" ]  && fatal "Required environment variable \$GCLOUD_HOSTED_METRICS_ID not set."
if [ -z "${GCLOUD_FM_URL}" ]; then  
  [ -z "${GCLOUD_SCRAPE_INTERVAL}" ]  && fatal "Required environment variable \$GCLOUD_SCRAPE_INTERVAL not set."
else
  FM_ENABLED="true"
  [ -z "${GCLOUD_FM_POLL_FREQUENCY}" ] && fatal "Required environment variable \$GCLOUD_FM_POLL_FREQUENCY not set."
  [ -z "${GCLOUD_FM_HOSTED_ID}" ]  && fatal "Required environment variable \$GCLOUD_FM_HOSTED_ID not set."
fi

#
# Global constants.
#
RELEASE_VERSION="v1.14.0"
RELEASE_URL="https://github.com/grafana/alloy/releases/download/${RELEASE_VERSION}"
CONFIG_FILE="config.alloy"

# Fleet Management enabled, use the FM config file.
if [ "${FM_ENABLED}" = "true" ]; then
  CONFIG_FILE="config-fm.alloy"
  CONFIG_SHA256_SUMS="${REMOTE_CONFIG_SHA256_SUMS}"
fi

# Architecture to install. If empty, the script will try to detect the value to use.
ARCH=${ARCH:=$(detect_arch)}

# Package system to install Alloy with. If not empty, MUST be either rpm or
# deb. If empty, the script will try to detect the host OS and the appropriate
# package system to use.
PACKAGE_SYSTEM=${PACKAGE_SYSTEM:=$(detect_package_system)}

# Enable or disable use of systemctl.
USE_SYSTEMCTL=${USE_SYSTEMCTL:-1}

# install_deb downloads and installs the deb package of Alloy.
install_deb() {
  # The DEB and RPM urls don't include the `v` version prefix in the file names,
  # so we trim it out using ${RELEASE_VERSION#v} below.
  DEB_NAME="alloy-${RELEASE_VERSION#v}-1.${ARCH}.deb"
  DEB_URL="${RELEASE_URL}/${DEB_NAME}"
  CURL_PATH=$(command -v curl)

  curl -fL# "${DEB_URL}" -o "/tmp/${DEB_NAME}" || fatal 'Failed to download package'

  case "${CURL_PATH}" in
    /snap/bin/curl)
      log '--'
      log '--- WARNING: curl installed via snap may not store downloaded file'
      log '--- If checksum of package fails, use apt to install curl'
      log '---'
      ;;
    *)
      ;;
  esac

  log '--- Verifying package checksum'
  (cd /tmp && check_sha "${SHA256_SUMS}" "${DEB_NAME}")

  safe_sudo dpkg -i "/tmp/${DEB_NAME}"
  rm "/tmp/${DEB_NAME}"
}

# install_rpm downloads and installs the rpm package of Alloy.
install_rpm() {
  # The DEB and RPM urls don't include the `v` version prefix in the file names,
  # so we trim it out using ${RELEASE_VERSION#v} below.
  RPM_NAME="alloy-${RELEASE_VERSION#v}-1.${ARCH}.rpm"
  RPM_URL="${RELEASE_URL}/${RPM_NAME}"

  curl -fL# "${RPM_URL}" -o "/tmp/${RPM_NAME}" || fatal 'Failed to download package'

  log '--- Verifying package checksum'
  (cd /tmp && check_sha "${SHA256_SUMS}" "${RPM_NAME}")

  safe_sudo rpm --reinstall "/tmp/${RPM_NAME}"
  rm "/tmp/${RPM_NAME}"
}

# download_config downloads the config file for Alloy and replaces
# placeholders with actual values.
download_config() {
  TMP_CONFIG_FILE="/tmp/${CONFIG_FILE}"
  curl -fsSL "https://storage.googleapis.com/cloud-onboarding/alloy/config/${CONFIG_FILE}" -o "${TMP_CONFIG_FILE}" || fatal 'Failed to download config'
  log '--- Verifying config checksum'
  (cd /tmp && check_sha "${CONFIG_SHA256_SUMS}" "${CONFIG_FILE}")

  sed -i -e "s~{GCLOUD_HOSTED_METRICS_URL}~${GCLOUD_HOSTED_METRICS_URL}~g" "${TMP_CONFIG_FILE}"
  sed -i -e "s~{GCLOUD_HOSTED_METRICS_ID}~${GCLOUD_HOSTED_METRICS_ID}~g" "${TMP_CONFIG_FILE}"
  sed -i -e "s~{GCLOUD_HOSTED_LOGS_URL}~${GCLOUD_HOSTED_LOGS_URL}~g" "${TMP_CONFIG_FILE}"
  sed -i -e "s~{GCLOUD_HOSTED_LOGS_ID}~${GCLOUD_HOSTED_LOGS_ID}~g" "${TMP_CONFIG_FILE}"
  if [ "${FM_ENABLED}" = "true" ]; then
    sed -i -e "s~{GCLOUD_FM_URL}~${GCLOUD_FM_URL}~g" "${TMP_CONFIG_FILE}"
    sed -i -e "s~{GCLOUD_FM_COLLECTOR_ID}~${HOSTNAME}~g" "${TMP_CONFIG_FILE}"
    sed -i -e "s~{GCLOUD_FM_POLL_FREQUENCY}~${GCLOUD_FM_POLL_FREQUENCY}~g" "${TMP_CONFIG_FILE}"
    sed -i -e "s~{GCLOUD_FM_HOSTED_ID}~${GCLOUD_FM_HOSTED_ID}~g" "${TMP_CONFIG_FILE}"
    sed -i -e "s~{GCLOUD_FM_LOCAL_ATTRIBUTES}~${GCLOUD_FM_LOCAL_ATTRIBUTES}~g" "${TMP_CONFIG_FILE}"
  else
    sed -i -e "s~{GCLOUD_SCRAPE_INTERVAL}~${GCLOUD_SCRAPE_INTERVAL}~g" "${TMP_CONFIG_FILE}"
  fi

  safe_sudo mkdir -p /etc/alloy
  safe_sudo mv "${TMP_CONFIG_FILE}" /etc/alloy/config.alloy
  safe_sudo chown -R root:root /etc/alloy
  safe_sudo find /etc/alloy -type d -exec chmod 755 {} \;
  safe_sudo find /etc/alloy -type f -exec chmod 644 {} \;
}

# create_env_file creates a file that contains the environment variables for Alloy.
create_env_file() {
  safe_sudo mkdir -p /etc/systemd/system/alloy.service.d
  OVERRIDE_FILE="/etc/systemd/system/alloy.service.d/env.conf"
  {
    echo '[Service]'
    echo "Environment=GCLOUD_RW_API_KEY=${GCLOUD_RW_API_KEY}"
    if [ "${FM_ENABLED}" = "true" ]; then
      # Older versions of the self monitoring pipelines still depend on GCLOUD_FM_COLLECTOR_ID.
      # Newer versions use the virtual attribute collector ID from the config file.
      echo "Environment=GCLOUD_FM_COLLECTOR_ID=${HOSTNAME}"
    fi
  } | safe_sudo tee "${OVERRIDE_FILE}" > /dev/null
  safe_sudo chmod 600 /etc/systemd/system/alloy.service.d/env.conf;
  if [ "${USE_SYSTEMCTL}" -eq "1" ]; then
    safe_sudo systemctl daemon-reload 
  fi
} 

check_sha() {
  local checksums="$1"
  local asset_name="$2"
  shift 2

  echo -n "${checksums}" | grep "${asset_name}" | sha256sum --check --status --quiet - || fatal 'Failed sha256sum check'
}

main() {
  detect_curl
  detect_tee

  log "--- Using package system ${PACKAGE_SYSTEM}. Downloading and installing package for ${ARCH}"

  case "${PACKAGE_SYSTEM}" in
    deb)
      install_deb
      ;;
    rpm)
      install_rpm
      ;;
    *)
      fatal "Could not detect a valid Package Management System. Must be either RPM or dpkg"
      ;;
  esac

  log '--- Retrieving config and placing in /etc/alloy/config.alloy'
  download_config

  log '--- Creating systemd override file for environment variables'
  create_env_file

  if [ "${USE_SYSTEMCTL}" -eq "1" ]; then
    log '--- Enabling and starting alloy.service'
    safe_sudo systemctl enable alloy.service
    safe_sudo systemctl start alloy.service
  fi

  log ''
  log ''
  log 'Alloy is now running!'
  log ''
  log 'To check the status of Alloy, run:'
  log '   sudo systemctl status alloy.service'
  log ''
  log 'To restart Alloy, run:'
  log '   sudo systemctl restart alloy.service'
  log ''
  log 'The config file is located at:'
  log '   /etc/alloy/config.alloy'
}

main
