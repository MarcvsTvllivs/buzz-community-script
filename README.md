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
  var_domain=buzz.example.com \
  COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/MarcvsTvllivs/buzz-community-script/main; \
  bash <(curl -fsSL https://raw.githubusercontent.com/MarcvsTvllivs/buzz-community-script/main/ct/buzz.sh)'
```

- `TERM` must name a real terminfo entry — `dumb` dies at the first `clear`.
- `mode=default` skips the whiptail menu; `PHS_SILENT=1` auto-answers auxiliary prompts.
- `COMMUNITY_SCRIPTS_URL` points the engine at this repo for `install/buzz-install.sh`
  when running via curl/tarball (no git origin to detect), and is baked into the
  container's `/usr/bin/update` shim so later `update` runs resolve here too.
- Omit `var_net`/`var_gateway` for DHCP; omit `var_domain` for plain `ws://<ip>:3000`.

### Unattended / preseeded values (`app_vars`)

| Variable | Meaning | Default |
|---|---|---|
| `var_domain` | Public domain; you terminate TLS at your own reverse proxy. Sets `RELAY_URL=wss://…`, media URL and CORS accordingly | unset → `ws://<container-ip>:3000` |
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

1. Import the owner secret key (from `/opt/buzz_data/config/owner-key.txt`, or
   the key you supplied) into the Buzz desktop app, point it at
   `ws://<container-ip>:3000`, then delete the recovery file.
2. Add members: `buzz-admin add-member --pubkey <npub-or-hex>` (inside the container,
   with `set -a; source /opt/buzz_data/config/buzz.env; set +a` first).

## Status

- Validated: `bash -n`, ShellCheck, `jq` metadata checks, fixture tests for
  config generation and ct/json agreement (see repo history for the run).
- **Not yet validated on a real Proxmox host** — no disposable PVE environment
  was available to the author at build time.
- **Not submitted to ProxmoxVED**, deliberately: upstream Buzz (created
  2026-03-06) misses the 6-month project-age gate until 2026-09-06 and
  publishes no server release artifacts (source builds only). Everything else
  follows current ProxmoxVED conventions so a future submission is a copy.

License: MIT, matching community-scripts. Buzz itself is Apache 2.0 by Block, Inc.
