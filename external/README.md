# external/ — deploy-kit for the FI external node

Self-hosted, idempotent deployment of an external WG-bridge node:

```
client → internal (RU) → AmneziaWG tunnel → external (FI) → Cloudflare WARP → internet
                                                  ▲
                                            this deploy-kit
```

The external node receives traffic from internal over an IPv6-only AmneziaWG
tunnel (`fd10::1`), accepts a VLESS inbound on the tunnel address (xray
listening on `[fd10::1]:10555`), and forwards everything to Cloudflare WARP
through a local SOCKS5 proxy (`127.0.0.1:40000`).

## Requirements

- Ubuntu 22.04 (clean install, root or sudo)
- 1+ GiB RAM (DKMS build for AmneziaWG kernel module needs ~500 MiB)
- 2+ GiB free disk on `/`
- Internet access, including reachability of `github.com` (for AWG kernel
  module DKMS build) and `pkg.cloudflareclient.com` (for WARP install)
- Public IPv4 (IPv6 optional)

## What it does (10 phases)

| # | Phase             | Purpose                                                |
|---|-------------------|--------------------------------------------------------|
| 0 | `00-init`         | Wizard fills `state.env` from `manifest.json`          |
| 1 | `01-precheck`     | OS / network / kernel / disk / RAM / port / state checks |
| 2 | `02-base`         | apt update, base tools, sysctl, admin user, sshd, sudoers, fail2ban, iptables-persistent |
| 3 | `03-amneziawg`    | DKMS install of AWG kernel module + userspace tools, generate keypair, render `awg0.conf`, bring `awg0` up |
| 4 | `04-warp`         | Install Cloudflare WARP, anonymous registration, set proxy mode + port, connect |
| 5 | `05-xray`         | Install xray binary, render `config.json` + systemd unit, start |
| 6 | `06-firewall`     | UFW (deny incoming, allow ssh + AWG), persist iptables |
| 7 | `07-validate`     | End-to-end checks (read-only): all services healthy    |
| 8 | `08-secrets-export` | Build `peer-info.{txt,json}` + tarball of `$SECRETS_DIR`, stage in admin home for scp |
| 9 | `09-finalize`     | Install backup-cleanup cron, write `/etc/deploy/deploy-summary.txt` |

## Quick start

```bash
# 1. Get the kit on the target server
git clone https://github.com/stanovovmtuci-pixel/deploy.git /opt/deploy-kit
cd /opt/deploy-kit/external

# 2. Edit manifest.json if needed (e.g., to pre-set PUBLIC_IPV4 in defaults).
#    Most fields are auto-detected or asked interactively.

# 3. Run the deploy
sudo ./deploy.sh
```

The wizard will ask you for a few things (admin user, SSH key, etc.).
Generated values (AWG keys, xray UUID) and auto-detected ones (interface,
public IP) are filled in automatically. Re-running the wizard is safe:
existing values in `state.env` are preserved.

After all phases finish, follow the instructions printed by `09-finalize`
to (a) `scp` the secrets bundle to your workstation and (b) register the
internal node as an AWG peer using `scripts/add-peer.sh`.

## CLI reference

```bash
sudo ./deploy.sh                       # full deploy (interactive)
sudo ./deploy.sh --from-phase 03       # resume from phase 03 onward
sudo ./deploy.sh --only 04             # re-run only phase 04 (force, ignores done flag)
sudo ./deploy.sh --rollback 04         # rollback phase 04 (must be in same RUN_ID)
sudo ./deploy.sh --rollback-all        # rollback every phase of current RUN_ID
sudo ./deploy.sh --list                # list phases and exit
sudo ./deploy.sh --dry-run             # parse manifest, show summary, no system changes
sudo ./deploy.sh --manifest-summary    # print all placeholders with classification
```

## Environment variables

