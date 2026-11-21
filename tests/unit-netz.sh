#!/usr/bin/env bash
# Unit-Test (#100): LAN bekommt ohne Zutun eine Adresse. Unter Ubuntu lässt NetworkManager alles
# außer WLAN und Mobilfunk unverwaltet (/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf)
# und überlässt kabelgebundene Karten netplan. /etc/netplan ist im ISO leer. Die gleichnamige
# Datei aus build/overlay verdeckt die aus /usr/lib.
#
# Der Selbsttest der ISO prüft das mit dem echten NetworkManager (selftest_netz). Hier sind
# NetworkManager, systemctl, nmcli und sleep Attrappen, selftest_netz kommt aus rescue/lf.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CONF=build/overlay/etc/NetworkManager/conf.d/10-globally-managed-devices.conf

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Image:"
check "die Datei aus dem Overlay hat den Namen der Ubuntu-Datei und liegt unter /etc/NetworkManager/conf.d" '[[ -f $CONF ]]'
check "sie enthält nur Kommentare: Sie verdeckt die Datei aus /usr/lib und setzt selbst nichts" '[[ -f $CONF ]] && ! grep -vqE "^[[:space:]]*(#|$)" "$CONF"'
check "keine Datei im Overlay lässt Karten unverwaltet oder schaltet die automatische Verbindung ab" '! grep -rqsE "^[[:space:]]*(unmanaged-devices|no-auto-default)[[:space:]]*=" build/overlay/etc/NetworkManager build/overlay/usr/lib/NetworkManager'
check "build.sh kopiert das Overlay ins System" 'grep -qF "cp -a --no-preserve=ownership \"\$SRC/build/overlay/.\" \"\$CHROOT/\"" build/build.sh'
check "chroot-setup schaltet NetworkManager ein" 'grep -q "^systemctl enable .*NetworkManager.service" build/chroot-setup.sh'
check "der Selbsttest ruft selftest_netz auf" 'grep -qx "	selftest_netz || ok=0" rescue/lf'

