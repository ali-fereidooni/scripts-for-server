#!/bin/bash

set -euo pipefail

IPSET_NAME="parspack4"
IP_URL="https://parspack.com/cdnips.txt"

TMP_DIR="$(mktemp -d)"
NEW_IP_FILE="$TMP_DIR/new-ips.txt"
OLD_IP_FILE="$TMP_DIR/old-ips.txt"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

echo "Downloading CDN IP list..."

curl -fsSL --connect-timeout 15 --max-time 60 \
    "$IP_URL" -o "$NEW_IP_FILE"

if [[ ! -s "$NEW_IP_FILE" ]]; then
    echo "Downloaded IP list is empty."
    exit 1
fi

echo "Validating IP addresses..."

python3 - "$NEW_IP_FILE" <<'PY'
import ipaddress
import sys

path = sys.argv[1]
valid = []

with open(path) as f:
    for line in f:
        line = line.split("#", 1)[0].strip()

        if not line:
            continue

        try:
            network = ipaddress.ip_network(line, strict=False)
        except ValueError:
            print(f"Invalid IP/CIDR: {line}")
            sys.exit(1)

        if network.version != 4:
            print(f"IPv6 entry found in IPv4 list: {line}")
            sys.exit(1)

        valid.append(str(network))

if not valid:
    print("No valid IPv4 entries found.")
    sys.exit(1)

with open(path, "w") as f:
    f.write("\n".join(sorted(set(valid))) + "\n")

print(f"Validated {len(set(valid))} IPv4 entries.")
PY

echo "Checking IPSet..."

if ! firewall-cmd --permanent --get-ipsets | grep -qw "$IPSET_NAME"; then
    echo "IPSet '$IPSET_NAME' does not exist."
    exit 1
fi

echo "Getting current entries..."

firewall-cmd --permanent \
    --ipset="$IPSET_NAME" \
    --get-entries | tr ' ' '\n' > "$OLD_IP_FILE"

echo "Removing old entries..."

if [[ -s "$OLD_IP_FILE" ]]; then
    firewall-cmd --permanent \
        --ipset="$IPSET_NAME" \
        --remove-entries-from-file="$OLD_IP_FILE"
fi

echo "Adding new entries..."

firewall-cmd --permanent \
    --ipset="$IPSET_NAME" \
    --add-entries-from-file="$NEW_IP_FILE"

echo "Reloading firewalld..."

firewall-cmd --reload

echo "CDN IPSet updated successfully."
