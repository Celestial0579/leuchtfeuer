#!/usr/bin/env bash
# Unit-Test (#85): ptrace ist ab dem Start gesperrt (kernel.yama.ptrace_scope=3).
#
# Geprüft werden nur der Wert im Image und die Zeile des Selbsttests:
#   - build/overlay/etc/sysctl.d/90-lf-ptrace.conf setzt kernel.yama.ptrace_scope = 3 und sonst
#     nichts, keine andere Datei im Overlay setzt den Wert,
#   - ihr Name folgt auf 10-ptrace.conf von Ubuntu (Wert 1): systemd-sysctl schreibt je Schlüssel
#     nur den letzten Wert in der Reihenfolge der Namen, also 3,
#   - der Selbsttest ruft selftest_ptrace auf. selftest_ptrace meldet 3 als gesperrt, jeden anderen
#     Wert und eine fehlende Datei als Fehler (hier mit einer Datei statt /proc).
# Echt prüft es selftest_ptrace im Boot-Test.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
F=build/overlay/etc/sysctl.d/90-lf-ptrace.conf

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Image:"
check "die Datei liegt im Overlay unter /etc/sysctl.d" '[[ -f $F ]]'
check "sie setzt nur kernel.yama.ptrace_scope = 3" '[[ $(grep -vE "^[[:space:]]*(#|$)" "$F") == "kernel.yama.ptrace_scope = 3" ]]'
check "keine andere Datei im Overlay setzt den Wert" '[[ $(grep -rlE "^[[:space:]]*kernel[./]yama[./]ptrace_scope" build/overlay) == "$F" ]]'
check "ihr Name folgt auf 10-ptrace.conf von Ubuntu: von beiden gilt ihre 3" '[[ $(printf "%s\n" "${F##*/}" 10-ptrace.conf | LC_ALL=C sort | tail -n 1) == "${F##*/}" ]]'
check "der Selbsttest ruft selftest_ptrace auf" 'grep -qx "	selftest_ptrace || ok=0" rescue/lf'

FN=$(sed -n '/^selftest_ptrace() {$/,/^}$/p' rescue/lf)
if [[ -z $FN ]]; then
	echo "  FAIL selftest_ptrace fehlt in rescue/lf"
	exit 1
fi
eval "$FN"

# zeile DATEI   Ausgabe und Exit-Code von selftest_ptrace, wenn DATEI für /proc/sys/kernel/yama/ptrace_scope steht
zeile() {
	OUT=$(LF_PTRACE_SCOPE=$1 selftest_ptrace)
	RC=$?
}

echo "selftest_ptrace mit einer Datei statt /proc:"
echo 3 >"$T/scope"
zeile "$T/scope"
check "3: gesperrt" '[[ $RC == 0 && $OUT == "LF-SELFTEST: ptrace: gesperrt (kernel.yama.ptrace_scope=3)" ]]'
for v in 0 1 2; do
	echo "$v" >"$T/scope"
	zeile "$T/scope"
	check "$v: FAIL mit dem Wert" '[[ $RC == 1 && $OUT == "LF-SELFTEST: ptrace: kernel.yama.ptrace_scope ist $v statt 3" ]]'
done
zeile "$T/fehlt"
check "ohne die Datei (Kernel ohne Yama): FAIL" '[[ $RC == 1 && $OUT == "LF-SELFTEST: ptrace: kernel.yama.ptrace_scope ist nicht lesbar statt 3" ]]'
: >"$T/scope"
zeile "$T/scope"
check "leere Datei: FAIL" '[[ $RC == 1 && $OUT == *"ist nicht lesbar statt 3" ]]'

echo
if ((fails)); then
	echo "unit-ptrace: $fails Fehler"
	exit 1
fi
echo "unit-ptrace: alles ok"