| Variable                  | Default                              | Purpose                       |
|---------------------------|--------------------------------------|-------------------------------|
| `NO_COLOR=1`              | unset                                | Disable ANSI colors           |
| `DEPLOY_LOG`              | `/var/log/deploy-external.log`       | Log file path                 |
| `DEPLOY_STATE_DIR`        | `/etc/deploy`                        | State directory               |
| `BACKUP_ROOT`             | `/var/backups/deploy`                | Per-phase backups root        |
| `SECRETS_DIR`             | `/root/external-deploy-secrets`      | Where AWG keys + UUID live    |
| `RUN_ID`                  | `YYYYMMDD-HHMMSS-PID`                | Resume into existing backups  |
| `DEPLOY_NONINTERACTIVE`   | unset                                | Skip y/n confirmations (CI)   |

## Adding peers

After deploy, register the internal node as an AWG peer:

```bash
sudo /opt/deploy-kit/external/scripts/add-peer.sh \
    --pubkey  '<INTERNAL_AWG_PUB_KEY>' \
    --allowed 'fd10::2/128'
```

`add-peer.sh` is idempotent (replaces an existing peer with the same pubkey)
and does **hot reload** via `awg syncconf` — no interface restart, existing
sessions stay connected.

## Paths of interest

| Path                                          | What                          |
|-----------------------------------------------|-------------------------------|
| `/var/log/deploy-external.log`                | Deploy log (all phases)       |
| `/etc/deploy/state.env`                       | Wizard-resolved values        |
| `/etc/deploy/deploy-summary.txt`              | Final report after deploy     |
| `/var/backups/deploy/<RUN_ID>/<phase>/`       | Per-phase backups (TTL 24h)   |
| `/root/external-deploy-secrets/`              | AWG keys, xray UUID, peer-info|
| `/etc/amnezia/amneziawg/awg0.conf`            | AWG interface config          |
| `/usr/local/etc/xray/config.json`             | xray config                   |
| `/usr/local/bin/xray`                         | xray binary                   |
| `/var/log/xray/{access,error}.log`            | xray runtime logs             |
| `/usr/src/amneziawg-1.0.0/`                   | DKMS sources for AWG module   |
| `/lib/modules/<kver>/updates/dkms/amneziawg.ko` | Compiled kernel module      |

## Rollback

Each phase takes a backup before changing anything. Roll back per-phase or
everything:

```bash
sudo ./deploy.sh --rollback 04         # one phase
sudo ./deploy.sh --rollback-all        # all phases of current RUN_ID
```

Rollback restores files, deletes files we created, restores iptables, and
stops services we started. **Not** rolled back: apt-installed packages,
generated keys (still in `$SECRETS_DIR`), and any manual changes.

If you need a clean slate: snapshot the VPS before running deploy-kit, or
re-create the VM.

## Security notes

- `state.env` mode `600 root:root` (contains some semi-secret values; private
  keys are NOT here — they live in `$SECRETS_DIR`)
- `awg0.conf` mode `600 root:root` (contains private key)
- `xray/config.json` mode `640 root:nogroup` (xray runs as `nobody`)
- WARP runs as the system warp user (managed by upstream package)
- Logs (`/var/log/deploy-external.log`) mode `600`

After successful deploy, **transfer the secrets bundle off-server**, then:

```bash
sudo rm -f /home/<admin>/external-deploy-secrets-<RUN_ID>.tar.gz
sudo rm -f /root/external-deploy-secrets-<RUN_ID>.tar.gz
sudo rm -rf /root/external-deploy-secrets
```

The interface keeps working as long as `awg-quick@awg0` stays running — its
in-memory key isn't touched. Do **not** `awg-quick down awg0` until you have
the bundle safely on your workstation.

## Architecture choices (FAQ)

