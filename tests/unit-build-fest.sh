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
#   - build.sh schreibt Basis-Image und Fassung der CLI ins Manifest des Releases.
# Mit einer Attrappe für curl: claude_cli_laden lädt die feste Fassung für linux-x64 und lehnt
# jede Datei mit einem anderen sha256 ab. Echt prüft es der ISO-Build in der CI.
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

echo
if ((fails)); then
	echo "unit-build-fest: $fails Fehler"
	exit 1
fi
echo "unit-build-fest: alles ok"
