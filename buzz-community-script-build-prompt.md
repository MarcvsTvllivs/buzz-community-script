# Build a Proxmox Community Scripts–Style Installer for Buzz

## Objective

Build a complete, working, Proxmox Community Scripts–compatible installer for **Buzz**:

- Buzz upstream: <https://github.com/block/buzz>
- Community Scripts development repository: <https://github.com/community-scripts/ProxmoxVED>
- Community Scripts production repository: <https://github.com/community-scripts/ProxmoxVE>

The result must provision Buzz in a dedicated Debian 13 LXC and follow the current Community Scripts conventions closely enough to be a credible future submission to `ProxmoxVED`.

This is an implementation task, not a planning exercise. Produce the files, execute all validation available in the environment, and report actual test results. Do not stop after creating stubs or describing commands.

## Scope and safety boundaries

1. Work only in a dedicated checkout or working directory for this task.
2. Do not modify a live Buzz installation, existing LXC, Proxmox host, Hermes configuration, credentials, DNS, reverse proxy, or firewall unless the user separately and explicitly authorizes it.
3. Do not open an issue, push a branch, or submit a pull request unless explicitly instructed after the implementation has been reviewed.
4. Never invent successful test output. Clearly distinguish:
   - static validation;
   - mocked/fixture testing;
   - disposable local service testing;
   - real Proxmox LXC lifecycle testing.
5. Do not expose secrets in logs, command arguments, diffs, test fixtures, or agent summaries.
6. Preserve user data, keys, configuration, and database state across updates. Update behavior must be reversible and idempotent.

## Mandatory prerequisite research

Before editing anything:

1. Inspect the current versions of:
   - `ProxmoxVED/AGENTS.md`
   - `ProxmoxVED/.github/agents/pve-script-creator.agent.md`
   - `ProxmoxVED/.github/pull_request_template.md`
   - `ProxmoxVE/CONTRIBUTING.md`
   - the current Community Scripts core helper functions used by CT and install scripts.
2. Confirm the exact repository root, branch, remote, HEAD, and working-tree status.
3. Inspect several current, comparable Community Scripts applications, especially ones that:
   - install a Rust application;
   - install PostgreSQL and Redis;
   - run multiple systemd services;
   - manage generated secrets and persistent data;
   - expose an HTTP/WebSocket service;
   - support migrations and update rollback.
4. Inspect current Buzz primary sources, including at minimum:
   - `README.md`
   - `ARCHITECTURE.md`
   - `SECURITY.md`
   - `deploy/compose/README.md`
   - `deploy/compose/.env.example`
   - Cargo workspace/crate manifests for `buzz-relay`, `buzz-admin`, `buzz-cli`, and migration/database crates;
   - the current database migrations;
   - current release tags and release assets.
5. Determine and document from source—not assumptions:
   - required Rust and Node versions;
   - whether the relay can be built and run without the desktop application;
   - exact binaries required on the server;
   - exact PostgreSQL version and extensions;
   - exact Redis requirements;
   - exact object-storage/S3 behavior;
   - whether MinIO is mandatory or replaceable with a local filesystem mode;
   - exact migration/bootstrap commands;
   - health/readiness endpoints;
   - required environment variables;
   - closed-relay owner/member bootstrap procedure;
   - update compatibility and migration behavior;
   - amd64/arm64 support based on actual dependencies and verified builds.
6. If upstream behavior is ambiguous or contradictory, stop and resolve it from source/tests or ask the user. Do not guess a deployment contract.

## Community Scripts constraints

Follow the latest repository instructions, even if they differ from this prompt. In particular:

- **No Docker or Docker Compose.** Install components directly inside the LXC.
- Use Community Scripts helper functions instead of custom download, runtime, database, version-check, backup, TLS, or repository setup logic whenever an appropriate helper exists.
- Do not use `git pull` as an updater.
- Do not hand-roll release checks when `check_for_gh_release` or an equivalent helper applies.
- Use explicit release deployment modes with the appropriate `fetch_and_deploy_*` helper.
- Prefix package/build commands with `$STD` as required by the repository conventions.
- Do not use `sudo` inside the LXC.
- Do not create unnecessary system users or pointless path variables.
- Do not put `export` statements in `.env` files.
- Do not create throwaway external install scripts when commands can be executed directly.
- Keep persistent data and irreplaceable configuration outside any application directory wiped by `CLEAN_INSTALL=1`.
- Use `create_backup`/`restore_backup` only where data cannot be relocated outside the replaced application tree.
- Never back up persistent data to `/tmp`.

## Required deliverables

Create exactly the standard three application files, using the current repository naming and casing conventions:

