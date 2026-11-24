#!/usr/bin/env bash
# Läuft im chroot: Pakete, Claude, Dienste, Sicherheits-Defaults.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }

# Fingerprint des Anthropic-Signaturschlüssels für das Claude-Desktop-Repo
# (laut https://code.claude.com/docs/en/desktop-linux).
# Derselbe Schlüssel signiert das Manifest der Claude Code CLI (manifest.json.sig). Damit prüft
# build/cli-fassung.sh neue Fassungen, bevor es sie meldet (#136).
CLAUDE_DESKTOP_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# Claude Code CLI in fester Fassung: die Datei für linux-x64 und ihr sha256 laut Manifest des
# Herstellers (https://downloads.claude.ai/claude-code-releases/<Fassung>/manifest.json). Für eine
# neue Fassung beide Werte zusammen ändern. Passt die Datei nicht, bricht der Build ab.
CLAUDE_CLI_VERSION="2.1.330"
CLAUDE_CLI_SHA256="f390eaa0814e6a1bff74cbb47acb74cb9c89d30ced809fe0af5af00c7bfe8ebb"

# claude_cli_laden DATEI   Lädt die Claude Code CLI in der festen Fassung nach DATEI und prüft den
#   festgelegten sha256. Status ungleich 0, wenn der Download scheitert oder die Datei nicht passt.
#   Ein Installationsskript aus dem Netz läuft dabei nicht.
claude_cli_laden() {
	curl -fsSL -o "$1" "https://downloads.claude.ai/claude-code-releases/$CLAUDE_CLI_VERSION/linux-x64/claude" || return 1
	printf '%s  %s\n' "$CLAUDE_CLI_SHA256" "$1" | sha256sum -c --status
}

# desktop_schluessel DATEI ZIEL   Schreibt aus der heruntergeladenen Schlüsseldatei DATEI nur den
#   Schlüssel mit CLAUDE_DESKTOP_FPR samt seinen Unterschlüsseln nach ZIEL. apt vertraut jedem
#   Schlüssel in der Datei hinter signed-by. Der Export allein reicht dafür nicht: Status ungleich 0,
#   wenn ZIEL danach nicht genau einen Hauptschlüssel hat, und zwar diesen. gpg arbeitet nur in
#   einem eigenen, leeren Verzeichnis, nie in dem von root.
desktop_schluessel() {
	local kh fpr=""
	kh="$(mktemp -d)" || return 1
	if gpg --homedir "$kh" --batch --quiet --no-autostart --import "$1" &&
		gpg --homedir "$kh" --batch --no-autostart --armor --export "$CLAUDE_DESKTOP_FPR" >"$2" &&
		[[ -s $2 ]]; then
		fpr="$(gpg --homedir "$kh" --batch --no-autostart --show-keys --with-colons "$2" | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }')"
	fi
	rm -rf "$kh"
	[[ $fpr == "$CLAUDE_DESKTOP_FPR" ]]
}

# Kein Dienststart im chroot
cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

log "System aktualisieren"
apt-get update -qq
apt-get full-upgrade -y -qq

log "Pakete installieren"
mapfile -t required < <(grep -v '^\s*#' /tmp/packages.list | grep -v '?$' | awk 'NF {print $1}')
mapfile -t optional < <(grep -v '^\s*#' /tmp/packages.list | grep '?$' | awk 'NF {sub(/\?$/, "", $1); print $1}')
apt-get install -y -qq --no-install-recommends "${required[@]}"
for p in "${optional[@]}"; do
	if apt-cache show "$p" >/dev/null 2>&1; then
		apt-get install -y -qq --no-install-recommends "$p" || echo "WARNUNG: optionales Paket $p nicht installierbar"
	else
		echo "HINWEIS: optionales Paket $p nicht im Archiv, übersprungen"
	fi
done

log "Claude Desktop aus dem offiziellen Anthropic-Repo"
key=/usr/share/keyrings/claude-desktop-archive-keyring.asc
roh="$(mktemp)"
curl -fsSL -o "$roh" https://downloads.claude.ai/claude-desktop/key.asc
if ! desktop_schluessel "$roh" "$key"; then
	echo "FEHLER: Im Claude-Desktop-Schlüssel steht nicht genau der Hauptschlüssel $CLAUDE_DESKTOP_FPR" >&2
	rm -f "$roh" "$key"
	exit 1
fi
rm -f "$roh"
echo "deb [arch=amd64 signed-by=$key] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
	>/etc/apt/sources.list.d/claude-desktop.list
