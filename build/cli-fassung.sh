#!/usr/bin/env bash
# build/cli-fassung.sh [--issue]
#   Vergleicht die stabile Fassung der Claude Code CLI beim Hersteller mit der festen Fassung im
#   Build (CLAUDE_CLI_VERSION in build/chroot-setup.sh, #65). Ist die stabile Fassung neuer, nennt
#   es sie mit ihrem sha256 für linux-x64. Beides stammt nur aus einem Manifest, dessen Signatur
#   (manifest.json.sig) der Anthropic-Schlüssel mit dem Fingerabdruck CLAUDE_DESKTOP_FPR aus
#   build/chroot-setup.sh bestätigt. Mit --issue legt es dafür ein Issue an oder ergänzt das offene
#   (Workflow .github/workflows/claude-cli.yml, #136). Den Build ändert es nie.
#
#   Status 0: aktuell oder gemeldet. Status 1: Abruf, Signatur oder Format passt nicht; dann meldet
#   es keine Fassung. Ein Wert vom Hersteller erscheint erst nach seiner Prüfung in einer Ausgabe:
#   Eine Zeile, die mit :: beginnt, wäre in GitHub Actions ein Befehl an den Runner.
set -uo pipefail

QUELLE=https://downloads.claude.ai/claude-code-releases
SCHLUESSEL_URL=https://downloads.claude.ai/claude-desktop/key.asc
TITEL="Build: neue Fassung der Claude Code CLI"
BOT="github-actions[bot]"
SETUP="$(dirname "$0")/chroot-setup.sh"

# fehler TEXT   Meldet TEXT und beendet mit Status 1. TEXT nennt nie einen ungeprüften Wert.
fehler() {
	echo "FEHLER: $*" >&2
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::error::$*"; fi
	exit 1
}

# zusammenfassung TEXT   Schreibt TEXT in die Zusammenfassung des Workflow-Laufs, sofern es eine gibt.
zusammenfassung() {
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}

# fassung_ok TEXT   Status 0, wenn TEXT eine Fassung X.Y.Z ist, jede Zahl mit höchstens 6 Ziffern.
fassung_ok() { [[ $1 =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }

# neuer A B   Status 0, wenn die Fassung A neuer ist als die Fassung B (beide geprüft).
neuer() {
	local -a a b
	local i
	IFS=. read -ra a <<<"$1"
	IFS=. read -ra b <<<"$2"
	for i in 0 1 2; do
		if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
		if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
	done
	return 1
}

# holen URL MAX DATEI   Lädt URL nur über https nach DATEI. Status ungleich 0, wenn der Abruf
#   scheitert oder die Datei größer ist als MAX Bytes.
holen() {
	curl --proto '=https' --tlsv1.2 -fsS --max-time 30 --retry 3 --retry-delay 5 --retry-all-errors \
		--max-filesize "$2" -o "$3" "$1" || return 1
	(($(wc -c <"$3") <= $2))
}

# signiert DATEN SIGNATUR SCHLUESSEL FPR   Status 0, wenn SIGNATUR eine gültige Signatur von DATEN
#   ist und ihr Hauptschlüssel den Fingerabdruck FPR hat. Weitere Schlüssel in der Datei SCHLUESSEL
#   gelten nicht. Ein abgelaufener oder widerrufener Schlüssel gilt nicht.
signiert() {
	local g="$D/gpg" status
	mkdir -m 700 "$g" || return 1
	GNUPGHOME=$g gpg --batch --quiet --no-autostart --import "$3" 2>/dev/null || return 1
	status=$(GNUPGHOME=$g gpg --batch --no-autostart --status-fd 1 --verify "$2" "$1" 2>/dev/null) || return 1
	grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status" || return 1
	! grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) ' <<<"$status" || return 1
	awk -v f="$4" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == f { ok = 1 } END { exit !ok }' <<<"$status"
}

# text FASSUNG SUMME BUILD FPR   Text für ein neues Issue
text() {
	printf 'Beim Hersteller gibt es eine neuere stabile Fassung der Claude Code CLI als im Build.\n\n'
	printf -- '- Fassung: `%s`\n- sha256 für linux-x64: `%s`\n- im Build: `%s`\n' "$1" "$2" "$3"
	printf -- '- Manifest: %s/%s/manifest.json, Signatur mit dem Schlüssel `%s` geprüft\n\n' "$QUELLE" "$1" "$4"
	printf 'Für die neue Fassung `CLAUDE_CLI_VERSION` und `CLAUDE_CLI_SHA256` in `build/chroot-setup.sh` zusammen ändern. Der PR läuft durch die CI wie jeder andere.\n\n'
	printf 'Gemeldet vom Workflow „Claude Code CLI“ (`.github/workflows/claude-cli.yml`, #136).\n'
}

# kommentar FASSUNG SUMME BUILD FPR   Text für einen Kommentar im offenen Issue
kommentar() {
	printf -- 'Neuere stabile Fassung: `%s`, sha256 für linux-x64 `%s`, im Build `%s`. Manifest: %s/%s/manifest.json, Signatur mit dem Schlüssel `%s` geprüft.\n' \
		"$1" "$2" "$3" "$QUELLE" "$1" "$4"
}

# melden FASSUNG SUMME BUILD FPR   Legt ein Issue an oder ergänzt das offene. Als offen zählt nur
#   ein Issue mit dem Titel TITEL, das der Workflow selbst angelegt hat. Nennt es den sha256 schon
#   (im Text oder in einem Kommentar), schreibt es nichts.
melden() {
	local repo=${GITHUB_REPOSITORY:-} nr alt
	[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fehler "GITHUB_REPOSITORY fehlt"
	nr=$(gh api --paginate "repos/$repo/issues?state=open&per_page=100" \
		--jq ".[] | select(.pull_request == null and .user.login == \"$BOT\" and .title == \"$TITEL\") | .number") ||
		fehler "Die offenen Issues ließen sich nicht lesen"
	nr=${nr%%$'\n'*}
	if [[ -n $nr ]]; then
		[[ $nr =~ ^[0-9]+$ ]] || fehler "Unerwartete Antwort beim Lesen der offenen Issues"
		alt=$(gh api "repos/$repo/issues/$nr" --jq .body && gh api "repos/$repo/issues/$nr/comments?per_page=100" --jq '.[].body') ||
			fehler "Das offene Issue #$nr ließ sich nicht lesen"
		if grep -qF -- "$2" <<<"$alt"; then
			echo "schon gemeldet in #$nr"
			zusammenfassung "Claude Code CLI $1 ist schon in #$nr gemeldet."
			return 0
		fi
		kommentar "$@" >"$D/text"
		gh issue comment "$nr" --repo "$repo" --body-file "$D/text" >/dev/null || fehler "Der Kommentar in #$nr ließ sich nicht schreiben"
		echo "ergänzt: #$nr"
		zusammenfassung "Claude Code CLI $1: in #$nr ergänzt."
	else
		text "$@" >"$D/text"
		gh issue create --repo "$repo" --title "$TITEL" --body-file "$D/text" >/dev/null || fehler "Das Issue ließ sich nicht anlegen"
		echo "gemeldet: neues Issue"
		zusammenfassung "Claude Code CLI $1: neues Issue angelegt."
	fi
}

issue=false
case $#:${1:-} in
1:--issue) issue=true ;;
0:) ;;
*)
	echo "Aufruf: $0 [--issue]" >&2
	exit 2
	;;
