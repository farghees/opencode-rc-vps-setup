---
name: opencode-rc-vps-setup
description: Set up OpenCode web (`opencode web`) on a Linux VPS as a 24/7 remote-control service with a password, bound to a private address (Tailscale by default), using a systemd user unit and a detached tmux session. Optionally adds a tailnet-only HTTPS URL via Tailscale Serve. Use when the user asks to set up OpenCode web or OpenCode remote access on a VPS, "opencode RC", "run opencode web 24/7 with a password over Tailscale", "make opencode web survive reboot", or when an OpenCode web service on a server has dropped or will not start.
---

# OpenCode web as a remote-control service on a VPS (systemd + tmux)

This runs `opencode web` as a systemd user service. It listens on one private address (the
Tailscale IP by default), requires basic-auth credentials, restarts itself if it exits, and comes
back after a reboot without anyone logging in.

Use it when you want to reach OpenCode from a phone or laptop over your tailnet. The web UI can run
shell commands on the host, so it must never listen on a public or wildcard address.

## Prerequisites

1. Linux with systemd and a user manager.
2. OpenCode installed. The native installer puts it at `~/.opencode/bin/opencode`. Check:
   `~/.opencode/bin/opencode web --help`. The `web` subcommand must exist.
3. `tmux` installed (e.g. `sudo apt install tmux`).
4. `curl`, `openssl` and `python3` (used by the checks and the bind-address validation).
5. A private address to bind:
   - Tailscale up (`tailscale ip -4` prints an address). This is the default.
   - Or an explicit private IPv4 address passed with `--bind`, for example on a LAN or a WireGuard tunnel.
6. Sudo once, to enable linger.

The installer refuses `0.0.0.0`, `::`, and public addresses. Loopback (`127.0.0.1`) is allowed but
then only the host itself can reach the UI.

## Quick path

```bash
# 1. Install the script's prerequisites above, then install the service.
#    Defaults: port 4096, bind = tailscale ip -4, username admin, workdir $HOME.
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh

# 2. Add a provider API key to rc.env, choose a model, then restart (see below).
# 3. Open the URL the installer prints and log in with the username and the password from rc.env.
```

Options: `--port 4096`, `--bind <IPv4>`, `--username <name>`, `--workdir <dir>`, `--tailscale-serve`, `--serve-port 8443`. Run with `--help` for details. The HTTPS option is described in its own section below.

## What gets installed

| Piece | Location | Purpose |
|---|---|---|
| systemd user unit | `~/.config/systemd/user/opencode-rc.service` | Starts and stops the service, enabled at boot |
| wrapper | `~/.config/opencode/rc-run.sh` (mode 700) | Loads `rc.env`, runs `opencode web`, restarts it on exit |
| credentials and keys | `~/.config/opencode/rc.env` (mode 600) | Basic-auth user and password, provider API keys |
| detached tmux session | own tmux server on socket `opencode-rc`, session `opencode-rc` | Keeps the web UI running with no terminal |
| linger | `loginctl enable-linger $USER` | User manager, and so the unit, starts at boot |
| Tailscale Serve (only with `--tailscale-serve`) | `tailscale serve` config, kept by tailscaled | Tailnet-only HTTPS URL in front of the service, persists across reboots |

`templates/opencode-rc.service` and `templates/rc-run.sh` are the templates. `scripts/install.sh` fills
in the absolute paths, the bind address, the port and the working directory. Nothing is hardcoded to a user.

`~/.config/opencode/opencode.jsonc` holds the model choice. It contains no secrets, so it is safe to share.

## Step by step (manual equivalent of install.sh)

1. **Check OpenCode.** `~/.opencode/bin/opencode web --help` must work. Use the absolute path in the
   unit: a non-interactive systemd shell does not reliably find `opencode` on PATH.
2. **Write `rc.env`** (mode 600) with at least:
   ```
   OPENCODE_SERVER_USERNAME=admin
   OPENCODE_SERVER_PASSWORD=<long random value>
   ```
   Generate the password with `openssl rand -hex 24`. Never put real values in a shared file.
3. **Write the wrapper and unit** from the templates, replacing `__TMUX__`, `__OPENCODE__`,
   `__ENV_FILE__`, `__WORKDIR__`, `__BIND__`, `__PORT__` and `__WRAPPER__`.