apt-get update -qq
# Ohne Recommends: QEMU/OVMF für Cowork wird im Rettungssystem nicht gebraucht.
apt-get install -y -qq --no-install-recommends claude-desktop

log "Claude Code CLI $CLAUDE_CLI_VERSION (feste Fassung, sha256 geprüft)"
claude_real="$(mktemp)"
if ! claude_cli_laden "$claude_real"; then
	echo "FEHLER: Die Claude Code CLI $CLAUDE_CLI_VERSION ließ sich nicht laden oder hat nicht den sha256 $CLAUDE_CLI_SHA256" >&2
	rm -f "$claude_real"
	exit 1
fi
# Die CLI liegt neben dem Assistenten. /usr/local/bin/claude ist ein Skript aus rescue/bin, das
# sie ohne Projekt-Einstellungen startet (--setting-sources user).
install -m 0755 "$claude_real" /usr/local/lib/lf/claude-cli
rm -f "$claude_real"
cli_v="$(/usr/local/lib/lf/claude-cli --version)"
echo "$cli_v"
if [[ $cli_v != "$CLAUDE_CLI_VERSION "* ]]; then
	echo "FEHLER: claude-cli --version meldet '$cli_v', erwartet $CLAUDE_CLI_VERSION" >&2
	exit 1
fi
# Auch wenn eine spätere ~/.bashrc ~/.local/bin wieder vorn in den PATH setzt: In jeder
# interaktiven Shell ist "claude" das Skript des Rettungssystems.
cat >>/etc/bash.bashrc <<'EOF'

# Leuchtfeuer: claude immer ohne Projekt-Einstellungen (siehe /usr/local/bin/claude)
claude() { /usr/local/bin/claude "$@"; }
EOF

