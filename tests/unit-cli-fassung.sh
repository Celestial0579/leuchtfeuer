#!/usr/bin/env bash
# Unit-Test (#136): Neue Fassungen der Claude Code CLI meldet ein Workflow, nur aus einem signierten
# Manifest.
#
# Statisch geprüft:
#   - .github/workflows/claude-cli.yml läuft nur nach Zeitplan und auf Abruf, ohne Rechte außer
#     contents: read und issues: write, auf ubuntu-26.04, mit derselben festgelegten checkout-Action
#     wie build.yml, ohne Zugangsdaten im Klon und ohne Ausdrücke außer github.token,
#   - build.yml prüft build/cli-fassung.sh mit shellcheck und führt diesen Test aus.
# Mit Attrappen für curl, gpg und gh, ohne Netz und ohne Schlüssel:
#   - gemeldet wird nur eine stabile Fassung, die neuer ist als die im Build,
#   - nur nach gültiger Signatur des Hauptschlüssels mit dem Fingerabdruck aus chroot-setup.sh,
#   - nur wenn Fassung und sha256 im Manifest das Format haben und zur stabilen Fassung passen,
#   - Werte vom Hersteller erscheinen erst nach der Prüfung in einer Ausgabe,
#   - ein Issue entsteht nur einmal, das offene wird ergänzt, ein schon gemeldeter sha256 nie
#     ein zweites Mal; als gemeldet zählen nur Text und Kommentare des Workflows.
# Echt prüft es der Workflow claude-cli.yml gegen den Hersteller.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
WF=.github/workflows/claude-cli.yml
BW=.github/workflows/build.yml
S=build/cli-fassung.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Workflow claude-cli.yml:"
# Die Ereignisse unter on: (zwei Leerzeichen eingerückt), die Rechte des Jobs (sechs Leerzeichen)
EREIGNISSE=$(sed -n '/^on:$/,/^[^[:space:]#]/p' "$WF" | sed -n 's/^  \([a-z_]*\):.*$/\1/p' | sort | tr '\n' ' ')
RECHTE=$(sed -n '/^    permissions:$/,/^    [a-z]/p' "$WF" | sed -n 's/^      \([a-z-]*: [a-z]*\)$/\1/p' | sort | tr '\n' ' ')
CO_WF=$(sed -n 's/^ *- uses: actions\/checkout@\([0-9a-f]*\) .*$/\1/p' "$WF" | sort -u)
CO_BW=$(sed -n 's/^ *- uses: actions\/checkout@\([0-9a-f]*\) .*$/\1/p' "$BW" | sort -u)
AUSDRUECKE=$(grep -o '\${{[^}]*}}' "$WF" | sort -u | tr '\n' ' ')
RUN_CLI='run: bash build/cli-fassung.sh --issue'
check "nur nach Zeitplan und auf Abruf (schedule, workflow_dispatch)" '[[ $EREIGNISSE == "schedule workflow_dispatch " ]]'
check "ohne Rechte für den ganzen Workflow (permissions: {})" 'grep -qx "permissions: {}" "$WF"'
check "der Job hat genau contents: read und issues: write" '[[ $(grep -c "^    permissions:$" "$WF") == 1 && $RECHTE == "contents: read issues: write " ]]'
check "läuft auf ubuntu-26.04, mit Zeitgrenze" '[[ $(grep -c "^    runs-on:" "$WF") == 1 ]] && grep -qx "    runs-on: ubuntu-26.04" "$WF" && grep -qE "^    timeout-minutes: [0-9]+$" "$WF"'
check "checkout per Commit-SHA wie in build.yml" '[[ $CO_WF =~ ^[0-9a-f]{40}$ && $CO_WF == "$CO_BW" ]]'
check "der Klon behält keine Zugangsdaten (persist-credentials: false)" 'grep -qx "          persist-credentials: false" "$WF"'
check "kein Ausdruck außer github.token, also nichts aus dem Ereignis im Skript" '[[ $AUSDRUECKE == "\${{ github.token }} " ]]'
check "der Workflow ruft build/cli-fassung.sh --issue auf" 'grep -qF -- "$RUN_CLI" "$WF"'
check "build.yml prüft build/cli-fassung.sh mit shellcheck" 'grep -qE "^[[:space:]]+build/build\.sh build/chroot-setup\.sh build/cli-fassung\.sh " "$BW"'
check "build.yml führt diesen Test aus" 'grep -qx "          bash tests/unit-cli-fassung.sh" "$BW"'

