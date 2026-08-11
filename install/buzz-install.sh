#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jannis Werner (MarcvsTvllivs)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/block/buzz

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -f /opt/buzz_data/config/buzz.env ]]; then
  msg_error "Existing Buzz configuration found at /opt/buzz_data/config/buzz.env — refusing to overwrite. Use the updater (run ct/buzz.sh on the Proxmox host) instead."
  exit 1
fi

if [[ -n "${var_owner_pubkey:-}" && ! "${var_owner_pubkey}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  msg_error "var_owner_pubkey must be a 64-character hex Nostr public key (convert npub to hex first)."
  exit 1
fi

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  libssl-dev \
  pkg-config \
  redis-server
msg_ok "Installed Dependencies"

PG_VERSION="17" setup_postgresql
PG_DB_NAME="buzz" PG_DB_USER="buzz" PG_DB_EXTENSIONS="pgcrypto" setup_postgresql_db

msg_info "Configuring Redis"
REDIS_PASS=$(openssl rand -hex 24)
cat <<EOF >>/etc/redis/redis.conf

# Buzz: authentication + persistence (mirrors upstream deploy/compose)
requirepass ${REDIS_PASS}
appendonly yes
EOF
systemctl enable -q --now redis-server
systemctl restart redis-server
msg_ok "Configured Redis"

msg_info "Installing MinIO Object Storage"
# Pinned to the MinIO release upstream Buzz pins in deploy/compose/compose.yml
# (RELEASE.2025-09-07T16-13-09Z); bump alongside upstream, not independently.
curl -fsSL -o /tmp/minio.deb "https://dl.min.io/server/minio/release/linux-amd64/archive/minio_20250907161309.0.0_amd64.deb"
echo "eeda08f699f6592d1b868ac8bda864ae2cacdb5ee1b888663366e8c8ff566249  /tmp/minio.deb" | sha256sum -c - >/dev/null
$STD apt install -y /tmp/minio.deb
rm -f /tmp/minio.deb
# The vendor systemd unit shipped in the deb runs as minio-user and reads
# /etc/default/minio; the user is required, not optional.
useradd -r -s /usr/sbin/nologin -d /var/lib/minio minio-user
mkdir -p /var/lib/minio
chown minio-user:minio-user /var/lib/minio
S3_ACCESS_KEY=$(openssl rand -hex 16)
S3_SECRET_KEY=$(openssl rand -hex 32)
cat <<EOF >/etc/default/minio
MINIO_VOLUMES=/var/lib/minio
MINIO_OPTS="--address 127.0.0.1:9000 --console-address 127.0.0.1:9001"
MINIO_ROOT_USER=${S3_ACCESS_KEY}
MINIO_ROOT_PASSWORD=${S3_SECRET_KEY}
EOF
chmod 600 /etc/default/minio
systemctl enable -q --now minio
msg_ok "Installed MinIO Object Storage"

fetch_and_deploy_gh_release "mcli" "minio/mc" "singlefile" "latest" "/usr/local/bin" "mc.linux-amd64.RELEASE.*Z"

msg_info "Creating Media Bucket"
for _ in {1..30}; do
  curl -fsS -m 2 http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS -m 2 http://127.0.0.1:9000/minio/health/live >/dev/null
# Credentials via environment, not argv, so they never appear in process lists.
# --config-dir: the client derives its config dir from the binary name, and
# ~/.mcli is already taken by fetch_and_deploy_gh_release's version file.
export MC_HOST_local="http://${S3_ACCESS_KEY}:${S3_SECRET_KEY}@127.0.0.1:9000"
$STD mcli --config-dir /root/.config/mcli mb --ignore-existing local/buzz-media
$STD mcli --config-dir /root/.config/mcli anonymous set none local/buzz-media
unset MC_HOST_local
msg_ok "Created Media Bucket"

setup_rust
NODE_VERSION="24" setup_nodejs
export PATH="$HOME/.cargo/bin:$PATH"

# The relay ships as relay-v<version> tags (no GitHub release objects); the
# desktop-v* release lane is a different product and must not be tracked here.
RELEASE=$(get_latest_gh_tag "block/buzz" "relay-v")
fetch_and_deploy_gh_tag "buzz" "block/buzz" "${RELEASE}" "/opt/buzz"

msg_info "Building Buzz Server (Patience)"
cd /opt/buzz
# Build parallelism scales to the memory actually granted (release rustc jobs
# peak ~1.5 GB each): 4 GB default -> 2 jobs. Granting more CPU/RAM at
# creation widens the build automatically.
JOBS=$(($(free -m | awk '/^Mem:/{print $2}') / 1536))
((JOBS < 1)) && JOBS=1
((JOBS > $(nproc))) && JOBS=$(nproc)
$STD cargo build --release --locked -j "${JOBS}" -p buzz-relay --bin buzz-relay -p buzz-admin --bin buzz-admin -p buzz-pair-relay --bin buzz-pair-relay
msg_ok "Built Buzz Server"

msg_info "Building Web Bundles"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export NODE_OPTIONS="--max-old-space-size=2048"
$STD corepack enable
$STD pnpm install --frozen-lockfile --filter buzz-web --filter buzz-admin-web
$STD pnpm -C web build
$STD pnpm -C admin-web build
msg_ok "Built Web Bundles"

msg_info "Deploying Artifacts"
install -m 0755 /opt/buzz/target/release/buzz-relay /opt/buzz/target/release/buzz-admin /opt/buzz/target/release/buzz-pair-relay /usr/local/bin/
mkdir -p /srv/buzz
cp -r /opt/buzz/web/dist /srv/buzz/web
cp -r /opt/buzz/admin-web/dist /srv/buzz/admin-web
touch /opt/buzz/.buzz-build-ok
msg_ok "Deployed Artifacts"

msg_info "Generating Configuration"
mkdir -p /opt/buzz_data/git /opt/buzz_data/backups
install -d -m 700 /opt/buzz_data/config
RELAY_KEY=$(buzz-admin generate-key | awk '/^Secret key:/ {print $3}')
if [[ -z "${var_owner_pubkey:-}" ]]; then
  # Operator supplied no identity: generate one and park it root-only for
  # exactly one pickup. Never printed to the install log.
  buzz-admin generate-key >/opt/buzz_data/config/owner-key.txt
  chmod 600 /opt/buzz_data/config/owner-key.txt
  var_owner_pubkey=$(awk '/^Public key:/ {print $3}' /opt/buzz_data/config/owner-key.txt)
  # The desktop app's key import only accepts bech32 (nsec1…), not the hex
  # buzz-admin prints — append the converted form (python3 is in the template).
  awk '/^Secret key:/ {print $3}' /opt/buzz_data/config/owner-key.txt | python3 -c '
import sys
data = bytes.fromhex(sys.stdin.read().strip())
assert len(data) == 32
CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for x in v:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ x
        for i in range(5):
            chk ^= GEN[i] if (b >> i) & 1 else 0
    return chk
acc = 0; bits = 0; d = []
for b in data:
    acc = (acc << 8) | b; bits += 8
    while bits >= 5:
        bits -= 5; d.append((acc >> bits) & 31)
if bits: d.append((acc << (5 - bits)) & 31)
hrp = [ord(c) >> 5 for c in "nsec"] + [0] + [ord(c) & 31 for c in "nsec"]
chk = polymod(hrp + d + [0] * 6) ^ 1
print("nsec1" + "".join(CH[x] for x in d) + "".join(CH[(chk >> 5 * (5 - i)) & 31] for i in range(6)))
' | sed 's/^/Secret key (nsec): /' >>/opt/buzz_data/config/owner-key.txt
  cat <<EOF >>/opt/buzz_data/config/owner-key.txt
This keypair owns this Buzz community (RELAY_OWNER_PUBKEY).
In the Buzz desktop app: paste the "Secret key (nsec)" value into the key
import, then Add community -> "Join an existing community" -> enter:
ws://${LOCAL_IP}:3000
(type the ws:// scheme; the form assumes wss:// for bare hostnames — use your
domain instead once you serve this relay through a reverse proxy).
Do not use "Create": that is Builderlab's hosted flow; this relay already is
your community. Verify you can sign in, then delete this file. It is not
needed by the relay at runtime.
EOF
fi
if [[ "${var_relay_open:-no}" == "yes" ]]; then
  REQUIRE_MEMBERSHIP="false"
else
  REQUIRE_MEMBERSHIP="true"
fi
cat <<EOF >/opt/buzz_data/config/buzz.env
# Buzz relay configuration — reference: block/buzz deploy/compose/.env.example
#
# To publish behind a reverse proxy later, set:
#   RELAY_URL=wss://<domain>
#   BUZZ_MEDIA_BASE_URL=https://<domain>/media
#   BUZZ_MEDIA_SERVER_DOMAIN=<domain>
#   BUZZ_CORS_ORIGINS=https://<domain>
# then: systemctl restart buzz-relay
# The proxy must pass WebSocket upgrades, allow long read timeouts (relay
# connections are long-lived) and client_max_body_size >= 52M (media uploads).
# Do it BEFORE inviting members: the relay scopes its community by RELAY_URL's
# hostname and answers only under it — content created under the old authority
# is orphaned by a change.
DATABASE_URL=postgres://buzz:${PG_DB_PASS}@127.0.0.1:5432/buzz
REDIS_URL=redis://:${REDIS_PASS}@127.0.0.1:6379
BUZZ_BIND_ADDR=0.0.0.0:3000
BUZZ_HEALTH_PORT=8080
BUZZ_METRICS_PORT=9102
RELAY_URL=ws://${LOCAL_IP}:3000
BUZZ_MEDIA_BASE_URL=http://${LOCAL_IP}:3000/media
BUZZ_MEDIA_SERVER_DOMAIN=${LOCAL_IP}
BUZZ_CORS_ORIGINS=http://${LOCAL_IP}:3000
BUZZ_REQUIRE_AUTH_TOKEN=true
BUZZ_REQUIRE_RELAY_MEMBERSHIP=${REQUIRE_MEMBERSHIP}
BUZZ_ALLOW_NIP_OA_AUTH=true
BUZZ_AUTO_MIGRATE=false
BUZZ_GIT_CONFORMANCE_PROBE=true
RELAY_OWNER_PUBKEY=${var_owner_pubkey}
BUZZ_RELAY_PRIVATE_KEY=${RELAY_KEY}
BUZZ_GIT_HOOK_HMAC_SECRET=$(openssl rand -hex 32)
BUZZ_GIT_REPO_PATH=/opt/buzz_data/git
BUZZ_GIT_PACK_CACHE_PATH=/opt/buzz_data/git/.pack-cache
BUZZ_S3_ENDPOINT=http://127.0.0.1:9000
BUZZ_S3_ACCESS_KEY=${S3_ACCESS_KEY}
BUZZ_S3_SECRET_KEY=${S3_SECRET_KEY}
BUZZ_S3_BUCKET=buzz-media
BUZZ_S3_REGION=us-east-1
BUZZ_S3_ADDRESSING_STYLE=path
BUZZ_WEB_DIR=/srv/buzz/web
BUZZ_ADMIN_WEB_DIR=/srv/buzz/admin-web
RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info
EOF
chmod 600 /opt/buzz_data/config/buzz.env
msg_ok "Generated Configuration"

msg_info "Running Database Migrations"
set -a
source /opt/buzz_data/config/buzz.env
set +a
$STD buzz-admin migrate
msg_ok "Ran Database Migrations"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/buzz-relay.service
[Unit]
Description=Buzz Relay
Wants=network-online.target
After=network-online.target postgresql.service redis-server.service minio.service
Requires=postgresql.service redis-server.service minio.service

[Service]
Type=simple
WorkingDirectory=/opt/buzz_data
EnvironmentFile=/opt/buzz_data/config/buzz.env
ExecStart=/usr/local/bin/buzz-relay
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now buzz-relay
for _ in {1..30}; do
  curl -fsS -m 2 http://127.0.0.1:8080/_readiness >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS -m 2 http://127.0.0.1:8080/_readiness >/dev/null
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
