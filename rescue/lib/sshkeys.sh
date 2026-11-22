# shellcheck shell=bash
# Eigene SSH-Schlüssel vom Stick (#99).
#
# Wer einen Stick mit Leuchtfeuer hat, legt nach dem Beschreiben seine öffentlichen SSH-Schlüssel in
# die Datei authorized_keys auf der Partition LF-SSH. authorized_keys.txt gilt auch, weil der Editor
# von Windows .txt anhängt. Wer sich damit per SSH anmeldet, ist der Live-Benutzer mit sudo ohne
# Passwort, also root. Deshalb:
#   - Gelesen wird beim Start (sshkeys_load, als root in lf-ssh-schluessel.service), bevor sich
#     jemand anmelden kann, und nur vom geprüften Startmedium: von der Disk, die lf_medium gewählt
#     hat (LF_BOOT_DISKS=1), und nur, wenn dort genau eine Partition LF-SSH liegt. Von fremden Disks
#     und Sticks nie.
#   - LF-SSH wird nur lesend eingehängt (ro,nodev,nosuid,noexec). Gelesen wird nur diese eine Datei,
#     höchstens 64 KiB, dann wird LF-SSH gleich wieder ausgehängt. Leuchtfeuer schreibt nie auf
#     LF-SSH und führt von dort nie etwas aus.
#   - Jede Zeile wird geprüft (sshkeys_check). Was nicht passt, gilt nicht, und tty1 sagt, welche
#     Zeile es war und warum. Aus der Datei steht dort nie mehr als ein gefilterter Kommentar.
#   - Die geprüften Schlüssel liegen nur im RAM, in $SSHKEYS_DIR (gehört root). Erst wenn der Mensch
#     auf tty1 SSH einschaltet und sie bestätigt (sshkeys_confirm), stehen sie in authorized_keys
#     dort, der einzigen Datei, die sshd liest (AuthorizedKeysFile in sshd_config.d/lf.conf). Jeder
#     gilt mit restrict,pty: eine Shell ja, Weiterleitungen nein.

SSHKEYS_LABEL="LF-SSH"
SSHKEYS_DIR=${SSHKEYS_DIR:-/run/lf/ssh}
SSHKEYS_MAX_BYTES=65536
SSHKEYS_MAX_KEYS=20
SSHKEYS_MAX_MSGS=30
SSHKEYS_COMMENT_WIDTH=40
SSHKEYS_MOUNT_OPTS="ro,nodev,nosuid,noexec"
# Mit verschlüsseltem Speicher: bestätigte Fingerabdrücke und die Hostschlüssel (tools_ssh_hostkeys).
# /etc/lf ist dann /persist/config. Der Ordner gehört root, wie /etc/lf/wifi.
SSHKEYS_ETC=${SSHKEYS_ETC:-/etc/lf/ssh}
# Wie sich jemand anmeldet (sshkeys_mode). Bei sshd gilt der erste Wert: Die Datei steht vor lf.conf.
SSHKEYS_MODE_CONF=${SSHKEYS_MODE_CONF:-/etc/ssh/sshd_config.d/00-lf-anmeldung.conf}

# sshkeys_want TYP   Was ssh-keygen -l zu einem erlaubten Typ nennen muss: "NAME BITS". Bei RSA steht
#   statt BITS die Untergrenze mit "+" davor. Status 1 für jeden anderen Typ: kein DSA, keine
#   Zertifikate.
sshkeys_want() {
	case $1 in
	ssh-ed25519) echo "ED25519 256" ;;
	sk-ssh-ed25519@openssh.com) echo "ED25519-SK 256" ;;
	ecdsa-sha2-nistp256) echo "ECDSA 256" ;;
	ecdsa-sha2-nistp384) echo "ECDSA 384" ;;
	ecdsa-sha2-nistp521) echo "ECDSA 521" ;;
	sk-ecdsa-sha2-nistp256@openssh.com) echo "ECDSA-SK 256" ;;
	ssh-rsa) echo "RSA +3072" ;;
	*) return 1 ;;
	esac
}

