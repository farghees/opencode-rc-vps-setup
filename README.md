# opencode-rc-vps-setup

Run OpenCode web (`opencode web`) on a Linux VPS 24/7 as a remote-control service. It uses a
systemd user unit that starts a detached tmux session on its own tmux socket, and linger so it
comes back after a reboot without anyone logging in. The web UI listens only on a private address
(Tailscale by default) and requires basic-auth credentials.

This is an agent skill. It can be installed with `npx skills` and used by Claude Code, or run
directly as a shell script.

> **Not affiliated with OpenCode or Anthropic. Use at your own risk.** The web UI can run shell
> commands on the host. The scripts write a systemd user unit, a wrapper and a credentials file,
> and enable linger (which needs sudo). Read them before running.

Sister project for Claude Code: [claude-rc-vps-setup](https://github.com/farghees/claude-rc-vps-setup).

## Requirements

- Linux with systemd and a user manager (mainstream distros)
- OpenCode with the native installer (binary at `~/.opencode/bin/opencode`), a version that has
  the `web` subcommand (`opencode web --help` must work)
- `tmux`, `curl`, `openssl` and `python3` (e.g. `sudo apt install tmux`)
- Tailscale up on the VPS (`tailscale ip -4` prints an address), or an explicit private IPv4
  address passed with `--bind`
- A provider API key for OpenCode (for example `OPENROUTER_API_KEY`), added after install
- sudo, once, to enable linger
- Optional, for `--tailscale-serve`: the `tailscale` CLI, and Serve enabled once for your tailnet

## Install

**1. Via the skills CLI**

```bash
npx skills add farghees/opencode-rc-vps-setup
```

Then ask Claude: "set up OpenCode web on this VPS".

**2. Manually**

```bash
git clone https://github.com/farghees/opencode-rc-vps-setup
mkdir -p ~/.claude/skills && cp -r opencode-rc-vps-setup/skills/opencode-rc-vps-setup ~/.claude/skills/
```

**3. Run the script directly**

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh
```

Options:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--port N` | `4096` | Port to listen on (1024 to 65535) |
| `--bind IP` | `tailscale ip -4` | IPv4 address to listen on. `0.0.0.0`, `::` and public addresses are refused. Loopback is allowed but reachable only from the host |
| `--username NAME` | `admin` | Basic-auth user name. Written only if `rc.env` has none yet |
| `--workdir DIR` | `$HOME` | Directory OpenCode starts in |
| `--tailscale-serve` | off | Also publish the service at a tailnet-only HTTPS URL with Tailscale Serve (see below) |
| `--serve-port N` | `8443` | HTTPS port for Tailscale Serve. Port 443 is often used by another web server |

Example with explicit values:

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh --port 4096 --bind 100.x.y.z --username admin --workdir ~/projects
```

The script is idempotent. Re-running it rewrites the unit and wrapper (keeping a timestamped backup
if they changed) and never overwrites existing credentials or provider keys.

## Open it

From a device on the same tailnet, browse to `http://<bind-address>:<port>` and sign in with the
user name and password from `rc.env`.

## Optional: an HTTPS URL on the tailnet (Tailscale Serve)

With `--tailscale-serve` the installer also puts the service behind Tailscale Serve, which gives a
URL of the form `https://<machine>.<tailnet>.ts.net:8443/` with a valid certificate:

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh --tailscale-serve
```

- **One-time admin step:** Serve must be enabled for your tailnet. If it is not, the installer prints
  a `login.tailscale.com/f/serve?node=...` link. Enable Serve there, then re-run the command. The
  service runs either way.
- **Tailnet only.** Serve is never Funnel. Funnel would publish the UI to the internet.
- **Phone:** join the tailnet with the Tailscale app, open the HTTPS URL, then use "Add to Home Screen".
- The installer checks the URL (401 without credentials, 200 with them) and refuses to overwrite a
  Serve handler on the same port that points elsewhere. `uninstall.sh` removes the handler only when
  it proxies to this service.

Details and troubleshooting are in `skills/opencode-rc-vps-setup/SKILL.md`.

## View the password

```bash
grep -E '^OPENCODE_SERVER_(USERNAME|PASSWORD)=' ~/.config/opencode/rc.env
```

The file is `chmod 600`. Do not paste it into chats, tickets or logs.

## Add a provider API key

Put the key in `~/.config/opencode/rc.env` (for example `OPENROUTER_API_KEY=...`), then restart:

```bash
systemctl --user restart opencode-rc.service
```

The install script warns if no `*_API_KEY` entry is present. The model and provider settings live in
`~/.config/opencode/opencode.jsonc`.

## Logs

```bash
systemctl --user status opencode-rc.service
journalctl --user -u opencode-rc.service -n 50
tmux -L opencode-rc attach -r -t opencode-rc     # read-only view; detach with Ctrl-b, then d
```

Do not press Ctrl-c in the attached tmux session, because that stops OpenCode.

## Uninstall

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh                      # keeps rc.env and linger
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh --purge              # also deletes rc.env (password and API keys)
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh --disable-linger     # also turns off linger (affects all user services)
```

OpenCode itself, `opencode.jsonc` and the rest of `~/.config/opencode` are not touched. A Tailscale Serve
handler on `--serve-port` (default 8443) is removed only if it proxies to this service.

## Security notes

- The unit binds to one private address. It never binds `0.0.0.0`.
- The optional Serve URL is tailnet only. Do not switch it to `tailscale funnel`, which is public.
- The wrapper refuses to start without `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD`.
- Anyone who can sign in can run commands as your user on the VPS. Keep the port off the public
  internet, keep Tailscale ACLs tight, and rotate the password by editing `rc.env` and restarting.
- Provider API keys are stored in `rc.env` with `chmod 600`. Treat that file as a secret.

## Repository layout

```
skills/opencode-rc-vps-setup/
  SKILL.md                  skill instructions, troubleshooting table
  scripts/install.sh        prerequisites, linger, writes wrapper and unit, starts it
  scripts/uninstall.sh      stops, disables and removes the unit and wrapper
  templates/opencode-rc.service
  templates/rc-run.sh
```

More detail and troubleshooting are in `skills/opencode-rc-vps-setup/SKILL.md`.

## License

MIT. See [LICENSE](LICENSE).
