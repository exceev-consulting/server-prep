# Third-party notices

## vps-audit (bundled, modified)

`server-audit.sh` is derived from [vps-audit](https://github.com/nuver-labs/vps-audit) v0.2.0, used under the MIT License:

```
MIT License

Copyright (c) 2024 Israel Abebe Kokiso

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ufw-docker (not bundled)

`server-prep.sh` downloads [ufw-docker](https://github.com/chaifeng/ufw-docker) at runtime. The release is pinned and its SHA-256 is checked. It is installed to `/usr/local/bin/ufw-docker` and runs `ufw-docker install`. ufw-docker is licensed under **GPL-3.0**, and none of its code is included in this repository.

## ShellCheck (not bundled)

`scripts/check.sh` downloads [ShellCheck](https://github.com/koalaman/shellcheck) into your cache (`${XDG_CACHE_HOME:-~/.cache}/server-prep/`) when version 0.11.0 is not installed. The release is pinned and its SHA-256 is checked. ShellCheck is licensed under **GPL-3.0**, and none of its code is included in this repository.

## Ideas

[vps-secure](https://github.com/rockballslab/vps-secure) inspired some of the security choices. No code is copied from it.
