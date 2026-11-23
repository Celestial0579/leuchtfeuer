#!/usr/bin/env bash
# Unit-Test (#84): Beenden > Ausschalten und Beenden > Neustart nach einer Claude-Freigabe.
#
# Sagt der Rückstand der letzten Freigabe, am Netzschalter auszuschalten („Sofort ausschalten“,
# „Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten“, auch die Zeile eines
# abgebrochenen Endes), zeigt power_menu diese Zeilen vorher an, rät zum Netzschalter und fährt
# nur nach einer Bestätigung herunter (Vorgabe Nein). Ohne so eine Zeile fragt es nicht.
# Dazu, ohne lf-freigabe: claude_freigabe_ohne_timer beendet eine Freigabe ohne Timer erst, wenn
# status nach dem Warten noch dasselbe sagt, und lf ruft es beim Start auf, im Menü vor dem
# Entsperren von LF-DATA und vor dem Selbsttest. Den Dialog danach teilt sich der Start mit dem
# Hauptmenü, das es bei jedem Durchlauf aufruft (claude_freigabe_ende_text, tests/unit-main-menu.sh,
# #115). Das Ende selbst prüft tests/unit-lf-freigabe.sh.
# Dialoge, tmux, sudo und systemctl sind Attrappen.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/claude.sh
LF_LOG=$T/lf.log
RUECKSTAND_ISO=$CLAUDE_FREIGABE_RUECKSTAND
CLAUDE_FREIGABE_RUECKSTAND=$T/rueckstand

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

eval "$(sed -n '/^power_menu() {$/,/^}$/p' rescue/lf)"
check "power_menu aus rescue/lf geladen" '[[ $(type -t power_menu) == function ]]'

# Attrappen. WAHL ist der Eintrag im Menü Beenden, JA der Exit-Code jeder Rückfrage. Echte
# Zeilenumbrüche im Text schreibt ui_yesno als \n mit, wie die Umbrüche der Vorlage.
ui_menu() { echo "$WAHL"; }
ui_yesno() {
	printf '%s|%s|%s\n' "$1" "${2//$'\n'/\\n}" "${3:-}" >>"$T/fragen"
	return "$JA"
}
tmux() { return 1; }
persist_close() { echo persist_close >>"$T/schritte"; }
sync() { echo sync >>"$T/schritte"; }
sudo() { echo "sudo $*" >>"$T/schritte"; }
log() { echo "$*" >>"$T/log"; }

# beenden WAHL [JA]   Beenden > WAHL, jede Rückfrage mit JA (Vorgabe 1: Nein)
beenden() {
	rm -f "$T/fragen" "$T/schritte" "$T/log"
	WAHL=$1 JA=${2:-1}
	power_menu
	RC=$?
}
# frage   Die Rückfrage "Netzschalter", ohne Titel und Optionen
frage() { sed -n 's/^Netzschalter|\(.*\)|--defaultno$/\1/p' "$T/fragen" 2>/dev/null; }
# aus WAS   Lief der Befehl für WAS (reboot oder poweroff), nach persist_close und sync?
aus() { [[ $(tr '\n' '|' <"$T/schritte" 2>/dev/null) == "persist_close|sync|sudo env SYSTEMCTL_SKIP_AUTO_KEXEC=1 SYSTEMCTL_SKIP_AUTO_SOFT_REBOOT=1 systemctl $1|" ]]; }

# Zeilen wie lf-freigabe sie in den Rückstand schreibt (off, switch_hint)
END_OPEN=$(sed -n 's/^END_OPEN="\(.*\)"$/\1/p' rescue/bin/lf-freigabe)
OFFEN="$END_OPEN, Ende seit 12:34. Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf"
SOFORT="Sofort ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (läuft weiter, beim Beenden liefe Code aus der Freigabe: boese.timer)"
NETZ="Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten (ein kurzer Druck fährt geordnet herunter), nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: Manager-Umgebung)"
MENUE="Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten): Weg zu root aus der Freigabe (sudo-Datei)"

