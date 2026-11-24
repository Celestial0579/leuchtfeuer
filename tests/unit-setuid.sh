#!/usr/bin/env bash
# Unit-Test (#153): setuid, setgid und Datei-Capabilities nur, wo Leuchtfeuer sie braucht
# (rescue/lib/setuid.sh).
#
# Statisch geprüft:
#   - chroot-setup.sh ruft setuid_haerten nach der letzten Paketinstallation auf, ein Fehler bricht ab,
#   - build.sh prüft vor dem squashfs mit setuid_pruefen und bricht bei einer Abweichung ab, host_deps
#     bringt getcap mit,
#   - der Selbsttest ruft selftest_setuid auf,
#   - SETUID_SOLL, SETUID_AUS und SETUID_CAP_AUS nennen genau die Programme aus #153.
# setuid_haerten mit Attrappen für dpkg-statoverride und setcap: die Aufrufe, eine fehlende Datei,
# ein Fehler. setuid_pruefen und selftest_setuid an einem Probe-Verzeichnis mit eigener passwd und
# group (die Dateien des Testbenutzers heißen dort root:root) und einer Attrappe für getcap: passt,
# eine Datei zu viel, eine fehlt, ein anderer Modus, setgid, Capabilities zu viel oder fehlend, ein
# Besitzer ohne Namen, kein getcap. Echt prüfen es der Bau (build.sh) und selftest_setuid im
# Boot-Test. Ausgeführt wird keins der Programme.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
C=build/chroot-setup.sh
B=build/build.sh
# shellcheck source=rescue/lib/setuid.sh
. rescue/lib/setuid.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
# zeile DATEI TEXT   Nummer der ersten Zeile, die genau TEXT ist
zeile() { grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1; }

echo "Bau:"
l_apt=$(grep -n 'apt-get install' "$C" | tail -n 1 | cut -d: -f1)
l_pam=$(zeile "$C" 'pam_haerten / || { echo "FEHLER: PAM ließ sich nicht wie erwartet einrichten" >&2; exit 1; }')
l_src=$(zeile "$C" '. /usr/local/lib/lf/setuid.sh')
l_call=$(zeile "$C" 'setuid_haerten / || { echo "FEHLER: setuid, setgid oder Capabilities ließen sich nicht wie erwartet einrichten" >&2; exit 1; }')
check "chroot-setup.sh: setuid_haerten nach der letzten Paketinstallation und nach PAM, ein Fehler bricht ab" '[[ -n $l_apt && -n $l_pam && -n $l_src && -n $l_call ]] && ((l_apt < l_pam && l_pam < l_src && l_src < l_call))'
check "chroot-setup.sh: danach installiert nichts mehr ein Paket" '[[ -n $l_call ]] && ! tail -n +$((l_call + 1)) "$C" | grep -vE "^[[:space:]]*#" | grep -qE "apt-get install|apt install|dpkg -i"'
sq=$(sed -n '/^squash() {$/,/^}$/p' "$B")
l_pruef=$(grep -nF 'if ! suid=$(setuid_pruefen "$CHROOT"); then' <<<"$sq" | cut -d: -f1)
l_mks=$(grep -nF 'mksquashfs "$CHROOT"' <<<"$sq" | cut -d: -f1)
check "build.sh liest setuid.sh" 'grep -qxF ". \"\$SRC/rescue/lib/setuid.sh\"" "$B"'
check "build.sh: setuid_pruefen vor dem squashfs, eine Abweichung bricht ab" '[[ -n $l_pruef && -n $l_mks ]] && ((l_pruef < l_mks)) && sed -n "$((l_pruef + 1)),$((l_pruef + 3))p" <<<"$sq" | grep -q "exit 1"'
hd=$(sed -n '/^host_deps() {$/,/^}$/p' "$B")
check "host_deps installiert libcap2-bin und prüft getcap" 'grep -qE "[[:space:]]libcap2-bin([[:space:]]|$)" <<<"$hd" && grep -qxF "	command -v getcap >/dev/null || die \"Build-Werkzeug fehlt: getcap\"" <<<"$hd"'
check "der Selbsttest liest setuid.sh und ruft selftest_setuid auf" 'grep -qE "^for f in .* setuid( |;)" rescue/lf && grep -qx "	selftest_setuid || ok=0" rescue/lf'