```text
ct/buzz.sh
install/buzz-install.sh
json/buzz.json
```

Add tests only where the repository convention permits them. Do not add unrelated files.

### `ct/buzz.sh`

It must:

- source the current Community Scripts `build.func` in the standard way;
- define `APP="Buzz"`;
- use Debian 13;
- provide justified defaults for CPU, RAM, disk, tags, architecture, GPU, and privileged/unprivileged mode;
- export every configurable `var_*` value that the install script consumes;
- implement a real `update_script()`;
- perform storage/resource checks before updates;
- preserve all persistent state and secrets;
- stop services in dependency-safe order;
- deploy and migrate the new version;
- restart services and verify readiness;
- fail safely and leave a recoverable state if an update or migration fails;
- finish with the required Community Scripts `start`, `build_container`, `description`, and access-information flow.

Do not claim arm64 support unless the complete native server stack has been verified on arm64. Ensure `var_arm64` and JSON `architectures` agree exactly.

### `install/buzz-install.sh`

It must perform a native installation—no containers inside the LXC—and must:

1. Run the required Community Scripts initialization sequence.
2. Install dependencies using repository helpers and current Debian packages where suitable.
3. Install/configure PostgreSQL using the Community Scripts database helpers.
4. Install/configure Redis securely.
5. Install an S3-compatible object-store component only if current Buzz genuinely requires it. If MinIO is required:
   - install it natively;
   - pin or track a defensible release source;
   - configure it as a managed systemd service;
   - keep data outside the replaceable Buzz source tree;
   - generate credentials securely.
6. Acquire and build/install only the Buzz server-side crates and assets actually required. Do not build the desktop client unless source inspection proves that the relay requires desktop-generated assets.
7. Generate cryptographically strong, stable secrets for:
   - relay signing identity;
   - owner/bootstrap identity where appropriate;
   - PostgreSQL;
   - Redis;
   - S3/object storage;
   - Git hook HMAC or other required Buzz secrets.
8. Store secret configuration with restrictive ownership and mode. Do not print private keys or passwords to normal logs.
9. Handle owner-key delivery carefully:
   - determine what the operator must retain to control the community;
   - display it once only if unavoidable;
   - preferably write it to a root-only recovery file and clearly report that path;
   - never place it in the public JSON metadata or MOTD.
10. Configure closed-relay production defaults unless source inspection shows they currently prevent first-owner onboarding. The completed installer must provide a tested bootstrap path that does not lock the operator out.
11. Run database migrations using the exact supported Buzz mechanism.
12. Create dependency-aware systemd services with sensible restart policy, ordering, health behavior, and environment-file handling.
13. Bind internal databases/object storage to loopback or private interfaces only. Expose only the Buzz relay/interface port required by clients.
14. Do not automatically configure public DNS or obtain a public certificate. If HTTPS is necessary for correct client behavior, use the current Community Scripts TLS helper or clearly expose a configurable reverse-proxy path without weakening security.
15. End with `motd_ssh`, `customize`, and `cleanup_lxc` in the required order.

## Configuration design

Use `app_vars` for values an operator may reasonably supply up front, with guarded prompts only when a value is absent. Candidate values include, subject to current Buzz source behavior:

- public Buzz domain/host;
- relay URL;
- CORS origin;
- HTTP port;
- closed/open relay selection, defaulting to closed;
- optional externally supplied owner public key;
- optional TLS/reverse-proxy mode.

For every configurable value:

1. the install script must read the exact `var_*` name;
2. `ct/buzz.sh` must export it;
3. `json/buzz.json` must declare it in `app_vars`;
4. secret values must use `type: "password"` and `secret: true`;
5. prompts must have an unattended escape path;
6. JSON defaults must match shell defaults.

Do not expose generated private keys or database passwords as ordinary website-generator variables unless the Community Scripts standard explicitly requires that design.

## Persistent-data layout

Derive the final paths from Community Scripts conventions, but maintain a clear separation resembling:

```text
/opt/buzz/                 # replaceable application/source/build output
/opt/buzz_data/            # persistent Buzz application state/configuration
/opt/buzz_data/config/     # root-only environment and key material
/opt/buzz_data/git/        # persistent Git data, if required
/var/lib/postgresql/       # PostgreSQL data
/var/lib/redis/            # Redis data
/var/lib/minio/            # object data, if MinIO is required
```

The updater must never destroy or silently regenerate relay identity, owner identity, database credentials, object-store credentials, Git data, media, audit records, or channel/event history.

## `json/buzz.json`

Use the current metadata schema and include all mandatory fields, including:

