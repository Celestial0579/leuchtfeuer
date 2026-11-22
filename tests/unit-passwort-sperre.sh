#!/usr/bin/env bash
# Unit-Test (GHSA-j332-2v26-m4qm): lf-claude wechselt mit su zu keinem anderen Benutzer.
#   - Das Passwort des Live-Benutzers ist ab dem Start gesperrt (lf-passwort-sperre.service). Die
#     Konsolen melden ihn ohne Passwort an, der serielle Port nicht. SSH setzt weiter beim
#     Einschalten ein Einmal-Passwort.
#   - PAM nimmt kein leeres Passwort an (kein nullok), su erlaubt den Wechsel nur root und der
#     Gruppe sudo (pam_wheel gleich nach pam_rootok), auch in gshadow ist kein Passwort leer:
#     pam_haerten beim Bau, pam_pruefen vor dem squashfs und im Selbsttest (selftest_kein_su).
#   - Der Selbsttest prüft nur die Konfiguration und dass das Passwort des Live-Benutzers gesperrt
#     ist. Er ruft weder su auf, noch meldet er sich an.
#
# PAM wird an Kopien der Dateien von Ubuntu 26.04 geprüft (Auszug, Leerraum wie dort), nie am
# System, auf dem der Test läuft. su läuft hier nicht.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/pam.sh
UNIT=build/overlay/etc/systemd/system/lf-passwort-sperre.service
GETTY=build/overlay/etc/systemd/system/getty@.service.d/autologin.conf
SETUP=build/chroot-setup.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
# words LISTE WORT …   Jedes WORT steht in der durch Leerzeichen getrennten LISTE.
words() {
	local l=" $1 " w
	shift
	for w; do [[ $l == *" $w "* ]] || return 1; done
}

# image DIR   PAM, shadow und gshadow wie in Ubuntu 26.04 (Auszug), noch ohne den Live-Benutzer.
image() {
	rm -rf "$1"
	mkdir -p "$1/etc/pam.d" "$1/usr/share/pam-configs"
	cat >"$1/etc/pam.d/su" <<'EOF'
#
# The PAM configuration file for the Shadow `su' service
#

# This allows root to su without passwords (normal operation)
auth       sufficient pam_rootok.so

# Uncomment this to force users to be a member of group wheel
# before they can use `su'.
# auth       required   pam_wheel.so

# Uncomment this if you want wheel members to be able to
# su without a password.
# auth       sufficient pam_wheel.so trust

# Uncomment this if you want members of a specific group to not
# be allowed to use su at all.
# auth       required   pam_wheel.so deny group=nosu

# parsing /etc/environment needs "readenv=1"
session       required   pam_env.so readenv=1
session       required   pam_env.so readenv=1 envfile=/etc/default/locale
session    optional   pam_mail.so nopen
session    required   pam_limits.so

# The standard Unix authentication modules, used with
# NIS (man nsswitch) as well as normal /etc/passwd and
# /etc/shadow entries.
@include common-auth
@include common-account
@include common-session
EOF
	printf '%s\n' $'auth\t\tinclude\t\tsu' $'account\t\tinclude\t\tsu' $'password\tinclude\t\tsu' \
		$'session\t\toptional\tpam_keyinit.so force revoke' $'session\t\tinclude\t\tsu' >"$1/etc/pam.d/su-l"
	printf '%s\n' '#' '# /etc/pam.d/common-auth - authentication settings common to all services' \
		'# Kommentar mit nullok, gilt nicht' '# here are the per-package modules (the "Primary" block)' \
		"$CA_NULLOK" $'auth\trequisite\t\t\tpam_deny.so' $'auth\trequired\t\t\tpam_permit.so' \
		'# end of pam-auth-update config' >"$1/etc/pam.d/common-auth"
	printf '%s\n' 'auth       optional   pam_faildelay.so  delay=3000000' '@include common-auth' \
		'auth       optional   pam_group.so' '@include common-account' >"$1/etc/pam.d/login"
	printf '%s\n' 'Name: Unix authentication' 'Default: yes' 'Priority: 256' 'Auth-Type: Primary' 'Auth:' \
		$'\t[success=end default=ignore]\tpam_unix.so nullok try_first_pass' 'Auth-Initial:' \
		$'\t[success=end default=ignore]\tpam_unix.so nullok' 'Password:' \
		$'\t[success=end default=ignore]\tpam_unix.so obscure use_authtok try_first_pass yescrypt' \
		>"$1/usr/share/pam-configs/unix"
	printf '%s\n' 'root:*:20413:0:99999:7:::' 'lf-claude:!:20413::::::' >"$1/etc/shadow"
	printf '%s\n' 'root:*::' 'sudo:*::' 'lf-claude:!::' >"$1/etc/gshadow"
}
CA_NULLOK=$'auth\t[success=1 default=ignore]\tpam_unix.so nullok'
CA_OHNE=$'auth\t[success=1 default=ignore]\tpam_unix.so'
UNIX_AUTH=$'\t[success=end default=ignore]\tpam_unix.so try_first_pass'
UNIX_INITIAL=$'\t[success=end default=ignore]\tpam_unix.so'