# Attrappen. curl liefert Dateien aus $T/netz (Pfad wie hinter https://downloads.claude.ai/) und
# scheitert wie curl -f, wenn es keine gibt. Jeder Aufruf steht in $T/curl.log.
mkdir -p "$T/bin" "$T/gh"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/curl.log"
out='' url=''
while (($#)); do
	case $1 in
	-o) out=$2; shift 2 ;;
	--proto | --max-time | --retry | --retry-delay | --max-filesize) shift 2 ;;
	-*) shift ;;
	*) url=$1; shift ;;
	esac
done
f="$T/netz/${url#https://downloads.claude.ai/}"
[[ $url == https://downloads.claude.ai/* && -f $f ]] || exit 22
cp "$f" "$out"
EOF
# gpg: --import merkt sich die Hauptschlüssel aus der Schlüsseldatei ("haupt FPR", "abgelaufen FPR").
# --verify liest die Signatur-Attrappe ("daten SHA256", "schluessel FPR", "haupt FPR") und meldet
# wie gpg: ohne passenden Schlüssel ERRSIG, bei anderen Daten BADSIG, sonst GOODSIG und VALIDSIG.
cat >"$T/bin/gpg" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/gpg.log"
case " $* " in
*" --import "*)
	cat "${@: -1}" >>"$GNUPGHOME/schluessel"
	exit 0
	;;
*" --verify "*)
	sig=${@: -2:1} daten=${@: -1}
	soll=$(sed -n 's/^daten //p' "$sig")
	sk=$(sed -n 's/^schluessel //p' "$sig")
	hk=$(sed -n 's/^haupt //p' "$sig")
	hk=${hk:-$sk}
	echo "[GNUPG:] NEWSIG"
	if ! grep -qx "haupt $hk" "$GNUPGHOME/schluessel" 2>/dev/null; then
		echo "[GNUPG:] ERRSIG ${sk: -16} 1 10 00 1795198147 9 $sk"
		echo "[GNUPG:] NO_PUBKEY ${sk: -16}"
		exit 2
	fi
	if [[ $(sha256sum <"$daten" | cut -d' ' -f1) != "$soll" ]]; then
		echo "[GNUPG:] BADSIG ${sk: -16} Attrappe"
		exit 1
	fi
	if grep -qx "abgelaufen $hk" "$GNUPGHOME/schluessel"; then
		echo "[GNUPG:] EXPKEYSIG ${sk: -16} Attrappe"
	else
		echo "[GNUPG:] GOODSIG ${sk: -16} Attrappe"
	fi
	echo "[GNUPG:] VALIDSIG $sk 2026-11-20 1795198147 0 4 0 1 10 00 $hk"
	echo "[GNUPG:] TRUST_UNDEFINED 0 pgp"
	exit 0
	;;
esac
exit 2
EOF
# gh: api liefert JSON aus $T/gh (offen.json, issue-N.json, kommentare-N.json) durch das echte jq
# mit dem Ausdruck hinter --jq. issue create und issue comment legen ihren Text in $T/gh ab.
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/gh.log"
((${GH_RC:-0} == 0)) || exit "$GH_RC"
case $1 in
api)
	shift
	url='' expr='.'
	while (($#)); do
		case $1 in
		--jq) expr=$2; shift 2 ;;
		--paginate) shift ;;
		*) url=$1; shift ;;
		esac
	done
	case $url in
	repos/*/issues\?state=open*) f=offen.json ;;
	repos/*/issues/*/comments*) n=${url#repos/*/issues/}; f=kommentare-${n%%/*}.json ;;
	repos/*/issues/*) f=issue-${url##*/}.json ;;
	*) exit 1 ;;
	esac
	jq -r "$expr" "$T/gh/$f"
	;;
