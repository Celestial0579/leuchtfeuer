#!/usr/bin/env bash
# Unit-Test (#65): Der ISO-Build hängt nur an festgelegten Fassungen.
#
# Statisch geprüft:
#   - build/Dockerfile hat genau eine FROM-Zeile: ubuntu:26.04 mit Digest,
#   - build.yml baut im Image aus build/Dockerfile, lehnt eines ohne Digest ab, nennt kein
#     ubuntu:26.04 ohne Digest und läuft in jedem Job auf ubuntu-26.04, nie auf ubuntu-latest,
#   - Dependabot hält das Image in /build aktuell, ohne eine andere Ubuntu-Fassung vorzuschlagen,
#   - chroot-setup.sh legt Fassung und sha256 der Claude Code CLI fest, führt kein Skript aus dem
#     Netz aus und verlangt, dass die installierte CLI die festgelegte Fassung meldet,
#   - chroot-setup.sh legt für apt nur den Claude-Desktop-Schlüssel mit dem festgelegten
#     Fingerabdruck ab und bricht ab, wenn danach ein anderer oder ein weiterer Hauptschlüssel darin
#     steht; gpg läuft dort nie im Verzeichnis von root,
#   - build.sh schreibt Basis-Image und Fassung der CLI ins Manifest des Releases.
# Mit einer Attrappe für curl: claude_cli_laden lädt die feste Fassung für linux-x64 und lehnt
# jede Datei mit einem anderen sha256 ab. Echt prüft es der ISO-Build in der CI.
# Mit einer Attrappe für gpg, ohne Schlüsselmaterial: desktop_schluessel lässt aus einer
# Schlüsseldatei nur den festgelegten Schlüssel durch und scheitert, wenn das nicht genau einer ist.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D=build/Dockerfile
W=.github/workflows/build.yml
B=.github/dependabot.yml
C=build/chroot-setup.sh
S=build/build.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# Feste Zeichenketten aus build.yml und chroot-setup.sh, wörtlich gesucht (grep -F).
RUN_IMG='"$img" /src/build/build.sh'
ENV_IMG='-e LF_BASIS_IMAGE="$img"'
IMG_RE='^ubuntu:26\.04@sha256:[0-9a-f]{64}$ ]]'
V_CHECK='[[ $cli_v != "$CLAUDE_CLI_VERSION "* ]]'
EXPORT_PIN='--armor --export "$CLAUDE_DESKTOP_FPR" >"$2"'
ALLE_PUB='$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }'
FPR_CHECK='[[ $fpr == "$CLAUDE_DESKTOP_FPR" ]]'
RUF_DESKTOP='if ! desktop_schluessel "$roh" "$key"; then'

echo "Basis-Image:"
check "build/Dockerfile hat genau eine FROM-Zeile" '[[ $(grep -c "^FROM" "$D") == 1 ]]'
check "sie nennt ubuntu:26.04 mit Digest" 'grep -qE "^FROM ubuntu:26\.04@sha256:[0-9a-f]{64}$" "$D"'
check "build.yml liest das Image aus build/Dockerfile und baut darin" 'grep -qF "build/Dockerfile)" "$W" && grep -qF -- "$RUN_IMG" "$W"'
check "build.yml bricht ab, wenn das Image keinen Digest hat" 'grep -qF -- "$IMG_RE" "$W"'
check "build.yml gibt das Image als LF_BASIS_IMAGE an den Build" 'grep -qF -- "$ENV_IMG" "$W"'
check "build.yml nennt kein ubuntu:26.04 ohne Digest" '! grep -qE "ubuntu:26\.04([^@]|$)" "$W"'
check "jeder Job läuft auf ubuntu-26.04" 'n=$(grep -cE "^[[:space:]]+runs-on:" "$W"); ((n > 0)) && [[ $(grep -cE "^[[:space:]]+runs-on: ubuntu-26\.04$" "$W") == "$n" ]]'
check "kein Job läuft auf ubuntu-latest" '! grep -q "ubuntu-latest" "$W"'
check "Dependabot prüft das Image in /build" 'grep -qE "^[[:space:]]+- package-ecosystem: docker$" "$B" && grep -qE "^[[:space:]]+directory: /build$" "$B"'
check "Dependabot schlägt keine andere Ubuntu-Fassung vor" 'grep -qE "^[[:space:]]+- dependency-name: ubuntu$" "$B" && grep -qF "\"version-update:semver-major\", \"version-update:semver-minor\"" "$B"'