4. **Enable linger.** `sudo loginctl enable-linger "$USER"`. Check: `loginctl show-user "$USER" -p Linger`.
5. **Start.** `systemctl --user daemon-reload && systemctl --user enable --now opencode-rc.service`.
6. **Verify** (next section).

## Choosing a model and a provider

OpenCode reads the model from `~/.config/opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "<provider>/<model-id>"
}
```

Use the `provider/model` form that your provider documents. Example: `openrouter/<vendor>/<model>` for
OpenRouter. Free models change often, so check the provider's list before you pick one.

Put the provider's API key in `rc.env`, not in `~/.bashrc`. The service does not read interactive shell
files, so a key exported only there is invisible to it:

```
OPENROUTER_API_KEY=<your key>
```

Rules for `rc.env`: one `KEY=value` per line, no spaces around `=`. Quote values only if they contain
spaces. The wrapper loads the file with `. file`, so anything the shell would mangle will be mangled.

After any change to `rc.env` or `opencode.jsonc`, restart the unit: `systemctl --user restart opencode-rc`.
The environment is read at start, not on every request.

## Verification

```bash
systemctl --user status opencode-rc            # active (exited or running), no failure
systemctl --user is-enabled opencode-rc        # enabled
loginctl show-user "$USER" -p Linger           # Linger=yes
tmux -L opencode-rc ls                         # opencode-rc: 1 windows (...)
curl -s -o /dev/null -w '%{http_code}\n' http://<bind-ip>:4096/                       # 401
curl -s -o /dev/null -w '%{http_code}\n' -K <(printf 'user = "%s:%s"\n' "$U" "$P") http://<bind-ip>:4096/   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4096/                       # 000 (refused) when bound to a non-loopback IP
tailscale serve status                          # with --tailscale-serve: https://<machine>.<tailnet>.ts.net:8443 (tailnet only)
curl -s -o /dev/null -w '%{http_code}\n' https://<machine>.<tailnet>.ts.net:8443/     # 401 (valid cert, no -k)
```

Read `$U` and `$P` from `rc.env` in your shell, for example with `. ~/.config/opencode/rc.env`. Do not
paste the password into chat or a log.

- 401 without credentials and 200 with them means auth is on and the server answers.
- Connection refused on `127.0.0.1` when the bind is a tailnet IP means the server is not listening on
  loopback, which is what you want.
- Connection refused on the public IP means the server is not exposed on the internet. Keep it that way.

## Access URL and password

- URL: `http://<bind-ip>:<port>/`. The default bind is the Tailscale IP, so from another tailnet device
  it is `http://100.x.y.z:4096/`.
- Username: `OPENCODE_SERVER_USERNAME` in `rc.env`.
- Password: `grep OPENCODE_SERVER_PASSWORD ~/.config/opencode/rc.env`. The installer never prints it.
- To rotate the password, edit `rc.env` and run `systemctl --user restart opencode-rc`.

The URL is plain HTTP. Tailscale's WireGuard tunnel encrypts the path between your devices. Do not
publish the port on a public interface, and do not put it behind a public reverse proxy without TLS
and extra access control.

## Optional: a tailnet-only HTTPS URL (Tailscale Serve)

Plain HTTP over the tailnet works, but some browsers and phone features want HTTPS. With
`--tailscale-serve` the installer puts the service behind Tailscale Serve. You get a URL of the form
`https://<machine>.<tailnet>.ts.net:<port>/` with a valid certificate. It is reachable only from
devices on your tailnet. The plain `http://<bind-ip>:<port>/` URL keeps working as well.

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh --tailscale-serve                    # HTTPS on port 8443
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/install.sh --tailscale-serve --serve-port 10000
```

**One-time admin step.** Tailscale Serve must be enabled for the tailnet. If it is not, the installer
prints a link such as `https://login.tailscale.com/f/serve?node=...`. Open it, enable Serve, then
re-run the same command. The service keeps running in the meantime. The installer never waits longer
than 60 seconds for the `tailscale` command, because that command blocks until Serve is enabled.

