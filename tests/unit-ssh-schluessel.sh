#!/usr/bin/env bash
# Unit-Test (#99): eigene SSH-Schlüssel von der Partition LF-SSH des Sticks.
#
# - sshkeys_check: jede Regel für eine Zeile (Typ, Bits, Optionen, Base64, Doppelte, Obergrenzen),
#   Zeilenenden von Windows, BOM, Kommentare nur gefiltert, private Schlüssel nie.
# - sshkeys_load: nur vom geprüften Startmedium, nur eine Partition LF-SSH mit FAT, nur lesend
#   eingehängt und gleich wieder ausgehängt, eine Datei bis 64 KiB.
# - Bestätigen beim Einschalten (alle zusammen oder je neuem Schlüssel), restrict,pty, mit Schlüssel
#   kein Passwort, ohne kein Schlüssel.
# - Hostschlüssel mit verschlüsseltem Speicher und die Markierung nach einer Freigabe (lf-freigabe).
# - Protokoll der Anmeldungen, Hinweis im Hauptmenü, lf.conf, Dienst beim Start.
# - sshd -T mit lf.conf (selftest_ssh), übersprungen ohne sshd.
#
# Alle Schlüssel entstehen beim Lauf mit ssh-keygen in einem eigenen Ordner, keiner liegt im Repo.
# sudo, mount, umount, lsblk, blkid, systemctl, loginctl, journalctl und die Dialoge sind
# Attrappen. Die sudo-Attrappe führt nur Dateibefehle im Testordner aus.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
# shellcheck source=rescue/lib/common.sh
. rescue/lib/common.sh
# shellcheck source=rescue/lib/tools.sh
. rescue/lib/tools.sh
# shellcheck source=rescue/lib/sshkeys.sh
. rescue/lib/sshkeys.sh
LF_LOG="$T/log"
LF_SSH_DIR="$T/etc-ssh"
SSHKEYS_DIR="$T/run/lf/ssh"
SSHKEYS_ETC="$T/etc-lf/ssh"
SSHKEYS_MODE_CONF="$T/sshd_config.d/00-lf-anmeldung.conf"
LF_BOOT_ENV="$T/lf-boot.env"
mkdir -p "$LF_SSH_DIR" "${SSHKEYS_MODE_CONF%/*}"
CONF=build/overlay/etc/ssh/sshd_config.d/lf.conf
UNIT=build/overlay/etc/systemd/system/lf-ssh-schluessel.service
FR=rescue/bin/lf-freigabe