echo "Image:"
U=$(sed -n 's/^export USERNAME="\(.*\)"$/\1/p' "$SETUP")
LOCK="ExecStart=/usr/sbin/usermod --password '!' $U"
check "casper legt den Live-Benutzer rescue an" '[[ $U == rescue ]]'
check "lf-passwort-sperre sperrt sein Passwort, einmal je Start" 'grep -qxF "$LOCK" "$UNIT" && grep -qx "Type=oneshot" "$UNIT" && grep -qx "RemainAfterExit=yes" "$UNIT"'
check "vor jeder Anmeldung mit Passwort (Konsolen, ssh) und vor dem Selbsttest" 'words "$(sed -n "s/^Before=//p" "$UNIT")" systemd-user-sessions.service ssh.service ssh.socket lf-selftest.service shutdown.target'
check "ohne Standard-Abhängigkeiten, nach local-fs: kein Zyklus mit ssh.socket" 'grep -qx "DefaultDependencies=no" "$UNIT" && grep -qx "After=local-fs.target" "$UNIT" && grep -qx "Conflicts=shutdown.target" "$UNIT"'
check "bei jedem Start, nicht noch einmal, wenn SSH startet (das Einmal-Passwort bleibt)" 'grep -qx "WantedBy=multi-user.target" "$UNIT" && ! grep -qE "^(WantedBy|RequiredBy|PartOf|BindsTo|Requires|Wants)=.*ssh" "$UNIT"'
check "chroot-setup schaltet sie ein" 'grep -qE "^systemctl enable .*lf-passwort-sperre\.service" "$SETUP"'
check "Autologin als rescue auf jeder Konsole (Vorlage getty@)" 'grep -qx "ExecStart=" "$GETTY" && grep -qxF "ExecStart=-/sbin/agetty --autologin $U --noclear %I \$TERM" "$GETTY"'
check "kein eigenes Drop-in für tty1, keins für den seriellen Port" '[[ -z $(find build/overlay \( -path "*getty@tty*" -o -path "*serial-getty*" \) -print -quit) ]]'
check "SSH: Einmal-Passwort per chpasswd, kein leeres Passwort für sshd" 'grep -q "| sudo chpasswd$" rescue/lib/tools.sh && ! grep -qi "^PermitEmptyPasswords *yes" build/overlay/etc/ssh/sshd_config.d/lf.conf'
last_install=$(grep -n 'apt-get install' "$SETUP" | tail -n1 | cut -d: -f1)
haerten_at=$(grep -n '^pam_haerten / ' "$SETUP" | cut -d: -f1)
check "chroot-setup härtet PAM nach der letzten Paketinstallation" '[[ -n $haerten_at && $haerten_at -gt $last_install ]] && grep -qxF ". /usr/local/lib/lf/pam.sh" "$SETUP"'
check "… und bricht den Bau ab, wenn das nicht gelingt" 'grep -qE "^pam_haerten / \|\| \{ .*exit 1; \}$" "$SETUP"'
lib_at=$(grep -n 'cp -a --no-preserve=ownership "$SRC/rescue/lib/." "$CHROOT/usr/local/lib/lf/"' build/build.sh | cut -d: -f1)
setup_at=$(grep -n '^	in_chroot /tmp/chroot-setup.sh$' build/build.sh | cut -d: -f1)
check "pam.sh liegt im chroot, bevor chroot-setup läuft" '[[ -n $lib_at && -n $setup_at ]] && ((lib_at < setup_at))'
pp=$(grep -nF 'if ! pam=$(pam_pruefen "$CHROOT"); then' build/build.sh | cut -d: -f1)
mk=$(grep -n '^	mksquashfs' build/build.sh | cut -d: -f1)
check "build.sh baut kein squashfs, solange pam_pruefen etwas findet" '[[ -n $pp && -n $mk ]] && ((pp < mk)) && sed -n "$((pp + 1)),$((pp + 3))p" build/build.sh | grep -qx "		exit 1" && grep -qxF ". \"\$SRC/rescue/lib/pam.sh\"" build/build.sh'
check "rescue/lf lädt pam.sh, der Selbsttest ruft selftest_kein_su auf" 'grep -qE "^for f in .* pam; do$" rescue/lf && grep -qx "	selftest_kein_su || good=0" rescue/lf'