issue)
	sub=$2
	shift 2
	nr='' titel='' text=''
	while (($#)); do
		case $1 in
		--title) titel=$2; shift 2 ;;
		--body-file) text=$2; shift 2 ;;
		--repo) shift 2 ;;
		*) nr=$1; shift ;;
		esac
	done
	case $sub in
	create) printf '%s\n' "$titel" >"$T/gh/erstellt-titel"; cp "$text" "$T/gh/erstellt.md" ;;
	comment) cp "$text" "$T/gh/kommentar-$nr.md" ;;
	*) exit 1 ;;
	esac
	;;
*) exit 1 ;;
esac
EOF
chmod +x "$T/bin/curl" "$T/bin/gpg" "$T/bin/gh"
export T

FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
FREMD=0123456789ABCDEF0123456789ABCDEF01234567
SUMME=$(printf 'Attrappe der CLI' | sha256sum | cut -d' ' -f1)
R=https://downloads.claude.ai/claude-code-releases

# setup FASSUNG [FPR]   Kopie des Skripts mit einer chroot-setup.sh, die FASSUNG und FPR festlegt
setup() {
	rm -rf "$T/build"
	mkdir -p "$T/build"
	cp "$S" "$T/build/"
	printf 'CLAUDE_DESKTOP_FPR="%s"\nCLAUDE_CLI_VERSION="%s"\nCLAUDE_CLI_SHA256="%064d"\n' "${2:-$FPR}" "$1" 0 >"$T/build/chroot-setup.sh"
}

# netz STABIL [MANIFEST-FASSUNG [SUMME [SIGNIERT-VON]]]   Antworten des Herstellers: der Zeiger auf
#   die stabile Fassung, ihr Manifest, eine Signatur-Attrappe dafür und die Schlüsseldatei
netz() {
	local m="$T/netz/claude-code-releases/$1"
	rm -rf "$T/netz"
	mkdir -p "$m" "$T/netz/claude-desktop"
	printf '%s' "$1" >"$T/netz/claude-code-releases/stable"
	printf '{"version":"%s","platforms":{"linux-x64":{"binary":"claude","checksum":"%s"}}}\n' "${2:-$1}" "${3:-$SUMME}" >"$m/manifest.json"
	printf 'daten %s\nschluessel %s\n' "$(sha256sum <"$m/manifest.json" | cut -d' ' -f1)" "${4:-$FPR}" >"$m/manifest.json.sig"
	printf 'haupt %s\n' "$FPR" >"$T/netz/claude-desktop/key.asc"
}

# offen JSON   Die offenen Issues, wie die API sie liefert
offen() { printf '%s\n' "$1" >"$T/gh/offen.json"; }
BOT_ISSUE='{"number":7,"title":"Build: neue Fassung der Claude Code CLI","user":{"login":"github-actions[bot]"},"body":"Fassung `2.1.335`"}'

# lauf [ARG...]   Das Skript aus $T/build mit den Attrappen, ohne die Umgebung eines Workflow-Laufs;
#   Status in RC, Ausgaben in $T/out und $T/err
lauf() {
	rm -f "$T/curl.log" "$T/gpg.log" "$T/gh.log" "$T/gh/erstellt-titel" "$T/gh/erstellt.md" "$T/gh"/kommentar-*.md
	env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY PATH="$T/bin:$PATH" GITHUB_REPOSITORY=Celestial0579/leuchtfeuer \
		bash "$T/build/cli-fassung.sh" "$@" >"$T/out" 2>"$T/err"
	RC=$?
}
nichts_geschrieben() { [[ ! -e $T/gh/erstellt.md ]] && ! compgen -G "$T/gh/kommentar-*.md" >/dev/null; }