echo "Claude Desktop:"
FN_D=$(sed -n '/^desktop_schluessel() {$/,/^}$/p' "$C")
check "für apt nur der Schlüssel mit dem festgelegten Fingerabdruck, aus dem Download exportiert" 'grep -qF -- "$EXPORT_PIN" <<<"$FN_D"'
check "geprüft werden alle Hauptschlüssel der Datei, nicht nur der erste" 'grep -qF -- "$ALLE_PUB" <<<"$FN_D" && ! grep -qF "{print \$10; exit}" "$C"'
check "der Status der Prüfung ist der Vergleich mit dem festgelegten Fingerabdruck" '[[ $(tail -n 2 <<<"$FN_D" | head -n 1) == $'"'"'\t'"'"'"$FPR_CHECK" ]]'
check "scheitert sie, bricht der Build ab" 'awk -v r="$RUF_DESKTOP" '"'"'$0 == r { an = 1 } an && $0 == "\texit 1" { ok = 1 } an && $0 == "fi" { an = 0 } END { exit !ok }'"'"' "$C"'
check "apt nimmt genau diese Datei (signed-by)" 'grep -qF "signed-by=\$key]" "$C" && [[ $(grep -c "^key=" "$C") == 1 ]]'
check "chroot-setup.sh läuft mit pipefail: Scheitert gpg, scheitert auch die Prüfung" 'grep -qx "set -Eeuo pipefail" "$C"'
check "jeder Aufruf von gpg hat ein eigenes --homedir (kein /root/.gnupg in der ISO)" '! grep -vE "^[[:space:]]*#" "$C" | grep -E "(^|[[:space:]\"(])gpg[[:space:]]" | grep -qv -- "--homedir"'

echo "Claude Code CLI:"
check "chroot-setup.sh legt die Fassung fest" 'grep -qE "^CLAUDE_CLI_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$" "$C"'
check "und ihren sha256" 'grep -qE "^CLAUDE_CLI_SHA256=\"[0-9a-f]{64}\"$" "$C"'
check "kein Skript aus dem Netz: kein install.sh, nichts an eine Shell übergeben" '! grep -qE "install\.sh|\|[[:space:]]*(ba)?sh([[:space:]]|$)|bash -c" "$C"'
check "die installierte CLI muss die festgelegte Fassung melden" 'grep -qF -- "$V_CHECK" "$C"'
check "build.sh schreibt Basis-Image und Fassung der CLI ins Manifest des Releases" 'grep -qF "lf-basis-image" "$S" && grep -qF "claude-code-cli" "$S"'

FN=$(sed -n '/^claude_cli_laden() {$/,/^}$/p' "$C")
if [[ -z $FN ]]; then
	echo "  FAIL claude_cli_laden fehlt in $C"
	echo "unit-build-fest: $((fails + 1)) Fehler"
	exit 1
fi
eval "$FN"

# curl-Attrappe: merkt sich die URL und schreibt $INHALT nach der Datei hinter -o. Mit CURL_RC
# ungleich 0 scheitert sie wie ein Download ohne Antwort.
curl() {
	local out='' url=''
	while (($#)); do
		case $1 in
		-o)
			out=$2
			shift 2
			;;
		-*) shift ;;
		*)
			url=$1
			shift
			;;
		esac
	done
	echo "$url" >"$T/url"
	((${CURL_RC:-0} == 0)) || return "$CURL_RC"
	printf '%s' "$INHALT" >"$out"
}

# lade   claude_cli_laden nach $T/cli, Status in RC
lade() {
	rm -f "$T/cli" "$T/url"
	claude_cli_laden "$T/cli"
	RC=$?
}

INHALT="Attrappe der Claude Code CLI"
SUMME=$(printf '%s' "$INHALT" | sha256sum | cut -d' ' -f1)
CLAUDE_CLI_VERSION=9.8.7
CLAUDE_CLI_SHA256=$SUMME

