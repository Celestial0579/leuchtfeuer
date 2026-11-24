#!/usr/bin/env bash
# Unit-Test (#144): Die Maschinen-ID entsteht bei jedem Start neu, und D-Bus nennt dieselbe.
#
# Statisch geprüft:
#   - build/chroot-setup.sh leert /etc/machine-id und macht danach /var/lib/dbus/machine-id zu einem
#     Link darauf, und danach schreibt nichts mehr eine eigene D-Bus-ID,
#   - der Selbsttest ruft selftest_machine_id auf.
# selftest_machine_id mit Dateien statt /etc, /var/lib/dbus und /rofs: gesetzte ID und Link darauf
# ist ok, wenn das Image keine ID trägt. Jede eigene Datei, ein Link woandershin, eine leere oder
# fehlende ID und eine ID im Image (die systemd beim Start übernähme) sind ein Fehler.
# Echt prüft es selftest_machine_id im Boot-Test.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
C=build/chroot-setup.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

LEER=': >/etc/machine-id'
LINK='ln -sf /etc/machine-id /var/lib/dbus/machine-id'
echo "Image:"
check "chroot-setup.sh leert /etc/machine-id" 'grep -qxF -- "$LEER" "$C"'
check "danach ist /var/lib/dbus/machine-id ein Link darauf" 'l=$(grep -nxF -- "$LEER" "$C" | cut -d: -f1); k=$(grep -nxF -- "$LINK" "$C" | cut -d: -f1); [[ -n $l && -n $k ]] && ((k > l))'
check "danach schreibt nichts mehr eine eigene D-Bus-ID" 'k=$(grep -nxF -- "$LINK" "$C" | cut -d: -f1); [[ -n $k ]] && ! tail -n +$((k + 1)) "$C" | grep -vE "^[[:space:]]*#" | grep -qE "dbus-uuidgen|machine-id"'
check "der Selbsttest ruft selftest_machine_id auf" 'grep -qx "	selftest_machine_id || ok=0" rescue/lf'

FN=$(sed -n '/^selftest_machine_id() {$/,/^}$/p' rescue/lf)
if [[ -z $FN ]]; then
	echo "  FAIL selftest_machine_id fehlt in rescue/lf"
	exit 1
fi
eval "$FN"

ID=0123456789abcdef0123456789abcdef
ANDERE=fedcba9876543210fedcba9876543210
OK="LF-SELFTEST: Maschinen-ID: je Start neu, D-Bus nennt dieselbe"

# image [ID|link:ZIEL|fehlt]   Das Image unter $T/rofs: /etc/machine-id leer und die D-Bus-Datei ein
#   Link auf /etc/machine-id wie im Build; mit ID steht diese in /etc/machine-id, mit link:ZIEL zeigt
#   der Link woandershin, mit fehlt gibt es kein Image
image() {
	rm -rf "$T/rofs"
	[[ ${1-} == fehlt ]] && return
	mkdir -p "$T/rofs/etc" "$T/rofs/var/lib/dbus"
	: >"$T/rofs/etc/machine-id"
	case ${1-} in
	'') ln -s /etc/machine-id "$T/rofs/var/lib/dbus/machine-id" ;;
	link:*) ln -s "${1#link:}" "$T/rofs/var/lib/dbus/machine-id" ;;
	datei) printf '%s\n' "$ANDERE" >"$T/rofs/var/lib/dbus/machine-id" ;;
	*)
		printf '%s\n' "$1" >"$T/rofs/etc/machine-id"
		ln -s /etc/machine-id "$T/rofs/var/lib/dbus/machine-id"
		;;
	esac
}
image

# zeile   Ausgabe und Exit-Code von selftest_machine_id mit $T/etc, $T/dbus und $T/rofs
zeile() {
	OUT=$(LF_MACHINE_ID=$T/etc LF_DBUS_MACHINE_ID=$T/dbus LF_ROFS=$T/rofs selftest_machine_id)
	RC=$?
}
# lage ETC [DBUS]   ETC ist der Inhalt von $T/etc; DBUS "link" (auf $T/etc), "link:ZIEL" oder ein
#   Inhalt für eine eigene Datei, ohne DBUS fehlt $T/dbus
lage() {
	rm -f "$T/etc" "$T/dbus" "$T/woanders"
	printf '%s\n' "$1" >"$T/etc"
	case ${2-} in
	'') ;;
	link) ln -s "$T/etc" "$T/dbus" ;;
	link:*) ln -s "${2#link:}" "$T/dbus" ;;
	*) printf '%s\n' "$2" >"$T/dbus" ;;
	esac
}

echo "selftest_machine_id mit Dateien statt /etc und /var/lib/dbus:"
lage "$ID" link
zeile
check "ID gesetzt, D-Bus ist ein Link darauf: ok" '[[ $RC == 0 && $OUT == "$OK" ]]'
lage "$ID" "$ID"
zeile
check "eigene Datei mit derselben ID: FAIL, kein Link" '[[ $RC == 1 && $OUT == *"ist kein Link auf"* ]]'
lage "$ID" "$ANDERE"
zeile
check "eigene Datei mit einer anderen ID (wie im Build bis #144): FAIL" '[[ $RC == 1 && $OUT == *"ist kein Link auf"* ]]'
lage "$ID"
printf '%s\n' "$ID" >"$T/woanders"
ln -s "$T/woanders" "$T/dbus"
zeile
check "Link auf eine andere Datei mit derselben ID: FAIL" '[[ $RC == 1 && $OUT == *"ist kein Link auf"* ]]'
lage "$ID"
zeile
check "ohne /var/lib/dbus/machine-id: FAIL" '[[ $RC == 1 && $OUT == *"ist kein Link auf"* ]]'
lage "" link
zeile
check "leere /etc/machine-id: FAIL" '[[ $RC == 1 && $OUT == *"ist leer oder keine ID" ]]'
lage uninitialized link
zeile
check "/etc/machine-id mit uninitialized: FAIL" '[[ $RC == 1 && $OUT == *"ist leer oder keine ID" ]]'
rm -f "$T/etc"
zeile
check "ohne /etc/machine-id: FAIL" '[[ $RC == 1 && $OUT == *"ist leer oder keine ID" ]]'
lage "$ID" link
image "$ANDERE"
zeile
check "das Image trägt eine ID in /etc/machine-id (systemd übernähme sie): FAIL" '[[ $RC == 1 && $OUT == *"Das Image unter"*"trägt eine ID oder fehlt" ]]'
image datei
zeile
check "die D-Bus-Datei im Image ist eine Datei mit ID (wie in den Betas bis #144): FAIL" '[[ $RC == 1 && $OUT == *"trägt eine ID oder fehlt" ]]'
image link:/var/lib/dbus/anders
zeile
check "der Link im Image zeigt woandershin: FAIL" '[[ $RC == 1 && $OUT == *"trägt eine ID oder fehlt" ]]'
image fehlt
zeile
check "kein Image unter /rofs: FAIL" '[[ $RC == 1 && $OUT == *"trägt eine ID oder fehlt" ]]'
image
zeile
check "danach wieder wie im Build: ok" '[[ $RC == 0 && $OUT == "$OK" ]]'

echo
if ((fails)); then
	echo "unit-machine-id: $fails Fehler"
	exit 1
fi
echo "unit-machine-id: alles ok"
