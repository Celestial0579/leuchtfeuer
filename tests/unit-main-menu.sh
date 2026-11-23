#!/usr/bin/env bash
# Unit-Test: Das Hauptmenü erscheint und empfiehlt bei einer auffälligen Disk die Datenrettung.
#
# Das Hauptmenü rief disks_overview in $( … ) auf. DISKS_ANY_BAD wurde damit nur in der
# Subshell gesetzt, und lf brach unter set -u mit "DISKS_ANY_BAD: unbound variable" ab,
# bevor das Menü erschien. Der Test lädt main_menu aus rescue/lf, ersetzt Dialoge, SMART und
# lsblk durch Attrappen und prüft:
#   - das Menü erscheint, auch unter set -u, ohne Fehlermeldung,
#   - mit einer auffälligen Disk ist "rescue" vorausgewählt und die Empfehlung nennt sie,
#   - mit unauffälligen Disks ist "clone" vorausgewählt,
#   - die Übersicht mit dem Zustand jeder Disk steht im Menütext,
#   - läuft SSH, steht der Hinweis auf offene Sitzungen über der Übersicht, und das Menü übernimmt
#     die Anmeldungen ins Protokoll (#99),
#   - gilt die Regel einer Claude-Freigabe ohne Timer erst bei einem späteren Durchlauf des Menüs,
#     endet die Freigabe dort wie beim Start von lf, danach sagt ein Dialog es mit dem neuen
#     Zustand; mit Timer bleibt sie, und ohne Freigabe wartet das Menü nicht. Die Anleitung sagt
#     es auch (#115),
#   - disks_overview gibt weiter dieselbe Tabelle aus (Claude-Kontext, Tests).
# Ohne Disks, ohne Dialoge und ohne lf-freigabe.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LF_RUN="$T/run"
LF_LOG="$T/lf.log"
mkdir -p "$LF_RUN"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# Der Merker im Kernel, die Einhängungen und die Regel einer Freigabe für claude.sh (GHSA-874q-q3v7-m56v):
# Merker 2, self/stat das echte des Lesers, keine Einhängung auf den Pfaden des Merkers, die Regel da.
LF_FREIGABE_MERKER=$T/merker LF_FREIGABE_PROC=$T/fproc LF_FREIGABE_REGEL=$T/regel
echo 2 >"$T/merker"
: >"$T/regel"
mkdir -p "$T/fproc/self" && ln -s /proc/self/stat "$T/fproc/self/stat"
echo "25 21 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:12 - proc proc rw" >"$T/fproc/self/mountinfo"
# shellcheck disable=SC1091
. rescue/lib/claude.sh
LF_RUN="$T/run"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# main_menu aus rescue/lf holen, ohne den Assistenten zu starten.
eval "$(sed -n '/^main_menu() {$/,/^}$/p' rescue/lf)"
check "main_menu aus rescue/lf geladen" '[[ $(type -t main_menu) == function ]]'

# Attrappen: zwei Disks, der SMART-Befund steht in $T/smart-<Gerät>.
disks_json() {
	printf '%s\n' '{"path":"/dev/sda","model":"Alte HDD","serial":"S1","size":500107862016,"tran":"sata"}' \
		'{"path":"/dev/sdb","model":"Neue SSD","serial":"S2","size":1000204886016,"tran":"usb"}'
}
disk_smart() { cat "$T/smart-$(basename "$1")"; }
ui_info() { :; }
# Schreibt die Argumente des Menüs mit, dann wie "Abbrechen": main_menu geht zu power_menu.
ui_menu() {
	printf '%s\n' "$@" >"$T/menu"
	return 1
}
power_menu() { return 0; }
# Der Hinweis über dem Menü: Jeder Aufruf schreibt den Zustand mit, den er bekommt.
claude_freigabe_hinweis() { printf '%s\n' "${1-ohne}" >>"$T/hinweise"; }
# SSH (#99): Jeder Aufruf der Übernahme ins Protokoll steht in $T/ssh-sync, der Hinweis in $T/ssh-hinweis.
tools_ssh_log_sync() { echo sync >>"$T/ssh-sync"; }
tools_ssh_hinweis() { cat "$T/ssh-hinweis" 2>/dev/null; }
tmux() { return 1; }
log() { :; }
# lf-freigabe status gibt der Reihe nach die Zeilen aus $T/status aus (ohne die Datei nichts: keine
# Freigabe), jeder Aufruf steht in $T/aufrufe.
lf-freigabe() {
	echo "lf-freigabe $*" >>"$T/aufrufe"
	if [[ $1 == status ]]; then
		local n
		n=$(($(cat "$T/n" 2>/dev/null || echo 0) + 1))
		echo "$n" >"$T/n"
		sed -n "${n}p" "$T/status" 2>/dev/null
	fi
}

