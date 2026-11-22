# shellcheck shell=bash
# Anmeldung im Rettungssystem: Ein leeres Passwort gilt nie, und su wechselt für lf-claude zu
# keinem anderen Benutzer (GHSA-j332-2v26-m4qm).
#
# casper legt den Live-Benutzer beim Boot ohne Passwort an (passwd -d), und er hat sudo ohne
# Passwort. Nähme PAM das leere Passwort an (nullok), würde jeder Benutzer mit su zum
# Live-Benutzer und damit root, auch lf-claude ohne Freigabe. Deshalb, jedes für sich:
#   - lf-passwort-sperre.service sperrt das Passwort bei jedem Start, vor jeder Anmeldung. Die
#     Konsolen melden den Live-Benutzer ohne Passwort an (getty@.service.d/autologin.conf), sudo
#     fragt ihn nicht danach, und SSH setzt beim Einschalten ein Einmal-Passwort.
#   - Kein nullok: Ein leeres Passwort gilt für keinen Dienst. Auch nicht in
#     /usr/share/pam-configs/unix, denn daraus schreibt pam-auth-update common-auth neu.
#   - su erlaubt den Wechsel nur root und der Gruppe sudo (pam_wheel mit use_uid, gleich nach
#     pam_rootok), also nie lf-claude, egal welches Passwort ein Konto hat.
#   - Auch in gshadow ist kein Passwort leer (newgrp, sg).
# pam_haerten richtet das beim Bau ein (chroot-setup.sh). pam_pruefen prüft es beim Bau vor dem
# squashfs (build.sh) und im laufenden System (Selbsttest), pam_gesperrt dort zusätzlich, dass das
# Passwort des Live-Benutzers gesperrt ist.

PAM_WHEEL_LINE='auth       requisite  pam_wheel.so use_uid group=sudo'

# pam_haerten WURZEL   Entfernt nullok aus PAM unter WURZEL, setzt pam_wheel gleich nach
#   pam_rootok in su ein und sperrt leere Passwörter in gshadow, dann pam_pruefen. Ein zweiter
#   Aufruf ändert nichts mehr.
pam_haerten() {
	local root=${1%/} f
	local -a files=()
	for f in "$root"/etc/pam.d/* "$root"/usr/share/pam-configs/*; do
		if [[ -f $f ]] && grep -qE '^[^#]*nullok' "$f"; then files+=("$f"); fi
	done
	if ((${#files[@]})); then sed -i -E '/^[[:space:]]*#/!s/[[:space:]]+nullok\b//g' "${files[@]}"; fi
	if [[ -f $root/etc/pam.d/su ]] && ! grep -qxF "$PAM_WHEEL_LINE" "$root/etc/pam.d/su"; then
		sed -i "/^auth[[:space:]]\+sufficient[[:space:]]\+pam_rootok\.so[[:space:]]*\$/a $PAM_WHEEL_LINE" "$root/etc/pam.d/su"
	fi
	if [[ -f $root/etc/gshadow ]] && grep -qE '^[^:]+::' "$root/etc/gshadow"; then
		sed -i -E 's/^([^:]+)::/\1:!:/' "$root/etc/gshadow"
	fi
	pam_pruefen "$root"
}

# pam_auth FILE   Die Zeilen für auth in FILE (auch @include), mit einfachen Leerzeichen.
pam_auth() {
	awk '!/^[[:space:]]*#/ && ($1 == "auth" || $1 == "-auth" || $1 == "@include") {$1 = $1; print}' "$1"
}

# pam_pruefen WURZEL   Nennt jede Abweichung unter WURZEL in einer Zeile, Rückgabe 1, wenn es
#   eine gibt: nullok in PAM, su ohne pam_wheel gleich nach pam_rootok, su-l nicht über su, ein
#   Konto oder eine Gruppe mit leerem Passwort.
pam_pruefen() {
	local root=${1%/} f bad=0 leer
	local -a auth=()
	if [[ ! -d $root/etc/pam.d ]]; then
		echo "kein Ordner $root/etc/pam.d"
		return 1
	fi
	for f in "$root"/etc/pam.d/* "$root"/usr/share/pam-configs/*; do
		if [[ -f $f ]] && grep -qE '^[^#]*nullok' "$f"; then
			echo "nullok in $f"
			bad=1
		fi
	done
	[[ -f $root/etc/pam.d/su ]] && mapfile -t auth < <(pam_auth "$root/etc/pam.d/su")
	if [[ ${auth[0]:-} != "auth sufficient pam_rootok.so" || ${auth[1]:-} != "auth requisite pam_wheel.so use_uid group=sudo" ]]; then
		echo "su: nach pam_rootok nicht gleich pam_wheel für die Gruppe sudo ($root/etc/pam.d/su)"
		bad=1
	fi
	if [[ ! -f $root/etc/pam.d/su-l || $(pam_auth "$root/etc/pam.d/su-l" | head -n1) != "auth include su" ]]; then
		echo "su-l: auth nicht zuerst aus su ($root/etc/pam.d/su-l)"
		bad=1
	fi
	for f in shadow gshadow; do
		if [[ ! -f $root/etc/$f ]] || ! leer=$(awk -F: 'NF > 1 && $2 == "" {printf "%s%s", s, $1; s = " "}' "$root/etc/$f"); then
			echo "$root/etc/$f nicht lesbar"
			bad=1
		elif [[ -n $leer && $f == shadow ]]; then
			echo "leeres Passwort: $leer"
			bad=1
		elif [[ -n $leer ]]; then
			echo "leeres Passwort für Gruppen: $leer"
			bad=1
		fi
	done
	((bad == 0))
}

# pam_gesperrt WURZEL BENUTZER   Das Passwort von BENUTZER unter WURZEL ist gesperrt, beginnt also
#   mit ! oder * (usermod --password '!', passwd -l). Sonst eine Zeile mit dem Grund, Rückgabe 1.
pam_gesperrt() {
	local root=${1%/} pw
	if ! pw=$(awk -F: -v u="$2" '$1 == u {print $2; f = 1; exit} END {exit !f}' "$root/etc/shadow" 2>/dev/null); then
		echo "Passwort von $2 nicht gefunden ($root/etc/shadow)"
		return 1
	fi
	[[ $pw == '!'* || $pw == '*'* ]] && return 0
	echo "Passwort von $2 nicht gesperrt ($root/etc/shadow)"
	return 1
}
