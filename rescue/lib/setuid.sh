# shellcheck shell=bash
# setuid, setgid und Datei-Capabilities im Rettungssystem (#153).
#
# Ein Programm mit setuid-Bit oder Capability läuft mit mehr Rechten als sein Aufrufer, auch wenn
# lf-claude es startet. Ein Fehler darin hebt die Grenzen auf, die Leuchtfeuer für Claude zieht.
# Deshalb behalten nur diese ihre Rechte (SETUID_SOLL):
#   - sudo von sudo-rs: lf-claude für lf-lesen und lf-aufgabe, der Live-Benutzer für alles,
#   - chrome-sandbox: Claude Desktop läuft als lf-claude und braucht die Sandbox von Electron,
#   - dbus-daemon-launch-helper: starten dürfen es nur root und die Gruppe messagebus,
#   - ssh-agent (setgid): schützt den Agenten vor ptrace durch Programme desselben Benutzers,
#   - cons.saver (setgid tty): mc an der Konsole,
#   - ping (cap_net_raw).
# Alles andere verliert sein Bit (SETUID_AUS). Eingehängt wird nur als root (Assistent, lf-aufgabe,
# sudo), Konten ändert nur root (casper, pam.sh), su und das klassische sudo (sudo.ws) braucht
# niemand, ssh-keysign nur die hostbasierte Anmeldung, und Passwörter prüfen nur Programme, die als
# root laufen (sudo, sshd, login). gst-ptp-helper von GStreamer verliert seine Capabilities
# (SETUID_CAP_AUS), PTP braucht hier niemand.
# setuid_haerten richtet das beim Bau ein (chroot-setup.sh), per dpkg-statoverride, damit ein Update
# das Bit nicht zurückbringt. setuid_pruefen vergleicht beim Bau vor dem squashfs (build.sh) und im
# laufenden System (Selbsttest) alle Dateien mit setuid, setgid oder Capability mit SETUID_SOLL.

# Was bleibt: „Pfad Modus Besitzer:Gruppe“, bei Capabilities „Pfad Capabilities“ wie von getcap
SETUID_SOLL=(
	"usr/bin/ping cap_net_raw=ep"
	"usr/bin/ssh-agent 2755 root:_ssh"
	"usr/lib/cargo/bin/sudo 4755 root:root"
	"usr/lib/claude-desktop/chrome-sandbox 4755 root:root"
	"usr/lib/dbus-1.0/dbus-daemon-launch-helper 4754 root:messagebus"
	"usr/lib/mc/cons.saver 2755 root:tty"
)
# Was sein Bit verliert: „Pfad Gruppe“, danach root:Gruppe 0755
SETUID_AUS=(
	"usr/bin/chage shadow"
	"usr/bin/chfn root"
	"usr/bin/chsh root"
	"usr/bin/expiry shadow"
	"usr/bin/fusermount3 root"
	"usr/bin/gpasswd root"
	"usr/bin/mount root"
	"usr/bin/ntfs-3g root"
	"usr/bin/passwd root"
	"usr/bin/su root"
	"usr/bin/sudo.ws root"
	"usr/bin/umount root"
	"usr/lib/cargo/bin/su root"
	"usr/lib/openssh/ssh-keysign root"
	"usr/sbin/mount.cifs root"
	"usr/sbin/mount.nfs root"
	"usr/sbin/pam_extrausers_chkpwd shadow"
	"usr/sbin/unix_chkpwd shadow"
)
# Was seine Capabilities verliert
SETUID_CAP_AUS=(
	usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper
)

# setuid_haerten WURZEL   Nimmt jeder Datei aus SETUID_AUS unter WURZEL setuid und setgid
#   (dpkg-statoverride, root:Gruppe 0755) und jeder aus SETUID_CAP_AUS die Capabilities, dann
#   setuid_pruefen. Fehlt eine der Dateien, ist das eine Abweichung: Die Listen sollen genau zum
#   Image passen.
setuid_haerten() {
	local root=${1%/} e p g bad=0
	for e in "${SETUID_AUS[@]}"; do
		read -r p g <<<"$e"
		if [[ ! -f $root/$p ]]; then
			echo "setuid_haerten: /$p fehlt"
			bad=1
		elif ! dpkg-statoverride --root "${root:-/}" --force-statoverride-add --update --add root "$g" 0755 "/$p"; then
			echo "setuid_haerten: dpkg-statoverride für /$p fehlgeschlagen"
			bad=1
		fi
	done
	for p in "${SETUID_CAP_AUS[@]}"; do
		if [[ ! -f $root/$p ]]; then
			echo "setuid_haerten: /$p fehlt"
			bad=1
		elif ! setcap -r "$root/$p"; then
			echo "setuid_haerten: setcap -r für /$p fehlgeschlagen"
			bad=1
		fi
	done
	((bad == 0)) || return 1
	setuid_pruefen "$root"
}

# setuid_liste WURZEL   Jede Datei unter WURZEL, ohne andere Dateisysteme, mit setuid oder setgid
#   als „Pfad Modus Besitzer:Gruppe“ (Namen aus WURZEL/etc/passwd und WURZEL/etc/group, sonst die
#   Nummer) und jede mit Capabilities als „Pfad Capabilities“ wie von getcap. Pfade ohne WURZEL,
#   sortiert.
setuid_liste() {
	local root=${1%/}
	{
		find "$root/" -xdev -type f -perm /6000 -printf '%P %m %U %G\n' |
			awk -v pw="$root/etc/passwd" -v gr="$root/etc/group" '
				BEGIN {
					while ((getline l < pw) > 0) { split(l, f, ":"); u[f[3]] = f[1] }
					while ((getline l < gr) > 0) { split(l, f, ":"); g[f[3]] = f[1] }
				}
				{ print $1, $2, (($3 in u) ? u[$3] : $3) ":" (($4 in g) ? g[$4] : $4) }'
		find "$root/" -xdev -type f -print0 | xargs -0 -r getcap 2>/dev/null |
			awk -v p="$root/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }'
	} | LC_ALL=C sort
}

# setuid_pruefen WURZEL   Nennt jede Abweichung von SETUID_SOLL unter WURZEL in einer Zeile,
#   Rückgabe 1, wenn es eine gibt: „nicht vorgesehen: …“ für eine Datei mit setuid, setgid oder
#   Capabilities, die SETUID_SOLL nicht so nennt, „fehlt: …“ für einen Eintrag aus SETUID_SOLL, den
#   es so nicht gibt.
setuid_pruefen() {
	local root=${1%/} ist soll out
	if ! command -v getcap >/dev/null; then
		echo "getcap fehlt (libcap2-bin)"
		return 1
	fi
	ist=$(setuid_liste "$root")
	soll=$(printf '%s\n' "${SETUID_SOLL[@]}" | LC_ALL=C sort)
	out=$(
		LC_ALL=C comm -23 <(printf '%s\n' "$ist") <(printf '%s\n' "$soll") | sed '/^$/d; s/^/nicht vorgesehen: /'
		LC_ALL=C comm -13 <(printf '%s\n' "$ist") <(printf '%s\n' "$soll") | sed '/^$/d; s/^/fehlt: /'
	)
	[[ -z $out ]] && return 0
	printf '%s\n' "$out"
	return 1
}
