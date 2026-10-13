# Hero OOS self-hosting examples

These are portable deployment examples for a dedicated Debian host with Python 3.11+, nginx, systemd and a domain you control. They do not contain a running service, account, token, database, signing key or update package. The API and data constraints are documented in [server/README.md](../server/README.md).

## Layout and installation

Use a dedicated non-login `hero-oos` service user. Install `server/server.py`, `server/backup.py`, and `deploy/daily-backup.py` under `/opt/hero-oos`. Create `/opt/hero-oos/venv` with Python 3.11+ and install `server/requirements.lock` into it. Code and dependencies should be administrator-owned and not writable by the service user. The examples assume:

| Path | Access |
| --- | --- |
| `/etc/hero-oos/config.json` | root-owned, group `hero-oos`, mode `0640` |
| `/var/lib/hero-oos` | service-owned, mode `0700` |
| `/var/lib/hero-oos/state.sqlite3` | service-owned, mode `0600` |
| `/var/lib/hero-oos/backups` | private backup directory, never web-readable |
| `/var/www/hero-oos-acme` | public ACME challenge files only |
| `/var/www/hero-oos-updates` | public, signed release packages and indexes only |

Adapt paths consistently in config, units and scripts if changing this layout. The Python application only binds `127.0.0.1`; do not expose its port directly. A single service instance must own the SQLite database. The example runs on port `4180`; change both nginx and backup health checks if changing it.

## First owner

Generate bootstrap material on the owner's Mac, outside this checkout:

```sh
python3 deploy/prepare-bootstrap.py \
  --token-file "$HOME/Library/Application Support/Hero OOS/cloud-bootstrap-token" \
  --config-output "$HOME/.config/hero-oos/server-config.json"
```

The tool refuses existing config files and symlink outputs. It creates a random token file with mode `0600` and a separate server config containing only its SHA-256 digest. Keep the token on the owner's Mac. Transfer only the generated config to `/etc/hero-oos/config.json` using an authenticated private administrative channel; restore the ownership and permissions above. Never add either generated file to Git, logs, a public download directory or an issue.

Install `hero-oos.service` in the host's systemd unit directory and review it before enabling it. In the native app, select your own HTTPS service URL, enter the desired initial organization name and create the first owner. The organization name is deployment-specific, not hardcoded. Bootstrap requires the secret and succeeds only once. After success, remove `bootstrapTokenHash` from the server config and restart the service to disable bootstrap explicitly. The native flow consumes its local bootstrap token after successful setup.

## HTTPS and nginx

Replace **every `example.com`** in `nginx-bootstrap.conf` and `nginx.conf` with your domain. These files belong in nginx's `http` context, such as a dedicated site include; they are not whole nginx configurations. Do not overwrite unrelated virtual hosts.

1. Point DNS at the host and permit the required HTTP/HTTPS traffic. Install the bootstrap site first. Its `/health` response confirms only the temporary web server setup, not the application/database.
2. Obtain a TLS certificate for your domain using an ACME client and webroot `/var/www/hero-oos-acme`. The final example expects `/etc/letsencrypt/live/example.com/{fullchain,privkey}.pem`; adapt to the actual certificate name.
3. Replace the bootstrap site with the final site and run `nginx -t` before reloading. Never enable both files as duplicate virtual hosts.
4. Check `https://your-domain/health` after switching. The proxied endpoint performs a database probe and returns the service API version without user data.

nginx overwrites `X-Real-IP` with `$remote_addr`, terminates TLS, imposes body/rate/time limits and disables access logs. Do not trust externally supplied forwarding headers or add tokens, query strings or bodies to logs. If a separate trusted proxy is added, configure and audit its real-IP trust boundary deliberately.

The optional renewal unit expects Certbot installed at `/opt/hero-oos-certbot/bin/certbot`; adapt to the actual installation. Use either the provided six-hour renewal timer or your ACME client's existing renewal schedule. A successful renewal tests nginx before reloading. Check timer status and certificate validity regularly.

## Backup and restore

The backup service uses SQLite's online backup API, validates the snapshot and keeps seven daily snapshots. It refuses to delete older backups if a new or existing daily snapshot fails validation. Install the backup service/timer after the primary service is healthy. These snapshots are on the same host; arrange private off-host backups for disaster recovery.

Database effective-page quota is 256 MiB shared across accounts, with 512 MiB free-disk reserve on new document writes. WAL, backups and release packages consume additional disk space. Monitor actual disk use.

For recovery, stop the service, preserve the current database and its WAL/SHM files, validate a backup with SQLite `quick_check`, then restore its ownership and mode. Keep old files until recovery is verified. Never replace a live SQLite main file or roll a database schema backward to downgrade an app.

## Privacy and update releases

Task documents use server-enforced organization and user scopes. This is API access control plus TLS, **not end-to-end encryption against the server operator**. Collages, images, local paths and Codex context are excluded from cloud task documents.

If hosting native updates, create your own Sparkle Ed25519 signing identity and configure your own HTTPS update URLs/public key in the native build. Keep private signing keys on the release workstation, never in this repository or on the web server. Upload immutable signed packages before atomically replacing signed indexes. Preserve release identity and schema compatibility when considering a rollback. Code signing/notarization and update signatures are separate checks; do not disable Gatekeeper or TLS verification.

The repository does not deploy these examples automatically. A complete Linux/systemd/nginx deployment must be validated on your own host before production use.