# sshkeys_msg DATEI TEXT   Eine Meldung für tty1. Nach SSHKEYS_MAX_MSGS kommt nur noch ein Hinweis,
#   dass es weitere gibt: Eine lange Datei voller falscher Zeilen füllt so keinen Dialog.
sshkeys_msg() {
	local n
	n=$(wc -l <"$1" 2>/dev/null) || n=0
	if ((n < SSHKEYS_MAX_MSGS)); then
		printf '%s\n' "$2" >>"$1"
	elif ((n == SSHKEYS_MAX_MSGS)); then
		echo "Weitere Meldungen sind nicht aufgeführt." >>"$1"
	fi
}

# sshkeys_check EINGABE SCHLÜSSEL MELDUNGEN   Prüft EINGABE Zeile für Zeile (Regel 3 in #99).
#   SCHLÜSSEL enthält danach je geltendem Schlüssel eine Zeile "TYP SCHLÜSSEL [KOMMENTAR]", ohne
#   Optionen. An MELDUNGEN wird je Zeile, die nicht gilt, angehängt, welche es war und warum.
#   - Zeilenenden von Windows (CRLF) und ein BOM am Anfang sind in Ordnung, leere Zeilen und
#     Kommentare (#) zählen nicht.
#   - Typen: ssh-ed25519, ecdsa-sha2-nistp256/384/521, ssh-rsa ab 3072 Bit, dazu ed25519 und
#     ecdsa-nistp256 als Sicherheitsschlüssel (sk-…@openssh.com).
#   - Keine Optionen vor dem Schlüssel (command=, from= …). Jeder gilt später mit restrict,pty.
#   - ssh-keygen -l muss die Zeile lesen können und denselben Typ nennen.
#   - Der Kommentar: nur sichtbare Zeichen (text_clean), gekürzt.
#   - Doppelte (gleicher Fingerabdruck) zählen einmal, höchstens SSHKEYS_MAX_KEYS.
#   - Ein privater Schlüssel in der Datei wird nie verwendet, die Meldung rät, ihn zu löschen.
sshkeys_check() {
	local in=$1 keys=$2 msgs=$3 tmp line t k c out bits fp name want n=0 good=0 block="" priv=0 calls=0
	local -A seen=()
	: >"$keys" || return 1
	tmp=$(mktemp) || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		((n == 1)) && line=${line#$'\xef\xbb\xbf'}
		line=${line%$'\r'}
		# Blöcke über mehrere Zeilen: ein privater Schlüssel (PEM, OpenSSH, PuTTY) oder ein
		# öffentlicher im Format RFC 4716. Ihre Zeilen werden einzeln nicht gemeldet.
		case $block in
		pem) [[ $line == -----END* ]] && block=""; continue ;;
		putty) [[ $line == Private-MAC:* ]] && block=""; continue ;;
		rfc4716) [[ $line == "---- END SSH2 PUBLIC KEY ----"* ]] && block=""; continue ;;
		esac
		if [[ $line =~ ^-----BEGIN\ ([A-Z0-9]+\ )*PRIVATE\ KEY----- ]]; then
			sshkeys_msg "$msgs" "Zeile $n: Hier beginnt ein privater Schlüssel. Er wird nie verwendet."
			priv=1 block=pem
			continue
		fi
		if [[ $line == PuTTY-User-Key-File-* ]]; then
			sshkeys_msg "$msgs" "Zeile $n: Hier beginnt ein privater Schlüssel von PuTTY. Er wird nie verwendet."
			priv=1 block=putty
			continue
		fi
		if [[ $line == "---- BEGIN SSH2 PUBLIC KEY ----"* ]]; then
			sshkeys_msg "$msgs" "Zeile $n: Ein Schlüssel im Format RFC 4716 (etwa aus PuTTYgen) gilt nicht. Nötig ist eine Zeile wie in id_ed25519.pub: ssh-ed25519 AAAA… Name"
			block=rfc4716
			continue
		fi
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		read -r t k c <<<"$line"
		if ! want=$(sshkeys_want "$t"); then
			case $t in
			ssh-dss) sshkeys_msg "$msgs" "Zeile $n: DSA (ssh-dss) gilt nicht." ;;
			*-cert-v01@openssh.com) sshkeys_msg "$msgs" "Zeile $n: Zertifikate gelten nicht, nur Schlüssel." ;;
			*=* | *,* | restrict | no-* | cert-authority | pty | agent-forwarding | port-forwarding | user-rc | X11-forwarding | x11-forwarding | touch-required | verify-required)
				sshkeys_msg "$msgs" "Zeile $n: Optionen vor dem Schlüssel gelten nicht. Jeder Schlüssel gilt mit restrict,pty." ;;
			*) sshkeys_msg "$msgs" "Zeile $n: kein Schlüsseltyp, der gilt (ssh-ed25519, ecdsa-sha2-nistp256/384/521, ssh-rsa ab 3072 Bit, auch als Sicherheitsschlüssel)." ;;
			esac
			continue
		fi
		if [[ ! $k =~ ^AAAA[A-Za-z0-9+/]+={0,2}$ ]] || ((${#k} > 8192)); then
			sshkeys_msg "$msgs" "Zeile $n: Nach dem Typ $t fehlt der Schlüssel, oder er ist kein Base64."
			continue
		fi
		if ((good >= SSHKEYS_MAX_KEYS)); then
			sshkeys_msg "$msgs" "Zeile $n: Es gelten höchstens $SSHKEYS_MAX_KEYS Schlüssel. Diese Zeile und alle weiteren gelten nicht."
			break
		fi
		# ssh-keygen höchstens so oft, wie es für die erlaubte Zahl mit Fehlern und Doppelten reicht
		if ((calls >= 3 * SSHKEYS_MAX_KEYS)); then
			sshkeys_msg "$msgs" "Zeile $n: zu viele Zeilen mit Schlüsseln. Diese Zeile und alle weiteren gelten nicht."
			break
		fi
		calls=$((calls + 1))
		printf '%s %s\n' "$t" "$k" >"$tmp"
		if ! out=$(ssh-keygen -l -E sha256 -f "$tmp" 2>/dev/null); then
			sshkeys_msg "$msgs" "Zeile $n: ssh-keygen kann den Schlüssel nicht lesen."
			continue
		fi
		read -r bits fp _ <<<"$out"
		name=${out##*(}
		name=${name%)}
		if [[ ! $bits =~ ^[0-9]+$ || ! $fp =~ ^SHA256:[A-Za-z0-9+/]+$ || $name != "${want%% *}" ]]; then
			sshkeys_msg "$msgs" "Zeile $n: Der Schlüssel passt nicht zum Typ $t."
			continue
		fi
		case ${want#* } in
		+*)
			if ((bits < ${want#* +})); then
				sshkeys_msg "$msgs" "Zeile $n: RSA mit $bits Bit ist zu kurz, nötig sind mindestens ${want#* +}."
				continue
			fi
			;;
		*)
			if [[ $bits != "${want#* }" ]]; then
				sshkeys_msg "$msgs" "Zeile $n: Der Schlüssel passt nicht zum Typ $t."
				continue
			fi
			;;
		esac
		if [[ -n ${seen[$fp]:-} ]]; then
			sshkeys_msg "$msgs" "Zeile $n: derselbe Schlüssel wie in Zeile ${seen[$fp]}. Er zählt einmal."
			continue
		fi
		seen[$fp]=$n
		c=$(printf '%s\n' "$c" | text_clean "$SSHKEYS_COMMENT_WIDTH")
		printf '%s %s%s\n' "$t" "$k" "${c:+ $c}" >>"$keys"
		good=$((good + 1))
	done <"$in" 2>/dev/null
	rm -f "$tmp"
	if ((priv)); then
		# Immer, auch nach SSHKEYS_MAX_MSGS
		echo "Ein privater Schlüssel lag ungeschützt auf dem Stick: Ihn dort löschen und ein neues Schlüsselpaar erzeugen. In die Datei gehört nur der öffentliche Schlüssel, etwa der Inhalt von id_ed25519.pub." >>"$msgs"
	fi
	return 0
}

# sshkeys_private_files ORDNER   Namen im obersten Ordner von LF-SSH, die nach einem privaten
#   Schlüssel aussehen: id_… ohne .pub am Ende, *.ppk von PuTTY. Gelesen wird keine dieser Dateien.
#   Auf FAT ist die Schreibweise beliebig.
sshkeys_private_files() {
	local f b
	for f in "$1"/*; do
		[[ -f $f ]] || continue
		b=${f##*/}
		case ${b,,} in
		*.pub) ;;
		id_* | *.ppk) printf '%s\n' "$b" ;;
		esac
	done
}

# sshkeys_partitions DISK   Partitionen der DISK, deren Dateisystem oder GPT-Eintrag LF-SSH heißt, je
#   Zeile eine. Jede zählt, auch mit anderem Dateisystem: Bei zweien gilt keine.
sshkeys_partitions() {
	lsblk -J -p -o NAME,TYPE,LABEL,PARTLABEL "$1" 2>/dev/null |
		jq -r --arg l "$SSHKEYS_LABEL" '.. | objects | select(.type? == "part" and (.label == $l or .partlabel == $l)) | .name'
}

# sshkeys_status ZUSTAND [ZAHL]   Hält fest, wie das Laden ausging (sshkeys_status_text).
sshkeys_status() { printf '%s\n' "$*" >"$SSHKEYS_DIR/status"; }

# sshkeys_take ORDNER   Mit eingehängtem LF-SSH: kopiert die eine Datei nach $SSHKEYS_DIR/eingang
#   (Zustand "gelesen") und meldet Dateien, die nach einem privaten Schlüssel aussehen.
sshkeys_take() {
	local f b size
	local -a files=()
	for f in "$1/authorized_keys" "$1/authorized_keys.txt"; do
		[[ -f $f && ! -L $f ]] && files+=("$f")
	done
	while IFS= read -r b; do
		sshkeys_msg "$SSHKEYS_DIR/meldungen" "Auf LF-SSH liegt $b, wohl ein privater Schlüssel. Er wird nie verwendet. Ihn dort löschen und ein neues Schlüsselpaar erzeugen: Er lag ungeschützt auf dem Stick."
	done < <(sshkeys_private_files "$1" | text_clean 40)
	case ${#files[@]} in
	0) sshkeys_status keine-datei; return 0 ;;
	2) sshkeys_status zwei-dateien; return 0 ;;
	esac
	if ! size=$(stat -c %s -- "${files[0]}"); then
		sshkeys_status fehler
		return 0
	fi
	if ((size > SSHKEYS_MAX_BYTES)); then
		sshkeys_status zu-gross
		return 0
	fi
	if head -c "$SSHKEYS_MAX_BYTES" -- "${files[0]}" >"$SSHKEYS_DIR/eingang"; then
		sshkeys_status gelesen
	else
		sshkeys_status fehler
	fi
}

