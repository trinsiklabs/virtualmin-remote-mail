#!/bin/bash
# install.sh — Install virtualmin-remote-mail from GitHub
# Usage: curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash
set -e

REPO="https://github.com/trinsiklabs/virtualmin-remote-mail.git"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

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

echo ""
echo "Done! Next steps:"
echo "  1. Configure a remote mail server at:"
echo "     Webmin > Servers > Remote Mail Server"
echo "  2. Enable for a domain:"
echo "     virtualmin enable-feature --domain example.com --virtualmin-remote-mail"
