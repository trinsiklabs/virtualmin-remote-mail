# virtualmin-remote-mail

A Virtualmin plugin that manages email services on a remote mail server. When a domain is created on the web hosting server and this feature is enabled, the plugin automatically provisions DNS records, Postfix transports, Dovecot mailboxes, OpenDKIM signing, and SSL certificates on the remote mail server.

## Architecture

This plugin is designed for a split-server setup:

- **Web server** (e.g., vh1): Runs Virtualmin, Nginx, PHP-FPM, MariaDB. Manages domains and DNS.
- **Mail server** (e.g., vh2): Runs Postfix, Dovecot, OpenDKIM, BIND. Handles all email.

Communication uses:
- **Webmin RPC** (`remote_foreign_call` via `fastrpc.cgi`) for service configuration
- **SSH** for file operations (SSL cert sync, disk usage, certbot hook deployment)

## What It Does

When the "Remote Mail Server" feature is enabled for a domain:

1. **DNS** (on web server): Creates MX, SPF, DKIM, DMARC records and mail host A records
2. **Postfix** (on mail server): Adds virtual domain, sender-dependent transport maps
3. **Dovecot** (on mail server): Creates Maildir structure for the domain
4. **OpenDKIM** (on mail server): Generates signing keys, configures signing/key tables
5. **SSL** (web → mail): Syncs SSL certificates, rebuilds Postfix SNI map with `postmap -F`
6. **Certbot hook** (on mail server): Deploys a deploy hook that rebuilds the SNI map on cert renewal

When the feature is removed, everything is cleaned up in reverse.

## Quick Install

```bash
# Install the plugin on the web server:
curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash

# Optionally, auto-configure the remote mail server too:
curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash -s -- --setup-remote vh2.trinsik.io
```

The `--setup-remote` flag will:
- Test SSH connectivity to the remote server
- Enable Webmin RPC permissions for the root user
- Deploy the certbot SNI sync hook
- Rebuild the Postfix SNI map with `postmap -F`

## Prerequisites

### On the web server (where Virtualmin runs)

1. **Virtualmin** installed and working
2. **SSH key authentication** to the mail server as root:
   ```bash
   ssh-keygen -t ed25519  # if no key exists
   ssh-copy-id root@mail-server
   ```

### On the mail server