**Port.** The default is 8443. Port 443 is often used by another web server on the host (for example
Caddy on `*:443`). If the chosen port already has a Serve handler that points somewhere else, the
installer refuses to overwrite it. Choose another `--serve-port`.

**What the installer checks.** The `tailscale serve status` line for the port must say `(tailnet only)`.
The URL must answer HTTP 401 without credentials and HTTP 200 with them, and the certificate must
validate without `-k`. The certificate can take a minute to appear, so the installer retries for a while.
If a check still fails, the installer prints a warning and no URL. The service itself is unaffected.

**Re-running is safe.** If the port already proxies to this service, nothing changes and only the checks
run. `uninstall.sh` removes the Serve handler only when it proxies to this service's bind address and
port. Other Serve handlers are never touched.

**Phone tip.** Join the phone to the tailnet with the Tailscale app, open the HTTPS URL in the browser,
then choose "Add to Home Screen" to get an icon that opens it like an app.

**Never use `tailscale funnel` for this.** Funnel publishes the URL to the public internet, and the
web UI can run shell commands. Serve is tailnet only. Check with `tailscale serve status`.

## Logs

```bash
tmux -L opencode-rc attach -r -t opencode-rc       # read-only view; detach with Ctrl-b, then d
tmux -L opencode-rc capture-pane -p -t opencode-rc | tail -n 40   # last lines without attaching
journalctl --user -u opencode-rc -n 50             # systemd side: start, stop, failures
```

Use `-r` on `attach`. It is read-only, so a stray keypress cannot reach the shell.

## Day-to-day commands

