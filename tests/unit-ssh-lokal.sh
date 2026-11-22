#!/usr/bin/env bash
# Unit-Test (GHSA-cmcp-h343-c4gj): lf-claude erreicht sshd auf diesem Rechner nicht, auch nicht als
# rescue mit dem Einmal-Passwort. Eine Regel im Ausgang (nftables, rescue/lib/lf-claude-ssh.nft)
# weist jede TCP-Verbindung von lf-claude auf Port 22 an eine eigene Adresse ab.
# lf-claude-ssh-sperre.service lädt sie beim Start, ssh.service und ssh.socket starten nur mit
# ihr. systemd-ssh-generator ist maskiert: Er bände sshd sonst an /run/ssh-unix-local/socket
# (AF_UNIX) und in einer VM an vsock-Port 22, an der Regel vorbei. In der ISO prüft das
# selftest_ssh_lokal, vor dem Einschalten auch der Assistent.
#
# Geprüft wird:
# - statisch: Regel, Dienst, Paketliste, chroot-setup mit der Maske für systemd-ssh-generator,
#   Aufruf des Selbsttests, Assistent,
# - selftest_ssh_lokal aus rescue/lf mit tools_ssh_regel und tools_ssh_nebenwege aus
#   rescue/lib/tools.sh, mit Attrappen für systemctl, id, ip, nft, timeout und selftest_as,
# - Werkzeuge > SSH: Vor dem Passwort lädt der Assistent die Regel neu und prüft sie und die Wege
#   neben ssh.service, sonst bleibt SSH aus,
# - mit dem echten nft in einem eigenen Benutzer- und Netz-Namespace (unshare, ohne root): die
#   Regel aus der Datei, mit der Nummer 1000 statt lf-claude, und selftest_ssh_lokal selbst. Dort
#   lauscht ein Python-Socket auf Port 22, kein sshd: Verbunden wird nur, angemeldet nie. Fehlt
#   ein Werkzeug dafür, oder erlaubt das System den Namespace nicht, wird das übersprungen.
set -u
cd "$(dirname "$0")/.." || exit 1
SELF="$PWD/tests/$(basename "$0")"

RULES=rescue/lib/lf-claude-ssh.nft
UNIT=build/overlay/etc/systemd/system/lf-claude-ssh-sperre.service
FN=$(
	sed -n '/^selftest_ssh_lokal() {$/,/^}$/p; /^selftest_ssh_lokal_regel() {$/,/^}$/p; /^selftest_ssh_lokal_treffer() {$/,/^}$/p' rescue/lf
	sed -n '/^tools_ssh_regel() {$/,/^}$/p; /^tools_ssh_nebenwege() {$/,/^}$/p' rescue/lib/tools.sh
)

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# als_claude ZIEL [PORT]   Verbindung als lf-claude (selftest_as), ohne ein Byte zu senden.
als_claude() {
	selftest_as timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "${2:-22}" 2>/dev/null
}