1. **Webmin** installed (the plugin uses Webmin RPC for Postfix/Dovecot configuration)
2. **Postfix** installed and configured for virtual mailbox domains
3. **Dovecot** installed and configured for virtual users
4. **OpenDKIM** installed (for DKIM signing)
5. **Certbot** installed (for Let's Encrypt certificate management)

### Webmin RPC Configuration (Critical)

The plugin communicates with the mail server via Webmin RPC (`fastrpc.cgi`). This requires:

1. **The root user must have RPC permission** on the mail server's Webmin. Verify:
   ```bash
   # On the mail server:
   cat /etc/webmin/webmin/root.acl
   ```
   If it doesn't contain `rpc=1` (or `rpc=2`), add it:
   ```bash
   echo "rpc=1" >> /etc/webmin/webmin/root.acl
   ```

2. **Webmin must allow HTTP basic auth for RPC callers.** Webmin automatically allows basic auth when the `User-Agent` header contains "Webmin" (which the RPC client sets). No manual configuration needed — but if you've added `sessiononly=` entries to `/etc/webmin/miniserv.conf` that restrict `rpc.cgi` or `fastrpc.cgi`, remove them.

3. **The password in the plugin config must match** the Webmin root password on the mail server. If the mail server uses PAM authentication (`passwd_mode=0` in `miniserv.conf`), this is the system root password. If it uses Webmin internal auth (`passwd_mode=2`), it's the password set via `changepass.pl`.

The `--setup-remote` flag in `install.sh` automates step 1. Steps 2-3 must be configured manually in the Webmin UI when adding the mail server.

### Postfix SNI Map (Important)

The plugin manages per-domain SSL certificates for Postfix using `tls_server_sni_maps`. This map **must** be built with `postmap -F` (not plain `postmap`). The `-F` flag base64-encodes certificate file contents into the hash table, which is required by Postfix for SNI lookups.

**Why this matters:** If `postmap` is run without `-F` (e.g., by a manual edit or a script), the SNI map breaks for ALL domains — Postfix will log `malformed BASE64 value` errors and TLS will fail.

The plugin handles this automatically:
- `sync_remote_mail_ssl()` runs `postmap -F` after copying certs
- The certbot deploy hook runs `postmap -F` after any cert renewal
- `feature_setup` deploys the hook if not already present

## Configuration

After installation, add a remote mail server in Webmin (Servers > Remote Mail Server):

| Field | Description |
|-------|-------------|
| Mail server hostname | The hostname of the mail server (used for DNS A records) |
| Webmin RPC hostname | Hostname for Webmin RPC (usually same as mail server) |
| Webmin port | Default: 10000 |
| Use SSL for Webmin | Yes (recommended) |
| Webmin username | `root` |
| Webmin password | The root password on the mail server's Webmin |
| SSH hostname | Hostname for SSH (usually same as mail server) |
| SSH username | `root` |
| SSH private key path | Path to the SSH key (e.g., `/root/.ssh/id_ed25519`) |
| Spam gateway IP | Optional: IP of inbound spam filter (e.g., MailChannels) |
| Spam gateway hostname prefix | Optional: hostname prefix for MX record (default: `mg`) |
| Outgoing relay server | Optional: SMTP relay for outbound mail |
| Outgoing relay port | Default: 25 |
| DKIM selector | Default: `202307` |

## SSL Certificate Lifecycle

Certificates flow through several paths depending on where the renewal happens:

### Web server renewal (Virtualmin/certbot on vh1)

1. Virtualmin renews cert → calls `feature_modify` for all plugins
2. Plugin detects `ssl_changed` → calls `sync_remote_mail_ssl`
3. Certs SCP'd to `/home/{domain}/ssl/` on mail server
4. `ssl.combined` built (key first, then fullchain)
5. `postmap -F hash:/etc/postfix/sni_map` rebuilds SNI map
6. Postfix restarted, Dovecot reloaded

### Mail server renewal (certbot on vh2)

1. Certbot renews cert → deploy hook fires
2. Hook copies certs to `/home/{domain}/ssl/`
3. `ssl.combined` rebuilt
4. `postmap -F hash:/etc/postfix/sni_map` rebuilds SNI map
5. Postfix restarted, Dovecot reloaded

### Important: postmap -F

The Postfix SNI map (`tls_server_sni_maps`) stores base64-encoded certificate contents, not file paths. Running `postmap` without `-F` corrupts the map. All code paths in this plugin use `postmap -F`.

## Testing

```bash
cd /usr/share/webmin/virtualmin-remote-mail

# Run unit tests (no server access needed)
prove t/01-lib.t t/02-feature.t t/03-dns.t t/04-user.t t/05-ssl.t

# Run integration tests (requires real servers)
REMOTE_MAIL_INTEGRATION=1 prove t/06-integration.t
```

## Troubleshooting

### "Connectivity test failed: Webmin RPC test failed:"

Empty error after "test failed:" means the RPC call returned no response. Common causes:

1. **Missing `remote_foreign_require`**: Fixed in v1.1+ — the plugin now calls `remote_foreign_require` before `remote_foreign_call` to establish the fastrpc session.

2. **RPC permission denied**: Check `/etc/webmin/webmin/root.acl` on the mail server — must contain `rpc=1` or `rpc=2`.

3. **Wrong password**: The Webmin password in the plugin config must match the mail server's Webmin root password. If using PAM auth (`passwd_mode=0`), it's the system root password.

4. **Firewall**: fastrpc uses a random high port (10001+) for the persistent connection. Ensure the web server can reach the mail server on ports 10000-10100.

### "malformed BASE64 value" in Postfix logs

The SNI map was built with `postmap` instead of `postmap -F`. Fix:
```bash
postmap -F hash:/etc/postfix/sni_map
systemctl restart postfix
```

### SSL cert not served for a domain

Check the SNI map entry exists and the cert files are at `/home/{domain}/ssl/`:
```bash
postmap -Fq domain.com hash:/etc/postfix/sni_map | head -5
ls -la /home/domain.com/ssl/
```

## File Structure

```
module.info                    # Module metadata (hidden plugin)
defaultacl                     # Default ACL
config / config.info           # Module configuration
virtualmin-remote-mail-lib.pl  # Core library (RPC, SSH, DNS builders, state, certbot hook)
virtual_feature.pl             # Virtualmin feature hooks
edit.cgi                       # Main module page
edit_servers.cgi               # Add/edit mail servers
save_server.cgi                # Save server config (deploys certbot hook)
edit_domain.cgi                # Per-domain mail settings
save_domain.cgi                # Per-domain actions
cgi_args.pl                    # URL argument defaults
log_parser.pl                  # Webmin action log parser
lang/en                        # Language strings
help/feat.html                 # Feature help page
t/                             # Test suite
```

## Feature Hooks

| Hook | Purpose |
|------|---------|
| `feature_setup` | Provisions DNS + Postfix + Dovecot + DKIM + SSL + certbot hook |
| `feature_delete` | Tears down all remote configuration |
| `feature_modify` | Handles domain rename + SSL cert changes |
| `feature_disable` / `feature_enable` | Suspend/unsuspend mail flow |
| `feature_validate` | Verifies remote config matches state |
| `feature_clash` | Prevents conflict with local mail feature |
| `feature_depends` | Requires DNS feature |
| `feature_backup` / `feature_restore` | Domain backup/restore support |

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full text.
