#!/usr/bin/env bash
# Unit-Test (GHSA-w376-95wf-5v9q): lf-claude erreicht nur HTTPS im Internet und die
# Namensauflösung, keinen Dienst auf diesem Rechner und keinen Rechner im lokalen Netz. Eine Regel
# im Ausgang (nftables, rescue/lib/lf-claude-netz.nft) weist jede andere Verbindung von lf-claude
# ab. lf-claude-netz-sperre.service lädt sie beim Start, Claude startet nur mit ihr
# (claude_netz_regel). In der ISO prüft das selftest_netz_claude.
#
# Geprüft wird:
# - statisch: Regel, Dienst, Paketliste, chroot-setup, Aufruf des Selbsttests, Start von CLI und
#   Desktop, die Adresse der Attrappe von lf-claude-check in Regel, claude-check.sh und Attrappe,
# - die Attrappe der API lauscht nur auf 127.76.70.1 und lehnt andere Adressen ab,
# - claude_netz_regel mit Attrappen für systemctl und sudo, claude_start und claude_desktop starten
#   ohne die Regel nicht,
# - mit dem echten nft in einem eigenen Benutzer- und Netz-Namespace (unshare, ohne root): die
#   Regel aus der Datei, mit der Nummer 1000 statt lf-claude. Erlaubte und abgewiesene Ziele, der
#   Zähler, Antworten als Gegenstelle, die Attrappe auf 127.76.70.1 gegen einen Dienst auf allen
#   Adressen, das Zusammenspiel mit lf-claude-ssh.nft, claude_netz_regel mit echtem unshare und
#   nft, und selftest_netz_claude selbst. Im Namespace gibt es keine Route nach draußen: Was die
#   Regel durchlässt, geht an eine Dummy-Karte und verschwindet. Fehlt ein Werkzeug dafür, oder
#   erlaubt das System den Namespace nicht, wird das übersprungen.
set -u
cd "$(dirname "$0")/.." || exit 1
SELF="$PWD/tests/$(basename "$0")"

RULES=rescue/lib/lf-claude-netz.nft
SSH_RULES=rescue/lib/lf-claude-ssh.nft
UNIT=build/overlay/etc/systemd/system/lf-claude-netz-sperre.service
ADDR=127.76.70.1
FN=$(
	sed -n '/^selftest_netz_claude() {$/,/^}$/p; /^selftest_netz_claude_treffer() {$/,/^}$/p' rescue/lf
	sed -n '/^claude_netz_regel() {$/,/^}$/p; /^claude_netz_text() {$/,/^}$/p' rescue/lib/claude.sh
)

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# verbinde.py PROTO ADRESSE PORT [QUELLE [SEKUNDEN]]   Eine Verbindung (TCP) oder ein Paket (UDP,
#   danach kurz auf eine Fehlermeldung warten). Ausgabe: ok, abgewiesen, zeit oder fehler:ERRNO.
VERBINDE='
import errno, socket, sys
proto, addr, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
wait = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
host, scope = addr, 0
if "%" in addr:
    host, dev = addr.split("%")
    scope = socket.if_nametoindex(dev)
