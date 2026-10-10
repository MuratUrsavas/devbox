# devbox: per-project Incus VMs for Claude Code and opencode

One base image with everything you need, and a VM per project cloned from it.
Each VM's only way out is an allowlisting proxy.

```
devbox-base (image: Ubuntu 26.04, Rust + cargo-nextest, Claude Code, opencode, Python)
   │  btrfs copy-on-write clone: instant, only changed blocks use disk
   ├─ my-app        ── mounts /home/you/src/my-app
   ├─ other-app     ── mounts /home/you/src/other-app
   └─ ...
        all on devbox-net: isolated bridge (no NAT/route/DNS) + ACL: tcp/3128 to the proxy only
devbox-proxy (Debian + squid)  ── devbox-up (NAT) ──▶ internet, allowlisted domains only
```

## Quick start

```bash
cp -r devbox ~/devbox && cd ~/devbox && chmod +x devbox *.sh
ln -s "$PWD/devbox" ~/.local/bin/devbox

devbox setup                    # Incus + deps, incus-admin group → log out/in
devbox build-base               # network, proxy, base image (once; rerun to refresh)
devbox create my-app ~/src/my-app
cd ~/src/my-app && devbox claude  # first run: /login
devbox opencode                   # same, with opencode; first run: /connect
```

`create` ends with `devbox verify`. Don't use a VM if any check prints `FAIL`.

## Picking the VM

Commands that act on a VM take its name as the first argument. When you run devbox inside a project folder,
it picks that folder's VM. So inside `~/src/my-app`, `devbox claude` and `devbox run cargo test` just work.
Anywhere else, use `devbox claude my-app`. Each VM records its project path in its Incus config
(`user.devbox.project`), so nothing needs a separate registry.

## Base image lifecycle

Incus images aren't layered like Docker. A VM is a one-time clone of the base, so rebuilding the base doesn't change existing VMs.

- `devbox build-base` rebuilds the image and lists VMs still on the older base.
- `devbox list` shows each VM's project and whether it's on the `current` or an `older` base.
- `devbox recreate <vm>` deletes and re-clones a VM from the current base, keeping its Claude Code, opencode and gh logins.
  The project folder lives on the host, so nothing in it is lost. Shell history, caches and the local session history
  of Claude Code and opencode inside the VM are reset.
- `devbox update <vm>` updates apt, Rust, Claude Code, opencode and cargo-nextest in place, if you'd rather not recreate.

Project-specific tools aren't part of the base. Install them in the VM: run `devbox shell` (the user has sudo),
use `devbox root`, or ask the agent to do it. apt, crates.io, PyPI and GitHub releases work through the proxy;
anything else needs `devbox allow` first. `recreate` starts from the base again, so such installs are lost;
keep a setup script in the project if you need to repeat them.

`devbox copy-login <from> <to>` copies only the Claude Code and opencode login tokens. Settings, hooks, plugins and MCP config aren't copied,
so one VM can't plant configuration that runs in another.

## opencode

The base installs opencode next to Claude Code, with `autoupdate` off (`devbox update` upgrades it) and `share` disabled.
The default allowlist includes `.opencode.ai` (installer, OpenCode Zen) and `.models.dev` (model catalogue); Anthropic is already allowed.
Log in on first run with `/connect`, or `devbox run opencode auth login`. To use another provider, allow its API domain first,
for example `devbox allow openai.com`.

## GitHub

Every VM has `gh` installed. Git in the VM rewrites `git@github.com:` remotes to HTTPS, because SSH is blocked,
and uses gh as its credential helper. The repo's own `.git/config` is untouched. Each VM gets its own token:

```bash
devbox gh-login my-app                    # prompts for the token (not echoed)
devbox gh-login my-app < ~/secrets/token  # or pipe it from a file outside any project
```

Use a fine-grained token limited to the VM's repos, with Contents, Pull requests and Issues set to read/write,
and no Workflows or Administration. Protect `main` with a ruleset that requires PRs.
`devbox recreate` keeps the gh login, like the Claude Code and opencode logins.