ENCRYPTED=0 SSH_ACTIVE=0 YESNO=1 KEYGEN_OK=1 START_OK=1
persist_encrypted() { ((ENCRYPTED)); }
is_online() { return 0; }
# Die Regel für lf-claude und die Wege zu sshd neben ssh.service prüft unit-ssh-lokal.sh. Hier
# gelten sie als in Ordnung.
tools_ssh_sperre() { return 0; }
# Von SSH läuft nichts mehr (tools_ssh_rest): keine Sitzung von logind, kein cgroup von ssh.service.
# Ohne das läse der Test die des Rechners, auf dem er läuft. Den Hinweis im Hauptmenü prüft unten
# eine eigene Attrappe.
loginctl() { :; }
LF_SSH_CGROUP="$T/kein-cgroup"
ip() { echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"; }
ui_msg() { printf '%s\n%s\n--\n' "$1" "$2" >>"$T/dialog"; }
ui_text() { printf '%s\n%s\n--\n' "$1" "$2" >>"$T/dialog"; }
# Ja, wenn der Text "ja-" enthält, Nein bei "nein-", sonst YESNO (0 = Ja). In $T/fragen: Titel|Vorgabe
ui_yesno() {
	printf '%s\n%s\n--\n' "$1" "$2" >>"$T/dialog"
	printf '%s|%s\n' "$1" "${3:-}" >>"$T/fragen"
	case $2 in
	*ja-*) return 0 ;;
	*nein-*) return 1 ;;
	esac
	return "$YESNO"
}
systemctl() {
	printf 'systemctl %s\n' "$*" >>"$T/calls"
	if [[ $1 == is-active ]]; then
		((SSH_ACTIVE)) && return 0
		return 3
	fi
	[[ $* == "start ssh" ]] && ! ((START_OK)) && return 1
	return 0
}
journalctl() {
	printf 'journalctl %s\n' "$*" >>"$T/calls"
	cat "$T/journal" 2>/dev/null
}
sudo() {
	local x skip=0
	local -a a=()
	printf '%s\n' "$*" >>"$T/sudo"
	for x in "$@"; do
		if [[ $x == /* && $x != "$T"/* && $x != /dev/null ]]; then
			echo "$*" >>"$T/sudo-abgelehnt"
			return 1
		fi
	done
	case $1 in
	install)
		shift
		for x in "$@"; do
			if ((skip)); then
				skip=0
				continue
			fi
			case $x in
			-o | -g) skip=1 ;;
			*) a+=("$x") ;;
			esac
		done
		command install "${a[@]}"
		;;
	cat | tee | chmod | test | head | rm | sh | mkdir) "$@" ;;
	ssh-keygen)
		# ssh-keygen -A: hier nur ed25519 im Testordner
		if [[ ${2:-} != -A ]] || ((!KEYGEN_OK)); then return 1; fi
		[[ -e $LF_SSH_DIR/ssh_host_ed25519_key ]] ||
			command ssh-keygen -q -t ed25519 -N '' -C test -f "$LF_SSH_DIR/ssh_host_ed25519_key" </dev/null
		;;
	chpasswd) cat >/dev/null ;;
	systemctl | journalctl) "$@" ;;
	*) return 0 ;;
	esac
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
reset() { rm -f "$T/sudo" "$T/dialog" "$T/fragen" "$T/calls" "$LF_LOG"; }

K=$T/k
mkdir -p "$K"
# kg TYP NAME [BITS]   Ein Schlüsselpaar für diesen Lauf, Kommentar = NAME
kg() {
	local -a b=()
	[[ -n ${3:-} ]] && b=(-b "$3")
	command ssh-keygen -q -N '' -t "$1" "${b[@]}" -C "$2" -f "$K/$2" </dev/null
}
pub() { cat "$K/$1.pub"; }
blob() { awk '{print $2}' "$K/$1.pub"; }
fp() { command ssh-keygen -l -E sha256 -f "$K/$1.pub" | awk '{print $2}'; }
hostfp() { command ssh-keygen -l -E sha256 -f "$LF_SSH_DIR/ssh_host_ed25519_key.pub" 2>/dev/null | awk '{print $2}'; }
for n in ed1 ed2 ed3; do kg ed25519 "$n"; done
kg ecdsa ec256 256
kg ecdsa ec384 384
kg ecdsa ec521 521
kg rsa rsa3072 3072
kg rsa rsa2048 2048
# Sicherheitsschlüssel (FIDO) gibt es hier nicht. Ihre öffentlichen Schlüssel haben dasselbe
# Format mit einem eigenen Typ und dem Namen der Anwendung, gebaut aus ed1 und ec256.
SK=0
if command -v python3 >/dev/null; then
	python3 -I - "$K/ed1.pub" "$K/ec256.pub" >"$K/sk" <<'PY' && SK=1
import base64, struct, sys


def s(b):
    return struct.pack(">I", len(b)) + b


def fields(path):
    blob = base64.b64decode(open(path).read().split()[1])
    out, o = [], 0
    while o < len(blob):
        n = struct.unpack(">I", blob[o:o + 4])[0]
        out.append(blob[o + 4:o + 4 + n])
        o += 4 + n
    return out


ed, ec = fields(sys.argv[1]), fields(sys.argv[2])
for t, body, c in (("sk-ssh-ed25519@openssh.com", s(ed[1]), "sk-ed"),
                   ("sk-ecdsa-sha2-nistp256@openssh.com", s(ec[1]) + s(ec[2]), "sk-ec")):
    print(t, base64.b64encode(s(t.encode()) + body + s(b"ssh:")).decode(), c)
PY
fi

echo "Prüfung jeder Zeile (sshkeys_check):"
# chk   sshkeys_check für $T/in. Meldungen hängt es an, wie beim Laden an eine leere Datei.
chk() {
	rm -f "$T/keys" "$T/msgs"
	sshkeys_check "$T/in" "$T/keys" "$T/msgs"
}
{
	pub ed1
	pub ec256
	pub ec384
	pub ec521
	pub rsa3072
	((SK)) && cat "$K/sk"
} >"$T/in"
chk
want=$((5 + 2 * SK))
check "alle erlaubten Typen gelten ($want Zeilen), ohne Meldung" '[[ $(wc -l <"$T/keys") == "$want" && ! -s $T/msgs ]]'
check "die Zeile bleibt Typ, Schlüssel und Kommentar" 'grep -qxF "ssh-ed25519 $(blob ed1) ed1" "$T/keys" && grep -qxF "ssh-rsa $(blob rsa3072) rsa3072" "$T/keys"'
if ((SK)); then
	check "Sicherheitsschlüssel (sk-ssh-ed25519, sk-ecdsa-sha2-nistp256)" 'grep -q "^sk-ssh-ed25519@openssh.com AAAA.* sk-ed$" "$T/keys" && grep -q "^sk-ecdsa-sha2-nistp256@openssh.com AAAA.* sk-ec$" "$T/keys"'
else
	echo "  übersprungen: Sicherheitsschlüssel (kein python3)"
fi

long=$(printf 'A%.0s' $(seq 8200))
{
	echo "# Kommentar"
	echo ""
	echo "ssh-dss AAAAB3NzaC1kc3MAAACBAP"
	echo "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQ"
	echo "command=\"true\" $(pub ed1)"
	echo "restrict $(pub ed1)"
	echo "no-pty,no-port-forwarding $(pub ed1)"
	echo "from=\"192.0.2.1\" $(pub ed1)"
	echo "ssh-foo AAAAB3Nz"
	echo "ssh-ed25519 kein-base64"
	echo "ssh-ed25519 AAAA$long"
	echo "ssh-rsa $(blob rsa2048) rsa2048"
	echo "ssh-ed25519 $(blob ec256) gemischt"
	echo "ecdsa-sha2-nistp256 $(blob ec384) gemischt"
	pub ed1
	echo "ssh-ed25519 $(blob ed1) anderer-kommentar"
	echo "   $(pub ed2)"
	echo "cert-authority $(pub ed2)"
	echo "sk-ssh-ed25519-cert-v01@openssh.com AAAAIHNr"
	printf '%s' "$(pub ed3)"
} >"$T/in"
chk
check "es gelten nur Zeile 15, 17 (Leerzeichen davor) und 20 (ohne Zeilenende)" '[[ $(cut -d" " -f3 "$T/keys" | tr "\n" " ") == "ed1 ed2 ed3 " ]]'
check "DSA" 'grep -qxF "Zeile 3: DSA (ssh-dss) gilt nicht." "$T/msgs"'
check "Zertifikate" 'grep -q "^Zeile 4: Zertifikate gelten nicht" "$T/msgs" && grep -q "^Zeile 19: Zertifikate gelten nicht" "$T/msgs"'
check "Optionen vor dem Schlüssel (command=, restrict, no-…, from=, cert-authority)" '[[ $(grep -c "^Zeile \(5\|6\|7\|8\|18\): Optionen vor dem Schlüssel gelten nicht. Jeder Schlüssel gilt mit restrict,pty.$" "$T/msgs") == 5 ]]'
check "unbekannter Typ" 'grep -q "^Zeile 9: kein Schlüsseltyp, der gilt" "$T/msgs"'
check "kein Base64 oder zu lang" 'grep -q "^Zeile 10: Nach dem Typ ssh-ed25519 fehlt der Schlüssel" "$T/msgs" && grep -q "^Zeile 11: Nach dem Typ ssh-ed25519 fehlt der Schlüssel" "$T/msgs"'
check "RSA unter 3072 Bit" 'grep -qxF "Zeile 12: RSA mit 2048 Bit ist zu kurz, nötig sind mindestens 3072." "$T/msgs"'
check "Typ passt nicht zum Schlüssel (ed25519/ecdsa, Kurve 256/384)" 'grep -q "^Zeile 13: " "$T/msgs" && grep -q "^Zeile 14: " "$T/msgs"'
check "Doppelte zählen einmal" 'grep -qxF "Zeile 16: derselbe Schlüssel wie in Zeile 15. Er zählt einmal." "$T/msgs"'
check "leere Zeilen, Kommentare und geltende Zeilen ohne Meldung, sonst eine je Zeile" '! grep -q "^Zeile \(1\|2\|15\|17\|20\):" "$T/msgs" && [[ $(wc -l <"$T/msgs") == 15 ]]'

esc=$(printf '\033')
{
	printf '\xef\xbb\xbf%s\r\n' "$(pub ed1)"
	printf 'ssh-ed25519 %s Name mit %s[31mFarbe%s[0m und `Backtick`\r\n' "$(blob ed2)" "$esc" "$esc"
	printf 'ecdsa-sha2-nistp256 %s %s\r\n' "$(blob ec256)" "$(printf 'x%.0s' $(seq 60))"
	printf '\r\n#Kommentar\r\n'
} >"$T/in"
chk
cr=$(grep -c $'\r' "$T/keys")
c2=$(sed -n 2p "$T/keys" | cut -d" " -f3-)
c3=$(sed -n 3p "$T/keys" | cut -d" " -f3-)
check "BOM und Zeilenenden von Windows stören nicht" '[[ $(wc -l <"$T/keys") == 3 && ! -s $T/msgs && $cr == 0 ]] && grep -qxF "ssh-ed25519 $(blob ed1) ed1" "$T/keys"'
check "Kommentar: Steuerzeichen, Backslash und Backtick als ?" '[[ $c2 == "Name mit ?[31mFarbe?[0m und ?Backtick?" ]]'
check "Kommentar: gekürzt auf 40 Zeichen" '[[ $c3 == "$(printf "x%.0s" $(seq 39))…" ]]'

command ssh-keygen -q -N '' -t ed25519 -C geheim -f "$K/geheim" </dev/null
command ssh-keygen -e -f "$K/ed2.pub" >"$K/ed2.rfc"
pk_lines=$(wc -l <"$K/geheim")
pt="PuTTY-User-Key-File"
{
	pub ed1
	cat "$K/geheim"
	printf '%s\n' "$pt-3: ssh-ed25519" "Encryption: none" "Comment: probe" "Public-Lines: 1" \
		"$(head -c 51 /dev/urandom | base64 -w0)" "Private-Lines: 1" "$(head -c 48 /dev/urandom | base64 -w0)" \
		"Private-MAC: $(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	cat "$K/ed2.rfc"
	pub ec256
} >"$T/in"
chk
l_putty=$((2 + pk_lines))
l_rfc=$((l_putty + 8))
secret=$(sed -n 2p "$K/geheim")
check "Blöcke über mehrere Zeilen: es gelten nur die Schlüssel davor und danach" '[[ $(cut -d" " -f3 "$T/keys" | tr "\n" " ") == "ed1 ec256 " ]]'
check "privater Schlüssel (OpenSSH): eine Meldung bei seiner ersten Zeile" 'grep -qxF "Zeile 2: Hier beginnt ein privater Schlüssel. Er wird nie verwendet." "$T/msgs"'
check "privater Schlüssel von PuTTY" 'grep -qxF "Zeile $l_putty: Hier beginnt ein privater Schlüssel von PuTTY. Er wird nie verwendet." "$T/msgs"'
check "RFC 4716 gilt nicht, mit dem Format, das gilt" 'grep -q "^Zeile $l_rfc: Ein Schlüssel im Format RFC 4716 .* ssh-ed25519 AAAA… Name$" "$T/msgs"'
check "zuletzt der Rat, ihn zu löschen und ein neues Paar zu erzeugen" '[[ $(tail -n1 "$T/msgs") == "Ein privater Schlüssel lag ungeschützt auf dem Stick: Ihn dort löschen und ein neues Schlüsselpaar erzeugen."* && $(wc -l <"$T/msgs") == 4 ]]'
check "vom privaten Schlüssel steht nichts in Schlüsseln oder Meldungen" '[[ -n $secret ]] && ! grep -qF "$secret" "$T/keys" "$T/msgs"'

for i in $(seq 1 21); do kg ed25519 "n$i"; done
for i in $(seq 1 21); do pub "n$i"; done >"$T/in"
chk
check "höchstens 20 Schlüssel, ab dem 21. eine Meldung" '[[ $(wc -l <"$T/keys") == 20 ]] && grep -qxF "Zeile 21: Es gelten höchstens 20 Schlüssel. Diese Zeile und alle weiteren gelten nicht." "$T/msgs"'
ssh-keygen() {
	echo x >>"$T/aufrufe"
	command ssh-keygen "$@"
}
for i in $(seq 1 100); do echo "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAAAgQ$i"; done >"$T/in"
: >"$T/aufrufe"
chk
unset -f ssh-keygen
check "ssh-keygen höchstens 60-mal (3 × 20), auch bei 100 Zeilen" '[[ $(wc -l <"$T/aufrufe") == 60 && ! -s $T/keys ]]'
check "höchstens 30 Meldungen, dann ein Hinweis" '[[ $(wc -l <"$T/msgs") == 31 && $(tail -n1 "$T/msgs") == "Weitere Meldungen sind nicht aufgeführt." ]]'

echo "Dateien auf LF-SSH (sshkeys_take):"
M=$T/mnt
mkdir -p "$M" "$SSHKEYS_DIR"
touch "$M/id_ed25519" "$M/ID_RSA" "$M/Schluessel.PPK" "$M/id_ed25519.pub" "$M/notiz.txt"
mkdir "$M/id_ordner"
take() {
	: >"$SSHKEYS_DIR/meldungen"
	rm -f "$SSHKEYS_DIR/status" "$SSHKEYS_DIR/eingang"
	sshkeys_take "$M"
	ST=$(cat "$SSHKEYS_DIR/status")
}
check "wie private Schlüssel: id_… ohne .pub und .ppk, Schreibweise egal, keine Ordner" '[[ $(sshkeys_private_files "$M" | LC_ALL=C sort | tr "\n" " ") == "ID_RSA Schluessel.PPK id_ed25519 " ]]'
take
check "ohne authorized_keys: keine-datei, eine Meldung je privatem Schlüssel" '[[ $ST == keine-datei && $(grep -c "wohl ein privater Schlüssel" "$SSHKEYS_DIR/meldungen") == 3 ]] && grep -q "^Auf LF-SSH liegt id_ed25519, wohl ein privater Schlüssel. Er wird nie verwendet." "$SSHKEYS_DIR/meldungen"'
rm -rf "$M"
mkdir -p "$M"
pub ed1 >"$M/authorized_keys.txt"
take
check "authorized_keys.txt gilt auch" '[[ $ST == gelesen && ! -s $SSHKEYS_DIR/meldungen ]] && cmp -s "$SSHKEYS_DIR/eingang" "$M/authorized_keys.txt"'
cp "$M/authorized_keys.txt" "$M/authorized_keys"
take
check "beide Dateien: keine gilt" '[[ $ST == zwei-dateien && ! -e $SSHKEYS_DIR/eingang ]]'
rm -f "$M/authorized_keys.txt" "$M/authorized_keys"
pub ed1 >"$T/anderswo"
ln -s "$T/anderswo" "$M/authorized_keys"
take
check "eine Verknüpfung zählt nicht" '[[ $ST == keine-datei && ! -e $SSHKEYS_DIR/eingang ]]'
rm -f "$M/authorized_keys"
head -c 65537 /dev/zero | tr "\0" "#" >"$M/authorized_keys"
take
check "größer als 64 KiB: gilt nicht" '[[ $ST == zu-gross && ! -e $SSHKEYS_DIR/eingang ]]'
head -c 65536 /dev/zero | tr "\0" "#" >"$M/authorized_keys"
take
check "genau 64 KiB: wird gelesen" '[[ $ST == gelesen && $(stat -c %s "$SSHKEYS_DIR/eingang") == 65536 ]]'

echo "Laden beim Start (sshkeys_load):"
STICK=$T/stick
mkdir -p "$STICK"
BOOT=/dev/sdz FS_TYPE=vfat FS_LABEL=LF-SSH MOUNT_OK=1 UMOUNT_OK=1
boot_disk() {
	[[ -n $BOOT ]] || return 1
	echo "$BOOT"
}
lsblk() {
	printf '%s\n' "$*" >>"$T/lsblk"
	printf '{"blockdevices":[{"name":"/dev/sdz","type":"disk","label":null,"partlabel":null,"children":[%s]}]}\n' "$PARTS"
}
blkid() {
	local a prev="" s=""
	for a in "$@"; do
		[[ $prev == -s ]] && s=$a
		prev=$a
	done
	printf '%s\n' "${*: -1}" >>"$T/blkid"
	case $s in
	TYPE) echo "$FS_TYPE" ;;
	LABEL) echo "$FS_LABEL" ;;
	esac
}
mount() {
	printf '%s\n' "$*" >>"$T/mount"
	((MOUNT_OK)) || return 32
	cp -a "$STICK/." "${!#}/"
}
umount() {
	printf '%s\n' "$*" >>"$T/umount"
	((UMOUNT_OK)) || return 32
	find "$1" -mindepth 1 -delete
}
P1='{"name":"/dev/sdz1","type":"part","label":"LEUCHTFEUER","partlabel":"ISO9660"}'
P2='{"name":"/dev/sdz2","type":"part","label":"LF_EFI","partlabel":"Appended2"}'
P3='{"name":"/dev/sdz3","type":"part","label":"LF-SSH","partlabel":"LF-SSH"}'
P4='{"name":"/dev/sdz4","type":"part","label":null,"partlabel":"Gap1"}'
P5='{"name":"/dev/sdz5","type":"part","label":null,"partlabel":"LF-SSH"}'
PARTS="$P1,$P2,$P3,$P4"
echo LF_BOOT_DISKS=1 >"$LF_BOOT_ENV"
load() {
	rm -f "$T/lsblk" "$T/blkid" "$T/mount" "$T/umount"
	sshkeys_load
	LOAD_RC=$?
	ST=$(cat "$SSHKEYS_DIR/status" 2>/dev/null)
}
{
	pub ed1
	echo "ssh-dss AAAAB3NzaC1kc3MAAACBAP"
	pub ed2
} >"$STICK/authorized_keys"
rm -rf "$T/run"
load
check "geladen: Zustand ok 2, die falsche Zeile gemeldet" '((LOAD_RC == 0)) && [[ $ST == "ok 2" && $(wc -l <"$SSHKEYS_DIR/kandidaten") == 2 ]] && grep -q "^Zeile 2: DSA" "$SSHKEYS_DIR/meldungen"'
check "Ordner 0755 (sshd liest als rescue), Kandidaten und Meldungen nur für root (0600)" '[[ $(stat -c %a "${SSHKEYS_DIR%/*}") == 755 && $(stat -c %a "$SSHKEYS_DIR") == 755 && $(stat -c %a "$SSHKEYS_DIR/kandidaten") == 600 && $(stat -c %a "$SSHKEYS_DIR/meldungen") == 600 ]]'
check "authorized_keys ist leer, bis SSH eingeschaltet ist (0644)" '[[ -f $SSHKEYS_DIR/authorized_keys && ! -s $SSHKEYS_DIR/authorized_keys && $(stat -c %a "$SSHKEYS_DIR/authorized_keys") == 644 ]]'
check "gefragt werden nur die Partitionen des Startmediums" '[[ $(cat "$T/lsblk") == "-J -p -o NAME,TYPE,LABEL,PARTLABEL /dev/sdz" ]]'
check "eingehängt nur lesend, ohne Geräte, setuid und Programme" '[[ $(cat "$T/mount") == "-t vfat -o ro,nodev,nosuid,noexec,uid=0,gid=0,umask=077 /dev/sdz3 $SSHKEYS_DIR/lf-ssh" ]]'
check "gleich wieder ausgehängt, nichts bleibt liegen" '[[ $(cat "$T/umount") == "$SSHKEYS_DIR/lf-ssh" && ! -e $SSHKEYS_DIR/lf-ssh && ! -e $SSHKEYS_DIR/eingang ]]'
echo "restrict,pty alt" >"$SSHKEYS_DIR/authorized_keys"
load
check "jeder Start beginnt mit leerem authorized_keys" '[[ $ST == "ok 2" && ! -s $SSHKEYS_DIR/authorized_keys ]]'
BOOT=""
load
check "ohne sicher erkannten Stick: nichts gelesen (kein-medium)" '[[ $ST == kein-medium && ! -e $T/lsblk && ! -e $T/mount && ! -s $SSHKEYS_DIR/kandidaten ]]'
BOOT=/dev/sdz
echo LF_BOOT_DISKS=2 >"$LF_BOOT_ENV"
load
check "zwei Disks mit der Kennung des Sticks: nichts gelesen (mehrdeutig)" '[[ $ST == mehrdeutig && ! -e $T/lsblk && ! -e $T/mount ]]'
rm -f "$LF_BOOT_ENV"
load
check "ohne /run/lf-boot.env ebenso" '[[ $ST == mehrdeutig && ! -e $T/mount ]]'
echo LF_BOOT_DISKS=1 >"$LF_BOOT_ENV"
PARTS="$P1,$P2,$P4"
load
check "ohne Partition LF-SSH: keine-partition" '[[ $ST == keine-partition && ! -e $T/mount ]]'
PARTS="$P1,$P2,$P3,$P4,$P5"
load
check "zwei Partitionen LF-SSH (eine nur mit dem GPT-Namen): keine gilt" '[[ $ST == zwei-partitionen && ! -e $T/mount ]]'
PARTS="$P1,$P2,$P3,$P4"
FS_TYPE=ext4
load
check "kein FAT: gilt nicht, nicht eingehängt" '[[ $ST == kein-fat && ! -e $T/mount ]] && grep -qx "/dev/sdz3" "$T/blkid"'
FS_TYPE=vfat FS_LABEL=ANDERS
load
check "FAT mit anderem Label: gilt nicht" '[[ $ST == kein-fat && ! -e $T/mount ]]'
FS_LABEL=LF-SSH MOUNT_OK=0
load
check "Einhängen scheitert: fehler, kein Ordner bleibt" '[[ $ST == fehler && ! -e $T/umount && ! -e $SSHKEYS_DIR/lf-ssh ]]'
MOUNT_OK=1 UMOUNT_OK=0
load
check "Aushängen scheitert: fehler, kein Schlüssel gilt" '[[ $ST == fehler && ! -e $SSHKEYS_DIR/eingang && ! -s $SSHKEYS_DIR/kandidaten ]]'
UMOUNT_OK=1
rm -rf "$SSHKEYS_DIR/lf-ssh"
echo "ssh-dss AAAAB3NzaC1kc3MAAACBAP" >"$STICK/authorized_keys"
load
check "nur falsche Zeilen: leer" '[[ $ST == leer && ! -s $SSHKEYS_DIR/kandidaten ]] && grep -q "^Zeile 1: DSA" "$SSHKEYS_DIR/meldungen"'
rm -f "$STICK/authorized_keys"
touch "$STICK/id_rsa"
load
check "nur ein privater Schlüssel: keine-datei mit Meldung" '[[ $ST == keine-datei ]] && grep -q "^Auf LF-SSH liegt id_rsa, wohl ein privater Schlüssel" "$SSHKEYS_DIR/meldungen"'
rm -f "$STICK/id_rsa"
check "jeder Zustand hat einen Satz für tty1 und den Selbsttest" '( for s in leer keine-datei keine-partition kein-medium mehrdeutig zwei-partitionen kein-fat zwei-dateien zu-gross fehler; do [[ -n $(sshkeys_status_text "$s") ]] || exit 1; done ) && [[ $(sshkeys_status_text ok 1) == "1 Schlüssel von LF-SSH geprüft." && $(sshkeys_status_text ok 3) == "3 Schlüssel von LF-SSH geprüft." ]]'

echo "Hinweis beim Start (sshkeys_notice):"
notice() {
	printf '%s\n' "$1" >"$SSHKEYS_DIR/status"
	printf '%s' "$2" >"$SSHKEYS_DIR/meldungen"
	rm -f "$T/dialog"
	sshkeys_notice
}
notice "ok 2" ""
check "alles gut: kein Hinweis" '[[ ! -e $T/dialog ]]'
notice keine-partition ""
check "ohne Partition (älterer Stick, CD): kein Hinweis" '[[ ! -e $T/dialog ]]'
notice kein-medium ""
check "ohne sicher erkannten Stick: kein Hinweis" '[[ ! -e $T/dialog ]]'
notice keine-datei ""
check "ohne Datei: kein Hinweis" '[[ ! -e $T/dialog ]]'
notice "ok 1" "Zeile 2: DSA (ssh-dss) gilt nicht."
check "mit Meldung: Zustand, Meldung und der Rat zur Datei" 'grep -qF "1 Schlüssel von LF-SSH geprüft.\n\nZeile 2: DSA (ssh-dss) gilt nicht.\n\nDie Datei an einem vertrauenswürdigen Rechner ändern und neu starten." "$T/dialog"'
notice leer "Zeile 1: DSA (ssh-dss) gilt nicht."
check "leer: Hinweis mit dem Rat zur Datei" 'grep -q "kein Schlüssel, der gilt" "$T/dialog" && grep -q "Die Datei an einem vertrauenswürdigen Rechner" "$T/dialog"'
notice mehrdeutig ""
check "mehrdeutig: Hinweis, aber kein Rat zur Datei" 'grep -q "mehr als eine Disk" "$T/dialog" && ! grep -q "Die Datei an einem" "$T/dialog"'
notice zwei-partitionen ""
check "zwei Partitionen: Hinweis, aber kein Rat zur Datei" 'grep -q "mehrere Partitionen LF-SSH" "$T/dialog" && ! grep -q "Die Datei an einem" "$T/dialog"'
rm -f "$SSHKEYS_DIR/status" "$T/dialog"
sshkeys_notice
check "ohne Zustand: kein Hinweis (das meldet der Selbsttest)" '[[ ! -e $T/dialog ]]'

echo "Art der Anmeldung (sshkeys_mode):"
reset
echo "restrict,pty alt" >"$SSHKEYS_DIR/authorized_keys"
sshkeys_mode schluessel
m_rc=$?
check "mit Schlüsseln: nur publickey, kein Passwort, authorized_keys bleibt" '((m_rc == 0)) && [[ $(grep -v "^#" "$SSHKEYS_MODE_CONF" | tr "\n" ";") == "PasswordAuthentication no;AuthenticationMethods publickey;" ]] && grep -qx "restrict,pty alt" "$SSHKEYS_DIR/authorized_keys"'
sshkeys_mode passwort
m_rc=$?
check "ohne: nur password, authorized_keys leer" '((m_rc == 0)) && [[ $(grep -v "^#" "$SSHKEYS_MODE_CONF" | tr "\n" ";") == "PasswordAuthentication yes;AuthenticationMethods password;" && ! -s $SSHKEYS_DIR/authorized_keys ]]'
check "als root installiert, 0644" 'grep -q "^install -m 0644 -o root -g root .* $SSHKEYS_MODE_CONF$" "$T/sudo" && [[ $(stat -c %a "$SSHKEYS_MODE_CONF") == 644 ]]'
check "die Datei steht vor lf.conf (bei sshd gilt der erste Wert)" 'grep -qF "SSHKEYS_MODE_CONF=\${SSHKEYS_MODE_CONF:-/etc/ssh/sshd_config.d/00-lf-anmeldung.conf}" rescue/lib/sshkeys.sh && [[ "00-lf-anmeldung.conf" < "lf.conf" ]]'

echo "Bestätigen beim Einschalten (sshkeys_confirm):"
HOSTFPS="   SHA256:HOSTPROBE (ED25519)"
cand() { printf '%s\n' "$@" >"$SSHKEYS_DIR/kandidaten"; }
cand "ssh-ed25519 $(blob ed1) ja-1" "ssh-ed25519 $(blob ed2) nein-2" "ecdsa-sha2-nistp256 $(blob ec256) ja-3"
: >"$SSHKEYS_DIR/authorized_keys"
reset
ENCRYPTED=0 YESNO=0
sshkeys_confirm "$HOSTFPS"
c_rc=$?
printf 'restrict,pty %s\n' "ssh-ed25519 $(blob ed1) ja-1" "ssh-ed25519 $(blob ed2) nein-2" "ecdsa-sha2-nistp256 $(blob ec256) ja-3" >"$T/want"
check "ohne verschlüsselten Speicher: eine Liste, eine Frage für alle, Vorgabe Nein" '((c_rc == 0)) && [[ $(cat "$T/fragen") == "SSH-Schlüssel|--defaultno" ]] && grep -q "Sollen die 3 Schlüssel von LF-SSH gelten" "$T/dialog"'
check "die Liste zeigt Typ, Bits, Fingerabdruck, Kommentar und die Hostschlüssel" 'grep -qF "ED25519 256 $(fp ed1) ja-1" "$T/dialog" && grep -qF "ECDSA 256 $(fp ec256) ja-3" "$T/dialog" && grep -qF "SHA256:HOSTPROBE" "$T/dialog"'
check "Ja: alle gelten, jeder mit restrict,pty" 'cmp -s "$SSHKEYS_DIR/authorized_keys" "$T/want" && [[ $(stat -c %a "$SSHKEYS_DIR/authorized_keys") == 644 ]]'
check "SSHKEYS_ACTIVE nennt sie" '[[ $(grep -c "" <<<"$SSHKEYS_ACTIVE") == 3 && $(head -n1 <<<"$SSHKEYS_ACTIVE") == "ED25519 256 $(fp ed1) ja-1" ]]'
check "ohne verschlüsselten Speicher merkt sich der Assistent nichts" '[[ ! -e $SSHKEYS_ETC/bestaetigt ]]'
: >"$SSHKEYS_DIR/authorized_keys"
reset
YESNO=1
sshkeys_confirm "$HOSTFPS"
c_rc=$?
check "Nein: keiner gilt" '((c_rc == 1)) && [[ ! -s $SSHKEYS_DIR/authorized_keys && -z $SSHKEYS_ACTIVE ]]'
reset
ENCRYPTED=1
rm -rf "$SSHKEYS_ETC"
mkdir -p "${SSHKEYS_ETC%/*}"
mkdir -m 700 "$SSHKEYS_ETC"
fp ec256 >"$SSHKEYS_ETC/bestaetigt"
sshkeys_confirm "$HOSTFPS"
c_rc=$?
printf 'restrict,pty %s\n' "ssh-ed25519 $(blob ed1) ja-1" "ecdsa-sha2-nistp256 $(blob ec256) ja-3" >"$T/want"
printf '%s\n' "$(fp ec256)" "$(fp ed1)" >"$T/want-fp"
check "verschlüsselt: eine Frage je neuem Schlüssel, Vorgabe Nein, keine für den bestätigten" '((c_rc == 0)) && [[ $(grep -c "^Neuer SSH-Schlüssel|--defaultno$" "$T/fragen") == 2 && $(grep -c "" "$T/fragen") == 2 ]]'
check "die Frage zeigt den Schlüssel und die Hostschlüssel" 'grep -qF "ED25519 256 $(fp ed1) ja-1" "$T/dialog" && grep -qF "SHA256:HOSTPROBE" "$T/dialog" && ! grep -qF "$(fp ec256)" "$T/dialog"'
check "es gelten der bestätigte und der mit Ja, nicht der mit Nein" 'cmp -s "$SSHKEYS_DIR/authorized_keys" "$T/want"'
check "gemerkt wird nur der neu bestätigte (0600)" 'cmp -s "$SSHKEYS_ETC/bestaetigt" "$T/want-fp" && [[ $(stat -c %a "$SSHKEYS_ETC/bestaetigt") == 600 && $(stat -c %a "$SSHKEYS_ETC") == 700 ]]'
reset
printf '%s\n' "$(fp ed1)" "$(fp ed2)" "$(fp ec256)" >"$SSHKEYS_ETC/bestaetigt"
sshkeys_confirm "$HOSTFPS"
c_rc=$?
check "verschlüsselt, alle bestätigt: keine Frage, alle gelten" '((c_rc == 0)) && [[ ! -e $T/fragen && $(wc -l <"$SSHKEYS_DIR/authorized_keys") == 3 ]]'
reset
ENCRYPTED=0 YESNO=0
cand "command=\"x\" ssh-ed25519 $(blob ed1) eins" "ssh-ed25519 $(blob ed2) zwei"
sshkeys_confirm "$HOSTFPS"
check "vor dem Bestätigen noch einmal geprüft: eine Zeile mit Optionen gilt nicht" '[[ $(cat "$SSHKEYS_DIR/authorized_keys") == "restrict,pty ssh-ed25519 $(blob ed2) zwei" ]]'
: >"$SSHKEYS_DIR/kandidaten"
reset
sshkeys_confirm "$HOSTFPS"
c_rc=$?
check "ohne Kandidaten: keine Frage, Status 1" '((c_rc == 1)) && [[ ! -e $T/dialog ]]'

echo "SSH einschalten (tools_ssh):"
ENCRYPTED=0 YESNO=0 SSH_ACTIVE=0
rm -f "$LF_SSH_DIR"/ssh_host_*
cand "ssh-ed25519 $(blob ed1) ed1"
reset
tools_ssh
check "mit bestätigtem Schlüssel: kein Passwort gesetzt, ssh gestartet" '! grep -q "^chpasswd" "$T/sudo" && grep -qx "systemctl start ssh" "$T/sudo"'
check "nur publickey, nur dieser Schlüssel" 'grep -qx "AuthenticationMethods publickey" "$SSHKEYS_MODE_CONF" && [[ $(cat "$SSHKEYS_DIR/authorized_keys") == "restrict,pty ssh-ed25519 $(blob ed1) ed1" ]]'
check "der Dialog nennt Schlüssel und Hostschlüssel, kein Passwort" 'grep -q "Anmeldung nur mit diesen Schlüsseln von LF-SSH" "$T/dialog" && grep -qF "$(fp ed1)" "$T/dialog" && grep -qF "$(hostfp)" "$T/dialog" && ! grep -q "Passwort (nur" "$T/dialog"'
check "das Protokoll nennt Schlüssel und Hostschlüssel" 'grep -qF "SSH eingeschaltet (nur Schlüssel von LF-SSH: ED25519 256 $(fp ed1) ed1), Hostschlüssel:" "$LF_LOG"'
reset
START_OK=0
tools_ssh
START_OK=1
check "startet ssh nicht: kein Passwort gesetzt oder gesperrt, der Dialog sagt es, ohne SSH ist an" '! grep -qE "^(chpasswd|usermod)" "$T/sudo" && grep -qF "SSH ließ sich nicht starten.\n\nDetails" "$T/dialog" && ! grep -qF "Das Einmal-Passwort gilt nicht" "$T/dialog" && ! grep -qx "SSH ist an" "$T/dialog"'
check "das Protokoll sagt es, nicht eingeschaltet" 'grep -qF "SSH ließ sich nicht starten" "$LF_LOG" && ! grep -q "SSH eingeschaltet" "$LF_LOG"'
reset
YESNO=1
tools_ssh
check "Nein: Einmal-Passwort, nur password, kein Schlüssel" 'grep -q "^chpasswd" "$T/sudo" && grep -qx "AuthenticationMethods password" "$SSHKEYS_MODE_CONF" && [[ ! -s $SSHKEYS_DIR/authorized_keys ]] && grep -q "Passwort (nur für diese Sitzung)" "$T/dialog"'
: >"$SSHKEYS_DIR/kandidaten"
reset
YESNO=0
tools_ssh
check "ohne Schlüssel von LF-SSH: keine Frage, Einmal-Passwort" '[[ ! -e $T/fragen ]] && grep -q "^chpasswd" "$T/sudo" && grep -qx "AuthenticationMethods password" "$SSHKEYS_MODE_CONF"'

echo "Hostschlüssel mit verschlüsseltem Speicher (tools_ssh_hostkeys):"
ENCRYPTED=1
rm -rf "$SSHKEYS_ETC"
rm -f "$LF_SSH_DIR"/ssh_host_*
reset
tools_ssh_hostkeys
h_rc=$?
fp1=$(hostfp)
check "beim ersten Einschalten erzeugt und gemerkt (Ordner 0700, Schlüssel 0600)" '((h_rc == 0)) && [[ -n $fp1 && -s $SSHKEYS_ETC/hostkeys/ssh_host_ed25519_key && $(stat -c %a "$SSHKEYS_ETC") == 700 && $(stat -c %a "$SSHKEYS_ETC/hostkeys") == 700 && $(stat -c %a "$SSHKEYS_ETC/hostkeys/ssh_host_ed25519_key") == 600 ]]'
# Nächster Start: lf-ssh-hostkeys.service hat schon neue erzeugt
rm -f "$LF_SSH_DIR"/ssh_host_*
command ssh-keygen -q -t ed25519 -N '' -C start2 -f "$LF_SSH_DIR/ssh_host_ed25519_key" </dev/null
reset
tools_ssh_hostkeys
check "beim nächsten Start gelten die gemerkten wieder, ohne Frage" '[[ $(hostfp) == "$fp1" && ! -e $T/fragen && $(stat -c %a "$LF_SSH_DIR/ssh_host_ed25519_key") == 600 && $(stat -c %a "$LF_SSH_DIR/ssh_host_ed25519_key.pub") == 644 ]]'
date '+%F %R' >"$SSHKEYS_ETC/hostkeys-freigabe"
reset
YESNO=0
tools_ssh_hostkeys
fp2=$(hostfp)
check "nach einer Freigabe: Rat zu neuen, mit Ja neue, gemerkt, Markierung weg" '[[ -n $fp2 && $fp2 != "$fp1" && ! -e $SSHKEYS_ETC/hostkeys-freigabe ]] && grep -q "Während einer Claude-Freigabe" "$T/dialog" && [[ $(command ssh-keygen -l -E sha256 -f "$SSHKEYS_ETC/hostkeys/ssh_host_ed25519_key.pub" | awk "{print \$2}") == "$fp2" ]]'
date '+%F %R' >"$SSHKEYS_ETC/hostkeys-freigabe"
reset
YESNO=1
tools_ssh_hostkeys
check "mit Nein: die gemerkten bleiben, die Markierung auch" '[[ $(hostfp) == "$fp2" && -e $SSHKEYS_ETC/hostkeys-freigabe ]]'
rm -rf "$SSHKEYS_ETC/hostkeys"
reset
tools_ssh_hostkeys
fp3=$(hostfp)
check "Markierung, aber noch keine gemerkt: gleich neue, ohne Frage" '[[ -n $fp3 && $fp3 != "$fp2" && ! -e $T/fragen && ! -e $SSHKEYS_ETC/hostkeys-freigabe && -s $SSHKEYS_ETC/hostkeys/ssh_host_ed25519_key ]]'
ENCRYPTED=0
rm -rf "$SSHKEYS_ETC"
reset
tools_ssh_hostkeys
check "ohne verschlüsselten Speicher wird nichts gemerkt" '[[ ! -e $SSHKEYS_ETC ]] && grep -qx "ssh-keygen -A" "$T/sudo"'
SSH_ACTIVE=1
reset
fp4=$(hostfp)
tools_ssh_newkeys
check "neue Hostschlüssel nur, solange SSH aus ist" '[[ $(hostfp) == "$fp4" ]] && grep -q "SSH ist an. Erst ausschalten" "$T/dialog"'
SSH_ACTIVE=0 YESNO=0
reset
tools_ssh_newkeys
fp5=$(hostfp)
check "Werkzeuge > SSH-Hostschlüssel neu erzeugen: Vorgabe Nein, dann neue, der Dialog zeigt sie" '[[ -n $fp5 && $fp5 != "$fp4" && $(cat "$T/fragen") == "SSH-Hostschlüssel|--defaultno" ]] && grep -qF "$fp5" "$T/dialog"'
check "Menüeintrag dafür" 'grep -q "sshneu \"SSH-Hostschlüssel neu erzeugen\"" rescue/lib/tools.sh && grep -q "sshneu) tools_ssh_newkeys ;;" rescue/lib/tools.sh'

echo "Protokoll und Hauptmenü:"
printf '%s\n' \
	"2026-11-22T10:00:00+0100 lf sshd-session[11]: Accepted publickey for rescue from 192.0.2.5 port 50000 ssh2: ED25519 SHA256:probe" \
	"2026-11-22T10:00:01+0100 lf sshd-session[12]: Failed password for rescue from 192.0.2.6 port 50001 ssh2" \
	"2026-11-22T10:00:02+0100 lf sshd[13]: Server listening on 0.0.0.0 port 22." \
	"2026-11-22T10:00:03+0100 lf sshd-session[14]: Invalid user ${esc}[31mevil from 192.0.2.7 port 50002" >"$T/journal"
reset
tools_ssh_log_sync
check "Anmeldungen und Fehlversuche kommen ins Protokoll" 'grep -qF "sshd: 2026-11-22T10:00:00+0100 lf sshd-session[11]: Accepted publickey for rescue from 192.0.2.5 port 50000 ssh2: ED25519 SHA256:probe" "$LF_LOG" && grep -qF "Failed password for rescue from 192.0.2.6" "$LF_LOG"'
check "anderes nicht, Steuerzeichen nur als ?" '! grep -q "Server listening" "$LF_LOG" && grep -qF "Invalid user ?[31mevil" "$LF_LOG" && ! grep -qF "$esc" "$LF_LOG"'
check "journalctl liest ab dem gemerkten Stand weiter" 'grep -qxF "journalctl -q -u ssh.service -o short-iso --no-pager --cursor-file=$SSHKEYS_DIR/journal-cursor" "$T/calls"'
SESS="3 7 9"
loginctl() {
	local s
	case $1 in
	list-sessions) for s in $SESS; do echo "$s 1000 rescue - pts/$s"; done ;;
	show-session)
		case "$2 $4" in
		"3 Service") echo login ;;
		"7 Service" | "9 Service") echo sshd ;;
		"7 RemoteHost") echo 192.0.2.5 ;;
		"9 RemoteHost") echo "192.0.2.6${esc}[0m" ;;
		esac
		;;
	esac
}
SSH_ACTIVE=1
check "SSH an, zwei Sitzungen: beide mit Adresse, gefiltert" '[[ $(tools_ssh_hinweis) == "SSH ist an: 2 offene Sitzungen (192.0.2.5, 192.0.2.6?[0m)." ]]'
SESS="3 7"
check "eine Sitzung" '[[ $(tools_ssh_hinweis) == "SSH ist an: 1 offene Sitzung (192.0.2.5)." ]]'
SESS="3"
check "keine Sitzung" '[[ $(tools_ssh_hinweis) == "SSH ist an, keine offene Sitzung." ]]'
SSH_ACTIVE=0
check "SSH aus: kein Hinweis" '[[ -z $(tools_ssh_hinweis) ]]'
check "das Hauptmenü übernimmt das Protokoll und zeigt den Hinweis" 'grep -qx "		tools_ssh_log_sync" rescue/lf && grep -qF "ssh=\$(tools_ssh_hinweis)" rescue/lf'

echo "Konfiguration:"
for l in "PermitRootLogin no" "DenyUsers lf-claude" "AllowUsers rescue" "AuthorizedKeysFile /run/lf/ssh/authorized_keys" \
	"KbdInteractiveAuthentication no" "UsePAM yes" "DisableForwarding yes" "AllowAgentForwarding no" "AllowTcpForwarding no" \
	"AllowStreamLocalForwarding no" "X11Forwarding no" "PermitTunnel no" "PermitUserRC no" "LogLevel VERBOSE"; do
	check "lf.conf: $l" 'grep -qxF "$l" "$CONF"'
done
check "lf.conf legt die Art der Anmeldung nicht fest (00-lf-anmeldung.conf), nie ein leeres Passwort" '! grep -qiE "^(PasswordAuthentication|AuthenticationMethods|PubkeyAuthentication|PermitEmptyPasswords)" "$CONF"'
check "sshd liest Schlüssel nur dort, wo der Assistent sie ablegt" 'grep -qF "SSHKEYS_DIR=\${SSHKEYS_DIR:-/run/lf/ssh}" rescue/lib/sshkeys.sh'
check "Dienst: einmal beim Start, vor jeder Anmeldung und vor ssh" 'grep -qx "ExecStart=/usr/local/bin/lf --ssh-schluessel" "$UNIT" && grep -qx "Type=oneshot" "$UNIT" && grep -qx "DefaultDependencies=no" "$UNIT" && grep -q "^Before=.*systemd-user-sessions.service" "$UNIT" && grep -q "^Before=.* ssh.service ssh.socket" "$UNIT" && grep -qx "WantedBy=multi-user.target" "$UNIT"'
check "Dienst nach udev und den lokalen Dateisystemen" 'grep -qx "After=local-fs.target systemd-udevd.service" "$UNIT"'
check "chroot-setup schaltet ihn ein" 'grep -q "^systemctl enable .*lf-ssh-schluessel.service" build/chroot-setup.sh'
check "lf --ssh-schluessel lädt die Schlüssel" 'grep -A3 "^--ssh-schluessel)" rescue/lf | grep -q "sshkeys_load"'
check "der Hinweis kommt nach dem Entsperren des Speichers" '[[ $(grep -n "^sshkeys_notice$" rescue/lf | cut -d: -f1) -gt $(grep -n "^persist_startup$" rescue/lf | cut -d: -f1) ]]'
check "sshkeys.sh wird geladen, pam.sh zuletzt" 'grep -q "^for f in .* tools sshkeys pam; do$" rescue/lf'
check "persist_encrypted: nur offen und über den LUKS-Mapper" '( eval "$(sed -n "/^persist_encrypted() {$/,/^}$/p" rescue/lib/persist.sh)"; LF_PERSIST=/persist PERSIST_MAPPER_DEV=/dev/mapper/lf-data; persist_is_open() { return 0; }; findmnt() { echo "$SRC_DEV"; }; SRC_DEV=/dev/mapper/lf-data persist_encrypted && ! SRC_DEV=/dev/sdz5 persist_encrypted && persist_is_open() { return 1; } && ! SRC_DEV=/dev/mapper/lf-data persist_encrypted )'

echo "sshd -T mit lf.conf (selftest_ssh):"
SSHD=${LF_SSHD:-/usr/sbin/sshd}
if [[ -x $SSHD ]]; then
	eval "$(sed -n '/^selftest_ssh() {$/,/^}$/p' rescue/lf)"
	out=$(SSHKEYS_DIR=/run/lf/ssh LF_SSHD=$SSHD LF_SSHD_CONFIG=$PWD/$CONF selftest_ssh "$T/st" 2>&1)
	st_rc=$?
	check "beide Arten der Anmeldung wie vorgesehen" '((st_rc == 0)) && grep -q "^LF-SELFTEST: SSH: nur Schlüssel aus /run/lf/ssh oder nur das Einmal-Passwort" <<<"$out" || { echo "$out"; false; }'
	grep -vx "DisableForwarding yes" "$CONF" >"$T/lf-ohne.conf"
	out=$(SSHKEYS_DIR=/run/lf/ssh LF_SSHD=$SSHD LF_SSHD_CONFIG=$T/lf-ohne.conf selftest_ssh "$T/st2" 2>&1)
	st_rc=$?
	check "ohne DisableForwarding schlägt der Selbsttest fehl" '((st_rc != 0)) && grep -q "nennt nicht: disableforwarding yes" <<<"$out"'
else
	echo "  übersprungen: sshd -T (kein $SSHD)"
fi

echo "Markierung nach einer Freigabe (lf-freigabe):"
eval "$(sed -n '/^hostkeys_mark() {$/,/^}$/p' "$FR")"
PERSIST=$T/persist MOUNTED=0
persist_mounted() { ((MOUNTED)); }
mkdir -p "$PERSIST/config" "$T/ziel"
hostkeys_mark
check "ohne eingehängten Speicher: nichts" '[[ ! -e $PERSIST/config/ssh ]]'
MOUNTED=1
hostkeys_mark
check "mit Speicher, auch ohne gemerkte Hostschlüssel: Markierung mit Zeit (Ordner 0700, Datei 0600)" '[[ $(stat -c %a "$PERSIST/config/ssh") == 700 && $(stat -c %a "$PERSIST/config/ssh/hostkeys-freigabe") == 600 ]] && grep -Eqx "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}" "$PERSIST/config/ssh/hostkeys-freigabe"'
echo "alt" >"$PERSIST/config/ssh/hostkeys-freigabe"
hostkeys_mark
check "eine vorhandene bleibt, wie sie ist" '[[ $(cat "$PERSIST/config/ssh/hostkeys-freigabe") == alt ]]'
rm -rf "$PERSIST/config/ssh"
ln -s "$T/ziel" "$PERSIST/config/ssh"
hostkeys_mark
check "config/ssh als Verknüpfung: nichts geschrieben" '[[ -z $(ls -A "$T/ziel") ]]'
rm -f "$PERSIST/config/ssh"
mkdir -m 700 "$PERSIST/config/ssh"
ln -s "$T/ziel/datei" "$PERSIST/config/ssh/hostkeys-freigabe"
hostkeys_mark
check "Markierung als Verknüpfung: nichts geschrieben" '[[ ! -e $T/ziel/datei ]]'
rm -rf "$PERSIST/config"
ln -s "$T/ziel" "$PERSIST/config"
hostkeys_mark
check "config als Verknüpfung: nichts" '[[ -z $(ls -A "$T/ziel") ]]'
l_mark=$(grep -n $'^\thostkeys_mark$' "$FR" | head -n1 | cut -d: -f1)
l_snap=$(grep -nF 'persist_now >"$SNAP/persist"' "$FR" | head -n1 | cut -d: -f1)
l_last=$(grep -nF 'date +%s >"$LAST"' "$FR" | tail -n1 | cut -d: -f1)
l_mark2=$(grep -n $'^\t\thostkeys_mark$' "$FR" | tail -n1 | cut -d: -f1)
check "beim Freischalten direkt vor dem Bild des Speichers (so kein Rückstand)" '[[ -n $l_mark && -n $l_snap ]] && ((l_snap == l_mark + 1))'
check "beim Ende nach dem Vergleich" '[[ -n $l_last && -n $l_mark2 ]] && ((l_mark2 > l_last))'

check "die sudo-Attrappe musste nichts außerhalb des Testordners ablehnen" '[[ ! -e $T/sudo-abgelehnt ]] || { cat "$T/sudo-abgelehnt"; false; }'

((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
