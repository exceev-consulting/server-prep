# Getting help

Support is best effort. The maintainers and the community answer when they can. There is no promised response time.

## Where to ask

- **A question:** [Q&A](https://github.com/exceev-consulting/server-prep/discussions/categories/q-a) in Discussions.
- **A working setup or a compatibility report:**
  [Show and tell](https://github.com/exceev-consulting/server-prep/discussions/categories/show-and-tell).
  A *Compatibility reports* category is planned in [#26](https://github.com/exceev-consulting/server-prep/issues/26).
- **An idea:** [Ideas](https://github.com/exceev-consulting/server-prep/discussions/categories/ideas) in Discussions.
- **A bug:** the [bug form](https://github.com/exceev-consulting/server-prep/issues/new?template=bug_report.yml).
- **A security problem:** a [private advisory](https://github.com/exceev-consulting/server-prep/security/advisories/new).
  See [SECURITY.md](SECURITY.md). Never a public issue or discussion.

## What to include

- **Version:** the first line of `./server-prep.sh --help`, like `server-prep.sh vX.Y.Z - ...`.
- **OS and version:** Ubuntu 24.04, Debian 13...
- **Server type:** VPS, dedicated or rented bare-metal, own server, laptop or desktop, VM for testing.
- **Panel:** Coolify, Dokploy, Openship, none.
- **Audit summary**, without `host` and `public_ip`:

```bash
sudo ./server-audit.sh --quiet --no-txt --json audit.json
jq '{version, os, score, summary,
     problems: [.checks[] | select(.status == "FAIL" or .status == "WARN") | {id, status, message}]}' audit.json
```

- `version` in this output is the audit's version.
- Read the messages before you post: a message can name a host, a user or an address. Remove those.
- Never post the whole `audit.json`, a filled config, tokens, keys or passwords.
- `--no-network` skips the public IP lookup.

## Paid help

Exceev Consulting builds and maintains server-prep and offers paid help.
[Get in touch](https://exceev.com/contact).