# Wert nach --default-item
vorauswahl() { sed -n '/^--default-item$/{n;p;q}' "$T/menu"; }

menue_zeigen() {
	rm -f "$T/menu"
	(main_menu) >"$T/out" 2>&1
	rc=$?
}

echo "Eine Disk auffällig:"
echo 'WARN|3 umgelagerte Sektoren' >"$T/smart-sda"
echo 'OK|' >"$T/smart-sdb"
menue_zeigen
check "kein Abbruch, keine Fehlermeldung" '((rc == 0)) && [[ ! -s $T/out ]]'
check "das Menü erscheint" '[[ -s $T/menu ]]'
check "Datenrettung ist vorausgewählt" '[[ $(vorauswahl) == rescue ]]'
check "die Empfehlung nennt die auffällige Disk" 'grep -qF "Empfehlung: Datenrettung (auffällige Disk gefunden)" "$T/menu"'
check "die Übersicht zeigt den Zustand jeder Disk" 'grep -qE "^sda +\[WARN\] +Alte HDD" "$T/menu" && grep -qE "^sdb +\[OK\] +Neue SSD" "$T/menu" && grep -qF "3 umgelagerte Sektoren" "$T/menu"'

echo "Eine Disk defekt:"
echo 'DEFEKT|SMART-Gesamtstatus FAILED' >"$T/smart-sdb"
echo 'OK|' >"$T/smart-sda"
menue_zeigen
check "Datenrettung ist vorausgewählt" '((rc == 0)) && [[ $(vorauswahl) == rescue ]]'

echo "Alle Disks unauffällig:"
echo 'OK|' >"$T/smart-sdb"
menue_zeigen
check "kein Abbruch, keine Fehlermeldung" '((rc == 0)) && [[ ! -s $T/out ]]'
check "Klonen ist vorausgewählt" '[[ $(vorauswahl) == clone ]]'
check "die Empfehlung sagt: alle unauffällig" 'grep -qF "Empfehlung: alle Disks unauffällig" "$T/menu"'
check "SSH aus: kein Hinweis, die Übersicht steht vorn" '! grep -qF "SSH ist" "$T/menu" && sed -n 2p "$T/menu" | grep -q "^GERÄT"'

echo "SSH an:"
echo 'SSH ist an: 1 offene Sitzung (192.0.2.5).' >"$T/ssh-hinweis"
rm -f "$T/ssh-sync"
menue_zeigen
check "kein Abbruch, keine Fehlermeldung" '((rc == 0)) && [[ ! -s $T/out ]]'
check "der Hinweis steht über der Übersicht" 'sed -n 2p "$T/menu" | grep -qF "SSH ist an: 1 offene Sitzung (192.0.2.5).\n\nGERÄT"'
check "das Menü übernimmt die Anmeldungen ins Protokoll" '[[ $(wc -l <"$T/ssh-sync") == 1 ]]'
rm -f "$T/ssh-hinweis"