# sshkeys_load   Beim Start, als root (lf --ssh-schluessel aus lf-ssh-schluessel.service). Legt in
#   $SSHKEYS_DIR an: status, kandidaten (geprüfte Schlüssel), meldungen (für tty1) und ein leeres
#   authorized_keys. Status 1 nur, wenn der Ordner sich nicht anlegen lässt. In einer Subshell, damit
#   die umask bleibt, wo sie hingehört.
sshkeys_load() (
	local bd n part fs label st mnt=$SSHKEYS_DIR/lf-ssh
	local -a parts=()
	# Der Elternordner (/run/lf) entsteht hier, wenn der Assistent noch nicht lief: lesbar für alle,
	# denn sshd liest authorized_keys als der Benutzer, der sich anmeldet.
	install -d -m 0755 "${SSHKEYS_DIR%/*}" "$SSHKEYS_DIR" || return 1
	umask 077
	rm -f -- "$SSHKEYS_DIR/status" "$SSHKEYS_DIR/eingang"
	: >"$SSHKEYS_DIR/kandidaten"
	: >"$SSHKEYS_DIR/meldungen"
	install -m 0644 /dev/null "$SSHKEYS_DIR/authorized_keys"
	if ! bd=$(boot_disk 2>/dev/null); then
		sshkeys_status kein-medium
		return 0
	fi
	n=$(sed -n 's/^LF_BOOT_DISKS=\([0-9]*\)$/\1/p' "$LF_BOOT_ENV" 2>/dev/null)
	if [[ $n != 1 ]]; then
		sshkeys_status mehrdeutig
		return 0
	fi
	mapfile -t parts < <(sshkeys_partitions "$bd")
	if ((${#parts[@]} != 1)); then
		if ((${#parts[@]})); then sshkeys_status zwei-partitionen; else sshkeys_status keine-partition; fi
		return 0
	fi
	part=${parts[0]}
	fs=$(blkid -p -o value -s TYPE "$part" 2>/dev/null)
	label=$(blkid -p -o value -s LABEL "$part" 2>/dev/null)
	if [[ $fs != vfat || $label != "$SSHKEYS_LABEL" ]]; then
		sshkeys_status kein-fat
		return 0
	fi
	if ! install -d -m 0700 "$mnt" || ! mount -t vfat -o "$SSHKEYS_MOUNT_OPTS,uid=0,gid=0,umask=077" "$part" "$mnt"; then
		sshkeys_status fehler
		rmdir "$mnt" 2>/dev/null
		return 0
	fi
	sshkeys_take "$mnt"
	if ! umount "$mnt"; then
		sshkeys_status fehler
		rm -f -- "$SSHKEYS_DIR/eingang"
		return 0
	fi
	rmdir "$mnt" 2>/dev/null
	st=$(<"$SSHKEYS_DIR/status")
	[[ $st == gelesen ]] || return 0
	sshkeys_check "$SSHKEYS_DIR/eingang" "$SSHKEYS_DIR/kandidaten" "$SSHKEYS_DIR/meldungen"
	rm -f -- "$SSHKEYS_DIR/eingang"
	n=$(wc -l <"$SSHKEYS_DIR/kandidaten")
	if ((n)); then sshkeys_status ok "$n"; else sshkeys_status leer; fi
	return 0
)

# sshkeys_status_text ZUSTAND [ZAHL]   Ein Satz für tty1 und den Selbsttest.
sshkeys_status_text() {
	case $1 in
	ok) if [[ ${2:-} == 1 ]]; then echo "1 Schlüssel von LF-SSH geprüft."; else echo "${2:-?} Schlüssel von LF-SSH geprüft."; fi ;;
	leer) echo "In authorized_keys auf LF-SSH steht kein Schlüssel, der gilt." ;;
	keine-datei) echo "Auf LF-SSH liegt keine Datei authorized_keys." ;;
	keine-partition) echo "Das Startmedium hat keine Partition LF-SSH: Start von CD oder DVD, oder ein Stick aus einer älteren Fassung (dann neu beschreiben, siehe Anleitung)." ;;
	kein-medium) echo "Der Stick ist nicht sicher zu erkennen (Start aus dem RAM oder per Ventoy). Schlüssel von LF-SSH gelten dann nicht." ;;
	mehrdeutig) echo "Beim Start trug mehr als eine Disk die Kennung dieses Sticks. Schlüssel von LF-SSH gelten dann nicht. Fremde Disks und Sticks abziehen und neu starten." ;;
	zwei-partitionen) echo "Auf dem Stick liegen mehrere Partitionen LF-SSH. Es gilt keine." ;;
	kein-fat) echo "Die Partition LF-SSH trägt kein FAT-Dateisystem mit dem Namen LF-SSH. Sie gilt nicht." ;;
	zwei-dateien) echo "Auf LF-SSH liegen authorized_keys und authorized_keys.txt. Es gilt keine der beiden: eine davon löschen." ;;
	zu-gross) echo "authorized_keys auf LF-SSH ist größer als 64 KiB und gilt nicht." ;;
	*) echo "LF-SSH ließ sich nicht lesen (journalctl -u lf-ssh-schluessel)." ;;
	esac
}