echo "Listen:"
SOLL_153="usr/bin/ping cap_net_raw=ep
usr/bin/ssh-agent 2755 root:_ssh
usr/lib/cargo/bin/sudo 4755 root:root
usr/lib/claude-desktop/chrome-sandbox 4755 root:root
usr/lib/dbus-1.0/dbus-daemon-launch-helper 4754 root:messagebus
usr/lib/mc/cons.saver 2755 root:tty"
AUS_153="usr/bin/chage shadow
usr/bin/chfn root
usr/bin/chsh root
usr/bin/expiry shadow
usr/bin/fusermount3 root
usr/bin/gpasswd root
usr/bin/mount root
usr/bin/ntfs-3g root
usr/bin/passwd root
usr/bin/su root
usr/bin/sudo.ws root
usr/bin/umount root
usr/lib/cargo/bin/su root
usr/lib/openssh/ssh-keysign root
usr/sbin/mount.cifs root
usr/sbin/mount.nfs root
usr/sbin/pam_extrausers_chkpwd shadow
usr/sbin/unix_chkpwd shadow"
check "SETUID_SOLL: sudo von sudo-rs, chrome-sandbox, Helfer von D-Bus, ssh-agent, cons.saver, ping" '[[ $(printf "%s\n" "${SETUID_SOLL[@]}") == "$SOLL_153" ]]'
check "SETUID_AUS: beide su, sudo.ws, Einhängen, Konten, ssh-keysign, Passwortprüfung" '[[ $(printf "%s\n" "${SETUID_AUS[@]}") == "$AUS_153" ]]'
check "SETUID_CAP_AUS: gst-ptp-helper" '[[ ${#SETUID_CAP_AUS[@]} == 1 && ${SETUID_CAP_AUS[0]} == usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper ]]'
check "kein Pfad steht in SETUID_SOLL und in SETUID_AUS" '[[ -z $(LC_ALL=C comm -12 <(printf "%s\n" "${SETUID_SOLL[@]}" | cut -d" " -f1 | LC_ALL=C sort) <(printf "%s\n" "${SETUID_AUS[@]}" "${SETUID_CAP_AUS[@]}" | cut -d" " -f1 | LC_ALL=C sort)) ]]'
check "setuid_liste bleibt auf dem Dateisystem von WURZEL (-xdev), im System also nicht in /proc oder eingehängten Disks" '[[ $(grep -c "find \"\$root/\" -xdev -type f " rescue/lib/setuid.sh) == 2 ]]'

echo "setuid_haerten mit Attrappen:"
mkdir -p "$T/bin"
cat >"$T/bin/dpkg-statoverride" <<'EOF'
#!/bin/sh
echo "$*" >>"$LOG_DSO"
case " $* " in *" $FAIL_DSO "*) exit 2 ;; esac
exit 0
EOF
cat >"$T/bin/setcap" <<'EOF'
#!/bin/sh
echo "$*" >>"$LOG_SETCAP"
[ -z "$FAIL_SETCAP" ] || exit 1
exit 0
EOF
chmod +x "$T/bin/dpkg-statoverride" "$T/bin/setcap"
export LOG_DSO=$T/dso.log LOG_SETCAP=$T/setcap.log FAIL_DSO='' FAIL_SETCAP=''
# h ROOT   Probe-Wurzel mit allen Dateien aus SETUID_AUS und SETUID_CAP_AUS, ohne besondere Rechte
h() {
	local e p
	rm -rf "$1"
	for e in "${SETUID_AUS[@]}" "${SETUID_CAP_AUS[@]}"; do
		p=${e%% *}
		mkdir -p "$1/${p%/*}" && : >"$1/$p"
	done
}
# haerten ROOT   setuid_haerten mit den Attrappen, setuid_pruefen nur gemeldet
haerten() {
	: >"$LOG_DSO"
	: >"$LOG_SETCAP"
	(
		PATH=$T/bin:$PATH
		setuid_pruefen() { echo "setuid_pruefen $1"; }
		setuid_haerten "$1"
	)
}
h "$T/h"
out=$(haerten "$T/h/")
rc=$?
want=$(for e in "${SETUID_AUS[@]}"; do read -r p g <<<"$e"; echo "--root $T/h --force-statoverride-add --update --add root $g 0755 /$p"; done)
check "jede Datei aus SETUID_AUS: root:Gruppe 0755 per dpkg-statoverride, dann setuid_pruefen" '((rc == 0)) && [[ $(cat "$LOG_DSO") == "$want" && $out == "setuid_pruefen $T/h" ]]'
check "gst-ptp-helper verliert seine Capabilities" '[[ $(cat "$LOG_SETCAP") == "-r $T/h/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper" ]]'
check "su und sudo.ws verlieren das Bit, unix_chkpwd behält die Gruppe shadow" 'grep -qxF -- "--root $T/h --force-statoverride-add --update --add root root 0755 /usr/bin/su" "$LOG_DSO" && grep -qxF -- "--root $T/h --force-statoverride-add --update --add root root 0755 /usr/lib/cargo/bin/su" "$LOG_DSO" && grep -qxF -- "--root $T/h --force-statoverride-add --update --add root root 0755 /usr/bin/sudo.ws" "$LOG_DSO" && grep -qxF -- "--root $T/h --force-statoverride-add --update --add root shadow 0755 /usr/sbin/unix_chkpwd" "$LOG_DSO"'
rm "$T/h/usr/bin/su"
out=$(haerten "$T/h")
rc=$?
check "eine Datei aus SETUID_AUS fehlt: Status 1, genannt, kein setuid_pruefen" '((rc == 1)) && [[ $out == "setuid_haerten: /usr/bin/su fehlt" ]] && [[ $(wc -l <"$LOG_DSO") == $((${#SETUID_AUS[@]} - 1)) ]]'
h "$T/h"
FAIL_DSO=/usr/bin/passwd
out=$(haerten "$T/h")
rc=$?
FAIL_DSO=''
check "dpkg-statoverride scheitert: Status 1, genannt" '((rc == 1)) && [[ $out == "setuid_haerten: dpkg-statoverride für /usr/bin/passwd fehlgeschlagen" ]]'
FAIL_SETCAP=1
out=$(haerten "$T/h")
rc=$?
FAIL_SETCAP=''
check "setcap scheitert: Status 1, genannt" '((rc == 1)) && [[ $out == "setuid_haerten: setcap -r für /usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper fehlgeschlagen" ]]'