fam = socket.AF_INET6 if ":" in host else socket.AF_INET
s = socket.socket(fam, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
s.settimeout(wait)
if src:
    s.bind((src, 0))
ziel = (host, port, 0, scope) if fam == socket.AF_INET6 else (host, port)
try:
    s.connect(ziel)
    if proto == "udp":
        s.send(b"x")
        try:
            s.recv(1)
        except socket.timeout:
            pass
    print("ok")
except socket.timeout:
    print("zeit")
except OSError as e:
    nein = (errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.EACCES, errno.EPERM, errno.ENETUNREACH)
    print("abgewiesen" if e.errno in nein else "fehler:%d" % e.errno)
'

# lausche NUMMER ADRESSE PORT [udp]   Lauscht als NUMMER (0: der Aufrufer), bis der Test endet.
#   Schreibt den PID nach $T/pids.
lausche() {
	local u=$1
	shift
	local -a als=()
	[[ $u == 0 ]] || als=(setpriv --reuid="$u" --regid="$u" --clear-groups)
	"${als[@]}" python3 -I -c '
import socket, sys, time
fam = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
if len(sys.argv) > 3:
    u = socket.socket(fam, socket.SOCK_DGRAM)
    u.bind((sys.argv[1], int(sys.argv[2])))
else:
    s = socket.socket(fam)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((sys.argv[1], int(sys.argv[2])))
    s.listen(16)
time.sleep(120)' "$@" &
	echo $! >>"$T/pids"
}

im_namespace() {
	local out rc n
	T=$(mktemp -d)
	trap '[[ -s $T/pids ]] && xargs kill <"$T/pids" 2>/dev/null; rm -rf "$T"' EXIT
	if ! { ip link set lo up && ip addr add 10.9.9.9/32 dev lo && ip addr add fd00::9/128 dev lo &&
		ip link add d0 address 02:00:00:00:00:09 type dummy && ip link set d0 up &&
		ip addr add 172.31.0.2/24 dev d0 && ip route add default dev d0 && ip -6 route add default dev d0; }; then
		echo "  FAIL Netz im Namespace nicht eingerichtet"
		return 1
	fi
	for ((n = 0; n < 50; n++)); do
		[[ -n $(ip -6 -o addr show dev d0 scope link -tentative -dadfailed) ]] && break
		sleep 0.1
	done
	# Hinaus geht nichts: Die Karte d0 ist eine Attrappe ohne Leitung.
	check "im Namespace gibt es nur lo und die Dummy-Karte d0" '[[ $(ip -o link show | awk -F": " "{print \$2}" | sort | tr "\n" " ") == "d0 lo " ]]'
	als() { # als NUMMER PROTO ADRESSE PORT [QUELLE [SEKUNDEN]]
		local u=$1
		shift
		if [[ $u == 0 ]]; then
			python3 -I -c "$VERBINDE" "$@"
		else
			setpriv --reuid="$u" --regid="$u" --clear-groups python3 -I -c "$VERBINDE" "$@"
		fi
	}
	selftest_as() {
		setpriv --reuid=1000 --regid=1000 --clear-groups "$@"
	}
	systemctl() {
		[[ $* == "is-active --quiet $CLAUDE_NETZ_DIENST" ]] && return "$ACTIVE"
		return 1
	}
	sudo() { "$@"; }
	eval "$FN"
	CLAUDE_NETZ_DIENST=lf-claude-netz-sperre.service
	CLAUDE_NETZ_REGEL=$T/regel.nft
	ACTIVE=0
	# erwarte NAME ERGEBNIS TREFFER NUMMER PROTO ADRESSE PORT [QUELLE [SEKUNDEN]]   Eine Verbindung
	#   mit ERGEBNIS (ok, abgewiesen, zeit, "nicht ok"), dabei steigt der Zähler um TREFFER.
	erwarte() {
		local name=$1 soll=$2 treffer=$3 vor nach ist
		shift 3
		vor=$(selftest_netz_claude_treffer)
		ist=$(als "$@")
		nach=$(selftest_netz_claude_treffer)
		if [[ $soll == "nicht ok" ]]; then
			check "$name: $ist, Zähler +$((nach - vor))" '[[ $ist != ok && $((nach - vor)) == "$treffer" ]]'
		else
			check "$name: $ist, Zähler +$((nach - vor))" '[[ $ist == "$soll" && $((nach - vor)) == "$treffer" ]]'
		fi
	}

	echo "Ohne Regel:"
	out=$(selftest_netz_claude)
	rc=$?
	check "der Selbsttest meldet die fehlende Regel" '((rc != 0)) && [[ $out == *"die Regel aus lf-claude-netz.nft ist nicht geladen"* ]]'
	check "claude_netz_regel: nein" '! claude_netz_regel'

	echo "Mit der Regel aus lf-claude-netz.nft:"
	sed 's/meta skuid "lf-claude" /meta skuid 1000 /' "$RULES" >"$T/regel.nft"
	check "nft lädt sie, auch ein zweites Mal, danach gibt es die Tabelle einmal" '[[ $(grep -c "meta skuid 1000 " "$T/regel.nft") == 1 ]] && nft -f "$T/regel.nft" && nft -f "$T/regel.nft" && [[ $(nft list tables | grep -c "^table inet lf_claude_netz$") == 1 ]]'
	check "der Zähler steht bei 0" '[[ $(selftest_netz_claude_treffer) == 0 ]]'
	check "claude_netz_regel: ja (echtes unshare und nft)" 'claude_netz_regel'
	ACTIVE=3
	check "claude_netz_regel: nein, wenn der Dienst nicht aktiv ist" '! claude_netz_regel'
	ACTIVE=0

	lausche 0 127.0.0.53 53
	lausche 0 127.0.0.53 53 udp
	lausche 0 0.0.0.0 4712
	lausche 0 127.0.0.1 4713
	lausche 1000 "$ADDR" 4711
	lausche 1000 127.0.0.1 4714
	lausche 1000 "$ADDR" 4715
	sleep 1

	echo "Erlaubt für lf-claude:"
	erwarte "DNS über TCP an 127.0.0.53" ok 0 1000 tcp 127.0.0.53 53
	erwarte "DNS über UDP an 127.0.0.53" ok 0 1000 udp 127.0.0.53 53
	erwarte "die eigene Attrappe auf $ADDR" ok 0 1000 tcp "$ADDR" 4711
	erwarte "HTTPS an eine öffentliche Adresse (geht an d0)" zeit 0 1000 tcp 1.1.1.1 443
	erwarte "HTTPS an eine öffentliche IPv6-Adresse (geht an d0)" zeit 0 1000 tcp 2606:4700:4700::1111 443

	echo "Abgewiesen für lf-claude, je ein Treffer:"
	erwarte "DNS an 127.0.0.54" abgewiesen 1 1000 udp 127.0.0.54 53
	erwarte "über $ADDR ein Dienst auf allen Adressen" abgewiesen 1 1000 tcp "$ADDR" 4712
	erwarte "$ADDR Port 22" abgewiesen 1 1000 tcp "$ADDR" 22
	erwarte "127.0.0.1, Dienst von root" abgewiesen 1 1000 tcp 127.0.0.1 4713
	erwarte "127.0.0.1, Quelle $ADDR" abgewiesen 1 1000 tcp 127.0.0.1 4713 "$ADDR"
	erwarte "127.0.0.1 Port 9" abgewiesen 1 1000 tcp 127.0.0.1 9
	erwarte "::1" abgewiesen 1 1000 tcp ::1 443
	erwarte "eigene Adresse 10.9.9.9" abgewiesen 1 1000 tcp 10.9.9.9 443
	erwarte "eigene Adresse fd00::9" abgewiesen 1 1000 tcp fd00::9 443
	erwarte "eigene Adresse 172.31.0.2" abgewiesen 1 1000 tcp 172.31.0.2 443
	erwarte "eigene link-local-Adresse" abgewiesen 1 1000 tcp fe80::ff:fe00:9%d0 443
	erwarte "link-local fe80::1" abgewiesen 1 1000 tcp fe80::1%d0 443
	erwarte "Rechner im Netz 172.31.0.1" abgewiesen 1 1000 tcp 172.31.0.1 443
	erwarte "privat 10.0.0.1" abgewiesen 1 1000 tcp 10.0.0.1 443
	erwarte "privat 172.16.0.1" abgewiesen 1 1000 tcp 172.16.0.1 443
	erwarte "privat 192.168.1.1" abgewiesen 1 1000 tcp 192.168.1.1 443
	erwarte "CGNAT 100.64.0.1" abgewiesen 1 1000 tcp 100.64.0.1 443
	erwarte "link-local 169.254.1.1" abgewiesen 1 1000 tcp 169.254.1.1 443
	erwarte "Dokumentation 192.0.2.1" abgewiesen 1 1000 tcp 192.0.2.1 443
	erwarte "Benchmark 198.18.0.1" abgewiesen 1 1000 tcp 198.18.0.1 443
	erwarte "reserviert 240.0.0.1" abgewiesen 1 1000 tcp 240.0.0.1 443
	erwarte "ULA fc00::1" abgewiesen 1 1000 tcp fc00::1 443
	erwarte "NAT64 mit 10.0.0.1" abgewiesen 1 1000 tcp 64:ff9b::a00:1 443
	erwarte "6to4 mit 10.0.0.1" abgewiesen 1 1000 tcp 2002:a00:1:: 443
	erwarte "Dokumentation 2001:db8::1" abgewiesen 1 1000 tcp 2001:db8::1 443
	erwarte "öffentlich, Port 80" abgewiesen 1 1000 tcp 1.1.1.1 80
	erwarte "öffentlich IPv6, Port 80" abgewiesen 1 1000 tcp 2606:4700:4700::1111 80
	erwarte "öffentlich, Port 22" abgewiesen 1 1000 tcp 1.1.1.1 22
	erwarte "UDP an eine öffentliche Adresse, Port 443" abgewiesen 1 1000 udp 1.1.1.1 443
	erwarte "Multicast 224.0.0.251" abgewiesen 1 1000 udp 224.0.0.251 5353

	echo "lf-claude als Gegenstelle:"
	erwarte "root erreicht die Attrappe von lf-claude auf $ADDR" ok 0 0 tcp "$ADDR" 4715
	erwarte "root erreicht keinen Dienst von lf-claude auf 127.0.0.1" "nicht ok" 1 0 tcp 127.0.0.1 4714 "" 0.5

	echo "Andere Benutzer:"
	erwarte "root, 127.0.0.1 Port 9" abgewiesen 0 0 tcp 127.0.0.1 9
	erwarte "root, Dienst von root auf 127.0.0.1" ok 0 0 tcp 127.0.0.1 4713
	erwarte "root, privat 10.0.0.1 (geht an d0)" zeit 0 0 tcp 10.0.0.1 443 "" 0.5
	erwarte "1001, Dienst von root auf 127.0.0.1" ok 0 1001 tcp 127.0.0.1 4713
	erwarte "auch root nicht über $ADDR an einen Dienst auf allen Adressen" abgewiesen 1 0 tcp "$ADDR" 4712

	echo "Zusammen mit lf-claude-ssh.nft:"
	sed 's/meta skuid "lf-claude" /meta skuid 1000 /' "$SSH_RULES" | nft -f -
	n=$(nft -j list chain inet lf_claude_ssh ausgang | jq '[.nftables[] | .rule? // empty | .expr[] | .counter? // empty | .packets] | add')
	erwarte "Port 22 auf 127.0.0.1 weist zuerst die Regel für SSH ab" abgewiesen 0 1000 tcp 127.0.0.1 22
	check "ihr Zähler steigt" '[[ $(nft -j list chain inet lf_claude_ssh ausgang | jq "[.nftables[] | .rule? // empty | .expr[] | .counter? // empty | .packets] | add") == $((n + 1)) ]]'

	echo "Selbsttest:"
	out=$(selftest_netz_claude)
	rc=$?
	sed 's/^/    /' <<<"$out"
	check "der Selbsttest besteht und nennt alle Ziele" '((rc == 0)) && [[ $out == "LF-SELFTEST: Netz für Claude: Verbindungen von lf-claude an eigene, private und andere Ziele als HTTPS scheitern an der Regel (127.0.0.1:9 127.0.0.1:443 ::1:443 10.9.9.9:443 fd00::9:443 fe80::ff:fe00:9%d0:443 10.255.255.1:443 1.1.1.1:80), root trifft sie nicht" ]]'

	echo "Mit einer zweiten Regel in der Kette:"
	nft insert rule inet lf_claude_netz claude tcp dport 80 accept
	check "claude_netz_regel erkennt sie" '! claude_netz_regel'
	out=$(selftest_netz_claude)
	rc=$?
	check "der Selbsttest auch" '((rc != 0)) && [[ $out == *"nicht geladen"* ]]'

	echo "Mit einer Regel für einen anderen Benutzer:"
	sed 's/meta skuid "lf-claude" /meta skuid 1001 /' "$RULES" | nft -f -
	check "claude_netz_regel erkennt sie" '! claude_netz_regel'
	erwarte "lf-claude erreicht 127.0.0.1 wieder" ok 0 1000 tcp 127.0.0.1 4713
	return "$((fails > 0))"
}

if [[ ${1:-} == --im-namespace ]]; then
	im_namespace
	exit
fi

T=$(mktemp -d)
trap '[[ -s $T/pids ]] && xargs kill <"$T/pids" 2>/dev/null; rm -rf "$T"' EXIT

echo "Regel:"
check "eine Tabelle inet (IPv4 und IPv6), erneutes Laden ersetzt sie" '[[ $(grep -vE "^[[:space:]]*(#|$)" "$RULES" | head -n 3 | tr "\n" "|") == "table inet lf_claude_netz|delete table inet lf_claude_netz|table inet lf_claude_netz {|" ]]'
check "Kette am Ausgang nach der für SSH, alles andere geht durch" 'grep -qxF "		type filter hook output priority filter + 10; policy accept;" "$RULES" && grep -qxF "		type filter hook output priority filter; policy accept;" "$SSH_RULES"'
check "nur lf-claude springt in die Kette claude, genau einmal" '[[ $(grep -c "meta skuid" "$RULES") == 1 ]] && grep -qxF "		meta skuid \"lf-claude\" jump claude" "$RULES"'
check "die Kette claude endet mit Abweisen" '[[ $(sed -n "/^	chain claude {$/,/^	}$/p" "$RULES" | grep -vE "^[[:space:]]*(#|$)" | tail -n 2 | head -n 1 | tr -d "\t") == "goto abweisen" ]]'
check "erlaubt sind nur DNS an 127.0.0.53, $ADDR ab Port 1024, Antworten von dort und HTTPS" '[[ $(sed -n "/^	chain claude {$/,/^	}$/p" "$RULES" | grep -E "accept$" | tr -d "\t" | tr "\n" "|") == "ct direction reply ip saddr $ADDR tcp sport 1024-65535 accept|ip daddr 127.0.0.53 udp dport 53 accept|ip daddr 127.0.0.53 tcp dport 53 accept|ip daddr $ADDR tcp dport 1024-65535 accept|tcp dport 443 accept|" ]]'
check "HTTPS erst nach eigenen, privaten und besonderen Adressen" '[[ $(sed -n "/^	chain claude {$/,/^	}$/p" "$RULES" | grep -nE "fib daddr type|@privat4|@privat6|tcp dport 443" | cut -d: -f1 | tr "\n" " ") =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)\ $ ]] && ((BASH_REMATCH[1] < BASH_REMATCH[4] && BASH_REMATCH[2] < BASH_REMATCH[4] && BASH_REMATCH[3] < BASH_REMATCH[4]))'
check "Eingang: über $ADDR nur Sockets genau an dieser Adresse" 'grep -qxF "		ip daddr $ADDR socket wildcard 1 goto abweisen" "$RULES" && grep -qxF "		type filter hook input priority filter + 10; policy accept;" "$RULES"'
check "Abweisen zählt im Zähler abgewiesen" '[[ $(sed -n "/^	chain abweisen {$/,/^	}$/p" "$RULES" | grep -vE "^[[:space:]]*(#|$)" | tr -d "\t" | tr "\n" "|") == "chain abweisen {|counter name \"abgewiesen\"|meta l4proto tcp reject with tcp reset|reject with icmpx admin-prohibited|}|" ]]'
for netz in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 224.0.0.0/4 240.0.0.0/4 fc00::/7 fe80::/10 ff00::/8 64:ff9b::/96 2002::/16; do
	check "privat: $netz" 'grep -qE "(\{ |, |^[[:space:]]+)${netz//./\\.}(,| \})" "$RULES"'
done

echo "Dienst, Paket und Bau:"
check "der Dienst lädt die Regel aus /usr/local/lib/lf" 'grep -qxF "ExecStart=/usr/sbin/nft -f /usr/local/lib/lf/$(basename "$RULES")" "$UNIT"'
check "vor dem Netz, ohne Standard-Abhängigkeiten" 'grep -qxF "Before=network-pre.target shutdown.target" "$UNIT" && grep -qxF "Wants=network-pre.target" "$UNIT" && grep -qxF "DefaultDependencies=no" "$UNIT"'
check "nach nftables.service (flush ruleset)" 'grep -qxF "After=local-fs.target nftables.service" "$UNIT"'
check "einmalig, bleibt aktiv, beim Start" 'grep -qxF "Type=oneshot" "$UNIT" && grep -qxF "RemainAfterExit=yes" "$UNIT" && grep -qxF "WantedBy=multi-user.target" "$UNIT"'
check "chroot-setup schaltet ihn ein, genau einmal" '[[ $(grep -cxF "systemctl enable lf-claude-netz-sperre.service" build/chroot-setup.sh) == 1 ]]'
check "nftables steht in der Paketliste" 'grep -qx "nftables" build/packages.list'
check "der Selbsttest ruft selftest_netz_claude auf" 'grep -qxF "	selftest_netz_claude || ok=0" rescue/lf'
check "der Bau kopiert rescue/lib nach /usr/local/lib/lf" 'grep -qF "cp -a --no-preserve=ownership \"\$SRC/rescue/lib/.\" \"\$CHROOT/usr/local/lib/lf/\"" build/build.sh'
check "CLAUDE_NETZ_REGEL und CLAUDE_NETZ_DIENST stehen fest, nie aus der Umgebung" 'grep -qxF "CLAUDE_NETZ_REGEL=/usr/local/lib/lf/$(basename "$RULES")" rescue/lib/claude.sh && grep -qxF "CLAUDE_NETZ_DIENST=$(basename "$UNIT")" rescue/lib/claude.sh'

echo "Attrappe von lf-claude-check:"
check "claude-check.sh nennt $ADDR fest" 'grep -qxF "CLAUDE_CHECK_ADDR=$ADDR" rescue/lib/claude-check.sh'
check "die CLI fragt dort" 'grep -qF "ANTHROPIC_BASE_URL=\"http://\$CLAUDE_CHECK_ADDR:\$port\"" rescue/lib/claude-check.sh && ! grep -qF "http://127.0.0.1" rescue/lib/claude-check.sh'
check "die Attrappe bekommt sie" 'grep -qF "LF_API_ADDR=\$CLAUDE_CHECK_ADDR python3 -I \"\$LF_LIB/selftest-claude-api.py\"" rescue/lib/claude-check.sh'
mkdir -p "$T/api"
echo '{"name": "Bash", "input": {"command": "true"}}' >"$T/api/aufruf"
python3 -I rescue/lib/selftest-claude-api.py "$T/api/port" "$T/api/aufruf" "$T/api/log" 2>"$T/api/fehler" &
echo $! >>"$T/pids"
for ((i = 0; i < 50; i++)); do
	[[ -s $T/api/port ]] && break
	sleep 0.1
done
port=$(cat "$T/api/port" 2>/dev/null)
check "die Attrappe lauscht auf $ADDR" '[[ $port =~ ^[0-9]+$ && $(python3 -I -c "$VERBINDE" tcp "$ADDR" "$port") == ok ]]'
check "auf 127.0.0.1 nicht" '[[ $(python3 -I -c "$VERBINDE" tcp 127.0.0.1 "$port") == abgewiesen ]]'
check "eine Adresse außerhalb von loopback lehnt sie ab" '! LF_API_ADDR=0.0.0.0 timeout 5 python3 -I rescue/lib/selftest-claude-api.py "$T/api/port2" "$T/api/aufruf" "$T/api/log2" 2>/dev/null && [[ ! -e $T/api/port2 ]]'

echo "claude_netz_regel (Attrappen):"
(
	fails=0
	eval "$FN"
	CLAUDE_NETZ_DIENST=lf-claude-netz-sperre.service
	CLAUDE_NETZ_REGEL=/usr/local/lib/lf/lf-claude-netz.nft
	AKTIV=0 SOLL="table inet lf_claude_netz { x }" IST="table inet lf_claude_netz { x }" SUDO_RC=0
	: >"$T/aufrufe"
	systemctl() {
		echo "systemctl $*" >>"$T/aufrufe"
		[[ $* == "is-active --quiet lf-claude-netz-sperre.service" ]] && return "$AKTIV"
		return 1
	}
	sudo() {
		echo "sudo $*" >>"$T/aufrufe"
		((SUDO_RC)) && return "$SUDO_RC"
		case "$*" in
		"unshare --net -- sh -c nft -f \"\$1\" && nft -s list table inet lf_claude_netz _ /usr/local/lib/lf/lf-claude-netz.nft") echo "$SOLL" ;;
		"nft -s list table inet lf_claude_netz") echo "$IST" ;;
		*) return 1 ;;
		esac
	}
	check "gleich: ja" 'claude_netz_regel'
	check "die Datei kommt in einem eigenen Netz-Namespace an nft, verglichen wird ohne Zähler" '[[ $(grep -c "^sudo unshare --net -- sh -c nft -f" "$T/aufrufe") == 1 && $(grep -cxF "sudo nft -s list table inet lf_claude_netz" "$T/aufrufe") == 1 ]]'
	IST="table inet lf_claude_netz { y }"
	check "anders: nein" '! claude_netz_regel'
	SOLL="" IST=""
	check "leer: nein" '! claude_netz_regel'
	SOLL="table inet lf_claude_netz { x }" IST=$SOLL SUDO_RC=1
	check "sudo scheitert: nein" '! claude_netz_regel'
	SUDO_RC=0 AKTIV=3
	: >"$T/aufrufe"
	check "Dienst nicht aktiv: nein, ohne sudo" '! claude_netz_regel && ! grep -q "^sudo" "$T/aufrufe"'
	exit "$fails"
)
fails=$((fails + $?))

