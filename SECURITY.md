# Security policy

server-prep changes SSH, the firewall and other security settings, so a bug can expose a server or lock its admin out.
Please report these problems privately.

## Report a vulnerability

Use **[Report a vulnerability](https://github.com/exceev-consulting/server-prep/security/advisories/new)**
(Security tab of the repo). Don't open a public issue or discussion.

Include:
- what is wrong and its impact (for example: a port left open, root login allowed from anywhere, a lockout);
- the script, the version (`./server-prep.sh --help` shows it) and the OS;
- steps to reproduce, on a test server.

Never send real tokens, private keys or passwords.
We try to answer within 7 days and will credit you in the release notes, unless you prefer not.

## Supported versions

Only the latest release and `main` get fixes. A security fix ships as a patch release, with the advisory published at
the same time. `server-audit.sh` tells you when a newer release fixes a security problem (check `upd.server_prep`), and
`./server-prep.sh --upgrade` installs it after checking every file against the release's `SHA256SUMS`.

## Out of scope

Bugs in the tools that server-prep installs (OpenSSH, UFW, Docker, CrowdSec, fail2ban, ufw-docker, Tailscale...)
belong to their own projects. Report them there. If server-prep configures one of them in an unsafe way,
that is in scope.