- `name`
- `slug`
- `categories`
- `date_created`
- `type`
- `updateable`
- `privileged`
- `architectures` when support is known
- `interface_port`
- `documentation`
- `website`
- full upstream `repository` URL
- `logo`
- `description`
- `install_methods`
- `default_credentials`
- `notes`
- optional `platforms`
- optional `app_vars`

Ensure:

- resource settings match `ct/buzz.sh`;
- `config_path` is attached to the relevant install method, not incorrectly placed at top level;
- notes clearly warn that Buzz is pre-1.0 if that remains true;
- notes identify any required desktop-client, reverse-proxy, certificate, or owner-key onboarding step;
- metadata does not claim features or architectures that were not tested.

## Installation and update invariants

The implementation must enforce these invariants:

1. A fresh install produces exactly one functioning Buzz community and a usable owner-bootstrap path.
2. Re-running the installer does not silently overwrite a working installation.
3. Updating preserves:
   - relay and owner keys;
   - PostgreSQL content;
   - Redis configuration/state where needed;
   - media/object storage;
   - Git data;
   - audit history;
   - all operator configuration.
4. A failed migration does not report success and does not discard the old version or its data.
5. Services do not start against a partially migrated database.
6. Secret-bearing files remain owner-only after installation and update.
7. Internal services are not exposed publicly by default.
8. Health checks distinguish process liveness from actual readiness of the relay and its dependencies.
9. A second run of configuration reconciliation is idempotent and creates no duplicate active keys.

## Testing requirements

### Static and fixture tests

At minimum run and report:

```bash
bash -n ct/buzz.sh install/buzz-install.sh
shellcheck ct/buzz.sh install/buzz-install.sh
jq empty json/buzz.json
```

Also run the repository’s current lint, metadata, formatting, and validation commands. Inspect CI workflows to identify the exact local equivalents.

Create narrow fixture tests where practical for:

- `.env` generation;
- exactly-one-active-key reconciliation;
- secret file modes;
- owner/bootstrap configuration;
- fresh-install versus update behavior;
- preservation of persistent paths;
- amd64/arm64 metadata agreement;
- JSON resource agreement with `ct/buzz.sh`;
- service ordering and expected dependencies.

### Build and service validation

Where the environment permits:

- build the required Buzz server binaries from the exact selected release/tag;
- verify each binary identifies or starts correctly;
- initialize a temporary PostgreSQL/Redis/object-store environment;
- run migrations;
- start the relay;
- verify both liveness and dependency-backed readiness;
- create/bootstrap an owner identity;
- authenticate and perform at least one real relay/API operation;
- stop and restart the stack and verify persistence.

### Real Proxmox lifecycle validation

If a disposable Proxmox environment is available, test the actual script through:

1. fresh LXC creation;
2. default and advanced settings;
3. closed-relay owner onboarding;
4. restart/reboot persistence;
5. update to a newer compatible Buzz version;
6. failed-update rollback or recovery;
7. backup and restore;
8. deletion of the disposable test container.

If real Proxmox testing is unavailable, state that plainly. Do not label mocked execution as an end-to-end LXC test.

## Security review

Before considering the work complete:

- scan added lines and generated output for secrets;
- confirm no secrets are passed via process arguments;
- inspect file modes and service `EnvironmentFile` usage;
- verify PostgreSQL, Redis, and object storage do not listen publicly by default;
- verify the relay is not left in an unauthenticated/open state contrary to the selected mode;
- check command construction for shell injection;
- check URLs, versions, and release assets against authoritative upstream sources;
- verify SSRF-sensitive webhook defaults are not weakened;
- run `git diff --check`;
- stage only intended files;
- perform an independent review focused on security, idempotence, update preservation, and Community Scripts compliance.

## Upstream eligibility gate

Before proposing or opening an upstream PR, check the current `ProxmoxVED` PR requirements and verify with current data that Buzz:

- is at least six months old;
- is actively maintained;
- meets the minimum GitHub-star requirement;
- publishes acceptable official release tarballs/server artifacts;
- can be installed without Docker under Community Scripts policy.

If any criterion is not met, keep the implementation as a tested local/community-style installer and report the blocker. Do not misrepresent eligibility or submit prematurely.

## Required final report

Report:

1. exact files created or changed;
2. selected Buzz version/tag and why;
3. installation architecture and persistent-data layout;
4. generated-secret and owner-recovery design;
5. update and rollback behavior;
6. every command/test actually run and its real result;
7. what was not testable;
8. remaining risks or upstream gaps;
9. whether the result is:
   - local pilot ready;
   - real-Proxmox verified;
   - or upstream-submission ready.

Do not declare the installer complete merely because the three files exist. Completion requires the strongest feasible execution and verification, with unsupported claims clearly labeled.