echo "claude_cli_laden mit einer Attrappe für curl:"
lade
check "passender sha256: Status 0, die Datei liegt da" '((RC == 0)) && [[ $(cat "$T/cli") == "$INHALT" ]]'
check "die URL nennt die feste Fassung und linux-x64" '[[ $(cat "$T/url") == "https://downloads.claude.ai/claude-code-releases/9.8.7/linux-x64/claude" ]]'
CLAUDE_CLI_SHA256=$(printf '%064d' 0)
lade
check "anderer sha256: Status ungleich 0" '((RC != 0))'
CLAUDE_CLI_SHA256=$SUMME
INHALT="eine andere Datei unter derselben Fassung"
lade
check "andere Datei unter derselben Fassung: Status ungleich 0" '((RC != 0))'
INHALT="Attrappe der Claude Code CLI"
CURL_RC=22
lade
check "Download scheitert: Status ungleich 0" '((RC != 0))'
unset CURL_RC
lade
check "danach wieder die passende Datei: Status 0" '((RC == 0))'

# gpg-Attrappe ohne Schlüsselmaterial. Eine Schlüsseldatei besteht hier aus Zeilen "haupt FPR" (ein
# Hauptschlüssel) und "unter FPR" (ein Unterschlüssel des Hauptschlüssels davor). Wie gpg:
#   --import nimmt alle Schlüssel der Datei in das Verzeichnis hinter --homedir auf, gleiche
#     Hauptschlüssel zusammengeführt, und scheitert mit Status 2 an einer Datei ohne Schlüssel,
#   --export FPR gibt jeden Schlüssel samt Unterschlüsseln aus, dessen Haupt- oder Unterschlüssel
#     den Fingerabdruck FPR hat, sonst nichts, --export ohne FPR alle Schlüssel,
#   --show-keys --with-colons zeigt je Hauptschlüssel pub und fpr, je Unterschlüssel sub und fpr;
#     mit GPG_SHOW_RC endet es danach mit diesem Status, wie gpg nach einem Fehler in der Datei.
# Jeder Aufruf steht in $T/gpg.log.
bloecke() {
	awk '$1 == "haupt" && NF == 2 { if (b != "") print b; b = $2; next }
		$1 == "unter" && NF == 2 && b != "" { b = b " " $2 }
		END { if (b != "") print b; else exit 2 }' "$1"
}
gpg() {
	local home='' art='' b
	local -a arg=()
	echo "$*" >>"$T/gpg.log"
	while (($#)); do
		case $1 in
		--homedir)
			home=${2:-}
			shift
			(($#)) && shift
			;;
		--import) art="import" && shift ;;
		--export) art="export" && shift ;;
		--show-keys) art="show" && shift ;;
		-*) shift ;;
		*) arg+=("$1") && shift ;;
		esac
	done
	[[ -n $home && -d $home ]] || return 2
	local datei=${arg[0]:-} fpr=${arg[0]:-*}
	case $art in
	import)
		b=$(bloecke "$datei") || { echo "gpg: keine gültigen OpenPGP-Daten gefunden." >&2; return 2; }
		{ cat "$home/bund" 2>/dev/null; printf '%s\n' "$b"; } | awk '
			!($1 in h) { h[$1] = 1; o[++n] = $1 }
			{ for (i = 2; i <= NF; i++) if (!(($1, $i) in s)) { s[$1, $i] = 1; u[$1] = u[$1] " " $i } }
			END { for (i = 1; i <= n; i++) print o[i] u[o[i]] }' >"$home/bund.neu" && mv "$home/bund.neu" "$home/bund"
		;;
	export)
		awk -v f="$fpr" '{ for (i = 1; i <= NF; i++) if (f == "*" || $i == f) { print "haupt " $1; for (j = 2; j <= NF; j++) print "unter " $j; next } }' "$home/bund"
		;;
	show)
		b=$(bloecke "$datei") || return 2
		awk '{ print "pub:-:4096:1:" substr($1, 25) ":0:::-:::scESC::::::23::0:"; print "fpr:::::::::" $1 ":"
			for (i = 2; i <= NF; i++) { print "sub:-:4096:1:" substr($i, 25) ":0::::::s::::::23:"; print "fpr:::::::::" $i ":" } }' <<<"$b"
		return "${GPG_SHOW_RC:-0}"
		;;
	*) return 2 ;;
	esac
}