# im_namespace   Läuft in einem eigenen Benutzer- und Netz-Namespace: root dort ist der Benutzer
#   der CI, 1000 dort steht für lf-claude. Auf lo liegen dazu 10.9.9.9 und fd00::9 als eigene
#   Adressen, die Karte d0 (dummy) hat die link-local-Adresse fe80::ff:fe00:9 aus ihrer MAC,
#   192.0.2.0/24 ist ein anderer Rechner. systemctl und id sind Attrappen, nft, ip und jq echt.
im_namespace() {
	local out rc n i
	T=$(mktemp -d)
	lp=
	trap '[[ -n $lp ]] && kill "$lp" 2>/dev/null; rm -rf "$T"' EXIT
	if ! { ip link set lo up && ip addr add 10.9.9.9/32 dev lo && ip addr add fd00::9/128 dev lo &&
		ip route add 192.0.2.0/24 dev lo &&
		ip link add d0 address 02:00:00:00:00:09 type dummy && ip link set d0 up; }; then
		echo "  FAIL Netz im Namespace nicht eingerichtet"
		return 1
	fi
	for ((i = 0; i < 50; i++)); do
		[[ -n $(ip -6 -o addr show dev d0 scope link -tentative -dadfailed) ]] && break
		sleep 0.1
	done
	# Lauscht auf [::]:22 für IPv4 und IPv6 und schließt jede Verbindung sofort wieder.
	python3 -I -c '
import socket
s = socket.socket(socket.AF_INET6)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", 22))
s.listen(16)
while True:
    c, _ = s.accept()
    c.close()
' &
	lp=$!
	for ((i = 0; i < 50; i++)); do
		timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null && break
		sleep 0.1
	done
	eval "$FN"
	systemctl() {
		case "$*" in
		"is-active --quiet lf-claude-ssh-sperre.service") return 0 ;;
		"show -p Requires --value ssh.service" | "show -p Requires --value ssh.socket") echo "lf-claude-ssh-sperre.service sysinit.target" ;;
		# Keine Einheit sshd-*.socket. list-unit-files endet dann mit 1, wie das echte.
		"list-units --all --plain --no-legend sshd-*.socket") return 0 ;;
		*) return 1 ;;
		esac
	}
	ln -s /dev/null "$T/generator"
	LF_SSH_GENERATOR="$T/generator" LF_SSH_UNIX_SOCKET="$T/kein-socket"
	id() { [[ $* == "-u lf-claude" ]] && echo 1000; }
	selftest_as() { setpriv --reuid=1000 --regid=1000 --clear-groups "$@" </dev/null; }

	echo "Im Namespace, ohne die Regel:"
	check "lf-claude erreicht den Socket auf 127.0.0.1:22, [::1]:22 und [fe80::ff:fe00:9%d0]:22 (die Lücke)" 'als_claude 127.0.0.1 && als_claude ::1 && als_claude fe80::ff:fe00:9%d0'
	out=$(selftest_ssh_lokal)
	rc=$?
	check "der Selbsttest meldet die fehlende Regel" '((rc != 0)) && [[ $out == *"die Regel aus lf-claude-ssh.nft ist nicht geladen"* ]]'

	echo "Mit der Regel aus lf-claude-ssh.nft:"
	sed 's/meta skuid "lf-claude" /meta skuid 1000 /' "$RULES" >"$T/regel.nft"
	check "nft lädt sie, auch ein zweites Mal" '[[ $(grep -c "meta skuid 1000 " "$T/regel.nft") == 1 ]] && nft -f "$T/regel.nft" && nft -f "$T/regel.nft"'
	check "danach steht sie genau einmal da, der Zähler bei 0" 'selftest_ssh_lokal_regel 1000 && [[ $(selftest_ssh_lokal_treffer) == 0 ]]'
	out=$(selftest_ssh_lokal)
	rc=$?
	sed 's/^/    /' <<<"$out"
	check "der Selbsttest besteht und nennt alle eigenen Adressen" '((rc == 0)) && [[ $out == "LF-SELFTEST: SSH lokal: lf-claude erreicht Port 22 auf eigenen Adressen nicht (127.0.0.1 127.0.0.2 ::1 ::ffff:127.0.0.1 10.9.9.9 fd00::9 fe80::ff:fe00:9%d0), root trifft die Regel nicht" ]]'
	check "je Ziel ein Treffer, root keiner" '[[ $(selftest_ssh_lokal_treffer) == 7 ]]'
	check "root erreicht den Socket weiter" 'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/22" 2>/dev/null'
	n=$(selftest_ssh_lokal_treffer)
	als_claude 127.0.0.1 23
	check "Port 23 trifft die Regel nicht" '[[ $(selftest_ssh_lokal_treffer) == "$n" ]]'
	timeout 2 setpriv --reuid=1000 --regid=1000 --clear-groups bash -c 'exec 3<>/dev/tcp/192.0.2.1/22' 2>/dev/null
	check "eine Verbindung zu einem anderen Rechner auch nicht" '[[ $(selftest_ssh_lokal_treffer) == "$n" ]]'

	echo "Mit einer Regel für einen anderen Benutzer:"
	sed 's/meta skuid "lf-claude" /meta skuid 1001 /' "$RULES" | nft -f -
	check "lf-claude erreicht den Socket wieder" 'als_claude 127.0.0.1'
	out=$(selftest_ssh_lokal)
	rc=$?
	check "der Selbsttest erkennt die falsche Regel" '((rc != 0)) && [[ $out == *"die Regel aus lf-claude-ssh.nft ist nicht geladen"* ]]'

	echo "Mit einer zweiten Regel in der Kette:"
	nft -f "$T/regel.nft"
	nft add rule inet lf_claude_ssh ausgang tcp dport 2222 accept
	out=$(selftest_ssh_lokal)
	rc=$?
	check "der Selbsttest erkennt sie" '((rc != 0)) && [[ $out == *"nicht geladen"* ]]'
	return "$((fails > 0))"
}