# sshkeys_join   Zeilen der Standardeingabe für einen Dialog: getrennt durch "\n".
sshkeys_join() {
	local l out=""
	while IFS= read -r l; do out+="$l\\n"; done
	printf '%s' "${out%\\n}"
}

# sshkeys_notice   Beim Start des Assistenten auf tty1: ein Hinweis, wenn beim Laden etwas nicht
#   stimmte. Ohne Partition, ohne Datei oder ohne sicher erkannten Stick sagt er nichts, solange es
#   keine Meldung gibt: Wer LF-SSH nicht nutzt, sieht davon nichts.
sshkeys_notice() {
	local st msgs tail="\n\nDie Datei an einem vertrauenswürdigen Rechner ändern und neu starten."
	st=$(sudo cat "$SSHKEYS_DIR/status" 2>/dev/null) || return 0
	[[ -n $st ]] || return 0
	msgs=$(sudo cat "$SSHKEYS_DIR/meldungen" 2>/dev/null)
	# Still bleibt es ohne Partition, ohne Datei und ohne Meldung: Dann gilt wie bisher das
	# Einmal-Passwort. Der Rat zur Datei passt nur, wenn sie der Grund ist.
	case ${st%% *} in
	ok | keine-datei) [[ -n $msgs ]] || return 0 ;;
	keine-partition | kein-medium) return 0 ;;
	leer | zwei-dateien | zu-gross) ;;
	*) tail= ;;
	esac
	# shellcheck disable=SC2086
	ui_text "SSH-Schlüssel auf LF-SSH" "$(sshkeys_status_text $st)${msgs:+\n\n$(sshkeys_join <<<"$msgs")}$tail"
}

