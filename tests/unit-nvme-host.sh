#!/usr/bin/env bash
# Unit-Test (#148): NVMe-Host-NQN und Host-ID entstehen bei jedem Start, keine stammt aus dem Build.
#
# Statisch geprüft:
#   - build/chroot-setup.sh entfernt /etc/nvme/hostnqn und /etc/nvme/hostid nach der letzten
#     Installation von Paketen und schaltet lf-nvme-host.service ein,
#   - lf-nvme-host.service läuft früh (vor udev und den Diensten von nvme-cli für NVMe-oF) und legt
#     beide an wie nvme-cli bei der Installation, aber nur, wenn sie fehlen,
#   - chroot-setup.sh maskiert die Dienste, mit denen sich nvme-cli beim Start selbst verbände,
#   - build.sh baut kein squashfs, solange start_ids_pruefen etwas findet,
#   - der Selbsttest ruft selftest_nvme_host auf.
# Mit Attrappen und Verzeichnissen statt /etc und /rofs:
#   - start_ids_pruefen findet jede Kennung aus dem Build (#144, #148),
#   - der Befehl aus lf-nvme-host.service legt fehlende Dateien an und lässt vorhandene stehen,
#   - selftest_nvme_host: beide vorhanden, im Format von nvme-cli, nicht im Image, und die Dienste
#     maskiert ist ok.
# Echt prüft es selftest_nvme_host im Boot-Test.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
C=build/chroot-setup.sh
B=build/build.sh
U=build/overlay/etc/systemd/system/lf-nvme-host.service

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

RM='rm -f /etc/nvme/hostnqn /etc/nvme/hostid'
MASK='systemctl mask nvmf-autoconnect.service nvmefc-boot-connections.service nvmf-connect-nbft.service nvmf-connect@.service'
RUF='if ! ids=$(start_ids_pruefen "$CHROOT"); then'
echo "Image:"
check "chroot-setup.sh entfernt Host-NQN und Host-ID" 'grep -qxF -- "$RM" "$C"'
check "erst nach der letzten Installation von Paketen" 'r=$(grep -nxF -- "$RM" "$C" | cut -d: -f1); i=$(grep -nE "apt-get install|dpkg -i" "$C" | tail -n 1 | cut -d: -f1); [[ -n $r && -n $i ]] && ((r > i))'
check "chroot-setup.sh schaltet lf-nvme-host.service ein" 'grep -qE "^systemctl enable .*lf-nvme-host\.service" "$C"'
check "chroot-setup.sh maskiert die Dienste, mit denen sich nvme-cli beim Start selbst verbände" 'grep -qxF -- "$MASK" "$C"'
check "die Masken stehen nach der letzten Installation von Paketen" 'm=$(grep -nxF -- "$MASK" "$C" | cut -d: -f1); i=$(grep -nE "apt-get install|dpkg -i" "$C" | tail -n 1 | cut -d: -f1); [[ -n $m && -n $i ]] && ((m > i))'
check "der Dienst läuft früh, ohne die Standard-Abhängigkeiten" 'grep -qx "DefaultDependencies=no" "$U" && grep -qx "WantedBy=sysinit.target" "$U" && grep -qx "Type=oneshot" "$U"'
check "vor udev und vor jedem Dienst von nvme-cli, der NVMe-oF verbindet" 'b=" $(sed -n "s/^Before=//p" "$U") "; [[ $b == *" systemd-udev-trigger.service "* && $b == *" nvmefc-boot-connections.service "* && $b == *" nvmf-autoconnect.service "* && $b == *" nvmf-connect-nbft.service "* ]]'
check "er legt beide an wie nvme-cli, nur wenn sie fehlen" 'e=$(sed -n "s/^ExecStart=//p" "$U"); [[ $e == *"[ -s /etc/nvme/hostnqn ] || /usr/sbin/nvme gen-hostnqn >/etc/nvme/hostnqn;"* && $e == *"[ -s /etc/nvme/hostid ] || /usr/bin/uuidgen >/etc/nvme/hostid;"* ]]'
check "build.sh baut kein squashfs mit Kennungen aus dem Build" 'awk -v r="$RUF" '"'"'$0 == "\t" r { an = 1 } an && $0 == "\t\texit 1" { ok = 1 } an && /^\tmksquashfs / { if (ok) gut = 1; an = 0 } END { exit !gut }'"'"' "$B"'
check "der Selbsttest ruft selftest_nvme_host auf" 'grep -qx "	selftest_nvme_host || ok=0" rescue/lf'

FN=$(sed -n '/^start_ids_pruefen() {$/,/^}$/p' "$B")
FS=$(sed -n '/^selftest_nvme_host() {$/,/^}$/p' rescue/lf)
if [[ -z $FN || -z $FS ]]; then
	echo "  FAIL start_ids_pruefen oder selftest_nvme_host fehlt"
	exit 1
