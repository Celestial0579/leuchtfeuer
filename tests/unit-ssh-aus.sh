#!/usr/bin/env bash
# Unit-Test (GHSA-45m7-28wq-mxq8): Werkzeuge > SSH > Ausschalten. Danach gilt das Einmal-Passwort
# nicht mehr, sshd nimmt keine Verbindung mehr an, und jede SSH-Sitzung endet samt allem, was in ihr
# läuft, auch eine Verbindung, die noch bei der Anmeldung ist. Bleibt etwas übrig, sagt das der
# Dialog.
#
# Hier läuft kein sshd: sudo, systemctl, loginctl und die Dialoge sind Attrappen. Die Sitzungen von
# logind stehen in $T/sessions (ID und PAM-Dienst), die Prozesse von sshd in $T/procs.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/tools.sh
LF_LOG="$T/log"
ME=$(id -un)
RE='sshd|sshd-session|sshd-auth'

YES=0         # Antwort auf „Ausschalten?“
USERMOD_RC=0  # 1: usermod scheitert
STUCK=""      # Sitzungen, die kill-session und terminate-session überstehen
PROCS_STUCK=0 # 1: Prozesse überstehen pkill

systemctl() { [[ $1 == is-active ]]; } # ssh läuft
ui_yesno() { printf '%s\n' "$2" >>"$T/yesno"; return "$YES"; }
ui_msg() { printf '%s\n%s\n' "$1" "$2" >>"$T/dialog"; }
sleep() { :; }
loginctl() {
	case $1 in
	list-sessions) awk '{printf "%7s 1000 rescue - 100 user - no -\n", $1}' "$T/sessions" ;;
	show-session) [[ $3 == -p && $4 == Service && $5 == --value ]] && awk -v id="$2" '$1 == id {print $2}' "$T/sessions" ;;
	esac
}
end_session() {
	[[ " $STUCK " == *" $1 "* ]] && return 0
	awk -v id="$1" '$1 != id' "$T/sessions" >"$T/sessions.neu"
	mv "$T/sessions.neu" "$T/sessions"
}
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case "$*" in
	"usermod -p ! "*) return "$USERMOD_RC" ;;
	"pkill -KILL -x $RE") ((PROCS_STUCK)) || : >"$T/procs" ;;
	"pgrep -l -x $RE") [[ -s $T/procs ]] || return 1; cat "$T/procs" ;;
	"loginctl kill-session --signal=SIGKILL "* | "loginctl terminate-session "*) end_session "${@: -1}" ;;
	esac
	return 0
}

