# virtualmin-remote-mail

A Virtualmin plugin that manages email services on a remote mail server. When a domain is created on the web hosting server and this feature is enabled, the plugin automatically provisions DNS records, Postfix transports, Dovecot mailboxes, OpenDKIM signing, and SSL certificates on the remote mail server.

## Architecture

This plugin is designed for a split-server setup:

- **vh1** (web server): Runs Virtualmin, Nginx, PHP-FPM, MariaDB. Manages domains and DNS.
- **vh2** (mail server): Runs Postfix, Dovecot, OpenDKIM, BIND. Handles all email.

Communication uses:
- **Webmin RPC** (`remote_foreign_call`) for service configuration
- **SSH** for file operations (SSL cert sync, disk usage)

## What It Does

When the "Remote Mail Server" feature is enabled for a domain:

1. **DNS** (on vh1): Creates MX, SPF, DKIM, DMARC records and mail host A records
2. **Postfix** (on vh2): Adds virtual domain, sender-dependent transport maps
3. **Dovecot** (on vh2): Creates Maildir structure for the domain
4. **OpenDKIM** (on vh2): Generates signing keys, configures signing/key tables
5. **SSL** (vh1 → vh2): Syncs SSL certificates, reloads services

When the feature is removed, everything is cleaned up in reverse.

## Installation

```bash
# On the web server (vh1):
cd /usr/share/webmin
tar xzf virtualmin-remote-mail.wbm.gz

# Or copy directly:
cp -r virtualmin-remote-mail /usr/share/webmin/

# Register in Virtualmin:
# System Settings → Features and Plugins → enable "Remote Mail Server"
```

## Prerequisites

1. Webmin installed on both servers
2. vh2 registered in vh1's Webmin Servers Index (Webmin → Servers → Webmin Servers Index)
3. SSH key authentication from vh1 → vh2 (`ssh-copy-id root@vh2`)
4. OpenDKIM, Postfix, Dovecot installed and configured on vh2

## Configuration

After installation, go to the module page and add a remote mail server with:

- Mail server hostname and Webmin RPC credentials
- SSH connection details
- Spam gateway IP (optional, for inbound filtering)
- Outgoing relay server (for sender-dependent transports)
- DKIM selector name

## Testing

```bash
cd /usr/share/webmin/virtualmin-remote-mail

# Run unit tests (no server access needed)
prove t/01-lib.t t/02-feature.t t/03-dns.t t/04-user.t t/05-ssl.t

# Run integration tests (requires real servers)
REMOTE_MAIL_INTEGRATION=1 prove t/06-integration.t
```

## File Structure

```
module.info                    # Module metadata (hidden plugin)
defaultacl                     # Default ACL
config / config.info           # Module configuration
virtualmin-remote-mail-lib.pl  # Core library
virtual_feature.pl             # Virtualmin feature hooks
edit.cgi                       # Main module page
edit_servers.cgi               # Add/edit mail servers
save_server.cgi                # Save server config
edit_domain.cgi                # Per-domain mail settings
save_domain.cgi                # Per-domain actions
cgi_args.pl                    # URL argument defaults
log_parser.pl                  # Webmin action log parser
lang/en                        # Language strings
help/feat.html                 # Feature help page
t/                             # Test suite
```

## Feature Hooks

The plugin implements the full Virtualmin feature lifecycle:

| Hook | Purpose |
|------|---------|
| `feature_setup` | Provisions DNS + Postfix + Dovecot + DKIM + SSL |
| `feature_delete` | Tears down all remote configuration |
| `feature_modify` | Handles domain rename |
| `feature_disable` / `feature_enable` | Suspend/unsuspend mail flow |
| `feature_validate` | Verifies remote config matches state |
| `feature_clash` | Prevents conflict with local mail feature |
| `feature_depends` | Requires DNS feature |
| `feature_backup` / `feature_restore` | Domain backup/restore support |

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full text.