if [[ ${1:-} == --im-namespace ]]; then
	im_namespace
	exit
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "Regel:"
check "eine Tabelle inet (IPv4 und IPv6), erneutes Laden ersetzt sie" '[[ $(grep -vE "^[[:space:]]*(#|$)" "$RULES" | head -n 3 | tr "\n" "|") == "table inet lf_claude_ssh|delete table inet lf_claude_ssh|table inet lf_claude_ssh {|" ]]'
check "Kette am Ausgang, alles andere geht durch" 'grep -qxF "		type filter hook output priority filter; policy accept;" "$RULES"'
check "genau eine Regel: lf-claude, TCP-Port 22, eigene Adresse, Zähler, abweisen" '[[ $(grep -cE "^[[:space:]]+(meta|tcp|ip|ip6|fib|ct|accept|drop|reject|jump|goto)" "$RULES") == 1 ]] && grep -qxF "		meta skuid \"lf-claude\" tcp dport 22 fib daddr type local counter reject with tcp reset comment \"lf-claude-ssh\"" "$RULES"'

echo "Dienst:"
check "lädt die Regel aus dem Ordner der lf-Bibliotheken" 'grep -qxF "ExecStart=/usr/sbin/nft -f /usr/local/lib/lf/lf-claude-ssh.nft" "$UNIT" && grep -qF "cp -a --no-preserve=ownership \"\$SRC/rescue/lib/.\" \"\$CHROOT/usr/local/lib/lf/\"" build/build.sh'
check "einmal je Start, bleibt aktiv" 'grep -qx "Type=oneshot" "$UNIT" && grep -qx "RemainAfterExit=yes" "$UNIT" && grep -qx "WantedBy=multi-user.target" "$UNIT"'
check "ssh.service und ssh.socket brauchen ihn und starten erst nach ihm" 'grep -qx "RequiredBy=ssh.service ssh.socket" "$UNIT" && grep -qx "Before=ssh.service ssh.socket shutdown.target" "$UNIT"'
check "kein Zyklus mit ssh.socket, nach nftables.service (flush ruleset)" 'grep -qx "DefaultDependencies=no" "$UNIT" && grep -qx "After=local-fs.target nftables.service" "$UNIT"'
check "kein ExecStop: Die Regel bleibt, auch wenn der Dienst endet" '! grep -q "^ExecStop" "$UNIT"'
check "nftables steht in der Paketliste" 'grep -qx nftables build/packages.list'
en=$(grep -n "^systemctl enable lf-claude-ssh-sperre.service$" build/chroot-setup.sh | cut -d: -f1)
dis=$(grep -n "^systemctl disable ssh.service ssh.socket" build/chroot-setup.sh | cut -d: -f1)
check "chroot-setup schaltet ihn ein, nach dem disable von ssh" '[[ -n $en && -n $dis ]] && ((en > dis))'
check "chroot-setup maskiert systemd-ssh-generator (sshd an AF_UNIX und vsock)" 'grep -qx "mkdir -p /etc/systemd/system-generators" build/chroot-setup.sh && grep -qx "ln -s /dev/null /etc/systemd/system-generators/systemd-ssh-generator" build/chroot-setup.sh'
check "der Selbsttest ruft selftest_ssh_lokal auf" 'grep -qx "	selftest_ssh_lokal || ok=0" rescue/lf'
check "der Selbsttest verbindet nur und meldet sich nie an" '[[ -n $FN ]] && ! grep -qE "(^|[^-_.[:alnum:]])(ssh|sshpass|su|login|chpasswd|usermod|passwd|curl|nc|socat)([[:space:]]|$)" <<<"$FN"'