echo "Attrappen:"
check "curl, gpg und gh sind die Attrappen, nicht die echten" '[[ $(PATH="$T/bin:$PATH" command -v curl) == "$T/bin/curl" && $(PATH="$T/bin:$PATH" command -v gpg) == "$T/bin/gpg" && $(PATH="$T/bin:$PATH" command -v gh) == "$T/bin/gh" ]]'

echo "Fassungen vergleichen:"
FN=$(sed -n '/^neuer() {$/,/^}$/p' "$S")
eval "$FN"
check "2.1.331 ist neuer als 2.1.330" 'neuer 2.1.331 2.1.330'
check "2.1.330 ist nicht neuer als 2.1.330" '! neuer 2.1.330 2.1.330'
check "2.1.325 ist nicht neuer als 2.1.330" '! neuer 2.1.325 2.1.330'
check "Zahlen, keine Zeichen: 2.1.330 ist neuer als 2.1.4, 2.10.0 als 2.9.9, 3.0.0 als 2.99.99" 'neuer 2.1.330 2.1.4 && neuer 2.10.0 2.9.9 && neuer 3.0.0 2.99.99'
check "führende Nullen zählen nicht: 2.1.0330 ist nicht neuer als 2.1.330" '! neuer 2.1.0330 2.1.330'

echo "Stabile Fassung nicht neuer als die im Build:"
setup 2.1.330
netz 2.1.325
offen '[]'
lauf --issue
check "älter: Status 0, aktuell" '((RC == 0)) && grep -qx "aktuell: stabil 2.1.325, im Build 2.1.330" "$T/out"'
check "dann wird nur der Zeiger auf die stabile Fassung gelesen, kein Manifest" '[[ $(wc -l <"$T/curl.log") == 1 ]] && grep -qF "$R/stable" "$T/curl.log"'
check "und nichts an GitHub geschrieben, nicht einmal gelesen" '[[ ! -e $T/gh.log ]] && nichts_geschrieben'
netz 2.1.330
lauf --issue
check "gleich: Status 0, aktuell" '((RC == 0)) && grep -qx "aktuell: stabil 2.1.330, im Build 2.1.330" "$T/out" && [[ ! -e $T/gh.log ]]'
check "jeder Abruf nur über https (--proto =https)" '! grep -vqF -- "--proto =https" "$T/curl.log"'

