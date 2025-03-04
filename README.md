# Simple Private Internet Access WireGuard Config Generator

This script generates WireGuard configuration files for Private Internet Access (PIA) VPN service, simplifying the setup process.

## Installation

```bash
git clone https://github.com/dieskim/simple-pia-wg-config-generator
cd simple-pia-wg-config-generator
chmod +x simple-pia-wg-config-generator.sh
DEBUG=1 PIA_USER=p0123456 PIA_PASS=xxxxxxxx ./simple-pia-wg-config-generator.sh
```

### Hardcode PIA_USER and PIA_PASS if needed

Edit simple-pia-wg-config-generator.sh and replace
```
"${PIA_USER:=your_pia_username}"  # Replace with your username (e.g., p0123456)
"${PIA_PASS:=your_pia_password}"  # Replace with your password (e.g., xxxxxxxx)
```

This script is based on PIA FOSS manual connections.
https://github.com/pia-foss/manual-connections/tree/master