echo "setuid_pruefen an einem Probe-Verzeichnis:"
# getcap-Attrappe: nennt für jede Datei, deren Pfad auf eine Zeile aus $CAPS endet, die Capabilities
cat >"$T/bin/getcap" <<'EOF'
#!/bin/sh
for f in "$@"; do
	while read -r suffix caps; do
		case "$f" in *"/$suffix") echo "$f $caps" ;; esac
	done <"$CAPS"
done
exit 0
EOF
chmod +x "$T/bin/getcap"
export CAPS=$T/caps
R=$T/r
# r   Probe-Wurzel, die zu PROBE_SOLL passt
PROBE_SOLL=("usr/bin/ping cap_net_raw=ep" "usr/bin/ssh-agent 2755 root:root" "usr/lib/cargo/bin/sudo 4755 root:root")
r() {
	rm -rf "$R"
	mkdir -p "$R/etc" "$R/usr/bin" "$R/usr/lib/cargo/bin" "$R/usr/sbin" "$R/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0"
	printf 'root:x:%s:%s:root:/root:/bin/sh\n' "$(id -u)" "$(id -g)" >"$R/etc/passwd"
	printf 'root:x:%s:\n' "$(id -g)" >"$R/etc/group"
	: >"$R/usr/bin/ping"
	: >"$R/usr/bin/ssh-agent"
	chmod 2755 "$R/usr/bin/ssh-agent"
	: >"$R/usr/lib/cargo/bin/sudo"
	chmod 4755 "$R/usr/lib/cargo/bin/sudo"
	ln -s ../lib/cargo/bin/sudo "$R/usr/bin/sudo"
	mkdir -p "$R/var/mail"
	chmod 2775 "$R/var/mail"
	: >"$R/usr/bin/su"
	chmod 0755 "$R/usr/bin/su"
	: >"$R/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper"
	echo "usr/bin/ping cap_net_raw=ep" >"$CAPS"
}
# pruefen [WURZEL]   setuid_pruefen mit PROBE_SOLL und der getcap-Attrappe
pruefen() {
	(
		PATH=$T/bin:$PATH
		SETUID_SOLL=("${PROBE_SOLL[@]}")
		setuid_pruefen "${1:-$R}"
	)
}
r
out=$(pruefen)
rc=$?
check "passt (eine Verknüpfung auf sudo und ein setgid-Ordner zählen nicht): Status 0, nichts gemeldet" '((rc == 0)) && [[ -z $out ]]'
out=$(pruefen "$R/")
rc=$?
check "WURZEL mit / am Ende: ebenso" '((rc == 0)) && [[ -z $out ]]'
chmod 4755 "$R/usr/bin/su"
out=$(pruefen)
rc=$?
check "eine setuid-Datei zu viel: genannt" '((rc == 1)) && [[ $out == "nicht vorgesehen: usr/bin/su 4755 root:root" ]]'
r
chmod 2755 "$R/usr/bin/su"
out=$(pruefen)
rc=$?
check "eine setgid-Datei zu viel: genannt" '((rc == 1)) && [[ $out == "nicht vorgesehen: usr/bin/su 2755 root:root" ]]'
r
chmod 0755 "$R/usr/lib/cargo/bin/sudo"
out=$(pruefen)
rc=$?
check "sudo ohne setuid: fehlt" '((rc == 1)) && [[ $out == "fehlt: usr/lib/cargo/bin/sudo 4755 root:root" ]]'
r
chmod 4711 "$R/usr/lib/cargo/bin/sudo"
out=$(pruefen)
rc=$?
check "ein anderer Modus: beides genannt" '((rc == 1)) && [[ $out == "nicht vorgesehen: usr/lib/cargo/bin/sudo 4711 root:root"$'"'"'\n'"'"'"fehlt: usr/lib/cargo/bin/sudo 4755 root:root" ]]'
r
echo "usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_admin,cap_sys_nice=ep" >>"$CAPS"
out=$(pruefen)
rc=$?
check "Capabilities zu viel: genannt" '((rc == 1)) && [[ $out == "nicht vorgesehen: usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_admin,cap_sys_nice=ep" ]]'
r
: >"$CAPS"
out=$(pruefen)
rc=$?
check "ping ohne Capability: fehlt" '((rc == 1)) && [[ $out == "fehlt: usr/bin/ping cap_net_raw=ep" ]]'
r
printf 'root:x:0:0:root:/root:/bin/sh\n' >"$R/etc/passwd"
out=$(pruefen)
rc=$?
check "Besitzer ohne Namen in WURZEL/etc/passwd: mit Nummer genannt" '((rc == 1)) && grep -qxF "nicht vorgesehen: usr/lib/cargo/bin/sudo 4755 $(id -u):root" <<<"$out" && grep -qxF "fehlt: usr/lib/cargo/bin/sudo 4755 root:root" <<<"$out"'
r
mkdir -p "$T/ohne-getcap"
for c in find awk sort comm sed xargs cat; do ln -s "$(command -v "$c")" "$T/ohne-getcap/$c"; done
out=$(
	SETUID_SOLL=("${PROBE_SOLL[@]}")
	PATH=$T/ohne-getcap setuid_pruefen "$R"
)
rc=$?
check "ohne getcap: Status 1, genannt" '((rc == 1)) && [[ $out == "getcap fehlt (libcap2-bin)" ]]'