| Task | Command |
|---|---|
| Restart (also after editing `rc.env` or `opencode.jsonc`) | `systemctl --user restart opencode-rc` |
| Stop | `systemctl --user stop opencode-rc` |
| Start | `systemctl --user start opencode-rc` |
| Disable at boot | `systemctl --user disable opencode-rc` |
| Change port, bind, username or workdir | re-run `install.sh` with the new options (it backs up the old unit and wrapper) |
| Update OpenCode | update it, then `systemctl --user restart opencode-rc` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Unit fails: "bind address ... not assigned after 60s" | Tailscale (or the chosen interface) was not up at boot, or the bind IP is wrong | `tailscale ip -4`; `tailscale up`; or re-run `install.sh --bind <IP>` |
| Installer: "cannot bind ... port in use" | Another process holds the port | `ss -ltnp \| grep :4096`; stop it or use `--port` |
| Pane shows `opencode: command not found` | Unit or wrapper used a bare `opencode`; non-interactive PATH | Re-run `install.sh` so the absolute path is written (`~/.opencode/bin/opencode`) |
| Web UI up, but model calls fail with auth or missing-key errors | Provider key is only in `~/.bashrc`, or not in `rc.env` at all | Add `<PROVIDER>_API_KEY=...` to `rc.env`, then restart the unit |
| Password rejected after editing `rc.env` | The unit read the old environment | `systemctl --user restart opencode-rc` |
| 200 without credentials | Basic auth not enabled, so the server is open | Stop the unit now. Check that `rc.env` has both `OPENCODE_SERVER_*` keys. The wrapper refuses to start without them, so check the wrapper and the unit's `ExecStart` |
| systemd reports the unit inactive or lost, while the tmux session is still running | The unit shared the default tmux server with another unit (e.g. a Claude Remote Control unit) | The unit must use its own socket: `tmux -L opencode-rc`. Do not use the default socket for this unit |
| `ExecStartPre` shows exit status 1 for `tmux -L opencode-rc kill-server` | Nothing was running on that socket | Harmless. The `-` prefix ignores it |
| Session missing after reboot | Linger not enabled, so the user manager does not start at boot | `sudo loginctl enable-linger "$USER"`; check `loginctl show-user "$USER" -p Linger` |
| `Failed to connect to bus` over SSH | No `XDG_RUNTIME_DIR` in the SSH session | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` |
| `--bind 0.0.0.0` refused | Wildcard binds expose the shell to every network | Bind to the Tailscale or another private IP |
| Pane shows `opencode exited (...), restarting in 5s` repeatedly | OpenCode crashes at start (bad config, bad model id, missing key) | Read the pane: `tmux -L opencode-rc capture-pane -p -t opencode-rc \| tail -n 40`. Fix `opencode.jsonc` or `rc.env` |
| Installer: "Tailscale Serve is not enabled on this tailnet" | One-time admin step not done yet | Open the printed `login.tailscale.com/f/serve?node=...` link, enable Serve, then re-run with `--tailscale-serve`. The HTTP URL works in the meantime |
| Installer warns that `tailscale serve` "did not finish within 60s" | The command was waiting for the Serve enable step (it blocks until then) | Same fix as above. The installer uses `timeout` on purpose, so it cannot hang |
| `tailscale serve` fails on 443, or 443 is busy | Another web server (e.g. Caddy on `*:443`) holds 443 | Use the default `--serve-port 8443`, or any free port |
| Installer: port already has a Serve handler for something else | The chosen HTTPS port is used by another Serve config | Pick another port with `--serve-port`. The installer does not overwrite it |
| HTTPS URL returns `000` right after enabling Serve | The certificate is still being issued | Wait a minute and retry. The installer retries automatically for about a minute |
| HTTPS returns 000 for a long time | The machine has no tailnet DNS name yet, or MagicDNS/HTTPS certificates are off in the admin console | `tailscale status --json` must show a `DNSName`. Check the admin console DNS settings |
| `tailscale serve status` shows `(Funnel on)`, or the URL works from outside the tailnet | Funnel is on for that port, which publishes it to the internet | Remove it: `sudo tailscale serve --https=<port> off`. Confirm `tailscale serve status` shows `(tailnet only)`. Do not use funnel for this skill |
| uninstall leaves a Serve handler in place | The handler proxies to a different address or port than this service | Expected. Serve is only changed when it proxies to this service. Remove other handlers by hand if you no longer want them |
| Wrapper stops at start with "... is not set in rc.env" | Credentials missing, deliberately refused | Re-run `install.sh` or add the keys to `rc.env` |

## Uninstall

```bash
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh                    # keeps rc.env and linger
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh --purge            # also deletes rc.env (password and keys)
bash ~/.claude/skills/opencode-rc-vps-setup/scripts/uninstall.sh --disable-linger   # also turns linger off (affects ALL user services)
```

This stops the service, disables and removes the unit and the wrapper, and resets the failed state.
If a Tailscale Serve handler on `--serve-port` (default 8443) proxies to this service, the handler is
removed too. Other Serve handlers are never touched.
OpenCode itself, `opencode.jsonc` and the rest of `~/.config/opencode` are not touched.

## Security notes

- The web UI can run commands on the host. Bind it to a private address only, never `0.0.0.0`.
- Basic auth is the only gate. Use a long random password (`openssl rand -hex 24`). Rotate it if it leaks.
- `rc.env` is mode 600 and holds the password and every provider key. Keep it out of git and out of chat.
- `opencode.jsonc` should hold no secrets. Keep keys in `rc.env`.
- The wrapper refuses to start without both `OPENCODE_SERVER_*` values, so the UI never runs open by accident.
- Tailscale ACLs decide which devices can reach the port. Restrict them if other people share the tailnet.
- Tailscale Serve (`--tailscale-serve`) is tailnet only. Never switch it to funnel, which is public.

## Files in this skill

- `scripts/install.sh`: prerequisite and bind-address checks, linger, creates `rc.env` or adds only
  missing keys, writes the wrapper and unit from the templates, enables and starts the service, runs the
  401 and 200 checks, prints the URL and the command to view the password. Idempotent. Run with `--help`.
  With `--tailscale-serve` it also sets up the tailnet-only HTTPS handler and verifies it.
- `scripts/uninstall.sh`: reverses the install. Keeps `rc.env` unless `--purge` is given. Removes a
  Serve handler on `--serve-port` only if it proxies to this service.
- `templates/opencode-rc.service`: the unit template (placeholders `__TMUX__`, `__WRAPPER__`, `__BIND__`, `__PORT__`, `__WORKDIR__`).
- `templates/rc-run.sh`: the wrapper template (placeholders `__ENV_FILE__`, `__WORKDIR__`, `__OPENCODE__`, `__BIND__`, `__PORT__`).
