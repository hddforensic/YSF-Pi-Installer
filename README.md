# YSF-Pi-Installer

Sets up **read-only access to your YSFReflector log** for the **YSF Sysop** iOS app, on the
Raspberry Pi (or other Debian machine) that runs your reflector.

> Version 0.1.0 (first draft, not yet released). Français : voir plus bas.

## What it does

1. Finds your reflector configuration (`YSFReflector.ini`) and log folder.
2. Creates a dedicated account (default `ysfmonitor`) that can run **one** small read-only
   program (`ysf-sysop-log`). No shell, no terminal, no port forwarding, no `sudo`.
3. Lets the app log in to that account with an **SSH key** (recommended), a **generated
   password**, or both.
4. Optionally adds a daily cleanup of old log files (default: keep 180 days). If you already
   have a cleanup job for this log folder, it is left alone.

It never touches your reflector, its configuration, its service, or your own accounts.
The SSH settings it adds apply to the dedicated account only; the SSH service is *reloaded*
(not restarted), so your current session stays open.

## Install

Download it, read it, then run it (recommended):

```bash
curl -fsSLO https://raw.githubusercontent.com/hddforensic/YSF-Pi-Installer/main/install.sh
less install.sh
sudo bash install.sh --dry-run     # preview: changes nothing
sudo bash install.sh
```

The script asks how the app should log in. With **SSH key**, the key is created *inside the
app, on your iPhone*; copy its **public** key into the question the script asks. The private
key never leaves the phone. With **password**, a long random password is generated and shown
**once** at the end: type it into the app.

**Installing over SSH, with no physical access to the Pi?** Add a safety timer. Before it touches
the SSH settings, the installer arms a timer; if you do not cancel it, the new SSH settings are
removed automatically after the delay, even if the new settings were to lock you out:

```bash
sudo bash install.sh --rollback-timer 30
```

Keep your current SSH session open, check that the app (or `ssh` as the new account) can
log in, then cancel the timer:

```bash
sudo systemctl stop ysf-sysop-rollback.timer
```

Uninstall at any time (logs and reflector are never touched):

```bash
sudo bash install.sh --uninstall
```

## Options

| Option | Meaning |
|---|---|
| `--dry-run` | Show what would be done, change nothing (works without `sudo`, a few checks are skipped) |
| `--auth key\|password\|both` | How the app logs in (asked if omitted) |
| `--pubkey "ssh-ed25519 AAAA..."` / `--pubkey-file F` | Public key from the app (repeatable) |
| `--reset-password` | Generate a new password |
| `--replace-keys` | Keep only the keys given with `--pubkey` (by default the already authorized keys stay) |
| `--keys-only` | Only update the authorized keys (with `--pubkey`, and `--replace-keys` to drop the others) |
| `--retention-only` | Only (re)install the log cleanup job (`--retention-days N`), or remove it (`--no-retention`) |
| `--user NAME` | Service account name (default `ysfmonitor`) |
| `--ini PATH` | Reflector configuration file (default: detected, else `/etc/YSFReflector.ini`) |
| `--retention-days N` / `--no-retention` | Log cleanup (default 180 days, minimum 7) |
| `--rollback-timer MIN` | Safety net for remote installs: if you do not cancel it, the SSH settings are removed automatically after MIN minutes (see below) |
| `-y`, `--yes` | No confirmation question (give the answers as options) |
| `--uninstall` | Remove everything this installer added |

## Requirements and limits (v0.1)

- Debian-family Linux with systemd and OpenSSH (Raspberry Pi OS, Debian 12/13).
- `[Log]` in `YSFReflector.ini` must have `FilePath`, `FileRoot`, `FileLevel=1` (or 2) and
  `FileRotate=1` (the default). The installer checks this and explains what to change.