fi
eval "$FN"
eval "$FS"

# wurzel   Ein System unter $T/root wie nach dem Build: /etc/machine-id leer, die D-Bus-Datei ein Link
#   darauf, /etc/nvme ohne Host-NQN und Host-ID
wurzel() {
	rm -rf "$T/root"
	mkdir -p "$T/root/etc/nvme" "$T/root/var/lib/dbus"
	: >"$T/root/etc/machine-id"
	ln -s /etc/machine-id "$T/root/var/lib/dbus/machine-id"
	printf '# discovery.conf\n' >"$T/root/etc/nvme/discovery.conf"
}
pruefe() {
	OUT=$(start_ids_pruefen "$T/root")
	RC=$?
}

echo "start_ids_pruefen mit einem System unter $T/root:"
wurzel
pruefe
check "wie nach dem Build: Status 0, nichts gemeldet" '[[ $RC == 0 && -z $OUT ]]'
printf '0123456789abcdef0123456789abcdef\n' >"$T/root/etc/machine-id"
pruefe
check "eine ID in /etc/machine-id: gemeldet" '[[ $RC == 1 && $OUT == "/etc/machine-id ist nicht leer" ]]'
wurzel
rm "$T/root/var/lib/dbus/machine-id"
printf '0123456789abcdef0123456789abcdef\n' >"$T/root/var/lib/dbus/machine-id"
pruefe
check "die D-Bus-Datei ist eine Datei: gemeldet" '[[ $RC == 1 && $OUT == "/var/lib/dbus/machine-id ist kein Link auf /etc/machine-id" ]]'
wurzel
ln -sf /var/lib/dbus/anders "$T/root/var/lib/dbus/machine-id"
pruefe
check "die D-Bus-Datei zeigt woandershin: gemeldet" '[[ $RC == 1 && $OUT == *"kein Link auf /etc/machine-id" ]]'
wurzel
printf 'nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555\n' >"$T/root/etc/nvme/hostnqn"
pruefe
check "eine Host-NQN: gemeldet" '[[ $RC == 1 && $OUT == "/etc/nvme/hostnqn ist im Image" ]]'
wurzel
printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' >"$T/root/etc/nvme/hostid"
pruefe
check "eine Host-ID: gemeldet" '[[ $RC == 1 && $OUT == "/etc/nvme/hostid ist im Image" ]]'
wurzel
ln -s /nirgends "$T/root/etc/nvme/hostid"
pruefe
check "ein Link als Host-ID, auch ins Leere: gemeldet" '[[ $RC == 1 && $OUT == "/etc/nvme/hostid ist im Image" ]]'

