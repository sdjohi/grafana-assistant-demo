#!/usr/bin/env bash
set -euo pipefail

echo "Resetting demo to clean state..."

# Reset feature flags to all off
cat > flagd/flags.json << 'EOF'
{
  "$schema": "https://flagd.dev/schema/v0/flags.json",
  "flags": {
    "slow-order-processing": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "bad-inventory-config": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    },
    "memory-leak": {
      "state": "ENABLED",
      "variants": {
        "on": true,
        "off": false
      },
      "defaultVariant": "off"
    }
  }
}
EOF

echo "Feature flags reset to default (all off)."

# Restart services to clear in-memory state (leaked data, orders)
docker compose restart order-service inventory-service api-gateway

echo "Services restarted. Demo is ready."
