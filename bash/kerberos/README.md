# Kerberos ticket maintenance

`check_ticket.sh` keeps a Kerberos ticket alive on a cluster node. It
renews when possible and re-authenticates via keytab when not. The
included systemd user units run it on a 6-hour schedule.

## One-time setup

1. **Create your keytab** (do this on a trusted machine, then copy it over):
   ```sh
   ktutil
   ktutil:  addent -password -p you@CC.IN2P3.FR -k 1 -e aes256-cts
   ktutil:  wkt ~/.config/kerberos/keytabs/you.keytab
   ktutil:  quit
   chmod 600 ~/.config/kerberos/keytabs/you.keytab
   ```
   (Sites differ — your admin may have a different recommended procedure.)

2. **Install the systemd units**:
   ```sh
   mkdir -p ~/.config/systemd/user
   cp ~/dotfiles-cluster/scripts/kerberos/kerberos-renew.service \
      ~/.config/systemd/user/
   cp ~/dotfiles-cluster/scripts/kerberos/kerberos-renew.timer \
      ~/.config/systemd/user/

   systemctl --user daemon-reload
   systemctl --user enable --now kerberos-renew.timer
   ```

3. **Verify** it ran:
   ```sh
   systemctl --user status kerberos-renew.timer
   systemctl --user list-timers kerberos-renew.timer
   tail ~/.config/kerberos/kerberos.log
   ```

## Configuration

Override defaults via env vars (e.g. in `~/.zshrc.local`):

| Variable         | Default                  | Purpose                              |
|------------------|--------------------------|--------------------------------------|
| `KRB_USERNAME`   | `$(whoami)`              | Principal username                   |
| `KRB_REALM`      | `CC.IN2P3.FR`            | Realm (set per site)                 |
| `KRB_CONFIG_DIR` | `~/.config/kerberos`     | Where keytab + log live              |

For IFIC or other realms, set `KRB_REALM` in `profiles/glui.zsh` (or
wherever fits).

## Without systemd

If your cluster doesn't have user systemd (some older nodes), use cron:

```cron
# m  h  dom mon dow  cmd
  */15 * *   *   *  $HOME/dotfiles-cluster/scripts/kerberos/check_ticket.sh
```

Or just call the script manually before long-running jobs that need
authenticated access:

```sh
~/dotfiles-cluster/scripts/kerberos/check_ticket.sh
```
