# 0001. End-to-end tests run in KVM virtual machines

- **Status:** accepted
- **Date:** 2026-10-27
- **Issues:** [#94](https://github.com/exceev-consulting/server-prep/issues/94), [#38](https://github.com/exceev-consulting/server-prep/issues/38)

## Context

CI checked syntax, ShellCheck, `--help` and the exit status. It never ran the scripts on a system, so
regressions showed up on real servers first:

- the ufw-docker bypass fixed in 1.1.1: 80/443 skipped UFW when Docker was already running;
- `Defaults logfile` rejected by sudo-rs on Ubuntu 26.04;
- `log_martians` and `fs.suid_dumpable` back to their old values after a reboot.

Most of what `server-prep.sh` changes lives in the kernel or in PID 1: sysctl, netfilter (UFW, ufw-docker, the
DOCKER-USER chain), auditd, AppArmor, sshd on a new port, systemd units and timers, and what survives a reboot.

## Options

| | systemd in a Docker container | KVM virtual machine |
|---|---|---|
| Kernel | the runner's, shared | its own |
| sysctl, UFW/iptables, auditd, AppArmor | partly, or not at all | yes |
| SSH on a new port, firewall seen from outside | faked | real, through forwarded ports |
| Reboot | no | yes |
| Image | a container image | the official cloud image VPS providers use |
| Start-up | seconds | 20 to 60 s with KVM |

GitHub-hosted Linux runners expose `/dev/kvm`, so a VM costs about a minute more per job than a container.

## Decision

Each system runs in its own QEMU/KVM virtual machine:

- booted from the official Debian or Ubuntu cloud image, checked against the published checksum and cached;
- set up by cloud-init with a throwaway sudo user and key, like a provider's default account;
- driven only over SSH and forwarded ports, like an operator, including a terminal for the interactive questions.

The VM's user network uses the documentation range `198.51.100.0/24`. The runner reaches the VM from
`198.51.100.2`, a public address for UFW and ufw-docker, so a published container port must stay closed to it.

Without `/dev/kvm` the harness falls back to TCG emulation: slow, same result.

## Consequences

- One job per system, run in parallel. A job takes about 20 to 30 minutes, mostly package installs.
- What stays untested: Tailscale, CrowdSec enrolment, Telegram, Cloudflare Tunnel and InfluxDB (they need
  accounts or secrets), adding the server to a real panel (#57, #23), laptops and desktops.
- The same harness runs on a maintainer's Linux machine with QEMU and `/dev/kvm`, without root:
  `tests/e2e/run.sh --os debian-13`.
- Reports are HTML pages published with the setup console on GitHub Pages. They are rebuilt from the latest
  run of `main` and of each open pull request, so nothing is stored in git. See `docs/e2e-tests.md`.