# Attrappen für selftest_ssh_lokal. nft liefert JSON wie nft 1.1: Regel und Kette aus RULE_UID und
# CHAIN, der Zähler steht in $T/zaehler. selftest_as zählt einen Treffer, solange BLOCK=1 gilt, und
# scheitert dann, sonst verbindet es. ROOT_HITS=1 lässt auch root die Regel treffen.
eval "$FN"
RULE_UID=999
CHAIN='"family": "inet", "table": "lf_claude_ssh", "name": "ausgang", "handle": 1, "type": "filter", "hook": "output", "prio": 0, "policy": "accept"'
FLAGS='["daddr"]'
NFT_OK=1 ACTIVE=0 REQ=1 BLOCK=1 ROOT_HITS=0 IPV6=1 V4=192.0.2.10 V6=2001:db8::10 LL=fe80::5054:ff:fe12:3456
# Wege neben ssh.service (tools_ssh_nebenwege): Die Maske ist ein Verweis auf /dev/null, den Socket
# gibt es nicht. UNITS und UNIT_FILES liefern systemctl list-units und list-unit-files, LIST_OK=0
# lässt list-units scheitern.
ln -s /dev/null "$T/generator"
LF_SSH_GENERATOR="$T/generator" LF_SSH_UNIX_SOCKET="$T/ssh-unix-local/socket"
UNITS='' UNIT_FILES='' LIST_OK=1
nft() {
	((NFT_OK)) || return 1
	local rule
	rule='{"rule": {"family": "inet", "table": "lf_claude_ssh", "chain": "ausgang", "handle": 2, "comment": "lf-claude-ssh", "expr": [{"match": {"op": "==", "left": {"meta": {"key": "skuid"}}, "right": '"$RULE_UID"'}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}}, {"match": {"op": "==", "left": {"fib": {"result": "type", "flags": '"$FLAGS"'}}, "right": "local"}}, {"counter": {"packets": '"$(cat "$T/zaehler")"', "bytes": 0}}, {"reject": {"type": "tcp reset"}}]}}'
	case "$*" in
	"-j list table inet lf_claude_ssh") echo '{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"table": {"family": "inet", "name": "lf_claude_ssh", "handle": 1}}, {"chain": {'"$CHAIN"'}}, '"$rule"']}' ;;
	"-j list chain inet lf_claude_ssh ausgang") echo '{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"chain": {'"$CHAIN"'}}, '"$rule"']}' ;;
	*) return 1 ;;
	esac
}
systemctl() {
	case "$*" in
	"is-active --quiet lf-claude-ssh-sperre.service") return "$ACTIVE" ;;
	"show -p Requires --value ssh.service" | "show -p Requires --value ssh.socket") ((REQ)) && echo "sysinit.target lf-claude-ssh-sperre.service" ;;
	"list-units --all --plain --no-legend sshd-*.socket")
		((LIST_OK)) || return 1
		[[ -n $UNITS ]] && echo "$UNITS"
		;;
	"list-unit-files --no-legend sshd-*.socket")
		[[ -n $UNIT_FILES ]] || return 1
		echo "$UNIT_FILES"
		;;
	*) return 1 ;;
	esac
	return 0
}
id() { [[ $* == "-u lf-claude" ]] && echo 999; }
ip() {
	case "$*" in
	"-6 -o addr show dev lo") ((IPV6)) && echo "1: lo    inet6 ::1/128 scope host noprefixroute \       valid_lft forever preferred_lft forever" ;;
	"-4 -o addr show scope global") [[ -n $V4 ]] && echo "2: eth0    inet $V4/24 brd 192.0.2.255 scope global dynamic eth0\       valid_lft 86000sec preferred_lft 86000sec" ;;
	"-6 -o addr show scope global -tentative -dadfailed") [[ -n $V6 ]] && echo "2: eth0    inet6 $V6/64 scope global dynamic mngtmpaddr \       valid_lft 86000sec preferred_lft 14000sec" ;;
	"-6 -o addr show scope link -tentative -dadfailed") [[ -n $LL ]] && echo "2: eth0    inet6 $LL/64 scope link \       valid_lft forever preferred_lft forever" ;;
	*) return 1 ;;
	esac
	return 0
}
selftest_as() {
	echo "$*" >>"$T/als"
	[[ $* == "timeout 5 bash -c "* ]] || return 9
	if ((BLOCK)); then
		echo $(($(cat "$T/zaehler") + 1)) >"$T/zaehler"
		return 1
	fi
	return 0
}
timeout() {
	echo "$*" >>"$T/root"
	((ROOT_HITS)) && echo $(($(cat "$T/zaehler") + 1)) >"$T/zaehler"
	return 1
}
lauf() {
	echo 0 >"$T/zaehler"
	rm -f "$T/als" "$T/root"
	out=$(selftest_ssh_lokal)
	rc=$?
}

