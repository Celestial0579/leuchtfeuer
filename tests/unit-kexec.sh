#!/usr/bin/env bash
# Unit-Test (GHSA-874q-q3v7-m56v): kexec ist ab dem Start gesperrt (kernel.kexec_load_disabled=1).
#
# Geprüft werden nur der Wert im Image und die Zeile des Selbsttests:
#   - build/overlay/etc/sysctl.d/90-lf-kexec.conf setzt kernel.kexec_load_disabled = 1 und sonst
#     nichts, keine andere Datei im Overlay setzt den Wert,
#   - der Selbsttest ruft selftest_kexec auf. selftest_kexec meldet 1 als gesperrt, jeden anderen
#     Wert und eine fehlende Datei als Fehler (hier mit einer Datei statt /proc).
# Echt prüft es selftest_kexec im Boot-Test.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
F=build/overlay/etc/sysctl.d/90-lf-kexec.conf

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Image:"
check "die Datei liegt im Overlay unter /etc/sysctl.d" '[[ -f $F ]]'
check "sie setzt nur kernel.kexec_load_disabled = 1" '[[ $(grep -vE "^[[:space:]]*(#|$)" "$F" 2>/dev/null) == "kernel.kexec_load_disabled = 1" ]]'
check "keine andere Datei im Overlay setzt den Wert" '[[ $(grep -rlE "^[[:space:]]*kernel[./]kexec_load_disabled" build/overlay) == "$F" ]]'
check "der Selbsttest ruft selftest_kexec auf" 'grep -qx "	selftest_kexec || ok=0" rescue/lf'

FN=$(sed -n '/^selftest_kexec() {$/,/^}$/p' rescue/lf)
if [[ -z $FN ]]; then
	echo "  FAIL selftest_kexec fehlt in rescue/lf"
	echo "unit-kexec: $((fails + 1)) Fehler"
	exit 1
fi
eval "$FN"

# zeile DATEI   Ausgabe und Exit-Code von selftest_kexec, wenn DATEI für /proc/sys/kernel/kexec_load_disabled steht
zeile() {
	OUT=$(LF_KEXEC_DISABLED=$1 selftest_kexec)
	RC=$?
}

echo "selftest_kexec mit einer Datei statt /proc:"
echo 1 >"$T/kexec"
zeile "$T/kexec"
check "1: gesperrt" '[[ $RC == 0 && $OUT == "LF-SELFTEST: kexec: gesperrt (kernel.kexec_load_disabled=1)" ]]'
echo 0 >"$T/kexec"
zeile "$T/kexec"
check "0: FAIL mit dem Wert" '[[ $RC == 1 && $OUT == "LF-SELFTEST: kexec: kernel.kexec_load_disabled ist 0 statt 1" ]]'
zeile "$T/fehlt"
check "ohne die Datei: FAIL" '[[ $RC == 1 && $OUT == "LF-SELFTEST: kexec: kernel.kexec_load_disabled ist nicht lesbar statt 1" ]]'
: >"$T/kexec"
zeile "$T/kexec"
check "leere Datei: FAIL" '[[ $RC == 1 && $OUT == *"ist nicht lesbar statt 1" ]]'

echo
if ((fails)); then
	echo "unit-kexec: $fails Fehler"
	exit 1
fi
echo "unit-kexec: alles ok"