- Log files must be readable by ordinary accounts (the reflector's default).
- Folder and file names without spaces.
- The app reaches the Pi over SSH: to use it away from home, the SSH TCP port of the Pi must
  be forwarded on your router. This installer cannot do that for you.
- Log files are named with the **UTC** date (that is how YSFReflector rotates them), not local time.

## Security notes

- Key login is recommended. A password on an SSH port exposed to the Internet will receive
  automated guessing attempts; the account can only read the log, but the log contains
  callsigns and IP addresses of linked stations.
- The installer validates what it writes: it runs `sshd -t`, checks the effective settings
  for the new account, checks that other accounts' settings are unchanged, and removes its
  changes if anything looks wrong.
- Read the script before running it as root. That is why the download-then-run method is recommended.

## Helper protocol (v1, for app developers)

The app runs one of these as the SSH command; the account's `ForceCommand` passes it to
`/usr/local/bin/ysf-sysop-log` (anything else is refused):

| Command | Output |
|---|---|
| `version` | the helper version |
| `status` | `key=value` lines: `helper_version`, `utc_now`, `utc_date`, `today_file_size`, `reflector_running`, `reflector_name`, `reflector_port` |
| `list` | one line `YYYY-MM-DD size` per daily log file |
| `read YYYY-MM-DD OFFSET` | raw log bytes of that UTC day from byte `OFFSET` to the end |
| `follow YYYY-MM-DD OFFSET` | like `read`, then keeps streaming; only for today's UTC date; ends by itself (exit 0) just after UTC midnight |

Errors: one line `ERR <message>` on stdout and a non-zero exit status. A *future or just-rolled*
day's file may not exist until the reflector writes its first line: `read` returns nothing for
today's date in that case, and `follow` waits.

## License

No license has been chosen yet.

---

# Français

**YSF-Pi-Installer** prépare, sur le Raspberry Pi qui héberge votre réflecteur YSF, un accès
**en lecture seule** au log pour l'application iOS **YSF Sysop**.

**Ce qu'il fait** : trouve la configuration et le dossier de logs du réflecteur ; crée un
compte dédié (`ysfmonitor`) qui ne peut lancer qu'un petit programme de lecture (pas de
terminal, pas de `sudo`, pas de redirection de ports) ; permet à l'app de se connecter par
**clé SSH** (recommandé), par **mot de passe généré**, ou les deux ; ajoute, si vous le
voulez, un nettoyage quotidien des vieux logs (180 jours par défaut, sans toucher à un
nettoyage déjà existant).

**Ce qu'il ne fait pas** : il ne touche ni au réflecteur, ni à sa configuration, ni à son
service, ni à vos propres comptes. Le service SSH est *rechargé* (pas redémarré) : votre
session reste ouverte.

**Installation** (télécharger, lire, puis exécuter) :

```bash
curl -fsSLO https://raw.githubusercontent.com/hddforensic/YSF-Pi-Installer/main/install.sh
less install.sh
sudo bash install.sh --dry-run     # aperçu : ne change rien
sudo bash install.sh
```

Avec la **clé SSH**, la clé est créée *dans l'app, sur votre iPhone* ; vous collez sa clé
**publique** quand le script la demande. La clé privée ne quitte jamais le téléphone. Avec le
**mot de passe**, un mot de passe long et aléatoire est affiché **une seule fois** à la fin.

**Installation à distance, sans accès physique au Pi ?** Ajoutez une minuterie de sécurité :
si vous ne l'annulez pas, les nouveaux réglages SSH sont retirés automatiquement après le délai,
même s'ils vous avaient coupé l'accès. Gardez votre session SSH ouverte, vérifiez que la
connexion du nouveau compte fonctionne, puis annulez la minuterie.

```bash
sudo bash install.sh --rollback-timer 30
sudo systemctl stop ysf-sysop-rollback.timer     # une fois la connexion vérifiée
```

**Désinstaller** (les logs et le réflecteur ne sont jamais touchés) :

```bash
sudo bash install.sh --uninstall
```

**Bon à savoir** : les fichiers de log portent la date **UTC** (c'est ainsi que YSFReflector
les fait tourner), pas l'heure locale. Pour utiliser l'app hors de la maison, le port SSH du Pi
doit être redirigé sur votre routeur : le script ne peut pas le faire.