# selftest_owner prüft, dass alles aus dem Overlay root gehört. Dafür muss jeder Ordner, in den
# das Overlay schreibt, in seiner Liste stehen (oder darunter liegen).
mapfile -t owner < <(sed -n '/^selftest_owner() {$/,/^}$/p' rescue/lf | tr ' \t' '\n\n' | grep '^/')
uncovered() {
	local d p hit
	while read -r d; do
		hit=0
		for p in "${owner[@]}"; do [[ $d == "$p" || $d == "$p"/* ]] && hit=1; done
		((hit)) || echo "$d"
	done < <(find build/overlay -type f | sed 's|^build/overlay||' | xargs -n1 dirname | sort -u)
}
miss=$(uncovered | tr '\n' ' ')
check "selftest_owner deckt jeden Ordner ab, in den das Overlay schreibt${miss:+ (fehlt: $miss)}" '((${#owner[@]} > 5)) && [[ -z $miss ]]'

FN=$(sed -n '/^selftest_netz() {$/,/^}$/p' rescue/lf)
if [[ -z $FN ]]; then
	echo "  FAIL selftest_netz fehlt in rescue/lf"
	exit 1
fi
eval "$FN"

# Attrappen. CFG ist die Ausgabe von NetworkManager --print-config, ACTIVE der Exit-Code von
# systemctl is-active. nmcli liefert für die ersten EARLY Aufrufe BEFORE, danach DEVS.
NetworkManager() { [[ $* == --print-config ]] && printf '%s\n' "$CFG"; }
systemctl() {
	echo "$*" >>"$T/systemctl"
	[[ $* == "is-active --quiet NetworkManager.service" ]] || return 9
	return "$ACTIVE"
}
nmcli() {
	local n
	echo "${LC_ALL:-ohne}" >>"$T/nmcli-locale"
	[[ $* == "--colors no -t -f DEVICE,TYPE,STATE device" ]] || return 9
	n=$(($(wc -l <"$T/nmcli-locale")))
	((NMCLI_RC == 0)) || return "$NMCLI_RC"
	if ((n <= EARLY)); then printf '%b\n' "$BEFORE"; else printf '%b\n' "$DEVS"; fi
}
sleep() { echo 1 >>"$T/sleeps"; }

UBUNTU='[keyfile]
unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma'
FIXED='# NetworkManager configuration: /etc/NetworkManager/NetworkManager.conf, /usr/lib/NetworkManager/conf.d/{10-default-firewall-use-iptables.conf,no-mac-addr-change.conf}, /etc/NetworkManager/conf.d/{10-globally-managed-devices.conf,default-wifi-powersave-on.conf}

[main]
# rc-manager=auto
plugins=ifupdown,keyfile

[ifupdown]
managed=false'
GOOD='lo:loopback:connected (externally)\nenp0s2:ethernet:connected'

run() {
	: >"$T/sleeps"
	: >"$T/nmcli-locale"
	: >"$T/systemctl"
	OUT=$(selftest_netz)
	RC=$?
	SLEEPS=$(wc -l <"$T/sleeps")
}
reset() { CFG=$FIXED ACTIVE=0 NMCLI_RC=0 EARLY=0 BEFORE='' DEVS=$GOOD; }

echo "Selbsttest mit Attrappen:"
reset
CFG=$UBUNTU
run
check "die Einstellung von Ubuntu (unmanaged-devices=*, ohne die Datei aus dem Overlay): FAIL mit der Zeile" '[[ $RC == 1 && $OUT == *"lässt Karten unverwaltet: unmanaged-devices=*,except:type:wifi"* ]]'

reset
run
check "mit der Datei aus dem Overlay und einer verbundenen Karte: ok, nennt die Karte, ohne zu warten" '[[ $RC == 0 && $OUT == *"verwaltet kabelgebundene Karten: enp0s2 (connected)" && $SLEEPS == 0 ]]'
check "nmcli läuft mit LC_ALL=C, der Zustand steht nicht übersetzt da" '[[ $(sort -u "$T/nmcli-locale") == C ]]'
check "es prüft, ob NetworkManager läuft" 'grep -qx "is-active --quiet NetworkManager.service" "$T/systemctl"'

reset
CFG='[keyfile]
unmanaged-devices=interface-name:veth*'
run
check "eine Regel nur für bestimmte Karten (interface-name:veth*) lässt LAN in Ruhe: ok" '[[ $RC == 0 ]]'

reset
CFG='[keyfile]
unmanaged-devices=mac:00:11:22:33:44:55;*'
run
check "ein * am Ende einer Liste mit ; lässt alles unverwaltet: FAIL" '[[ $RC == 1 && $OUT == *"lässt Karten unverwaltet"* ]]'

reset
CFG=
run
check "liefert NetworkManager --print-config nichts: FAIL" '[[ $RC == 1 && $OUT == *"--print-config liefert nichts"* ]]'

reset
ACTIVE=3
run
check "läuft NetworkManager nicht: FAIL, nmcli wird nicht gefragt" '[[ $RC == 1 && $OUT == *"NetworkManager läuft nicht"* && ! -s $T/nmcli-locale ]]'

reset
DEVS='lo:loopback:connected (externally)\nenp0s2:ethernet:unmanaged\nenp3s0:ethernet:connected'
run
check "bleibt eine kabelgebundene Karte unverwaltet: FAIL mit ihrem Namen, nach 20 s" '[[ $RC == 1 && $OUT == *"kabelgebundene Karte unverwaltet: enp0s2" && $SLEEPS == 20 ]]'

reset
EARLY=3
BEFORE='lo:loopback:unmanaged\nenp0s2:ethernet:unmanaged'
DEVS='lo:loopback:connected (externally)\nenp0s2:ethernet:connecting (getting IP configuration)'
run
check "ist sie nur kurz nach dem Start unverwaltet: ok nach 3 s" '[[ $RC == 0 && $SLEEPS == 3 && $OUT == *"enp0s2 (connecting (getting IP configuration))" ]]'

reset
NMCLI_RC=8
run
check "antwortet nmcli nicht: FAIL, nach 20 s" '[[ $RC == 1 && $OUT == *"nmcli zeigt keine Geräte"* && $SLEEPS == 20 ]]'

reset
DEVS='lo:loopback:connected (externally)\nwlp1s0:wifi:unmanaged'
run
check 'ohne kabelgebundene Karte: ok, „keine“ (WLAN prüft der Test nicht)' '[[ $RC == 0 && $OUT == *"Karten: keine" ]]'

echo
((fails == 0)) && echo "Alle Tests bestanden." || {
	echo "$fails Test(s) fehlgeschlagen."
	exit 1
}