echo "selftest_setuid:"
FN=$(sed -n '/^selftest_setuid() {$/,/^}$/p' rescue/lf)
if [[ -z $FN ]]; then
	echo "  FAIL selftest_setuid fehlt in rescue/lf"
	exit 1
fi
eval "$FN"
r
out=$(
	PATH=$T/bin:$PATH
	SETUID_SOLL=("${PROBE_SOLL[@]}")
	selftest_setuid "$R"
)
rc=$?
check "passt: Status 0, eine Zeile" '((rc == 0)) && [[ $out == "LF-SELFTEST: setuid: nur sudo, chrome-sandbox, der Helfer von D-Bus, ssh-agent, cons.saver und ping" ]]'
chmod 4755 "$R/usr/bin/su"
chmod 0755 "$R/usr/lib/cargo/bin/sudo"
out=$(
	PATH=$T/bin:$PATH
	SETUID_SOLL=("${PROBE_SOLL[@]}")
	selftest_setuid "$R"
)
rc=$?
check "Abweichungen: Status 1, je eine Zeile" '((rc == 1)) && [[ $out == "LF-SELFTEST: setuid: nicht vorgesehen: usr/bin/su 4755 root:root"$'"'"'\n'"'"'"LF-SELFTEST: setuid: fehlt: usr/lib/cargo/bin/sudo 4755 root:root" ]]'

((fails == 0)) && echo "unit-setuid: alles ok" || { echo "unit-setuid: $fails Test(s) fehlgeschlagen."; exit 1; }