echo "Start von CLI und Desktop:"
start_fn=$(sed -n '/^claude_start() {$/,/^}$/p; /^claude_desktop() {$/,/^}$/p' rescue/lib/claude.sh)
(
	fails=0
	eval "$start_fn"
	CLAUDE_FREIGABE_STAND=aus LF_RUN=$T LF_LIB=$T LF_LOG=$T/log
	NETZ=1
	claude_startbar() { return 0; }
	claude_netz_regel() { return "$NETZ"; }
	claude_netz_text() { echo "NETZTEXT"; }
	claude_gesperrt_text() { echo "GESPERRT"; }
	ui_msg() { echo "ui_msg $1: $2" >>"$T/start"; }
	ui_info() { :; }
	is_online() {
		echo "is_online" >>"$T/start"
		return 1
	}
	claude_scope() { echo "claude_scope" >>"$T/start"; }
	cage() { echo "cage" >>"$T/start"; }
	for f in claude_start claude_desktop; do
		: >"$T/start"
		"$f" >/dev/null 2>&1
		check "$f: ohne die Regel nur der Hinweis, kein Start" '[[ $(cat "$T/start") == "ui_msg "*": NETZTEXT" ]]'
		NETZ=0
		: >"$T/start"
		"$f" >/dev/null 2>&1
		check "$f: mit der Regel geht es weiter" '[[ $(head -n 1 "$T/start") == is_online ]]'
		NETZ=1
	done
	check "claude_start prüft die Regel nach claude_startbar und vor is_online" '[[ $(sed -n "/^claude_start() {$/,/^}$/p" rescue/lib/claude.sh | grep -nE "claude_startbar;|claude_netz_regel;|is_online;" | cut -d: -f1 | head -n 3 | tr "\n" " ") =~ ^([0-9]+)\ ([0-9]+)\ ([0-9]+)\ $ ]] && ((BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] < BASH_REMATCH[3]))'
	exit "$fails"
)
fails=$((fails + $?))

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
	echo "unit-netz-claude: $fails FAIL"
	exit 1
fi
echo "unit-netz-claude: alles ok"