# datei ZEILE...   die Schlüsseldatei aus dem Download
datei() { printf '%s\n' "$@" >"$T/roh"; }
# probe   desktop_schluessel mit $T/roh nach $T/ziel, mit pipefail wie in chroot-setup.sh; Status in
#   RC, die Hauptschlüssel in ZIEL in HAUPT
probe() {
	rm -f "$T/ziel" "$T/gpg.log"
	(
		set -o pipefail
		desktop_schluessel "$T/roh" "$T/ziel"
	) 2>>"$T/gpg.err"
	RC=$?
	HAUPT=$(awk '$1 == "haupt" { printf "%s ", $2 }' "$T/ziel" 2>/dev/null)
}

if [[ -z $FN_D ]]; then
	echo "  FAIL desktop_schluessel fehlt in $C"
	fails=$((fails + 1))
else
	eval "$FN_D"
	A=$(printf '%040d' 1 | tr 0 A) B=$(printf '%040d' 2 | tr 0 B) X=$(printf '%040d' 3 | tr 0 C)
	U1=$(printf '%040d' 4 | tr 0 D) U2=$(printf '%040d' 5 | tr 0 E)
	CLAUDE_DESKTOP_FPR=$A
	echo "desktop_schluessel mit einer Attrappe für gpg:"
	datei "haupt $A" "unter $U1" "unter $U2"
	probe
	check "der festgelegte Schlüssel allein: Status 0, mit seinen Unterschlüsseln" '((RC == 0)) && [[ $HAUPT == "$A " ]] && [[ $(grep -c "^unter " "$T/ziel") == 2 ]]'
	check "gpg arbeitet nur im eigenen Verzeichnis, danach ist es weg" 'h=$(sed -n "1s/^--homedir \([^ ]*\) .*/\1/p" "$T/gpg.log"); [[ -n $h && $h != /root/* && ! -e $h ]] && ! grep -qv -- "^--homedir $h " "$T/gpg.log"'
	datei "haupt $A" "haupt $B"
	probe
	check "festgelegter Schlüssel, dahinter ein fremder: Status 0, nur der festgelegte" '((RC == 0)) && [[ $HAUPT == "$A " ]]'
	datei "haupt $B" "haupt $A"
	probe
	check "fremder Schlüssel zuerst, dahinter der festgelegte: Status 0, nur der festgelegte" '((RC == 0)) && [[ $HAUPT == "$A " ]]'
	datei "haupt $A" "haupt $A"
	probe
	check "der festgelegte Schlüssel zweimal: Status 0, ein Hauptschlüssel" '((RC == 0)) && [[ $HAUPT == "$A " ]]'
	datei "haupt $B"
	probe
	check "nur ein fremder Schlüssel: Status ungleich 0" '((RC != 0))'
	datei "haupt $X" "unter $A"
	probe
	check "fremder Hauptschlüssel mit dem festgelegten Fingerabdruck als Unterschlüssel: Status ungleich 0" '((RC != 0))'
	datei "haupt $A" "haupt $X" "unter $A"
	probe
	check "derselbe neben dem festgelegten Schlüssel: Status ungleich 0" '((RC != 0))'
	printf 'kein Schlüssel\n' >"$T/roh"
	probe
	check "eine Datei ohne Schlüssel: Status ungleich 0" '((RC != 0))'
	: >"$T/roh"
	probe
	check "eine leere Datei: Status ungleich 0" '((RC != 0))'
	datei "haupt $A"
	GPG_SHOW_RC=2 probe
	check "gpg --show-keys scheitert, nachdem es den festgelegten Schlüssel gezeigt hat: Status ungleich 0" '((RC != 0))'
	(
		set +o pipefail
		rm -f "$T/ziel"
		GPG_SHOW_RC=2 desktop_schluessel "$T/roh" "$T/ziel"
	) 2>>"$T/gpg.err"
	RC=$?
	check "dasselbe ohne pipefail beim Aufrufer: Status ungleich 0 (#146)" '((RC != 0))'
	unset -f gpg
fi

echo
if ((fails)); then
	echo "unit-build-fest: $fails Fehler"
	exit 1
fi
echo "unit-build-fest: alles ok"