echo "Neuere stabile Fassung, gültig signiert:"
netz 2.1.340
offen '[]'
lauf --issue
check "Status 0, Fassung und sha256 in der Ausgabe" '((RC == 0)) && grep -qx "neu: stabil 2.1.340 (sha256 $SUMME), im Build 2.1.330" "$T/out"'
check "Manifest, Signatur und Schlüssel werden gelesen" 'u=$(awk "{ print \$NF }" "$T/curl.log"); grep -qxF "$R/2.1.340/manifest.json" <<<"$u" && grep -qxF "$R/2.1.340/manifest.json.sig" <<<"$u" && grep -qxF "https://downloads.claude.ai/claude-desktop/key.asc" <<<"$u"'
check "ohne offenes Issue: ein neues Issue mit festem Titel" '[[ $(cat "$T/gh/erstellt-titel") == "Build: neue Fassung der Claude Code CLI" ]]'
check "es nennt Fassung, sha256, Fassung im Build und den Schlüssel" 'grep -qF "\`2.1.340\`" "$T/gh/erstellt.md" && grep -qF "\`$SUMME\`" "$T/gh/erstellt.md" && grep -qF "\`2.1.330\`" "$T/gh/erstellt.md" && grep -qF "$FPR" "$T/gh/erstellt.md"'
check "und sonst nichts: kein Kommentar" '! compgen -G "$T/gh/kommentar-*.md" >/dev/null'
offen "[$BOT_ISSUE]"
printf '%s\n' '{"number":7,"body":"Fassung `2.1.335`"}' >"$T/gh/issue-7.json"
printf '%s\n' '[]' >"$T/gh/kommentare-7.json"
lauf --issue
check "offenes Issue des Workflows: wird ergänzt, kein zweites" '((RC == 0)) && [[ -s $T/gh/kommentar-7.md && ! -e $T/gh/erstellt.md ]] && grep -qF "\`$SUMME\`" "$T/gh/kommentar-7.md"'
printf '%s\n' "[{\"user\":{\"login\":\"jemand\"},\"body\":\"Neuere stabile Fassung: \`2.1.340\`, sha256 für linux-x64 \`$SUMME\`\"}]" >"$T/gh/kommentare-7.json"
lauf --issue
check "der sha256 nur in einem Kommentar von jemand anderem: zählt nicht, das Issue wird ergänzt" '((RC == 0)) && [[ -s $T/gh/kommentar-7.md ]] && ! grep -q "schon gemeldet" "$T/out"'
printf '%s\n' "[{\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"Neuere stabile Fassung: \`2.1.340\`, sha256 für linux-x64 \`$SUMME\`\"}]" >"$T/gh/kommentare-7.json"
lauf --issue
check "der sha256 steht schon in einem Kommentar des Workflows: nichts geschrieben" '((RC == 0)) && grep -qx "schon gemeldet in #7" "$T/out" && nichts_geschrieben'
offen '[{"number":3,"title":"Build: neue Fassung der Claude Code CLI","user":{"login":"jemand"},"body":""},{"number":4,"title":"etwas anderes","user":{"login":"github-actions[bot]"},"body":""},{"number":5,"title":"Build: neue Fassung der Claude Code CLI","user":{"login":"github-actions[bot]"},"pull_request":{},"body":""}]'
lauf --issue
check "gleicher Titel von jemand anderem, anderer Titel, ein PR: zählen nicht, ein neues Issue" '((RC == 0)) && [[ -s $T/gh/erstellt.md ]] && ! compgen -G "$T/gh/kommentar-*.md" >/dev/null'
offen '[]'
GH_RC=1 lauf --issue
check "GitHub antwortet nicht: Status 1" '((RC == 1)) && nichts_geschrieben'
lauf
check "ohne --issue: Fassung in der Ausgabe, GitHub bleibt unberührt" '((RC == 0)) && grep -qF "neu: stabil 2.1.340" "$T/out" && [[ ! -e $T/gh.log ]]'

echo "Signatur:"
m="$T/netz/claude-code-releases/2.1.340/manifest.json"
netz 2.1.340
sed -i "s/$SUMME/$(printf '%064d' 1)/" "$m"
lauf --issue
check "Manifest nach der Signatur verändert: Status 1, kein sha256 in einer Ausgabe" '((RC == 1)) && ! grep -qE "[0-9a-f]{64}" "$T/out" "$T/err" && [[ ! -e $T/gh.log ]]'
netz 2.1.340 2.1.340 "$SUMME" "$FREMD"
printf 'haupt %s\nhaupt %s\n' "$FPR" "$FREMD" >"$T/netz/claude-desktop/key.asc"
lauf --issue
check "signiert von einem weiteren Schlüssel aus derselben Datei: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340 2.1.340 "$SUMME" "$FREMD"
lauf --issue
check "signiert von einem Schlüssel, den es nicht gibt: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340
printf 'abgelaufen %s\n' "$FPR" >>"$T/netz/claude-desktop/key.asc"
lauf --issue
check "abgelaufener Schlüssel: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340
printf 'haupt %s\n' "$FPR" >>"$T/netz/claude-code-releases/2.1.340/manifest.json.sig"
sed -i "s/^schluessel .*/schluessel $FREMD/" "$T/netz/claude-code-releases/2.1.340/manifest.json.sig"
printf 'haupt %s\n' "$FPR" >"$T/netz/claude-desktop/key.asc"
lauf --issue
check "signiert von einem Unterschlüssel des festgelegten Hauptschlüssels: gilt" '((RC == 0)) && [[ -s $T/gh/erstellt.md ]]'
setup 2.1.330 "$FREMD"
netz 2.1.340
lauf --issue
check "anderer Fingerabdruck in chroot-setup.sh: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
setup 2.1.330
netz 2.1.340
rm "$T/netz/claude-code-releases/2.1.340/manifest.json.sig"
lauf --issue
check "keine Signatur: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'

echo "Werte vom Hersteller:"
netz 2.1.340 2.1.339
lauf --issue
check "Manifest einer anderen Fassung (auch signiert): Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340 2.1.340 "$(printf '%063d' 0)"
lauf --issue
check "sha256 mit 63 Zeichen: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340 2.1.340 "${SUMME^^}"
lauf --issue
check "sha256 in Großbuchstaben: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340
printf '2.1.340\n::warning::eingeschleust' >"$T/netz/claude-code-releases/stable"
lauf --issue
check "Zeiger mit einer zweiten Zeile: Status 1, die Zeile erscheint nirgends" '((RC == 1)) && ! grep -qF "eingeschleust" "$T/out" "$T/err" && [[ ! -e $T/gh.log ]]'
for z in "2.1" "--help" "2.1.340 " "v2.1.340" "1234567.0.0"; do
	printf '%s' "$z" >"$T/netz/claude-code-releases/stable"
	lauf --issue
	check "Zeiger \"$z\": Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
done
rm "$T/netz/claude-code-releases/stable"
lauf --issue
check "kein Zeiger erreichbar: Status 1" '((RC == 1)) && [[ ! -e $T/gh.log ]]'
netz 2.1.340
rm -f "$T/out"
env PATH="$T/bin:$PATH" GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/summary" bash "$T/build/cli-fassung.sh" bla >"$T/out" 2>&1
RC=$?
check "unbekanntes Argument: Status 2" '((RC == 2))'
printf '2.1.340\n::warning::eingeschleust' >"$T/netz/claude-code-releases/stable"
env PATH="$T/bin:$PATH" GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/summary" bash "$T/build/cli-fassung.sh" >"$T/out" 2>&1
check "im Workflow: ein Fehler wird als ::error:: gemeldet, ohne den Wert vom Hersteller" '[[ $(grep -c "^::" "$T/out") == 1 ]] && grep -q "^::error::" "$T/out" && ! grep -qF "eingeschleust" "$T/out"'
netz 2.1.340
env PATH="$T/bin:$PATH" GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/summary" bash "$T/build/cli-fassung.sh" >"$T/out" 2>&1
check "im Workflow: Fassung und sha256 stehen in der Zusammenfassung" 'grep -qF "stabil 2.1.340 (sha256 $SUMME)" "$T/summary"'

echo "Mit build/chroot-setup.sh aus dem Repo:"
FEST=$(sed -n 's/^CLAUDE_CLI_VERSION="\([0-9.]*\)"$/\1/p' build/chroot-setup.sh)
FEST_FPR=$(sed -n 's/^CLAUDE_DESKTOP_FPR="\([0-9A-F]*\)"$/\1/p' build/chroot-setup.sh)
rm -rf "$T/build"
mkdir -p "$T/build"
cp "$S" build/chroot-setup.sh "$T/build/"
netz 0.0.1
lauf --issue
check "die feste Fassung wird gelesen ($FEST)" '((RC == 0)) && grep -qx "aktuell: stabil 0.0.1, im Build $FEST" "$T/out"'
netz 999999.0.0 999999.0.0 "$SUMME" "$FEST_FPR"
printf 'haupt %s\n' "$FEST_FPR" >"$T/netz/claude-desktop/key.asc"
offen '[]'
lauf --issue
check "der festgelegte Fingerabdruck wird gelesen und gilt" '((RC == 0)) && grep -qF "neu: stabil 999999.0.0" "$T/out" && [[ -s $T/gh/erstellt.md ]]'

echo
if ((fails)); then
	echo "unit-cli-fassung: $fails Fehler"
	sed 's/^/    | /' "$T/out" "$T/err" 2>/dev/null | head -n 20
	exit 1
fi
echo "unit-cli-fassung: alles ok"