echo "Die Zeilen und der Ort stimmen mit lf-freigabe überein:"
check "derselbe Rückstand wie RESIDUE in lf-freigabe" '[[ $RUECKSTAND_ISO == "$(sed -n "s/^RESIDUE=//p" rescue/bin/lf-freigabe)" ]]'
check "jeder Hinweis von lf-freigabe aufs Ausschalten am Netzschalter enthält, wonach das Menü sucht" '[[ $(grep -c "echo \".*Netzschalter gedrückt halten" rescue/bin/lf-freigabe) == 3 ]] && grep -qF "echo \"Sofort ausschalten: Netzschalter gedrückt halten" rescue/bin/lf-freigabe && grep -qF "echo \"Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten" rescue/bin/lf-freigabe && grep -qF "echo \"\$END_OPEN, Ende seit \$(date +%H:%M). Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten" rescue/bin/lf-freigabe && grep -qF "grep -aF \"Netzschalter gedrückt halten\"" rescue/lib/claude.sh'

echo "Ohne Zeile zum Netzschalter:"
beenden reboot
check "kein Rückstand: Neustart ohne Rückfrage" '((RC == 0)) && [[ ! -e $T/fragen ]] && aus reboot'
printf '%s\n' "$MENUE" "root-Prozesse bei Claude: 123" >"$T/rueckstand"
beenden poweroff
check "Rückstand ohne Netzschalter (Beenden > Ausschalten genügt): ausschalten ohne Rückfrage" '((RC == 0)) && [[ ! -e $T/fragen ]] && aus poweroff'

echo "Mit Zeile zum Netzschalter:"
printf '%s\n' "$NETZ" "Manager-Umgebung: LD_PRELOAD" >"$T/rueckstand"
beenden poweroff
check "Ausschalten: die Rückfrage nennt die Zeile und rät zum Netzschalter, Vorgabe Nein" '[[ $(frage) == "Im Rückstand der letzten Claude-Freigabe steht:\n\n$NETZ\n\nHalte stattdessen den Netzschalter gedrückt, bis das Gerät aus ist. Beim Ausschalten über das Menü beendet systemd jeden Dienst, und Code aus der Freigabe liefe dabei.\n\nTrotzdem Ausschalten?" ]]'
check "Nein: nichts heruntergefahren, LF-DATA nicht geschlossen, im Protokoll" '((RC == 1)) && [[ ! -e $T/schritte ]] && grep -qxF "Beenden: Ausschalten abgebrochen, der Rückstand sagt, am Netzschalter auszuschalten" "$T/log"'
beenden poweroff 0
check "Ja: ausgeschaltet wie bisher, im Protokoll" '((RC == 0)) && aus poweroff && grep -qxF "Beenden: Ausschalten trotz Hinweis aufs Ausschalten am Netzschalter" "$T/log"'
printf '%s\n' "$MENUE" "$SOFORT" >"$T/rueckstand"
beenden reboot
check "Sofort ausschalten, auch in einer späteren Zeile: Neustart erst nach Rückfrage" '((RC == 1)) && [[ ! -e $T/schritte ]] && [[ $(frage) == *"steht:\n\n$SOFORT\n\nHalte"*"Beim Neustart über das Menü"*"Trotzdem Neustart?" ]]'
printf '%s\n' "$OFFEN" "$MENUE" >"$T/rueckstand"
beenden reboot
check "ein abgebrochenes Ende: Rückfrage mit seiner Zeile" '((RC == 1)) && [[ $(frage) == *"steht:\n\n$OFFEN\n\nHalte"* ]]'
beenden shell
check "Zur Shell: keine Rückfrage" '((RC == 0)) && [[ ! -e $T/fragen && ! -e $T/schritte ]]'
printf 'Sofort ausschalten: Netzschalter gedrückt halten (beim Beenden liefe Code aus der Freigabe: \033]0;x\007neu.timer)\n' >"$T/rueckstand"
beenden reboot
check "Steuerzeichen aus dem Rückstand stehen gefiltert in der Rückfrage" '[[ $(frage) == *"Freigabe: ?]0;x?neu.timer)\n\nHalte"* ]] && ! grep -q $'"'"'\033'"'"' "$T/fragen"'
for i in 1 2 3 4 5 6 7; do echo "Sofort ausschalten: Netzschalter gedrückt halten ($i)"; done >"$T/rueckstand"
beenden reboot
check "höchstens 5 Zeilen" '[[ $(frage) == *"(5)\n\nHalte"* && $(frage) != *"(6)"* ]]'
rm -f "$T/rueckstand"

