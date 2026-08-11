#!/usr/bin/env bash
# Engine comes from community-scripts/core; this repo only ships the scripts.
# A local core checkout wins (COMMUNITY_SCRIPTS_CORE_DIR, else a sibling ../core),
# so a fork or branch of core can be tested without editing this file.
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/shared/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/shared/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jannis Werner (MarcvsTvllivs)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/block/buzz

APP="Buzz"
var_tags="${var_tags:-chat;nostr;ai}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-30}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
#var_arm64="${var_arm64:-no}" # unset = ask the user; set yes/no only when verified
var_unprivileged="${var_unprivileged:-1}"

# Application settings the install script reads up front (see json app_vars).
export var_owner_pubkey="${var_owner_pubkey:-}"
export var_relay_open="${var_relay_open:-}"

header_info "$APP"
variables
color
catch_errors

# Fail before the container build, not inside it.
if [[ -n "${var_owner_pubkey:-}" && ! "${var_owner_pubkey}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  msg_error "var_owner_pubkey must be a 64-character hex Nostr public key (convert npub to hex first)."
  exit 1
fi

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/buzz_data/config/buzz.env ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # Buzz has three release lanes; the relay server ships as relay-v<version>
  # tags without GitHub release objects, so version state comes from tags.
  RELEASE=$(get_latest_gh_tag "block/buzz" "relay-v")
  # .buzz-build-ok lives in the replaced tree, so an interrupted update
  # (deployed source, failed build) re-runs instead of reporting up-to-date.
  if [[ "${RELEASE}" == "$(cat ~/.buzz 2>/dev/null)" && -f /opt/buzz/.buzz-build-ok ]]; then
    msg_ok "No update required. ${APP} is already at ${RELEASE}"
    exit
  fi

  msg_info "Stopping Service"
  systemctl stop buzz-relay
  msg_ok "Stopped Service"

  msg_info "Backing up PostgreSQL Database"
  runuser -u postgres -- pg_dump buzz | gzip >"/opt/buzz_data/backups/buzz-$(date +%F-%H%M%S).sql.gz"
  find /opt/buzz_data/backups -name 'buzz-*.sql.gz' | sort -r | tail -n +4 | xargs -r rm --
  msg_ok "Backed up PostgreSQL Database"

  # All persistent state lives in /opt/buzz_data and /var/lib, so the source
  # tree is replaced wholesale with no backup/restore step.
  CLEAN_INSTALL=1 fetch_and_deploy_gh_tag "buzz" "block/buzz" "${RELEASE}" "/opt/buzz"

  setup_rust
  NODE_VERSION="24" setup_nodejs
  export PATH="$HOME/.cargo/bin:$PATH"

  msg_info "Building Buzz Server (Patience)"
  cd /opt/buzz
  $STD cargo build --release --locked -p buzz-relay --bin buzz-relay -p buzz-admin --bin buzz-admin -p buzz-pair-relay --bin buzz-pair-relay
  msg_ok "Built Buzz Server"

  msg_info "Building Web Bundles"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  $STD corepack enable
  $STD pnpm install --frozen-lockfile --filter buzz-web --filter buzz-admin-web
  $STD pnpm -C web build
  $STD pnpm -C admin-web build
  msg_ok "Built Web Bundles"

  msg_info "Running Database Migrations"
  set -a
  source /opt/buzz_data/config/buzz.env
  set +a
  $STD /opt/buzz/target/release/buzz-admin migrate
  msg_ok "Ran Database Migrations"

  msg_info "Deploying Artifacts"
  install -m 0755 /opt/buzz/target/release/buzz-relay /opt/buzz/target/release/buzz-admin /opt/buzz/target/release/buzz-pair-relay /usr/local/bin/
  rm -rf /srv/buzz/web /srv/buzz/admin-web
  mkdir -p /srv/buzz
  cp -r /opt/buzz/web/dist /srv/buzz/web
  cp -r /opt/buzz/admin-web/dist /srv/buzz/admin-web
  touch /opt/buzz/.buzz-build-ok
  msg_ok "Deployed Artifacts"

  msg_info "Starting Service"
  systemctl start buzz-relay
  for _ in {1..30}; do
    curl -fsS -m 2 http://127.0.0.1:8080/_readiness >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS -m 2 http://127.0.0.1:8080/_readiness >/dev/null
  msg_ok "Started Service"
  msg_ok "Updated ${APP} to ${RELEASE}"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Point the Buzz desktop app (BUZZ_RELAY_URL) at:${CL}"
echo -e "${GATEWAY}${BGN}ws://${IP}:3000${CL}"
echo -e "${INFO}${YW}If no owner key was supplied, the generated owner identity is in /opt/buzz_data/config/owner-key.txt inside the container.${CL}"