# sshkeys_mode_text schluessel|passwort   Inhalt von $SSHKEYS_MODE_CONF (Regel 7): Mit Schlüsseln
#   gilt nur ein Schlüssel, ohne nur das Passwort.
sshkeys_mode_text() {
	echo "# Von Werkzeuge > SSH beim Einschalten geschrieben (#99). Bei sshd gilt der erste Wert."
	if [[ $1 == schluessel ]]; then
		printf '%s\n' "PasswordAuthentication no" "AuthenticationMethods publickey"
	else
		printf '%s\n' "PasswordAuthentication yes" "AuthenticationMethods password"
	fi
}

# sshkeys_mode schluessel|passwort   Schreibt $SSHKEYS_MODE_CONF. Ohne Schlüssel ist authorized_keys
#   danach leer.
sshkeys_mode() {
	local tmp rc=0
	tmp=$(mktemp) || return 1
	sshkeys_mode_text "$1" >"$tmp"
	run sudo install -d -m 0755 -o root -g root "$SSHKEYS_DIR" || rc=1
	if [[ $1 != schluessel ]]; then
		run sudo install -m 0644 -o root -g root /dev/null "$SSHKEYS_DIR/authorized_keys" || rc=1
	fi
	run sudo install -m 0644 -o root -g root "$tmp" "$SSHKEYS_MODE_CONF" || rc=1
	rm -f "$tmp"
	return "$rc"
}

