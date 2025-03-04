#!/bin/bash

# Script to generate a WireGuard .conf file for PIA with interactive region selection

# Check for required tools
for cmd in curl jq wg; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Error: $cmd is required. Please install it."
        exit 1
    fi
done

# Default values (hardcode here or override with env vars)
: "${DEBUG:=0}"              # Default to 0 (off) unless set
: "${PIA_USER:=your_pia_username}"  # Replace with your username (e.g., p0123456)
: "${PIA_PASS:=your_pia_password}"  # Replace with your password (e.g., xxxxxxxx)
CA_CERT="./ca/ca.rsa.4096.crt"         # Store in current directory

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to print debug messages if DEBUG=1
debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "DEBUG: $1"
    fi
}

# Download CA certificate if not present
mkdir -p "$(dirname "$CA_CERT")"
if [ ! -f "$CA_CERT" ]; then
    echo -n "Downloading CA certificate... "
    curl -s -o "$CA_CERT" "https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt"
    if [ $? -eq 0 ] && [ -s "$CA_CERT" ]; then
        echo -e "${GREEN}Success${NC}"
    else
        echo -e "${RED}Failed to download CA certificate.${NC}"
        exit 1
    fi
else
    echo "CA certificate already exists at $CA_CERT"
fi

# Step 1: Get authentication token
echo -n "Authenticating with PIA... "
TOKEN_RESPONSE=$(curl -s --location --request POST \
    "https://www.privateinternetaccess.com/api/client/v2/token" \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')

debug "TOKEN_RESPONSE=$TOKEN_RESPONSE"
debug "TOKEN=$TOKEN"

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo -e "${RED}Failed to authenticate. Check your credentials.${NC}"
    exit 1
fi
echo -e "${GREEN}Success${NC}"

# Step 2: Fetch server list from v6 endpoint
echo -n "Fetching server list... "
SERVER_LIST=$(curl -s "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -n 1)

debug "SERVER_LIST length=${#SERVER_LIST}"

if [ -z "$SERVER_LIST" ]; then
    echo -e "${RED}Failed to fetch server list.${NC}"
    exit 1
fi
echo -e "${GREEN}Success${NC}"

# Step 3: Build array of regions, sorted alphabetically by name
echo "Available regions (sorted alphabetically):"
REGIONS=$(echo "$SERVER_LIST" | jq -r '.regions[] | [.id, .name] | join(" - ")' | sort -t '-' -k 2)
REGION_ARRAY=()
i=0
while IFS= read -r line; do
    REGION_ARRAY[$i]="$line"
    echo "$i) ${REGION_ARRAY[$i]}"
    ((i++))
done <<< "$REGIONS"

# Step 4: Let user pick a region
echo -n "Enter the number of the region you want to use: "
read CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#REGION_ARRAY[@]}" ] || [ "$CHOICE" -lt 0 ]; then
    echo -e "${RED}Invalid selection.${NC}"
    exit 1
fi

SELECTED_REGION=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d' ' -f1)
REGION_NAME=$(echo "${REGION_ARRAY[$CHOICE]}" | cut -d'-' -f2- | sed 's/^ *//')
echo -e "${GREEN}Selected region: $REGION_NAME ($SELECTED_REGION)${NC}"

# Step 5: Get server details for the selected region
SERVER_IP=$(echo "$SERVER_LIST" | jq -r --arg reg "$SELECTED_REGION" '.regions[] | select(.id == $reg) | .servers.wg[0].ip')
SERVER_HOSTNAME=$(echo "$SERVER_LIST" | jq -r --arg reg "$SELECTED_REGION" '.regions[] | select(.id == $reg) | .servers.wg[0].cn')

debug "SERVER_IP=$SERVER_IP"
debug "SERVER_HOSTNAME=$SERVER_HOSTNAME"

if [ -z "$SERVER_IP" ] || [ -z "$SERVER_HOSTNAME" ]; then
    echo -e "${RED}No WireGuard server available for '$SELECTED_REGION'.${NC}"
    exit 1
fi
echo -e "${GREEN}Found server: $SERVER_IP ($SERVER_HOSTNAME)${NC}"

# Step 6: Generate WireGuard keys (use temp file to mimic PIA's approach)
echo -n "Generating WireGuard keys... "
wg genkey > wg_temp.key
PRIVATE_KEY=$(cat wg_temp.key)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
rm -f wg_temp.key
debug "PRIVATE_KEY=$PRIVATE_KEY"
debug "PUBLIC_KEY=$PUBLIC_KEY"
echo -e "${GREEN}Done${NC}"

# Step 7: Register with PIA WireGuard API
echo -n "Registering with PIA WireGuard API... "
CURL_CMD="curl -s -v -G \
    --connect-to \"$SERVER_HOSTNAME::$SERVER_IP:\" \
    --cacert \"$CA_CERT\" \
    --data-urlencode \"pt=$TOKEN\" \
    --data-urlencode \"pubkey=$PUBLIC_KEY\" \
    \"https://$SERVER_HOSTNAME:1337/addKey\""
debug "Executing: $CURL_CMD"
if [ "$DEBUG" = "1" ]; then
    WG_RESPONSE=$(eval "$CURL_CMD" 2> curl_verbose.log)
    debug "See curl_verbose.log for detailed output"
else
    WG_RESPONSE=$(eval "$CURL_CMD")
fi
CURL_EXIT=$?

debug "CURL Exit Code=$CURL_EXIT"
debug "WG_RESPONSE=$WG_RESPONSE"

if [ "$CURL_EXIT" -ne 0 ]; then
    echo -e "${RED}curl failed with exit code $CURL_EXIT. Check curl_verbose.log.${NC}"
    exit 1
fi

STATUS=$(echo "$WG_RESPONSE" | jq -r '.status' 2>/dev/null)
debug "STATUS=$STATUS"

if [ "$STATUS" != "OK" ]; then
    echo -e "${RED}Failed to connect to WireGuard API. Response: $WG_RESPONSE${NC}"
    exit 1
fi

SERVER_KEY=$(echo "$WG_RESPONSE" | jq -r '.server_key')
SERVER_PORT=$(echo "$WG_RESPONSE" | jq -r '.server_port')
DNS_SERVERS=$(echo "$WG_RESPONSE" | jq -r '.dns_servers | join(", ")')
PEER_IP=$(echo "$WG_RESPONSE" | jq -r '.peer_ip')

debug "SERVER_KEY=$SERVER_KEY"
debug "SERVER_PORT=$SERVER_PORT"
debug "DNS_SERVERS=$DNS_SERVERS"
debug "PEER_IP=$PEER_IP"

echo -e "${GREEN}Success${NC}"

# Step 8: Generate WireGuard config file (match PIA's format)
CONFIG_FILE="./configs/pia-$SELECTED_REGION.conf"
mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $PEER_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_KEY
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
echo -e "${GREEN}WireGuard config generated: ./configs/$CONFIG_FILE${NC}"