# Der Befehl aus lf-nvme-host.service mit $T/nvme statt /etc/nvme und Attrappen für nvme und uuidgen,
# die jeden Aufruf in $T/aufrufe festhalten.
mkdir -p "$T/bin"
cat >"$T/bin/nvme" <<'X'
#!/bin/sh
echo "nvme $*" >>"$T/aufrufe"
[ "$1" = gen-hostnqn ] && echo nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555
X
cat >"$T/bin/uuidgen" <<'X'
#!/bin/sh
echo uuidgen >>"$T/aufrufe"
echo aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
X
chmod +x "$T/bin/nvme" "$T/bin/uuidgen"
export T
CMD=$(sed -n "s/^ExecStart=\/bin\/sh -c '\(.*\)'$/\1/p" "$U")
CMD=${CMD//\/usr\/sbin\/nvme/$T/bin/nvme}
CMD=${CMD//\/usr\/bin\/uuidgen/$T/bin/uuidgen}
CMD=${CMD//\/etc\/nvme/$T/nvme}
starte() {
	rm -f "$T/aufrufe"
	(umask 077 && sh -c "$CMD")
	RC=$?
}

echo "Der Befehl von lf-nvme-host.service mit Attrappen:"
rm -rf "$T/nvme"
starte
check "ohne /etc/nvme: Status 0, legt das Verzeichnis und beide Dateien an" '((RC == 0)) && [[ $(cat "$T/nvme/hostnqn") == nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555 && $(cat "$T/nvme/hostid") == aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ]]'
check "lesbar für alle (umask 022, wie bei der Installation)" '[[ $(stat -c %a "$T/nvme/hostnqn") == 644 && $(stat -c %a "$T/nvme/hostid") == 644 ]]'
starte
check "beide vorhanden: kein Aufruf, nichts geändert" '((RC == 0)) && [[ ! -e $T/aufrufe ]]'
rm "$T/nvme/hostid"
printf 'nqn.2014-08.org.nvmexpress:uuid:99999999-2222-3333-4444-555555555555\n' >"$T/nvme/hostnqn"
starte
check "nur die Host-ID fehlt: nur uuidgen, die Host-NQN bleibt" '((RC == 0)) && [[ $(cat "$T/aufrufe") == uuidgen && $(cat "$T/nvme/hostnqn") == *99999999* ]]'

# zustand NQN ID [IMAGE]   NQN und ID unter $T/etc-nvme ("-" lässt die Datei weg); IMAGE "frei" (wie
#   im Build), "nqn" oder "id" (diese Datei steht auch im Image) oder "fehlt" (kein Image)
zustand() {
	rm -rf "$T/etc-nvme" "$T/rofs" "$T/systemd"
	mkdir -p "$T/etc-nvme" "$T/systemd"
	local u
	for u in nvmf-autoconnect.service nvmefc-boot-connections.service nvmf-connect-nbft.service nvmf-connect@.service; do
		ln -s /dev/null "$T/systemd/$u"
	done
	[[ $1 == - ]] || printf '%s\n' "$1" >"$T/etc-nvme/hostnqn"
	[[ $2 == - ]] || printf '%s\n' "$2" >"$T/etc-nvme/hostid"
	case ${3:-frei} in
	fehlt) return ;;
	frei) mkdir -p "$T/rofs/etc/nvme" ;;
	nqn) mkdir -p "$T/rofs/etc/nvme" && printf '%s\n' "$1" >"$T/rofs/etc/nvme/hostnqn" ;;
	id) mkdir -p "$T/rofs/etc/nvme" && printf '%s\n' "$2" >"$T/rofs/etc/nvme/hostid" ;;
	esac
}
zeile() {
	OUT=$(LF_NVME_DIR=$T/etc-nvme LF_ROFS=$T/rofs LF_SYSTEMD_ETC=$T/systemd selftest_nvme_host)
	RC=$?
}
NQN=nqn.2014-08.org.nvmexpress:uuid:11111111-2222-3333-4444-555555555555
HID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
OK="LF-SELFTEST: NVMe-Host: Host-NQN und Host-ID von diesem Start, keine Verbindung von selbst"

echo "selftest_nvme_host mit Verzeichnissen statt /etc/nvme und /rofs:"
zustand "$NQN" "$HID"
zeile
check "beide da, im Format von nvme-cli, nicht im Image: ok" '[[ $RC == 0 && $OUT == "$OK" ]]'
zustand - "$HID"
zeile
check "ohne Host-NQN: FAIL" '[[ $RC == 1 && $OUT == *"fehlt oder hat nicht das Format"* ]]'
zustand "$NQN" -
zeile
check "ohne Host-ID: FAIL" '[[ $RC == 1 && $OUT == *"fehlt oder hat nicht das Format"* ]]'
zustand "kein nqn" "$HID"
zeile
check "Host-NQN ohne das Format: FAIL" '[[ $RC == 1 && $OUT == *"fehlt oder hat nicht das Format"* ]]'
zustand "$NQN" "kein-uuid"
zeile
check "Host-ID ohne das Format: FAIL" '[[ $RC == 1 && $OUT == *"fehlt oder hat nicht das Format"* ]]'
zustand "$NQN" "$HID" nqn
zeile
check "die Host-NQN steht auch im Image: FAIL" '[[ $RC == 1 && $OUT == *"Das Image unter"*"trägt Host-NQN oder Host-ID"* ]]'
zustand "$NQN" "$HID" id
zeile
check "die Host-ID steht auch im Image: FAIL" '[[ $RC == 1 && $OUT == *"trägt Host-NQN oder Host-ID"* ]]'
zustand "$NQN" "$HID" fehlt
zeile
check "kein Image unter /rofs: FAIL" '[[ $RC == 1 && $OUT == *"oder fehlt" ]]'
for u in nvmf-autoconnect.service nvmefc-boot-connections.service nvmf-connect-nbft.service nvmf-connect@.service; do
	zustand "$NQN" "$HID"
	rm "$T/systemd/$u"
	zeile
	check "$u nicht maskiert: FAIL" '[[ $RC == 1 && $OUT == "LF-SELFTEST: NVMe-Host: $u ist nicht maskiert, das System verbände sich von selbst" ]]'
done
zustand "$NQN" "$HID"
ln -sf /usr/lib/systemd/system/nvmf-autoconnect.service "$T/systemd/nvmf-autoconnect.service"
zeile
check "ein Link auf den Dienst statt auf /dev/null: FAIL" '[[ $RC == 1 && $OUT == *"nvmf-autoconnect.service ist nicht maskiert"* ]]'

echo
if ((fails)); then
	echo "unit-nvme-host: $fails Fehler"
	exit 1
fi
echo "unit-nvme-host: alles ok"