echo "selftest_ssh_lokal mit Attrappen:"
lauf
check "besteht: je Ziel eine Verbindung als lf-claude, die die Regel trifft" '((rc == 0)) && [[ $out == "LF-SELFTEST: SSH lokal: lf-claude erreicht Port 22 auf eigenen Adressen nicht (127.0.0.1 127.0.0.2 ::1 ::ffff:127.0.0.1 192.0.2.10 2001:db8::10 fe80::5054:ff:fe12:3456%eth0), root trifft die Regel nicht" ]]'
check "verbunden wird mit bash auf /dev/tcp, Port 22, als lf-claude" '[[ $(wc -l <"$T/als") == 7 ]] && ! grep -qvF "timeout 5 bash -c exec 3<>\"/dev/tcp/\$1/22\" _ " "$T/als" && grep -qx "timeout 5 bash -c .* _ ::ffff:127.0.0.1" "$T/als"'
check "link-local mit der Karte (%eth0)" 'grep -qx "timeout 5 bash -c .* _ fe80::5054:ff:fe12:3456%eth0" "$T/als"'
check "root verbindet einmal, auf 127.0.0.1" '[[ $(cat "$T/root") == "5 bash -c exec 3<>\"/dev/tcp/\$1/22\" _ 127.0.0.1" ]]'
FLAGS='"daddr"'
lauf
check "fib-Flags als einzelner Wert (ältere nft): gleich" '((rc == 0))'
FLAGS='["daddr"]'
IPV6=0 V4='' V6='' LL=''
lauf
check "ohne IPv6 und ohne Adresse der Karten: nur 127.0.0.1 und 127.0.0.2" '((rc == 0)) && [[ $out == *"(127.0.0.1 127.0.0.2), root"* ]]'
IPV6=1 V4=192.0.2.10 V6=2001:db8::10 LL=fe80::5054:ff:fe12:3456

ACTIVE=3
lauf
check "Dienst nicht aktiv: FAIL" '((rc != 0)) && [[ $out == *"lf-claude-ssh-sperre.service ist nicht aktiv"* ]]'
ACTIVE=0 REQ=0
lauf
check "ssh startet ohne den Dienst: FAIL für ssh.service und ssh.socket" '((rc != 0)) && [[ $out == *"ssh.service startet auch ohne"* && $out == *"ssh.socket startet auch ohne"* ]]'
REQ=1 NFT_OK=0
lauf
check "keine Tabelle: FAIL, keine Verbindung" '((rc != 0)) && [[ $out == *"nicht geladen"* && ! -e $T/als && ! -e $T/root ]]'
NFT_OK=1 RULE_UID=0
lauf
check "Regel für einen anderen Benutzer: FAIL" '((rc != 0)) && [[ $out == *"nicht geladen"* ]]'
RULE_UID=999
CHAIN='"family": "inet", "table": "lf_claude_ssh", "name": "ausgang", "handle": 1, "type": "filter", "hook": "input", "prio": 0, "policy": "accept"'
lauf
check "Kette am Eingang statt am Ausgang: FAIL" '((rc != 0)) && [[ $out == *"nicht geladen"* ]]'
CHAIN='"family": "inet", "table": "lf_claude_ssh", "name": "ausgang", "handle": 1, "type": "filter", "hook": "output", "prio": 0, "policy": "accept"'
BLOCK=0
lauf
check "lf-claude verbindet sich, der Zähler steht: FAIL je Ziel" '((rc != 0)) && [[ $(grep -c "lf-claude erreicht Port 22 auf" <<<"$out") == 7 && $(grep -c "trifft die Regel nicht (Zähler 0 -> 0)" <<<"$out") == 7 ]]'
BLOCK=1 ROOT_HITS=1
lauf
check "die Regel trifft auch root: FAIL" '((rc != 0)) && [[ $out == *"die Regel trifft auch root (Zähler 7 -> 8)"* ]]'
ROOT_HITS=0

echo "Wege zu sshd neben ssh.service (systemd-ssh-generator):"
LF_SSH_GENERATOR="$T/kein-generator"
lauf
check "Generator nicht maskiert: FAIL" '((rc != 0)) && [[ $out == *"LF-SELFTEST: SSH lokal: Weg zu sshd an der Regel vorbei: systemd-ssh-generator ist nicht maskiert ($T/kein-generator)"* ]]'
ln -s /usr/lib/systemd/system-generators/systemd-ssh-generator "$T/anderer-generator"
LF_SSH_GENERATOR="$T/anderer-generator"
lauf
check "Verweis auf den Generator statt auf /dev/null: FAIL" '((rc != 0)) && [[ $out == *"systemd-ssh-generator ist nicht maskiert"* ]]'
LF_SSH_GENERATOR="$T/generator"
mkdir -p "$T/ssh-unix-local"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/ssh-unix-local/socket" 2>/dev/null ||
	: >"$T/ssh-unix-local/socket"