log "Benutzer für Claude: lf-claude, als root nur die lf-Werkzeuge"
# Claude läuft nicht als Live-Benutzer (sudo ohne Passwort), sondern als eigener Benutzer ohne
# Zugriff auf Blockgeräte und ohne Passwort. Gruppen: die eigene und render (GPU für Claude
# Desktop, keine Bildschirm- oder Eingabegeräte). Als root darf er nur die lf-Werkzeuge starten:
# lf-lesen (Diagnose) und lf-aufgabe (Rettungsaufgaben, nur auf das bestätigte Ziel).
# Volles sudo gibt es nur zeitlich begrenzt, wenn der Techniker es freischaltet (lf-freigabe).
getent group render >/dev/null || groupadd --system render
useradd --system --home-dir /var/lib/lf-claude --create-home --shell /bin/bash --groups render lf-claude
chmod 700 /var/lib/lf-claude
cat >/etc/sudoers.d/lf-claude <<'EOF'
# Leuchtfeuer: Claude (lf-claude) darf als root nur die lf-Werkzeuge starten.
lf-claude ALL=(root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe
EOF
chmod 0440 /etc/sudoers.d/lf-claude
visudo -cf /etc/sudoers.d/lf-claude

log "Benutzer zum Lesen von LF-SSH: lf-ssh-leser"
# Als er liest mtools beim Start die Kopie der Partition LF-SSH (sshkeys_fat in
# rescue/lib/sshkeys.sh, #123). Ein eigener Systembenutzer mit eigener Gruppe, den sonst nichts
# verwendet: ohne Home, ohne Shell, Passwort gesperrt, in keiner weiteren Gruppe. Der Selbsttest
# prüft das (sshkeys_reader_check).
useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin lf-ssh-leser

log "Live-Benutzer und Autologin"
# casper legt den Benutzer beim Boot an (sudo ohne Passwort).
#
# LIVEMEDIA_TIMEOUT: Das Live-System wird nur auf dem Medium gesucht, das das Bootmenü nennt
# (live-media=). Ohne diese Zeile durchsucht casper alle Blockgeräte, sobald der Stick beim
# ersten Versuch noch nicht da ist, und das ist bei USB-Sticks der Normalfall: Jede Partition
# mit ext, xfs, btrfs, ntfs oder vfat wird dann mit "ro" eingehängt (bei ext und xfs spielt das
# das Journal nach, schreibt also auf die Disk des Kunden), und das erste Dateisystem mit einem
# Ordner casper würde als Live-System gestartet. casper versucht es 60 Sekunden lang. Die Suche
# über alle Geräte beginnt frühestens nach der hier genannten Zahl von Sekunden, also nie.
# Die Datei kommt über den Hook von casper in die initrd (update-initramfs weiter unten).
cat >/etc/casper.conf <<'EOF'
export USERNAME="rescue"
export USERFULLNAME="Leuchtfeuer"
export HOST="lf"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="Ubuntu"
export LIVEMEDIA_TIMEOUT=3600
EOF
# Ein leeres Passwort gilt nie, und su wechselt für lf-claude zu keinem anderen Benutzer
# (GHSA-j332-2v26-m4qm, siehe rescue/lib/pam.sh). Erst nach der letzten Paketinstallation, denn
# pam-auth-update schreibt common-auth dabei neu. Das Passwort selbst sperrt
# lf-passwort-sperre.service bei jedem Start, die Konsolen melden den Live-Benutzer ohne Passwort
# an (getty@.service.d/autologin.conf).
# shellcheck source=rescue/lib/pam.sh
. /usr/local/lib/lf/pam.sh
pam_haerten / || { echo "FEHLER: PAM ließ sich nicht wie erwartet einrichten" >&2; exit 1; }

log "Locale und Tastatur (Deutsch)"
sed -i 's/^# *\(de_DE.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=de_DE.UTF-8
cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT="nodeadkeys"
XKBOPTIONS=""
BACKSPACE="guess"
EOF
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime

log "Sicherheits-Defaults für fremde Datenträger"
# mdadm: keine automatische Assemblierung (ein Resync würde auf die Quell-Disk schreiben)
install -d /etc/mdadm
echo 'AUTO -all' >/etc/mdadm/mdadm.conf
# LVM: keine Auto-Aktivierung
if [[ -f /etc/lvm/lvm.conf ]]; then
	sed -i 's/^\(\s*\)#\?\s*event_activation = .*/\1event_activation = 0/' /etc/lvm/lvm.conf
	grep -q 'auto_activation_volume_list' /etc/lvm/lvm.conf ||
		sed -i '/^activation {/a\	auto_activation_volume_list = []' /etc/lvm/lvm.conf
fi
# Kein automatisches Swap auf gefundenen Partitionen
systemctl mask swap.target >/dev/null 2>&1 || true

log "Dienste"
systemctl enable lf-theme.service lf-ready.service lf-selftest.service lf-ssh-hostkeys.service lf-passwort-sperre.service lf-ssh-schluessel.service NetworkManager.service
# SSH nur auf Wunsch über den Assistenten
systemctl disable ssh.service ssh.socket >/dev/null 2>&1 || true
# ssh.service und ssh.socket starten nur mit der Regel, die lf-claude den Weg zu sshd auf diesem
# Rechner sperrt (GHSA-cmcp-h343-c4gj). Nach dem disable, damit es die Verweise nicht entfernt.
systemctl enable lf-claude-ssh-sperre.service
# systemd-ssh-generator bindet sshd sonst bei jedem Start an den AF_UNIX-Socket
# /run/ssh-unix-local/socket (Modus 0666) und in einer VM mit /dev/vsock an vsock-Port 22, beides
# unabhängig vom Menü und an der Regel vorbei, die nur TCP sieht (GHSA-cmcp-h343-c4gj).
mkdir -p /etc/systemd/system-generators
ln -s /dev/null /etc/systemd/system-generators/systemd-ssh-generator
# Keine Wartezeit auf Netzwerk beim Booten
systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service >/dev/null 2>&1 || true
# Keine automatischen Updates im Live-System
systemctl mask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
# Strg+Alt+Entf startet keinen Neustart (auch nicht siebenmal in zwei Sekunden:
# /usr/lib/systemd/system.conf.d/lf-strg-alt-entf.conf aus dem Overlay). Er liefe geordnet, mit dem
# Code, den root während einer Claude-Freigabe abgelegt haben kann (lf-freigabe).
systemctl mask ctrl-alt-del.target

log "initramfs neu bauen"
update-initramfs -u -k all

log "Aufräumen"
# SSH-Hostschlüssel entstehen bei der Installation von openssh-server. Im öffentlichen ISO wären sie
# auf jedem Stick dieselben, und jeder könnte sich mit ihnen als das Rettungssystem ausgeben
# (GHSA-72hw-w482-prv6). Eigene erzeugt lf-ssh-hostkeys.service bei jedem Start.
rm -f /etc/ssh/ssh_host_*
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/apt/* /root/.cache
rm -f /usr/sbin/policy-rc.d
: >/etc/machine-id
# D-Bus nennt dieselbe Maschinen-ID wie systemd, die bei jedem Start neu entsteht. Als eigene Datei
# aus dem Build hätten alle Starts derselben ISO dieselbe D-Bus-ID, und sie stünde im öffentlichen
# ISO (#144). selftest_machine_id prüft es beim Start.
ln -sf /etc/machine-id /var/lib/dbus/machine-id