echo "pam_haerten am Auszug von Ubuntu 26.04:"
image "$T/orig"
image "$T/a"
out=$(pam_pruefen "$T/a")
rc=$?
check "vorher: pam_pruefen nennt nullok und su ohne pam_wheel" '((rc == 1)) && grep -qx "nullok in $T/a/etc/pam.d/common-auth" <<<"$out" && grep -qx "nullok in $T/a/usr/share/pam-configs/unix" <<<"$out" && grep -q "^su: " <<<"$out" && [[ $(wc -l <<<"$out") == 3 ]]'
out=$(pam_haerten "$T/a")
rc=$?
check "danach: pam_pruefen findet nichts" '((rc == 0)) && [[ -z $out ]]'
r=$(grep -n '^auth       sufficient pam_rootok.so$' "$T/orig/etc/pam.d/su" | cut -d: -f1)
check "su: genau eine Zeile neu, pam_wheel gleich nach pam_rootok" '[[ $(diff "$T/orig/etc/pam.d/su" "$T/a/etc/pam.d/su") == "${r}a$((r + 1))"$'"'"'\n'"'"'"> $PAM_WHEEL_LINE" ]]'
check "common-auth: nur nullok fehlt, der Kommentar mit nullok bleibt" '[[ $(diff "$T/orig/etc/pam.d/common-auth" "$T/a/etc/pam.d/common-auth" | grep -c "^[<>]") == 2 ]] && grep -qxF "$CA_OHNE" "$T/a/etc/pam.d/common-auth" && grep -qx "# Kommentar mit nullok, gilt nicht" "$T/a/etc/pam.d/common-auth"'
check "pam-configs/unix: ohne nullok, Optionen dahinter bleiben" 'grep -qxF "$UNIX_AUTH" "$T/a/usr/share/pam-configs/unix" && grep -qxF "$UNIX_INITIAL" "$T/a/usr/share/pam-configs/unix" && ! grep -q nullok "$T/a/usr/share/pam-configs/unix"'
check "su-l, login, shadow und gshadow unverändert" 'cmp -s "$T/orig/etc/pam.d/su-l" "$T/a/etc/pam.d/su-l" && cmp -s "$T/orig/etc/pam.d/login" "$T/a/etc/pam.d/login" && cmp -s "$T/orig/etc/shadow" "$T/a/etc/shadow" && cmp -s "$T/orig/etc/gshadow" "$T/a/etc/gshadow"'
cp -a "$T/a" "$T/a2"
pam_haerten "$T/a2" >/dev/null
check "ein zweiter Aufruf ändert nichts" 'diff -r "$T/a" "$T/a2" >/dev/null'