## Commands

| Command | |
|---|---|
| `claude [vm] [args]` | Claude Code; `--dangerously-skip-permissions` is what the sandbox is for |
| `opencode [vm] [args]` | opencode; self-update and session sharing are off in `~/.config/opencode/opencode.json` |
| `run [vm] <cmd…>` / `shell [vm]` / `root [vm]` | Commands and shells in the VM |
| `list`, `start [vm]`, `stop [vm]`, `stop --all` | Lifecycle |
| `gh-login [vm]` | Log gh in with a GitHub token |
| `allow <domain>`, `deny <domain>`, `reload-proxy` | Edit and apply your domain list (see below) |
| `denied [vm]`, `log` | Requests the proxy refused; the access log |
| `unlock [vm]` / `lock` | Open the proxy for one VM only, then close it |
| `verify [vm]`, `audit [vm]` | Containment checks; host-execution audit of the project |
| `snapshot [vm] [name]`, `restore [vm] <name>` | VM disk snapshots |
| `destroy [vm]`, `uninstall` | Remove one VM, or everything devbox made (never project folders) |

All devbox instances stay stopped after a host reboot (`boot.autostart=false` on the `devbox` profile); any command that needs a VM starts it.

Resources default to 8 vCPU, 16 GiB RAM and an 80 GiB disk, applied at create time:
`DEVBOX_CPUS=4 DEVBOX_MEM=8GiB devbox create small-thing ~/src/small-thing`.

## Allowed domains

The proxy's list is the defaults shipped in `default-allowed-domains.txt`, merged with your own `~/.config/devbox/domains.txt`
(`$XDG_CONFIG_HOME` or `DEVBOX_CONFIG_DIR` move it). Keep personal changes in your file, so the repo stays generic.

```
.example.com      # allow example.com and all its subdomains
example.com       # allow exactly example.com
!.pypi.org        # deny, even though a default allows it
!gist.github.com  # deny one subdomain of an allowed parent
```

`devbox allow <domain>` and `devbox deny <domain>` edit that file for you (a deny replaces an earlier allow of the same
entry, and the other way round) and reload the proxy. After editing the file by hand, run `devbox reload-proxy`.
Denies don't apply while the proxy is opened for one VM by `unlock`, `update` or `build-base`.

## What still crosses the boundary

- **The project folder is shared read-write.** Code the agent writes there runs on the host as soon as you build or use git:
  `build.rs`, dependency changes, `.cargo/config.toml`, `.git/hooks`, `.git/config` (`core.fsmonitor` and friends),
  `.envrc`, `.vscode/`. Run `devbox audit` before building or running git on the host. The recommended flow is that
  the agent commits in the VM, and either you review and push from the host, or, with `gh-login`, it pushes a branch
  and opens a PR for you to review.
- **All VMs share one allowlist.** Allowed domains can carry data out, especially GitHub.
- **`unlock` and `update` open the proxy for one VM.** Other VMs stay locked, and can't take that VM's IP:
  every VM's NIC has MAC and IPv4 filtering, which `verify` checks.
- **Snapshots cover the VM disk only.**

## Troubleshooting

- **`verify` fails on direct internet or on the host being reachable.** Check that Incus uses nftables
  (`incus info | grep -i firewall`) and that `incus config device show <vm>` lists `security.acls`.
- **The proxy has no internet.** Docker sets `FORWARD` to drop; allow `devbox-up` in `DOCKER-USER`.
  With firewalld, put `devbox-net` and `devbox-up` in the `trusted` zone.
- **Subnet clash.** Set `DEVBOX_SANDBOX_CIDR` and `DEVBOX_UPLINK_CIDR` before the first `build-base`,
  and keep them set for every later command.
- **"VMs will be full copies".** Your `default` pool isn't btrfs or ZFS. Use `DEVBOX_POOL=devbox` to make devbox create its own btrfs pool.