lauf
check "/run/ssh-unix-local/socket da: FAIL" '((rc != 0)) && [[ $out == *"Weg zu sshd an der Regel vorbei: Socket $T/ssh-unix-local/socket"* ]]'
rm -f "$T/ssh-unix-local/socket"
UNITS='sshd-unix-local.socket loaded active listening OpenSSH Server Socket (systemd-ssh-generator, AF_UNIX Local)'
lauf
check "Einheit sshd-unix-local.socket geladen: FAIL" '((rc != 0)) && [[ $out == *"Weg zu sshd an der Regel vorbei: Einheit sshd-unix-local.socket"* ]]'
UNITS='sshd-vsock.socket not-found inactive dead sshd-vsock.socket'
lauf
check "nur ein Verweis auf eine Einheit, die es nicht gibt (not-found): besteht" '((rc == 0))'
UNITS='' UNIT_FILES='sshd-vsock.socket generated -'
lauf
check "Datei sshd-vsock.socket (generated): FAIL" '((rc != 0)) && [[ $out == *"Weg zu sshd an der Regel vorbei: Einheit sshd-vsock.socket"* ]]'
UNIT_FILES='' LIST_OK=0
lauf
check "systemctl nennt die Einheiten nicht: FAIL" '((rc != 0)) && [[ $out == *"systemctl nennt die Einheiten sshd-*.socket nicht"* ]]'
LIST_OK=1
lauf
check "danach besteht er wieder" '((rc == 0))'

echo "Assistent (Werkzeuge > SSH):"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/tools.sh
# systemctl und nft bleiben die Attrappen von oben: ssh läuft nicht, keine Einheit sshd-*.socket,
# die Tabelle wie aus lf-claude-ssh.nft.
unset -f ip id timeout
LF_LOG="$T/log"
LF_SSH_DIR="$T/ssh"
mkdir -p "$LF_SSH_DIR"
START_RC=0 RESTART_RC=0
is_online() { return 0; }
id() { if [[ $* == "-u lf-claude" ]]; then echo 999; else command id "$@"; fi; }
# Von SSH läuft nichts mehr (tools_ssh_rest): keine Sitzung von logind, kein cgroup von ssh.service.
# Ohne das läse der Test die des Rechners, auf dem er läuft.
loginctl() { :; }
LF_SSH_CGROUP="$T/kein-cgroup"
ip() { echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"; }
ui_msg() { printf '%s\n%s\n' "$1" "$2" >>"$T/dialog"; }
ui_yesno() { return 1; }
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case "$*" in
	"ssh-keygen -A") [[ -e $LF_SSH_DIR/ssh_host_ed25519_key ]] || command ssh-keygen -q -t ed25519 -N '' -C test -f "$LF_SSH_DIR/ssh_host_ed25519_key" ;;
	chpasswd) cat >/dev/null ;;
	"systemctl restart lf-claude-ssh-sperre.service") return "$RESTART_RC" ;;
	"nft -j list table inet lf_claude_ssh") nft -j list table inet lf_claude_ssh ;;
	"systemctl start ssh") return "$START_RC" ;;
	esac
	return 0
}
# bleibt_aus TEXT   tools_ssh, das SSH auslässt: kein Passwort, kein Start, der Dialog nennt TEXT.
bleibt_aus() {
	[[ -e $T/sudo ]] && ! grep -qE "^(chpasswd|systemctl start ssh|usermod)" "$T/sudo" &&
		[[ $(head -n1 "$T/dialog") == SSH ]] && grep -qF "$1" "$T/dialog" && grep -qF "SSH bleibt aus" "$T/dialog" &&
		! grep -q "Passwort (nur\|SSH ist an" "$T/dialog"
}
START_RC=1
tools_ssh
check "startet ssh nicht (etwa ohne die Regel), sperrt es das Einmal-Passwort wieder" '[[ $(grep -nx "systemctl start ssh" "$T/sudo" | cut -d: -f1) -lt $(grep -nx "usermod -p ! $(id -un)" "$T/sudo" | cut -d: -f1) ]]'
check "und sagt das, ohne Passwort und ohne SSH ist an" '[[ $(head -n1 "$T/dialog") == SSH ]] && grep -qF "SSH ließ sich nicht starten. Das Einmal-Passwort gilt nicht." "$T/dialog" && ! grep -q "Passwort (nur\|SSH ist an" "$T/dialog"'
rm -f "$T/sudo" "$T/dialog"
START_RC=0
tools_ssh
check "startet ssh, bleibt es wie bisher: kein Sperren, Dialog mit Passwort" '! grep -q "^usermod" "$T/sudo" && grep -q "^SSH ist an$" "$T/dialog" && grep -q "Passwort (nur für diese Sitzung): " "$T/dialog"'
check "vor dem Passwort: Regel neu geladen und geprüft, dann chpasswd, dann ssh" '[[ $(grep -xE "systemctl restart lf-claude-ssh-sperre.service|nft -j list table inet lf_claude_ssh|chpasswd|systemctl start ssh" "$T/sudo" | tr "\n" "|") == "systemctl restart lf-claude-ssh-sperre.service|nft -j list table inet lf_claude_ssh|chpasswd|systemctl start ssh|" ]]'
rm -f "$T/sudo" "$T/dialog"
RESTART_RC=1
tools_ssh
check "lädt die Regel nicht neu: SSH bleibt aus, kein Passwort" 'bleibt_aus "ließ sich nicht laden"'
rm -f "$T/sudo" "$T/dialog"
RESTART_RC=0 RULE_UID=0
tools_ssh
check "geladen ist eine Regel für einen anderen Benutzer: SSH bleibt aus" 'bleibt_aus "Geladen ist nicht genau die Regel aus lf-claude-ssh.nft"'
rm -f "$T/sudo" "$T/dialog"
RULE_UID=999 NFT_OK=0
tools_ssh
check "keine Tabelle: SSH bleibt aus" 'bleibt_aus "Geladen ist nicht genau die Regel aus lf-claude-ssh.nft"'
rm -f "$T/sudo" "$T/dialog"
NFT_OK=1
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/ssh-unix-local/socket" 2>/dev/null ||
	: >"$T/ssh-unix-local/socket"