echo "pam_pruefen findet jede Abweichung:"
# fresh NAME   Kopie des gehärteten Auszugs.
fresh() { rm -rf "${T:?}/$1" && cp -a "$T/a" "$T/$1"; }
# finds NAME ZEILE   pam_pruefen scheitert für NAME und nennt ZEILE (mit $T/NAME für %).
finds() {
	local o
	o=$(pam_pruefen "$T/$1") && return 1
	grep -qxF "${2//%/$T/$1}" <<<"$o"
}
fresh b
sed -i "s/pam_unix.so\$/pam_unix.so nullok/" "$T/b/etc/pam.d/common-auth"
check "nullok wieder in common-auth" 'finds b "nullok in %/etc/pam.d/common-auth"'
fresh c
echo 'auth       sufficient pam_unix.so nullok' >>"$T/c/etc/pam.d/login"
check "nullok in einem anderen Dienst" 'finds c "nullok in %/etc/pam.d/login"'
fresh d
sed -i "s/pam_unix.so try_first_pass/pam_unix.so nullok_secure try_first_pass/" "$T/d/usr/share/pam-configs/unix"
check "nullok_secure in pam-configs/unix" 'finds d "nullok in %/usr/share/pam-configs/unix"'
SU_MSG="su: nach pam_rootok nicht gleich pam_wheel für die Gruppe sudo (%/etc/pam.d/su)"
fresh e
sed -i '/pam_wheel.so use_uid/d' "$T/e/etc/pam.d/su"
check "su ohne pam_wheel" 'finds e "$SU_MSG"'
fresh f
sed -i '/pam_wheel.so use_uid/d; s/^@include common-auth$/@include common-auth\n'"$PAM_WHEEL_LINE"'/' "$T/f/etc/pam.d/su"
check "pam_wheel erst nach common-auth" 'grep -qxF "$PAM_WHEEL_LINE" "$T/f/etc/pam.d/su" && finds f "$SU_MSG"'
fresh g
sed -i 's/pam_wheel.so use_uid group=sudo/pam_wheel.so group=sudo/' "$T/g/etc/pam.d/su"
check "pam_wheel ohne use_uid (prüft sonst den Namen der Anmeldung, nicht lf-claude)" 'finds g "$SU_MSG"'
fresh h
sed -i 's/^auth       sufficient pam_rootok.so$/&\n-auth      sufficient pam_permit.so/' "$T/h/etc/pam.d/su"
check "eine Zeile zwischen pam_rootok und pam_wheel, auch mit -auth" 'finds h "$SU_MSG"'
fresh i
printf '%s\n' '@include common-auth' 'account include su' >"$T/i/etc/pam.d/su-l"
check "su-l ohne su (su - rescue ginge an pam_wheel vorbei)" 'finds i "su-l: auth nicht zuerst aus su (%/etc/pam.d/su-l)"'
fresh j
rm "$T/j/etc/pam.d/su-l"
check "su-l fehlt" 'finds j "su-l: auth nicht zuerst aus su (%/etc/pam.d/su-l)"'
fresh k
printf '%s\n' 'rescue::20413:0:99999:7:::' 'gast::20413:0:99999:7:::' >>"$T/k/etc/shadow"
check "Konten mit leerem Passwort (wie casper sie anlegt)" 'finds k "leeres Passwort: rescue gast"'
fresh l
rm "$T/l/etc/shadow"
check "shadow fehlt" 'finds l "%/etc/shadow nicht lesbar"'
fresh gl
printf '%s\n' 'users:::' 'plugdev:::rescue' >>"$T/gl/etc/gshadow"
check "Gruppen mit leerem Passwort in gshadow" 'finds gl "leeres Passwort für Gruppen: users plugdev"'
fresh gf
rm "$T/gf/etc/gshadow"
check "gshadow fehlt" 'finds gf "%/etc/gshadow nicht lesbar"'
check "kein Ordner pam.d" 'mkdir -p "$T/m" && finds m "kein Ordner %/etc/pam.d"'
image "$T/n"
sed -i '/pam_rootok/d' "$T/n/etc/pam.d/su"
out=$(pam_haerten "$T/n")
rc=$?
check "pam_haerten: su ohne pam_rootok, keine Zeile eingesetzt, Rückgabe 1" '((rc == 1)) && grep -qxF "${SU_MSG//%/$T/n}" <<<"$out" && ! grep -q pam_wheel.so.use_uid "$T/n/etc/pam.d/su"'
image "$T/gh"
printf '%s\n' 'users:::' 'plugdev:::rescue' >>"$T/gh/etc/gshadow"
out=$(pam_haerten "$T/gh")
rc=$?
GS_NEU=$'users:!::\nplugdev:!::rescue'
check "pam_haerten sperrt leere Passwörter in gshadow, die anderen Zeilen bleiben" '((rc == 0)) && [[ -z $out && $(tail -n 2 "$T/gh/etc/gshadow") == "$GS_NEU" && $(head -n 3 "$T/gh/etc/gshadow") == "$(cat "$T/orig/etc/gshadow")" ]]'