esac

for w in curl gpg jq; do command -v "$w" >/dev/null || fehler "$w fehlt"; done
if $issue; then command -v gh >/dev/null || fehler "gh fehlt"; fi

[[ -r $SETUP ]] || fehler "$SETUP fehlt"
build=$(sed -n 's/^CLAUDE_CLI_VERSION="\([0-9.]*\)"$/\1/p' "$SETUP")
fpr=$(sed -n 's/^CLAUDE_DESKTOP_FPR="\([0-9A-F]*\)"$/\1/p' "$SETUP")
fassung_ok "$build" || fehler "CLAUDE_CLI_VERSION in $SETUP ist keine Fassung X.Y.Z"
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || fehler "CLAUDE_DESKTOP_FPR in $SETUP ist kein Fingerabdruck"

D=$(mktemp -d) || fehler "Kein Arbeitsverzeichnis"
trap 'rm -rf "$D"' EXIT

holen "$QUELLE/stable" 64 "$D/stable" || fehler "Die stabile Fassung ließ sich nicht abrufen"
stabil=$(<"$D/stable")
fassung_ok "$stabil" || fehler "Der Hersteller nennt als stabile Fassung keine Fassung X.Y.Z"

if ! neuer "$stabil" "$build"; then
	echo "aktuell: stabil $stabil, im Build $build"
	zusammenfassung "Claude Code CLI: stabil $stabil, im Build $build. Nichts zu melden."
	exit 0
fi

holen "$QUELLE/$stabil/manifest.json" 65536 "$D/manifest.json" || fehler "Das Manifest ließ sich nicht abrufen"
holen "$QUELLE/$stabil/manifest.json.sig" 8192 "$D/manifest.json.sig" || fehler "Die Signatur des Manifests ließ sich nicht abrufen"
holen "$SCHLUESSEL_URL" 65536 "$D/key.asc" || fehler "Der Anthropic-Schlüssel ließ sich nicht abrufen"
signiert "$D/manifest.json" "$D/manifest.json.sig" "$D/key.asc" "$fpr" ||
	fehler "Die Signatur des Manifests passt nicht zum Schlüssel $fpr"

v=$(jq -er '.version' "$D/manifest.json" 2>/dev/null) || fehler "Das Manifest nennt keine Fassung"
[[ $v == "$stabil" ]] || fehler "Das Manifest nennt eine andere Fassung als die stabile"
summe=$(jq -er '.platforms["linux-x64"].checksum' "$D/manifest.json" 2>/dev/null) || fehler "Das Manifest nennt keinen sha256 für linux-x64"
[[ $summe =~ ^[0-9a-f]{64}$ ]] || fehler "Der sha256 für linux-x64 im Manifest hat nicht das Format"

echo "neu: stabil $stabil (sha256 $summe), im Build $build"
if $issue; then
	melden "$stabil" "$summe" "$build" "$fpr"
else
	zusammenfassung "Claude Code CLI: stabil $stabil (sha256 $summe), im Build $build."
fi
