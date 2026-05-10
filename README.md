# wg-install

> One-command WireGuard client installer for any Linux. Paste config, press Ctrl+D, done.
>
> 任意 Linux 一键 WireGuard 客户端安装。粘贴配置、Ctrl+D、搞定。

[![ShellCheck](https://github.com/NetApptool/wg-install/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/NetApptool/wg-install/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick Start / 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/NetApptool/wg-install/main/wg-install.sh -o /tmp/wg-install.sh
sudo bash /tmp/wg-install.sh
```

Then paste your `wg0.conf`, press **Ctrl+D**, answer 4 prompts. That's it.

之后粘贴你的 `wg0.conf`,按 **Ctrl+D**,回答 4 个小问题。完事。

---

## What it does

- Detects your distro and installs `wireguard-tools` (and the kernel module if your kernel < 5.6)
- Asks you to paste a standard WireGuard config (`[Interface]` + `[Peer]`)
- Drops it at `/etc/wireguard/wg0.conf` (mode 600, root-owned)
- Brings up `wg0` and enables `wg-quick@wg0` for boot autostart
- Verifies handshake and prints your new public exit IP

## Why another wg installer

Most existing scripts focus on **server** setup. This one is for **client** machines that just want to dial into an existing WireGuard server (a VPS, wg-easy, your office gateway, whatever) — without you having to remember 7 commands and which packages to install on which distro.

Three things this script handles that you'd otherwise stub your toe on:

| Pain point | What this does |
|---|---|
| **You're SSHing in over `0.0.0.0/0` AllowedIPs** — wg-quick up will kill your SSH session | Detects `$SSH_CLIENT`, asks if you want to add a host route preserving the SSH path |
| **`resolvconf` failures on Rocky/RHEL/Kylin** — `Failed to set DNS configuration: Could not activate remote peer` | Manages `/etc/resolv.conf` directly via PostUp/PostDown helper scripts. Doesn't depend on `systemd-resolved` / `openresolv` / `netconfig` |
| **Old kernels** without built-in WireGuard module | Detects kernel < 5.6 and tries `wireguard-dkms` (Debian/Ubuntu) or `kmod-wireguard` from EPEL (RHEL family) |

## Tested on

| Distro | Status | Notes |
|---|---|---|
| Ubuntu 22.04 / 24.04 | ✅ | Default kernel, no DKMS needed |
| Debian 12 | ✅ | |
| Rocky Linux 9.5 | ✅ | Reference platform |
| RHEL 9 / AlmaLinux 9 | ✅ | Same path as Rocky |
| Fedora 39+ | ✅ | |
| openEuler 22+ | 🟢 | Untested but same code path as Rocky 9 |
| Arch / Manjaro | 🟢 | Untested but should work |
| Kylin V10 SP3 | ⚠️ | Kernel 4.19 — needs `kmod-wireguard` from Kylin repo or EPEL, may fail without kernel-headers |
| CentOS 7 / Ubuntu 18.04 | ❌ | EOL kernels, not supported |

## Interactive prompts

The script asks **4 yes/no questions** with sensible defaults:

1. **Existing config detected** — backup & overwrite, or cancel?
2. **SSH self-protection** — add a host route to keep your SSH alive (only if `0.0.0.0/0`)?
3. **Kill switch** — drop all traffic if VPN goes down? (default: no)
4. **Start now & enable on boot?** (default: yes)

You can also use it non-interactively for unattended installs by piping a config and answering defaults — see [Advanced](#advanced) below.

## Example session

```text
═══════════════════════════════════════════════
  wg-install v0.2.0  WireGuard 一键客户端安装
═══════════════════════════════════════════════

[1/6] 检测系统...
      ✓ Rocky Linux 9.5 (Blue Onyx)  内核 5.14.0-503.14.1.el9_5.x86_64
      ✓ 包管理器: dnf

[2/6] 安装依赖...
      正在安装 wireguard-tools curl iproute iptables ... ✓ 完成(耗时 8 秒)
      ✓ 已加载 wireguard 内核模块

[3/6] 请粘贴你的 WireGuard 配置
      粘贴完成后按 Ctrl+D 结束:
      ────────────────────────────────────────
      [your wg0.conf paste here]
      ────────────────────────────────────────
      ✓ 配置已识别  对端: 8.138.192.234:51820
      ✓ 全流量模式 (0.0.0.0/0)

[4/6] 几个小问题:
      ⚠  检测到你正在通过 SSH 连接(来自 192.168.50.50)
      保护当前 SSH 连接? [Y/n]:
      ✓ 已加保护规则,启动后 SSH 不会断
      ...

[5/6] 启动隧道...
      ✓ wg-quick up wg0
      ✓ systemctl enable wg-quick@wg0  (开机自启已开)

[6/6] 连通性测试...
      ✓ 握手成功 (peer 已确认)
      ✓ 出口 IP  8.138.192.234
      ✓ DNS 解析 (example.com)  正常

═══════════════════════════════════════════════
  ✅ 全部完成!
═══════════════════════════════════════════════
```

## Common commands after install

```bash
sudo wg show                              # check status
sudo wg-quick down wg0                    # stop temporarily
sudo wg-quick up wg0                      # start manually
sudo systemctl restart wg-quick@wg0       # restart cleanly
sudo systemctl disable --now wg-quick@wg0 # disable permanently
sudo vi /etc/wireguard/wg0.conf           # edit config (then restart)
```

## Files this script touches

| Path | Why |
|---|---|
| `/etc/wireguard/wg0.conf` | The config you pasted, with PostUp/PostDown injected |
| `/etc/wireguard/wg0-dns-up.sh` | DNS handler (only if your config has `DNS = ...`) |
| `/etc/wireguard/wg0-dns-down.sh` | Restore original `/etc/resolv.conf` on tunnel down |
| `/etc/wireguard/wg0.conf.bak.<timestamp>` | Backup of your previous config (if any) |
| `/tmp/wg-install.log` | Install log (kept for diagnostics) |

System packages installed:
- All distros: `wireguard-tools`, `curl`, `iproute2` (or `iproute`), `iptables`
- Old kernels (< 5.6): plus `wireguard-dkms` (apt) or `kmod-wireguard` (dnf/yum) + `epel-release`

## Advanced

### Pipe-to-bash

If you trust the source, you can skip the file step:

```bash
curl -fsSL https://raw.githubusercontent.com/NetApptool/wg-install/main/wg-install.sh | sudo bash
```

The script reads from `/dev/tty` so interactive prompts still work in this mode.

### CLI flags

```bash
bash wg-install.sh --help     # show help
bash wg-install.sh --version  # show version
```

### Uninstall

```bash
sudo systemctl disable --now wg-quick@wg0
sudo rm -rf /etc/wireguard/wg0.conf /etc/wireguard/wg0-dns-*.sh
sudo rm -rf /etc/wireguard/wg0.conf.bak.*  # optional
```

## FAQ

**Q: My handshake doesn't happen — `wg show` shows `transfer: 0 B received`.**
A: The server side hasn't registered your peer's public key. Add your public key on the server's WireGuard config (or in wg-easy / similar admin UI).

**Q: I'm on Kylin V10 SP3 and the kernel module fails to build.**
A: Kylin V10 SP3 ships kernel 4.19 without WireGuard. Try the Kylin official repo for `kmod-wireguard`, or upgrade kernel. CentOS 7 / Ubuntu 18 have the same problem.

**Q: Does this work behind a corporate proxy?**
A: Package install (apt/dnf) inherits the proxy, but you may need to set `http_proxy` and `https_proxy` env vars before running. The WireGuard tunnel itself uses UDP and won't go through HTTP proxies.

**Q: Why don't you support `wg0-2`, `wg1`, etc?**
A: Single-tunnel client is 95% of cases. Multi-tunnel users probably know enough to just `cp wg0.conf wg1.conf` and `systemctl enable wg-quick@wg1` themselves.

## Security notes

- The config you paste contains your **private key**. The script writes it with mode 600 owned by root.
- Consider also `chattr +i /etc/wireguard/wg0.conf` after install if you want extra protection from accidental overwrite.
- This script does NOT exfiltrate your config anywhere. Read it before running — it's ~400 lines of bash.

## Contributing

Issues and PRs welcome. If this fails on your distro, please open an issue with:
- `cat /etc/os-release`
- `uname -r`
- `/tmp/wg-install.log`

## License

[MIT](LICENSE)
