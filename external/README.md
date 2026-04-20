# external server scripts

This directory will contain deployment scripts for the external (outbound) node
which provides AmneziaWG endpoint and WARP egress.

Status: **not yet implemented** — written after internal deploy is tested.

For now, the external server is expected to be provisioned manually with:
- AmneziaWG server (`awg0.conf` listening on configurable port)
- Xray or Marzban for AWG peer handoff
- Cloudflare WARP for outbound
