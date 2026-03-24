#!/bin/bash
# install.sh — Install virtualmin-remote-mail from GitHub
# Usage: curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash
#
# Options:
#   --setup-remote HOST  After install, configure the remote mail server HOST
#                        (sets up RPC ACL, certbot hook, and SSH key)
set -e

REPO="https://github.com/trinsiklabs/virtualmin-remote-mail.git"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

REMOTE_HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup-remote) REMOTE_HOST="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Downloading virtualmin-remote-mail..."
git clone --depth 1 "$REPO" "$TMPDIR/virtualmin-remote-mail" 2>/dev/null

echo "Packaging module..."
tar czf "$TMPDIR/virtualmin-remote-mail.wbm.gz" \
    --exclude='.git' --exclude='t' --exclude='.gitignore' \
    --exclude='install.sh' \
    -C "$TMPDIR" virtualmin-remote-mail/

echo "Installing module..."
/usr/share/webmin/install-module.pl "$TMPDIR/virtualmin-remote-mail.wbm.gz"

# Register as Virtualmin plugin if not already present
CONFIG="/etc/webmin/virtual-server/config"
if [ -f "$CONFIG" ]; then
    if ! grep -q 'virtualmin-remote-mail' "$CONFIG"; then
        sed -i 's/^plugins=.*/& virtualmin-remote-mail/' "$CONFIG"
        echo "Registered as Virtualmin plugin."
    fi
fi

# ---- Remote mail server setup ----
if [ -n "$REMOTE_HOST" ]; then
    echo ""
    echo "Setting up remote mail server: $REMOTE_HOST"

    # Test SSH connectivity
    echo -n "  Testing SSH to $REMOTE_HOST... "
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        echo ""
        echo "  SSH key authentication to root@$REMOTE_HOST is required."
        echo "  Run: ssh-copy-id root@$REMOTE_HOST"
        echo "  Then re-run: $0 --setup-remote $REMOTE_HOST"
        exit 1
    fi

    # Ensure RPC is allowed for root on the remote Webmin
    echo -n "  Enabling Webmin RPC for root on $REMOTE_HOST... "
    ssh "root@$REMOTE_HOST" '
        ACL_FILE="/etc/webmin/webmin/root.acl"
        if [ -f "$ACL_FILE" ]; then
            if ! grep -q "^rpc=" "$ACL_FILE"; then
                echo "rpc=1" >> "$ACL_FILE"
            fi
        else
            echo "rpc=1" > "$ACL_FILE"
        fi
    ' 2>/dev/null
    echo "OK"

    # Deploy certbot SNI sync hook
    echo -n "  Deploying certbot SNI sync hook... "
    HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/virtualmin-remote-mail-sni-sync.sh"
    # Extract hook script from the installed plugin
    HOOK_CONTENT=$(perl -e '
        use lib "/usr/share/webmin", "/usr/share/webmin/virtualmin-remote-mail";
        do "virtualmin-remote-mail-lib.pl" if -f "virtualmin-remote-mail-lib.pl";
        require "/usr/share/webmin/virtualmin-remote-mail/virtualmin-remote-mail-lib.pl"
            if !defined(&get_certbot_hook_script);
        if (defined(&get_certbot_hook_script)) {
            print &get_certbot_hook_script();
        }
    ' 2>/dev/null)
    if [ -z "$HOOK_CONTENT" ]; then
        # Fallback: use inline hook
        HOOK_CONTENT='#!/bin/bash
# virtualmin-remote-mail-sni-sync.sh — Certbot deploy hook
# Rebuilds the Postfix SNI map after certificate renewal.
set -euo pipefail
CERT_NAME=$(basename "$RENEWED_LINEAGE")
HOME_DIR="/home/$CERT_NAME"
[ ! -d "$HOME_DIR/ssl" ] && exit 0
FULLCHAIN="$RENEWED_LINEAGE/fullchain.pem"
PRIVKEY="$RENEWED_LINEAGE/privkey.pem"
CHAIN="$RENEWED_LINEAGE/chain.pem"
[ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ] && exit 0
cp "$FULLCHAIN" "$HOME_DIR/ssl/$CERT_NAME.crt"
cp "$PRIVKEY"   "$HOME_DIR/ssl/$CERT_NAME.key"
[ -f "$CHAIN" ] && cp "$CHAIN" "$HOME_DIR/ssl/$CERT_NAME.ca"
cat "$PRIVKEY" "$FULLCHAIN" > "$HOME_DIR/ssl.combined"
DOMAIN_USER=$(stat -c "%U" "$HOME_DIR" 2>/dev/null || echo root)
chown "$DOMAIN_USER:$DOMAIN_USER" "$HOME_DIR/ssl/$CERT_NAME.crt" "$HOME_DIR/ssl/$CERT_NAME.key" "$HOME_DIR/ssl.combined" 2>/dev/null || true
[ -f "$HOME_DIR/ssl/$CERT_NAME.ca" ] && chown "$DOMAIN_USER:$DOMAIN_USER" "$HOME_DIR/ssl/$CERT_NAME.ca" 2>/dev/null || true
chmod 600 "$HOME_DIR/ssl/$CERT_NAME.key" "$HOME_DIR/ssl.combined"
[ -f /etc/postfix/sni_map ] && postmap -F hash:/etc/postfix/sni_map 2>/dev/null || true
systemctl restart postfix 2>/dev/null || true
systemctl reload dovecot 2>/dev/null || true
logger -t certbot-sni-sync "Rebuilt SNI map for $CERT_NAME"'
    fi
    echo "$HOOK_CONTENT" | ssh "root@$REMOTE_HOST" "
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > $HOOK_PATH
        chmod 755 $HOOK_PATH
    " 2>/dev/null
    echo "OK"

    # Ensure Postfix SNI map uses postmap -F
    echo -n "  Rebuilding Postfix SNI map with postmap -F... "
    ssh "root@$REMOTE_HOST" '
        if [ -f /etc/postfix/sni_map ]; then
            postmap -F hash:/etc/postfix/sni_map 2>/dev/null && echo "OK" || echo "SKIP (no sni_map entries)"
        else
            echo "SKIP (no sni_map)"
        fi
    ' 2>/dev/null

    echo ""
    echo "Remote server $REMOTE_HOST configured."
fi

echo ""
echo "Done! Next steps:"
echo "  1. Configure a remote mail server in Webmin:"
echo "     Webmin > Servers > Remote Mail Server"
echo "  2. Enable for a domain:"
echo "     virtualmin enable-feature --domain example.com --virtualmin-remote-mail"
if [ -z "$REMOTE_HOST" ]; then
    echo ""
    echo "  To auto-configure the remote mail server, re-run with:"
    echo "     $0 --setup-remote MAIL_SERVER_HOSTNAME"
fi