echo "Freigabe ohne Timer bei einem späteren Durchlauf (#115):"
# Jeder Aufruf der Attrappen steht der Reihe nach in $T/aufrufe. Das Menü wählt bei jedem
# Durchlauf "Disk-Liste aktualisieren", beim letzten (DURCHLAEUFE) "Abbrechen".
ui_info() { echo "ui_info $1" >>"$T/aufrufe"; }
ui_msg() { printf 'ui_msg %s\n%s\n' "$1" "$2" >>"$T/aufrufe"; }
sudo() { echo "sudo $*" >>"$T/aufrufe"; }
run() { "$@"; }
sleep() { echo "sleep $*" >>"$T/aufrufe"; }
ui_menu() {
	local n
	n=$(($(cat "$T/menu-n" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$T/menu-n"
	echo "ui_menu $n" >>"$T/aufrufe"
	((n < DURCHLAEUFE)) || return 1
	echo refresh
}
# durchlaeufe N STATUS…   main_menu mit N Durchläufen, lf-freigabe status sagt der Reihe nach STATUS….
durchlaeufe() {
	DURCHLAEUFE=$1
	shift
	rm -f "$T/aufrufe" "$T/n" "$T/menu-n" "$T/hinweise"
	printf '%s\n' "$@" >"$T/status"
	(main_menu) >"$T/out" 2>&1
	rc=$?
}
# zeile TEXT   Die erste Zeile in $T/aufrufe, die genau TEXT ist.
zeile() { grep -n -m1 -x -F -- "$1" "$T/aufrufe" | cut -d: -f1; }
NN="Neustart nötig (letzte Freigabe bis 12:40): Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (nach der Freigabe kann Code aus ihr in jedem Programm als root mitlaufen)"
# Je Durchlauf fragt das Menü den Zustand einmal (claude_freigabe_zustand), dazu claude_freigabe_ohne_timer.
durchlaeufe 2 "aus" "aus" "an, ohne Ablauf" "an, ohne Ablauf" "$NN" "$NN"
check "die Regel ohne Timer gilt erst beim zweiten Durchlauf: Nach 5 s noch so, endet die Freigabe wie beim Ablauf, ein Dialog sagt es mit dem neuen Zustand" '((rc == 0)) && [[ ! -s $T/out && $(grep -cx "lf-freigabe status" "$T/aufrufe") == 6 && $(grep -cx "sudo lf-freigabe ablauf" "$T/aufrufe") == 1 ]] && grep -qx "sleep 5" "$T/aufrufe" && grep -qx "ui_info Claude-Freigabe" "$T/aufrufe" && grep -qxF "Bis eben galt noch eine Claude-Freigabe ohne Timer. Sie ist jetzt beendet wie nach Ablauf der Zeit, mit Prüfung des Rückstands.\n\nZustand: $NN\n\nClaude bleibt bis zum Neustart gesperrt. Sicher endet root-Zugriff nur mit dem Ausschalten am Netzschalter." "$T/aufrufe"'
check "…nach dem Menü des ersten Durchlaufs, vor dem des zweiten" 'a=$(zeile "ui_menu 1") && b=$(zeile "sudo lf-freigabe ablauf") && c=$(zeile "ui_msg Claude-Freigabe") && d=$(zeile "ui_menu 2") && ((a < b && b < c && c < d))'
durchlaeufe 2 "an bis 12:40" "an bis 12:40" "an bis 12:40" "an bis 12:40"
check "mit Timer: Die Freigabe bleibt, das Menü wartet nicht" '((rc == 0)) && [[ $(grep -cx "lf-freigabe status" "$T/aufrufe") == 4 ]] && grep -qx "ui_menu 2" "$T/aufrufe" && ! grep -qE "^(sudo|sleep|ui_msg)" "$T/aufrufe"'
durchlaeufe 2 "aus" "aus" "aus" "aus"
check "ohne Freigabe: Das Menü wartet nicht" '((rc == 0)) && [[ $(grep -cx "lf-freigabe status" "$T/aufrufe") == 4 ]] && grep -qx "ui_menu 2" "$T/aufrufe" && ! grep -qE "^(sudo|sleep|ui_msg)" "$T/aufrufe"'
# Das Menü merkt sich eine Freigabe über die Durchläufe (GHSA-874q-q3v7-m56v): Der Hinweis bekommt den
# Zustand aus claude_freigabe_zustand im Menü selbst.
KM="Neustart nötig: Das Menü kennt eine Freigabe seit dem Start, lf-freigabe meldet trotzdem: aus"
durchlaeufe 2 "aus" "an bis 12:40" "aus" "aus"
check "sieht das Menü an bis, sagt lf-freigabe beim nächsten Durchlauf aus: Neustart nötig im Hinweis (GHSA-874q-q3v7-m56v)" '((rc == 0)) && [[ $(sed -n 1p "$T/hinweise") == "an bis 12:40" && $(sed -n 2p "$T/hinweise") == "$KM" ]]'
durchlaeufe 2 "aus" "aus" "an, ohne Ablauf" "an, ohne Ablauf" "aus" "aus"
check "endet eine Freigabe ohne Timer im Menü und sagt lf-freigabe danach aus: der Dialog und der Hinweis sagen Neustart nötig" '((rc == 0)) && [[ $(sed -n 2p "$T/hinweise") == "$KM" ]] && grep -qF "Zustand: $KM" "$T/aufrufe"'
check "die Anleitung sagt es: beim Start und bei jeder Rückkehr ins Hauptmenü" 'grep -qF "Gilt beim Start des Assistenten oder bei jeder Rückkehr ins Hauptmenü noch eine Freigabe, aber kein Timer beendet sie, beendet er sie gleich, wie nach Ablauf der Zeit." docs/anleitung.md'

echo "Ausgabe für andere Aufrufer:"
echo 'WARN|3 umgelagerte Sektoren' >"$T/smart-sda"
text=$(disks_overview)
check "disks_overview gibt Kopf, zwei Disks und den Grund aus" '[[ $(wc -l <<<"$text") == 4 && $(head -n 1 <<<"$text") == "GERÄT"* ]]'
disks_overview_scan
check "disks_overview_scan setzt beide Werte im Aufrufer" '((DISKS_ANY_BAD == 1)) && [[ $DISKS_OVERVIEW == "$text" ]]'

if ((fails)); then
	echo "unit-main-menu: $fails Fehler"
	exit 1
fi
echo "unit-main-menu: alles ok"