**Why DKMS instead of upstream apt package?**
Ubuntu 22.04 has no official AmneziaWG package. We build from
[github.com/amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
via DKMS. Phase 03 builds the module for **all installed kernels** —
this protects you from a "surprise reboot to a different kernel" scenario.

**Why xray as native systemd, not Docker?**
Less moving parts. The data path is `AWG → xray → SOCKS5 (WARP)`, and
warp-svc itself is native; running xray in Docker would mean kernel-level
networking gymnastics with no benefit. The native setup is also what we
validated in production.

**Why no MASQUERADE / NAT?**
The chain is: internal client → internal xray → AWG → external xray
(userspace) → SOCKS5(WARP) → internet. External xray opens **new outbound
connections** from its own host — no kernel forwarding, no NAT needed.
This is intentional and simpler than a full L3 forwarder.

**Why anonymous WARP, not WARP+?**
Free tier is plenty for our throughput. WARP+ requires per-account binding
which complicates rotation; anonymous registration is regenerable in
seconds if rate-limited.

**Why IPv6-only AWG tunnel?**
The tunnel only carries control + xray VLESS — no end-user IP forwarding.
IPv6 ULA (fd10::/64) is sufficient and avoids any conflict with VPS
internal networks (which often use 10.0.0.0/8).

## Troubleshooting

### `xray fails to start with "bind: cannot assign requested address"`
The AWG interface is not up. Check:
```bash
systemctl status awg-quick@awg0
ip -6 addr show awg0
sudo modprobe amneziawg
```

### `WARP doesn't connect`
```bash
warp-cli --accept-tos status
journalctl -u warp-svc --no-pager -n 50
warp-cli --accept-tos registration show
```

If registration is corrupted, delete and re-register:
```bash
warp-cli --accept-tos registration delete
sudo ./deploy.sh --only 04-warp
```

### `AWG handshake never happens after add-peer`
- Check public/private keypair on internal side (`awg show awg0` — both peers
  see each other's pubkey)
- Check obfuscation params (`Jc/Jmin/Jmax/S1/S2/H1-H4`) match between
  external and internal — even one mismatch silently drops handshake
- Check UDP/51821 reachable from internal:
  `nc -uvz <external-ip> 51821`

### Reboot lost the AWG interface
Check DKMS coverage for the new kernel:
```bash
dkms status amneziawg
ls /lib/modules/$(uname -r)/updates/dkms/
```

If missing for current kernel:
```bash
sudo dkms install -m amneziawg -v 1.0.0 -k $(uname -r)
sudo modprobe amneziawg
sudo systemctl restart awg-quick@awg0
```

### General failure → restart from a phase
```bash
sudo ./deploy.sh --from-phase 05
```
or roll back the bad phase first:
```bash
sudo ./deploy.sh --rollback 05
sudo ./deploy.sh --only 05
```

## Layout reference

```
external/
├── deploy.sh                 # entrypoint
├── manifest.json             # placeholder schema
├── README.md                 # this file
├── lib/
│   ├── common.sh             # log, ok, warn, fail, ask, save_state...
│   ├── render.sh             # python3 template engine
│   ├── backup.sh             # per-phase snapshot + rollback
│   ├── validation.sh         # is_valid_*, check_*
│   ├── manifest.sh           # jq-based manifest.json parser
│   └── secrets.sh            # AWG keypair + xray UUID generation
├── phases/
│   ├── 00-init.sh            # wizard
│   ├── 01-precheck.sh        # pre-flight checks
│   ├── 02-base.sh            # base hardening
│   ├── 03-amneziawg.sh       # AWG via DKMS + userspace
│   ├── 04-warp.sh            # Cloudflare WARP
│   ├── 05-xray.sh            # xray native systemd
│   ├── 06-firewall.sh        # UFW + persist iptables
│   ├── 07-validate.sh        # end-to-end checks
│   ├── 08-secrets-export.sh  # peer-info + tarball
│   └── 09-finalize.sh        # cron + summary
├── scripts/
│   └── add-peer.sh           # add AWG peer, hot reload
└── templates/
    ├── configs/
    │   ├── awg0.conf.tpl
    │   ├── sshd_config-deploy.conf.tpl
    │   ├── fail2ban-jail.local.tpl
    │   └── sysctl-deploy.conf.tpl
    ├── systemd/
    │   ├── xray.service.tpl
    │   └── xray.service.d-10-donot_touch_single_conf.conf.tpl
    └── xray/
        └── config.json.tpl
```

## License & origin

This deploy-kit is a personal infrastructure tool. The bundled software
(AmneziaWG, xray, Cloudflare WARP, fail2ban, UFW) carries its own respective
license — refer to upstream projects.

Generated and maintained by hand against a working production reference
(FI external node, Ubuntu 22.04, kernel 5.15.0-176, AWG DKMS 1.0.0,
xray-core latest, cloudflare-warp).