# start SITZUNG… -- PROZESS…   Neuer Fall: Sitzungen als "ID DIENST", Prozesse als "PID NAME".
start() {
	rm -f "$T/sudo" "$T/dialog" "$T/yesno" "$LF_LOG"
	: >"$T/sessions"
	: >"$T/procs"
	while (($#)) && [[ $1 != -- ]]; do echo "$1" >>"$T/sessions"; shift; done
	(($#)) && shift
	while (($#)); do echo "$1" >>"$T/procs"; shift; done
}
at() { grep -n -x -F -- "$1" "$T/sudo" | head -n1 | cut -d: -f1; }
shown() { tr '\n' ' ' <"$T/dialog" 2>/dev/null; }

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Nein:"
YES=1
start "1 login" "4 sshd" -- "900 sshd"
tools_ssh
check "die Frage sagt, dass offene Sitzungen enden" 'grep -qF "Das beendet auch alle offenen SSH-Sitzungen." "$T/yesno"'
check "nichts geändert" '[[ ! -e $T/sudo ]] && grep -qx "4 sshd" "$T/sessions"'

echo "Ja, zwei SSH-Sitzungen und eine Verbindung bei der Anmeldung:"
YES=0
start "1 login" "4 sshd" "7 sshd" -- "812 sshd-auth" "813 sshd-session"
tools_ssh
pw=$(at "usermod -p ! $ME")
stop=$(at "systemctl stop ssh.socket ssh.service")
pk=$(at "pkill -KILL -x $RE")
k4=$(at "loginctl kill-session --signal=SIGKILL 4")
k7=$(at "loginctl kill-session --signal=SIGKILL 7")
check "erst wird das Einmal-Passwort gesperrt, dann sshd und der Socket gestoppt" '[[ -n $pw && -n $stop ]] && ((pw < stop))'
check "dann enden alle Prozesse von sshd, auch die bei der Anmeldung" '[[ -n $pk ]] && ((stop < pk))'
check "dann endet in beiden SSH-Sitzungen alles mit SIGKILL" '[[ -n $k4 && -n $k7 ]] && ((pk < k4 && pk < k7))'
check "beide Sitzungen werden abgemeldet" '[[ -n $(at "loginctl terminate-session 4") && -n $(at "loginctl terminate-session 7") ]]'
check "die Sitzung auf tty1 bleibt" '! grep -qE "^loginctl [a-z-]+ (--signal=SIGKILL )?1$" "$T/sudo" && grep -qx "1 login" "$T/sessions"'
check "danach ist keine SSH-Sitzung und kein sshd mehr da" '[[ $(cat "$T/sessions") == "1 login" && ! -s $T/procs ]]'
check "der Dialog: aus, Passwort ungültig, 2 Sitzungen beendet, Neustart empfohlen" '[[ $(shown) == *"SSH ist aus. Das Einmal-Passwort gilt nicht mehr."*"2 offene SSH-Sitzungen wurden beendet."*"hatte root"*"Neustart (Beenden > Neustart)"* && $(shown) != *"Nicht alles"* ]]'
check "das Protokoll nennt die Zahl" 'grep -qF "SSH ausgeschaltet, beendete SSH-Sitzungen: 2" "$LF_LOG"'

echo "Ja, niemand angemeldet:"
start "1 login" --
tools_ssh
check "Passwort gesperrt, sshd gestoppt" '[[ -n $(at "usermod -p ! $ME") && -n $(at "systemctl stop ssh.socket ssh.service") ]]'
check "keine Sitzung beendet" '! grep -q "^loginctl" "$T/sudo"'
check "der Dialog sagt nur, dass SSH aus ist" '[[ $(shown) == "SSH SSH ist aus. Das Einmal-Passwort gilt nicht mehr. " ]]'

echo "Eine Sitzung endet, eine bleibt:"
STUCK=4
start "1 login" "4 sshd" "5 sshd" --
tools_ssh
check "der Assistent wartet auf logind, bevor er etwas meldet" '(($(grep -c "^pgrep" "$T/sudo") == 10))'
check "der Dialog nennt die offene Sitzung und rät zum Neustart" '[[ $(shown) == *"2 offene SSH-Sitzungen wurden beendet."*"Nicht alles ist beendet:\n   Noch offene SSH-Sitzungen: 4"*"Neustart (Beenden > Neustart)"* ]]'
check "das Protokoll auch" 'grep -qF "Noch offene SSH-Sitzungen: 4" "$LF_LOG"'
STUCK=""

echo "Ein Prozess von sshd bleibt:"
PROCS_STUCK=1
start "1 login" "5 sshd" -- "812 sshd-auth"
tools_ssh
check "der Dialog nennt Sitzung und Prozess" '[[ $(shown) == *"1 offene SSH-Sitzung wurde beendet."*"Noch laufende Prozesse von sshd: 812 sshd-auth"*"Neustart"* ]]'
PROCS_STUCK=0

echo "Das Passwort lässt sich nicht sperren:"
USERMOD_RC=1
start "1 login" --
tools_ssh
check "der Dialog sagt das, statt es für ungültig zu erklären" '[[ $(shown) == *"Das Einmal-Passwort ließ sich nicht sperren."* && $(shown) != *"gilt nicht mehr"* ]]'
check "sshd wird trotzdem gestoppt" '[[ -n $(at "systemctl stop ssh.socket ssh.service") ]]'
USERMOD_RC=0

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