echo "Freigabe ohne Timer beim Start (claude_freigabe_ohne_timer):"
# lf-freigabe status gibt der Reihe nach die Zeilen aus $T/status aus.
lf-freigabe() {
	echo "lf-freigabe $*" >>"$T/aufrufe"
	if [[ $1 == status ]]; then
		local n
		n=$(($(cat "$T/n" 2>/dev/null || echo 0) + 1))
		echo "$n" >"$T/n"
		sed -n "${n}p" "$T/status"
	fi
}
sudo() { echo "sudo $*" >>"$T/aufrufe"; }
run() { "$@"; }
sleep() { echo "sleep $*" >>"$T/aufrufe"; }
ui_info() { echo "ui_info $1" >>"$T/aufrufe"; }
start() {
	rm -f "$T/aufrufe" "$T/n"
	printf '%s\n' "$@" >"$T/status"
	OUT=$(claude_freigabe_ohne_timer ui)
	RC=$?
}
start "an, ohne Ablauf" "an, ohne Ablauf" "aus, Neustart empfohlen (letzte Freigabe bis 12:40)"
check "Regel ohne Timer, nach 5 s noch so: lf-freigabe ablauf, dann der neue Zustand" '((RC == 0)) && [[ $OUT == "aus, Neustart empfohlen (letzte Freigabe bis 12:40)" && $(grep -c "^lf-freigabe status" "$T/aufrufe") == 3 ]] && grep -qx "sudo lf-freigabe ablauf" "$T/aufrufe" && grep -qx "sleep 5" "$T/aufrufe" && grep -qx "ui_info Claude-Freigabe" "$T/aufrufe"'
start "an bis 12:40"
check "Freigabe mit Timer: nichts, kein Warten" '((RC == 1)) && [[ -z $OUT ]] && ! grep -q "^sudo\|^sleep\|^ui_info" "$T/aufrufe"'
start "aus"
check "keine Freigabe: nichts" '((RC == 1)) && ! grep -q "^sudo\|^sleep" "$T/aufrufe"'
start "an, ohne Ablauf" "an bis 12:40"
check "nach dem Warten mit Timer (Freischalten war noch nicht fertig): nichts" '((RC == 1)) && grep -qx "sleep 5" "$T/aufrufe" && ! grep -q "^sudo" "$T/aufrufe"'
LF_FREIGABE_WARTE=1 start "an, ohne Ablauf" "an, ohne Ablauf" "aus"
check "die Wartezeit kommt aus LF_FREIGABE_WARTE" '((RC == 0)) && grep -qx "sleep 1" "$T/aufrufe"'

echo "Aufruf beim Start von lf:"
l_end=$(grep -n '^if freigabe_ende=$(claude_freigabe_ohne_timer ui); then$' rescue/lf | cut -d: -f1)
l_persist=$(grep -n '^persist_startup$' rescue/lf | cut -d: -f1)
l_banner=$(grep -n '^banner$' rescue/lf | cut -d: -f1)
check "im Menü: nach dem Start der Oberfläche, vor dem Entsperren von LF-DATA" '[[ -n $l_end && -n $l_persist && -n $l_banner ]] && ((l_banner < l_end && l_end < l_persist))'
check "vor dem Selbsttest, ohne Dialog" 'sed -n "/^--selftest)$/,/^	;;$/p" rescue/lf | grep -A3 "^	if freigabe_ende=\$(claude_freigabe_ohne_timer); then$" | grep -q "^	selftest$"'
start_dialog='	ui_msg "Claude-Freigabe" "$(claude_freigabe_ende_text "Beim Start galt noch" "$freigabe_ende")"'
check "danach ein Dialog mit dem neuen Zustand, Text wie bisher (claude_freigabe_ende_text, #115)" '[[ -n $l_end && $(sed -n "$((l_end + 1))p" rescue/lf) == "$start_dialog" && $(claude_freigabe_ende_text "Beim Start galt noch" "aus, Neustart empfohlen (letzte Freigabe bis 12:40)") == "Beim Start galt noch eine Claude-Freigabe ohne Timer. Sie ist jetzt beendet wie nach Ablauf der Zeit, mit Prüfung des Rückstands.\n\nZustand: aus, Neustart empfohlen (letzte Freigabe bis 12:40)\n\nSicher endet root-Zugriff nur mit einem Neustart." && $(claude_freigabe_ende_text "Beim Start galt noch" "") == *"\n\nZustand: unbekannt\n\n"* ]]'

echo
if ((fails)); then
	echo "unit-beenden: $fails Fehler"
	exit 1
fi
echo "unit-beenden: alles ok"
