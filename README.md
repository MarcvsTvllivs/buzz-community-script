# Buzz — Proxmox VE LXC installer (Community Scripts style)

A [community-scripts/ProxmoxVED](https://github.com/community-scripts/ProxmoxVED)-compatible
installer for [Buzz](https://github.com/block/buzz), Block's self-hostable
human+agent workspace built on a Nostr relay.

It provisions a Debian 13 LXC and installs the full native stack — no Docker:

| Component | How |
|---|---|
| `buzz-relay`, `buzz-admin`, `buzz-pair-relay` | Built from source at the newest `relay-v*` tag (`cargo build --release --locked`, Rust toolchain pinned by upstream's `rust-toolchain.toml`) |
| Web + admin bundles | `pnpm` (corepack) + Vite, served by the relay from `/srv/buzz` |
| PostgreSQL 17 | community-scripts `setup_postgresql` helpers, `pgcrypto` enabled |
| Redis | Debian package, password + AOF, loopback only |
| MinIO | Vendor `.deb` pinned to the exact release upstream pins in `deploy/compose/compose.yml`, loopback only |

## Usage

On a Proxmox VE host:

```bash
git clone https://github.com/MarcvsTvllivs/buzz-community-script.git
cd buzz-community-script
bash ct/buzz.sh
```

Defaults are production-sized — **2 vCPU / 4 GB RAM / 20 GB disk** — and the
source build scales its parallelism to whatever CPU/RAM the container actually
has, so granting more (at creation, or `pct set` before an update) just makes
rebuilds faster.

The community-scripts `core` engine resolves `install/buzz-install.sh` from this
checkout automatically (or from this repo's raw URL via the git origin). Run the
same command again later to update: it tracks upstream `relay-v*` tags, takes a
`pg_dump` safety backup, rebuilds, migrates, and verifies `/_readiness` before
reporting success.

### Fully unattended (no TTY — proven on PVE 9.2.10)

```bash
ssh root@<pve-host> 'export TERM=xterm PHS_SILENT=1 mode=default \
  var_ctid=603 var_hostname=buzz \
  var_net=10.13.37.33/24 var_gateway=10.13.37.1 \
  var_container_storage=local-zfs var_template_storage=local \
  COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/MarcvsTvllivs/buzz-community-script/main; \
  bash <(curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/buzz-community-script/main/ct/buzz.sh)'
```

- `TERM` must name a real terminfo entry — `dumb` dies at the first `clear`.
- `mode=default` skips the whiptail menu; `PHS_SILENT=1` auto-answers auxiliary prompts.
- `COMMUNITY_SCRIPTS_URL` points the engine at this repo for `install/buzz-install.sh`
  when running via curl/tarball (no git origin to detect), and is baked into the
  container's `/usr/bin/update` shim so later `update` runs resolve here too.
- Omit `var_net`/`var_gateway` for DHCP.

### Unattended / preseeded values (`app_vars`)

| Variable | Meaning | Default |
|---|---|---|
| `var_owner_pubkey` | Your Nostr public key (64-char hex) as community owner | unset → keypair generated into `/opt/buzz_data/config/owner-key.txt` (root-only) |
| `var_relay_open` | `yes` disables the membership requirement | `no` (closed relay) |

Example: `var_owner_pubkey=<hex> bash ct/buzz.sh`

## Layout inside the container

```
/opt/buzz/                 replaceable source + build tree (wiped on update)
/usr/local/bin/            buzz-relay, buzz-admin, buzz-pair-relay, mcli
/srv/buzz/                 web + admin-web bundles
/opt/buzz_data/config/     buzz.env (0600), owner-key.txt if generated (0600)
/opt/buzz_data/git/        relay git hosting data
/opt/buzz_data/backups/    pg_dump taken before each update (last 3 kept)
/var/lib/postgresql|redis|minio   database / cache / object storage
```

Updates never touch `/opt/buzz_data` or `/var/lib/*`; a failed build or
migration leaves the previous binaries in `/usr/local/bin` and the data intact.

## After first install

1. Read the recovery file (`pct exec <ctid> -- cat /opt/buzz_data/config/owner-key.txt`,
   or use the key you supplied) and paste the **"Secret key (nsec)"** value into the
   Buzz desktop app's key import. The form accepts bech32 (`nsec1…`) only — raw hex
   is silently rejected with a greyed-out button.
2. **Add community → "Join an existing community"** → enter `ws://<container-ip>:3000`.
   Include the `ws://` scheme — the form assumes `wss://` for bare hostnames. The
   "Create" option is Builderlab's hosted flow and is not needed for self-hosting:
   your relay already is a community, and you are its owner.
3. Once signed in, delete the recovery file:
   `pct exec <ctid> -- rm /opt/buzz_data/config/owner-key.txt`
4. Add members: `buzz-admin add-member --pubkey <npub-or-hex>` (inside the container,
   with `set -a; source /opt/buzz_data/config/buzz.env; set +a` first). Members join
   with the same URL via the same "Join an existing community" flow.

## Publishing behind a reverse proxy (later, optional)

The installer configures plain `ws://<container-ip>:3000` and deliberately does no
reverse-proxy or TLS setup. To publish under a domain: edit
`/opt/buzz_data/config/buzz.env` — its header documents the four URL keys
(`RELAY_URL=wss://<domain>`, media base/domain, CORS) — then
`systemctl restart buzz-relay`. Your proxy must pass WebSocket upgrades, allow
long read timeouts, and accept bodies ≥ 52 MB (media uploads). **Do it before
inviting members:** the relay scopes its community by `RELAY_URL`'s hostname and
answers only under it, so content created under the old authority is orphaned by
a change. Clients then join with the bare domain (the app normalizes it to
`wss://<domain>`).

## Status

- Validated: `bash -n`, ShellCheck, `jq` metadata checks, fixture tests for
  config generation and ct/json agreement (see repo history for the run).
- **Real-Proxmox verified** (PVE 9.2.10, 2026-08-11): fresh unattended install,
  reboot persistence, explicit migrations, readiness gate, and WSS through a
  reverse proxy with valid TLS. Failed-update rollback and vzdump restore not
  yet exercised.
- **Not submitted to ProxmoxVED**, deliberately: upstream Buzz (created
  2026-03-06) misses the 6-month project-age gate until 2026-09-06 and
  publishes no server release artifacts (source builds only). Everything else
  follows current ProxmoxVED conventions so a future submission is a copy.

License: MIT, matching community-scripts. Buzz itself is Apache 2.0 by Block, Inc.