echo "Selbsttest (selftest_kein_su aus rescue/lf):"
FN=$(sed -n '/^selftest_kein_su() {$/,/^}$/p' rescue/lf)
eval "$FN"
check "selftest_kein_su aus rescue/lf geladen" '[[ $(type -t selftest_kein_su) == function ]]'
check "er prüft nur die Konfiguration: kein su, keine Anmeldung, nichts als lf-claude" '! grep -qE "selftest_as|timeout|runuser|setpriv|cargo/bin/su| -c true" <<<"$FN"'
PASS="LF-SELFTEST: Anmeldung: kein leeres Passwort, kein nullok, su nur für root und die Gruppe sudo, Passwort von rescue gesperrt"
# live NAME FELD   Kopie des gehärteten Auszugs, dazu rescue mit FELD als Passwort wie nach dem Start.
live() {
	fresh "$1"
	echo "rescue:$2:20413:0:99999:7:::" >>"$T/$1/etc/shadow"
}
live s '!'
out=$(selftest_kein_su "$T/s")
rc=$?
check "gehärtet, Passwort von rescue gesperrt (lf-passwort-sperre): bestanden" '((rc == 0)) && [[ $out == "$PASS" ]]'
live s2 '!$y$j9T$beispiel$beispiel'
out=$(selftest_kein_su "$T/s2")
rc=$?
check "gesperrt mit passwd -l (! vor dem Hash): bestanden" '((rc == 0)) && [[ $out == "$PASS" ]]'
live s3 '$y$j9T$beispiel$beispiel'
out=$(selftest_kein_su "$T/s3")
rc=$?
check "Passwort gesetzt, nicht gesperrt: durchgefallen, mit Grund" '((rc == 1)) && [[ $out == "LF-SELFTEST: Anmeldung: Passwort von rescue nicht gesperrt ($T/s3/etc/shadow)" ]]'
out=$(selftest_kein_su "$T/a")
rc=$?
check "kein Konto rescue: durchgefallen" '((rc == 1)) && [[ $out == "LF-SELFTEST: Anmeldung: Passwort von rescue nicht gefunden ($T/a/etc/shadow)" ]]'
live s4 ''
out=$(selftest_kein_su "$T/s4")
rc=$?
ZWEI="LF-SELFTEST: Anmeldung: leeres Passwort: rescue"$'\n'"LF-SELFTEST: Anmeldung: Passwort von rescue nicht gesperrt ($T/s4/etc/shadow)"
check "leeres Passwort, wie casper es anlegt: durchgefallen, mit beiden Gründen" '((rc == 1)) && [[ $out == "$ZWEI" ]]'
image "$T/alt"
echo 'rescue::20413:0:99999:7:::' >>"$T/alt/etc/shadow"
out=$(selftest_kein_su "$T/alt")
rc=$?
check "Stand vor dem Fix: durchgefallen, alle Gründe genannt" '((rc == 1)) && [[ $(grep -c "^LF-SELFTEST: Anmeldung: " <<<"$out") == 5 && $(wc -l <<<"$out") == 5 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