tools_ssh
check "/run/ssh-unix-local/socket da: SSH bleibt aus" 'bleibt_aus "Socket $T/ssh-unix-local/socket"'
rm -f "$T/sudo" "$T/dialog" "$T/ssh-unix-local/socket"
UNIT_FILES='sshd-unix-local.socket generated -'
tools_ssh
check "Einheit sshd-unix-local.socket: SSH bleibt aus" 'bleibt_aus "Einheit sshd-unix-local.socket"'
rm -f "$T/sudo" "$T/dialog"
UNIT_FILES='' LF_SSH_GENERATOR="$T/kein-generator"
tools_ssh
check "Generator nicht maskiert: SSH bleibt aus" 'bleibt_aus "systemd-ssh-generator ist nicht maskiert"'
LF_SSH_GENERATOR="$T/generator"

echo "Im Netz-Namespace (echtes nft, ohne root):"
grund=
for t in unshare newuidmap nft jq python3 setpriv timeout; do
	command -v "$t" >/dev/null || grund+=" $t fehlt"
done
sub=$(awk -F: -v u="$(id -un)" '$1 == u && $3 >= 1001 {print $2; exit}' /etc/subuid 2>/dev/null)
subg=$(awk -F: -v u="$(id -un)" '$1 == u && $3 >= 1001 {print $2; exit}' /etc/subgid 2>/dev/null)
[[ -n $sub && -n $subg ]] || grund+=" keine Nummern für $(id -un) in /etc/subuid und /etc/subgid"
NS=(unshare --map-root-user --map-users="1:${sub:-0}:1001" --map-groups="1:${subg:-0}:1001" --net)
if [[ -z $grund ]] && ! "${NS[@]}" bash -c 'ip link set lo up && nft list ruleset' >/dev/null 2>&1; then
	grund=" das System erlaubt den Namespace nicht"
fi
if [[ -n $grund ]]; then
	echo "  übersprungen:$grund"
else
	"${NS[@]}" bash "$SELF" --im-namespace
	(($? == 0)) || fails=$((fails + 1))
fi

echo
if ((fails)); then
	echo "unit-ssh-lokal: $fails Fehler"
	exit 1
fi
echo "unit-ssh-lokal: alles ok"