# sshkeys_confirm HOSTSCHLÜSSEL   Beim Einschalten von SSH (Regel 6): zeigt die geprüften Schlüssel
#   (Typ, Bits, SHA256-Fingerabdruck, Kommentar) und die Fingerabdrücke der Hostschlüssel und lässt
#   sie bestätigen.
#   - Mit verschlüsseltem Speicher merkt sich der Assistent bestätigte Fingerabdrücke in
#     $SSHKEYS_ETC/bestaetigt. Neue zeigt er einzeln und fragt nach jedem.
#   - Ohne ihn fragt er bei jedem Einschalten einmal für alle.
#   Was gilt, steht danach mit restrict,pty in authorized_keys, und SSHKEYS_ACTIVE nennt es, je
#   Zeile "NAME BITS SHA256:… [KOMMENTAR]". Abgelehnte gelten nicht. Status 1: Es gilt keiner.
sshkeys_confirm() {
	local fps=$1 tmp i t k c bits fp rest name known=""
	local -a keys=() shown=() prints=() acc=() fresh=()
	SSHKEYS_ACTIVE=""
	tmp=$(mktemp -d) || return 1
	sudo cat "$SSHKEYS_DIR/kandidaten" >"$tmp/in" 2>/dev/null
	# Noch einmal nach denselben Regeln: Es gilt nur, was sie jetzt noch erfüllt.
	sshkeys_check "$tmp/in" "$tmp/keys" "$tmp/msgs"
	mapfile -t keys <"$tmp/keys"
	for i in "${!keys[@]}"; do
		read -r t k c <<<"${keys[i]}"
		printf '%s %s\n' "$t" "$k" >"$tmp/one"
		read -r bits fp rest <<<"$(ssh-keygen -l -E sha256 -f "$tmp/one" 2>/dev/null)"
		name=${rest##*(}
		name=${name%)}
		prints[i]=$fp
		shown[i]="$name $bits $fp${c:+ $c}"
	done
	if ((${#keys[@]} == 0)); then
		rm -rf "$tmp"
		return 1
	fi
	if persist_encrypted; then
		known=$(sudo cat "$SSHKEYS_ETC/bestaetigt" 2>/dev/null)
		for i in "${!keys[@]}"; do
			if grep -qxF -- "${prints[i]}" <<<"$known"; then
				acc+=("$i")
			elif ui_yesno "Neuer SSH-Schlüssel" "Auf LF-SSH steht ein Schlüssel, der hier noch nicht bestätigt ist:\n\n   ${shown[i]}\n\nSoll er gelten? Wer den privaten Schlüssel dazu hat, meldet sich per SSH an und hat root.\n\nHostschlüssel dieses Rechners:\n${fps//$'\n'/\\n}" --defaultno; then
				acc+=("$i")
				fresh+=("${prints[i]}")
			fi
		done
	else
		ui_text "SSH-Schlüssel auf LF-SSH" "Diese Schlüssel stehen auf LF-SSH:\n\n$(printf '   %s\n' "${shown[@]}" | sshkeys_join)\n\nHostschlüssel dieses Rechners:\n${fps//$'\n'/\\n}"
		ui_yesno "SSH-Schlüssel" "Sollen die ${#keys[@]} Schlüssel von LF-SSH gelten, bis SSH aus ist? Wer den privaten Schlüssel zu einem davon hat, meldet sich per SSH an und hat root.\n\nOhne verschlüsselten Speicher fragt Leuchtfeuer bei jedem Einschalten. Bei Nein gilt das Einmal-Passwort." --defaultno &&
			acc=("${!keys[@]}")
	fi
	if ((${#acc[@]} == 0)); then
		rm -rf "$tmp"
		return 1
	fi
	: >"$tmp/ak"
	for i in "${acc[@]}"; do
		printf 'restrict,pty %s\n' "${keys[i]}" >>"$tmp/ak"
		SSHKEYS_ACTIVE+="${shown[i]}"$'\n'
	done
	if ! run sudo install -d -m 0755 -o root -g root "$SSHKEYS_DIR" ||
		! run sudo install -m 0644 -o root -g root "$tmp/ak" "$SSHKEYS_DIR/authorized_keys"; then
		SSHKEYS_ACTIVE=""
		rm -rf "$tmp"
		return 1
	fi
	if ((${#fresh[@]})); then
		printf '%s\n' "${fresh[@]}" >"$tmp/neu"
		run sudo install -d -m 0700 -o root -g root "$SSHKEYS_ETC" &&
			sudo tee -a "$SSHKEYS_ETC/bestaetigt" <"$tmp/neu" >/dev/null &&
			run sudo chmod 600 "$SSHKEYS_ETC/bestaetigt"
	fi
	rm -rf "$tmp"
	SSHKEYS_ACTIVE=${SSHKEYS_ACTIVE%$'\n'}
	return 0
}
