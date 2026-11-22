# shellcheck shell=bash
# Persistenter Speicher auf dem Boot-Stick (Partition LF-DATA, LUKS2 + ext4).
# Die ISO wird dafür nicht verändert: Die Partition wird hinter den ISO-Bereich angehängt.
#
# Wer den Speicher stellt, bestimmt die Sitzung: Aus ihm kommen Programme (~/.local/bin), die
# Regeln und Einstellungen für Claude (~/.claude), SSH-Schlüssel und WLAN-Profile. Deshalb gilt:
#   - Der eigene Speicher ist die Partition LF-DATA auf dem Stick, von dem das System läuft,
#     und nur sie. Eine Partition gleichen Namens auf einer anderen Disk wird nie verwendet.
#   - Eingebunden wird er erst, wenn der Techniker ihn in dieser Sitzung freigibt: mit der
#     Passphrase (verschlüsselt) oder mit einem ausdrücklichen Ja (unverschlüsselt).
#   - Aus dem Speicher wird nichts als Shell-Code gelesen. lf.conf ist eine Liste von
#     Einstellungen (persist_config_load).

PERSIST_LABEL="LF-DATA"
# Übergang von firestrike-rescue, gilt eine Beta lang: Ein Speicher mit dem alten Namen gilt
# weiter, unter denselben Regeln wie LF-DATA. Neu angelegt wird nur LF-DATA.
PERSIST_LABEL_OLD="FRS-DATA"
PERSIST_CONFIG_OLD="/etc/lf/frs.conf"
PERSIST_MAPPER="lf-data"
PERSIST_MAPPER_DEV="/dev/mapper/$PERSIST_MAPPER"
PERSIST_CONFIG="/etc/lf/lf.conf"
# Verzeichnisse im Home, die auf die Persistenz zeigen
PERSIST_HOME_DIRS=(.claude .config/Claude .local/share/keyrings .local/share/claude .local/bin .ssh .config/rclone)

# persist_candidates DISK   Partitionen von DISK, die den Namen des Speichers tragen.
# Als children verschachtelt lsblk -J die Partitionen nur mit der Spalte NAME oder mit --tree,
# sonst ist die Liste flach (util-linux 2.41, die ISO). jq sucht deshalb wie persist_foreign in
# allen Geräten, gleich in welcher Form, und nimmt nur Partitionen. Das Dateisystem im
# entsperrten Speicher trägt auch den Namen, liegt aber in einem crypt-Gerät und zählt nicht mit.
persist_candidates() {
	lsblk -J -o PATH,TYPE,PARTLABEL,LABEL "$1" 2>/dev/null |
		jq -r --arg l "$PERSIST_LABEL" --arg o "$PERSIST_LABEL_OLD" '.blockdevices[]? | .. | objects
			| select(.type? == "part")
			| select(.partlabel == $l or .label == $l or .partlabel == $o or .label == $o) | .path'
}

# Die Partition des eigenen Speichers: LF-DATA auf dem Boot-Stick. Ist der Stick nicht sicher
# zu erkennen oder tragen dort mehrere Partitionen den Namen, gibt es keinen Speicher.
persist_find() {
	local bd parts
	boot_medium_unique || return 1
	bd=$(boot_disk 2>/dev/null) || return 1
	mapfile -t parts < <(persist_candidates "$bd")
	((${#parts[@]} == 1)) || return 1
	echo "${parts[0]}"
}

# Partitionen mit dem Namen des Speichers auf anderen Disks als dem Boot-Stick.
persist_foreign() {
	local bd
	bd=$(boot_disk 2>/dev/null || true)
	lsblk -J -o PATH,PKNAME,TYPE,PARTLABEL,LABEL 2>/dev/null |
		jq -r --arg l "$PERSIST_LABEL" --arg o "$PERSIST_LABEL_OLD" --arg bd "$bd" '.blockdevices[] | .. | objects
			| select(.type? == "part") | select(.partlabel == $l or .label == $l or .partlabel == $o or .label == $o)
			| select(("/dev/" + (.pkname // "")) != $bd) | .path'
}

# Sagt einmal je Sitzung, dass eine fremde Partition den Namen des Speichers trägt. Sie wird
# weder eingehängt noch sonst angefasst.
persist_foreign_notice() {
	local list
	list=$(persist_foreign | tr '\n' ' ')
	[[ -n ${list// /} ]] || return 0
	log "Partition mit dem Namen $PERSIST_LABEL auf einer anderen Disk wird nicht verwendet: $list"
	[[ -f $LF_RUN/persist-foreign-told ]] && return 0
	touch "$LF_RUN/persist-foreign-told"
	ui_msg "Persistenter Speicher" "Auf einer anderen Disk liegt eine Partition mit dem Namen $PERSIST_LABEL:\n\n   $list\n\nDer Speicher dieses Rettungssystems liegt nur auf dem Stick, von dem es gestartet wurde. Die Partition wird nicht verwendet und nicht eingehängt.\n\nStammt die Disk aus fremder Hand, ist Vorsicht angebracht. Ist es dein Speicher auf einem anderen Stick, starte von jenem Stick."
}

# Tragen auf dem Stick mehrere Partitionen den Namen des Speichers, nimmt persist_find keine, und
# es wird auch keine weitere angelegt. Das sagt diese Funktion einmal je Sitzung (Rückgabe 0).
# Solche Sticks gibt es aus der Zeit, als der Assistent den Speicher nicht fand und bei jedem
# Start anbot, einen neuen anzulegen.
persist_ambiguous_notice() {
	local bd list
	bd=$(boot_disk 2>/dev/null) || return 1
	list=$(persist_candidates "$bd" | tr '\n' ' ')
	list=${list% }
	(($(wc -w <<<"$list") > 1)) || return 1
	log "Mehrere Partitionen mit dem Namen $PERSIST_LABEL auf dem Stick, keine wird verwendet: $list"
	[[ -f $LF_RUN/persist-ambiguous-told ]] && return 0
	touch "$LF_RUN/persist-ambiguous-told"
	ui_msg "Persistenter Speicher" "Auf dem Stick tragen mehrere Partitionen den Namen $PERSIST_LABEL:\n\n   $list\n\nWelche davon der Speicher ist, lässt sich nicht sicher sagen. Keine wird verwendet, und es wird kein weiterer Speicher angelegt.\n\nAn einem anderen Rechner prüfen, welche die Daten enthält, die anderen löschen und neu starten."
	return 0
}

# Einstellungen, die lf.conf setzen darf, mit dem Muster ihres Wertes. Hier steht nur, was der
# Assistent auch benutzt: LF_TECHNIKER im Rettungsbericht (recover_run), LF_TARGET_FS als
# Vorauswahl beim Formatieren (target_format). Nichts davon startet einen Dienst oder ein Programm.
persist_config_pattern() {
	case $1 in
	LF_TECHNIKER) echo '^[^[:cntrl:]"$`\]{0,100}$' ;;
	LF_TARGET_FS) echo '^(ext4|exfat)$' ;;
	*) return 1 ;;
	esac
}

# persist_config_load DATEI   Liest lf.conf als Daten, nie als Shell-Code.
# Gültig sind Leerzeilen, Kommentare (#) und Zeilen der Form NAME=Wert oder NAME="Wert" für die
# Namen aus persist_config_pattern. Solche Zeilen setzen die gleichnamige Variable. Jede andere
# Zeile wird nicht übernommen, ihre Nummer steht danach in PERSIST_CONFIG_REJECTED.
persist_config_load() {
	local LC_ALL=C file=$1 line key value pattern n=0
	local quoted='^([A-Z_]+)="([^"]*)"$' bare='^([A-Z_]+)=([A-Za-z0-9._-]*)$'
	PERSIST_CONFIG_REJECTED=""
	[[ -f $file && ! -L $file && -r $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		if ((n > 200)); then
			PERSIST_CONFIG_REJECTED+=" ab $n"
			break
		fi
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		[[ -z $line || $line == \#* ]] && continue
		if [[ $line =~ $quoted || $line =~ $bare ]]; then
			key=${BASH_REMATCH[1]}
			value=${BASH_REMATCH[2]}
			# Übergang, eine Beta lang: Die Namen aus der frs.conf gelten als die lf-Namen.
			[[ $key == FRS_* ]] && key=LF_${key#FRS_}
			if pattern=$(persist_config_pattern "$key") && [[ $value =~ $pattern ]]; then
				printf -v "$key" '%s' "$value"
				continue
			fi
		fi
		PERSIST_CONFIG_REJECTED+=" $n"
	done 2>/dev/null <"$file"
	return 0
}

persist_is_open() { mountpoint -q "$LF_PERSIST"; }

# persist_encrypted   Ist der Speicher offen und verschlüsselt (LUKS)? Nur dann merkt sich SSH
#   Fingerabdrücke und Hostschlüssel (#99): Auf einem unverschlüsselten Speicher könnte sie jeder
#   lesen und ändern, der den Stick in der Hand hat.
persist_encrypted() {
	persist_is_open && [[ $(findmnt -n -o SOURCE "$LF_PERSIST" 2>/dev/null | head -n1) == "$PERSIST_MAPPER_DEV" ]]
}

# Persistenz entsperren und einhängen; danach Home-Verzeichnisse umlenken.
persist_open() {
	persist_is_open && return 0
	local dev
	dev=$(persist_find) || return 1
	[[ -z $dev ]] && return 1
	local fsdev=$dev
	if [[ $(sudo blkid -o value -s TYPE "$dev") == crypto_LUKS ]]; then
		if [[ ! -e $PERSIST_MAPPER_DEV ]]; then
			local pw tries=0
			while ((tries < 3)); do
				pw=$(ui_password "Persistenter Speicher" "Passphrase für den persistenten Speicher (Configs, Claude-Login):\n\nAbbrechen = ohne Persistenz weiter") || return 1
				printf '%s' "$pw" | sudo cryptsetup open --key-file - "$dev" "$PERSIST_MAPPER" 2>/dev/null && break
				tries=$((tries + 1))
				ui_msg "Falsche Passphrase" "Entsperren fehlgeschlagen ($tries/3)."
			done
			[[ -e $PERSIST_MAPPER_DEV ]] || return 1
		fi
		fsdev=$PERSIST_MAPPER_DEV
	else
		# Ohne Verschlüsselung gibt es keine Passphrase, die den Speicher als den eigenen ausweist.
		# Er wird deshalb nie ohne Rückfrage eingebunden. Beim Start fragt der Assistent nur einmal.
		[[ ${1:-} == startup && -f $LF_RUN/persist-plain-declined ]] && return 1
		if ! ui_yesno "Speicher nicht verschlüsselt" "Der persistente Speicher auf dem Stick ($dev) ist nicht verschlüsselt.\n\nWer den Stick in der Hand hatte, kann seinen Inhalt verändert haben: Programme unter ~/.local/bin, Regeln und Einstellungen für Claude, SSH-Schlüssel, WLAN-Profile. Der Assistent bindet das alles ein.\n\nWar der Stick immer bei dir? Dann den Speicher verwenden?" --defaultno; then
			touch "$LF_RUN/persist-plain-declined"
			log "Unverschlüsselter Speicher $dev nicht eingebunden (abgelehnt)"
			return 1
		fi
	fi
	sudo install -d "$LF_PERSIST"
	# Im Speicher liegen Programme und Verknüpfungen (~/.local/bin). Gerätedateien und
	# Setuid-Bits braucht er nicht.
	run sudo mount -o noatime,nodev,nosuid "$fsdev" "$LF_PERSIST" || { ui_msg "Persistenz" "Einhängen fehlgeschlagen, siehe Protokoll."; return 1; }
	persist_bind
	log "Persistenz eingehängt: $dev"
	log_init
}

persist_bind() {
	local d
	sudo install -d -o "$(id -u)" -g "$(id -g)" "$LF_PERSIST/home" "$LF_PERSIST/logs" "$LF_PERSIST/config"
	for d in "${PERSIST_HOME_DIRS[@]}"; do
		install -d "$LF_PERSIST/home/$d" "$HOME/$d"
		mountpoint -q "$HOME/$d" || run sudo mount --bind "$LF_PERSIST/home/$d" "$HOME/$d"
	done
	chmod 700 "$HOME/.ssh" 2>/dev/null || true
	persist_bind_claude
	# Ältere Fassungen schrieben den BitLocker-Wiederherstellungsschlüssel ins Protokoll, und
	# Claude las es (GHSA-cwvh-chmr-9xg8). Bevor Claude startet, wird er in seinen Verläufen und
	# Protokollen auf dem Speicher maskiert: als Claude in dessen Home und als Live-Benutzer in den
	# Ordnern aus der Zeit, als Claude als Live-Benutzer lief.
	log_scrub_tree claude_as -- "$CLAUDE_HOME" || true
	log_scrub_tree -- "$LF_PERSIST/home/.claude" "$LF_PERSIST/home/.config/Claude" || true
	# Eigene Konfiguration: /persist/config wird zu /etc/lf
	sudo install -d /etc/lf
	mountpoint -q /etc/lf || run sudo mount --bind "$LF_PERSIST/config" /etc/lf
	# Übergang, eine Beta lang: Ein Speicher von firestrike-rescue hat nur die frs.conf. Sie wird
	# als lf.conf übernommen und bleibt selbst, wie sie ist. Eine Verknüpfung wird nicht übernommen.
	if [[ ! -e $PERSIST_CONFIG && ! -L $PERSIST_CONFIG && -f $PERSIST_CONFIG_OLD && ! -L $PERSIST_CONFIG_OLD ]]; then
		cp -- "$PERSIST_CONFIG_OLD" "$PERSIST_CONFIG" && log "frs.conf als lf.conf übernommen"
	fi
	[[ -f $PERSIST_CONFIG ]] || cat >"$PERSIST_CONFIG" <<-'EOF'
		# Leuchtfeuer – eigene Einstellungen (liegt auf dem persistenten Speicher)
		# Eine Einstellung pro Zeile, NAME=Wert. Die Datei wird als Liste gelesen, nicht als Skript.
		# Firmen- bzw. Technikername, steht im Rettungsbericht (report.txt)
		#LF_TECHNIKER="Vorname Nachname"
		# Vorauswahl beim Formatieren von Ziel-Disks: ext4 oder exfat
		#LF_TARGET_FS=ext4
	EOF
	# WLAN-Profile übernehmen
	if compgen -G "/etc/lf/wifi/*.nmconnection" >/dev/null; then
		sudo install -m 600 /etc/lf/wifi/*.nmconnection /etc/NetworkManager/system-connections/
		run sudo nmcli connection reload
	fi
	# Eigene CLAUDE.md anlegen, falls es noch keine gibt
	claude_as test -f "$CLAUDE_HOME/.claude/CLAUDE.md" ||
		claude_as sh -c 'mkdir -p "$1" && cat >"$1/CLAUDE.md"' lf "$CLAUDE_HOME/.claude" <<-'EOF'
		# Meine Ergänzungen für Claude im Rettungssystem

		Diese Datei liegt auf dem persistenten Speicher des Sticks und wird zusätzlich zu
		/etc/claude-code/CLAUDE.md (Regeln des Rettungssystems) geladen.

		- Antworte auf Deutsch.
	EOF
	# lf.conf wird gelesen, nicht ausgeführt.
	if persist_config_load "$PERSIST_CONFIG" && [[ -n $PERSIST_CONFIG_REJECTED ]]; then
		log "lf.conf: Zeilen nicht übernommen:$PERSIST_CONFIG_REJECTED"
		ui_msg "lf.conf" "Diese Zeilen der lf.conf wurden nicht übernommen:$PERSIST_CONFIG_REJECTED\n\nDie Datei ist eine Liste von Einstellungen und wird nicht als Skript ausgeführt. Erlaubt sind, je eine pro Zeile:\n\n   LF_TECHNIKER=\"Vorname Nachname\"\n   LF_TARGET_FS=ext4 oder exfat\n\nBearbeiten: Werkzeuge > Persistenter Speicher > lf.conf bearbeiten."
	fi
}

# persist_bind_claude   Das Home von Claude ($CLAUDE_HOME) kommt vom Speicher (claude-home).
#   Beim ersten Mal werden ~/.claude, ~/.config/Claude und der Schlüsselbund des Live-Benutzers
#   übernommen: Login (CLI und Desktop) und eigene CLAUDE.md aus der Zeit, als Claude als
#   Live-Benutzer lief. Die aktualisierte CLI lädt Claude neu.
persist_bind_claude() {
	local h=$LF_PERSIST/claude-home d
	if ! sudo test -d "$h"; then
		run sudo install -d -m 700 "$h"
		for d in .claude .config/Claude .local/share/keyrings; do
			[[ -d $LF_PERSIST/home/$d ]] || continue
			run sudo install -d "$h/$(dirname "$d")"
			run sudo cp -a "$LF_PERSIST/home/$d" "$h/$d"
		done
		# -h: Verknüpfungen selbst umschreiben, nie ihr Ziel.
		run sudo chown -R -h "$CLAUDE_USER:$CLAUDE_USER" "$h"
	elif [[ $(sudo stat -c %U "$h" 2>/dev/null) != "$CLAUDE_USER" ]]; then
		# Ein Speicher aus einer älteren Version (Benutzer frs-claude) mit anderer Benutzernummer.
		run sudo chown -R -h "$CLAUDE_USER:$CLAUDE_USER" "$h"
	fi
	mountpoint -q "$CLAUDE_HOME" || run sudo mount --bind "$h" "$CLAUDE_HOME"
}

persist_close() {
	local d
	mountpoint -q "$CLAUDE_HOME" && run sudo umount "$CLAUDE_HOME"
	for ((i = ${#PERSIST_HOME_DIRS[@]} - 1; i >= 0; i--)); do
		d=${PERSIST_HOME_DIRS[i]}
		mountpoint -q "$HOME/$d" && run sudo umount "$HOME/$d"
	done
	mountpoint -q /etc/lf && run sudo umount /etc/lf
	persist_is_open && run sudo umount "$LF_PERSIST"
	[[ -e /dev/mapper/$PERSIST_MAPPER ]] && run sudo cryptsetup close "$PERSIST_MAPPER"
	return 0
}

# Freier Platz hinter der letzten Partition (ISO-Bereich) auf dem Stick in Bytes.
# Die GPT der ISO endet am ISO-Ende, deshalb wird gegen die echte Gerätegröße gerechnet.
persist_free_bytes() {
	local bd=$1 total ss lastend
	total=$(sudo blockdev --getsize64 "$bd")
	ss=$(sudo blockdev --getss "$bd")
	lastend=$(sudo sfdisk -J "$bd" 2>/dev/null | jq '[.partitiontable.partitions[]? | .start + .size] | max // 0')
	echo $((total - lastend * ss - 1048576))
}

# persist_free_number DISK   Die kleinste freie Nummer in der GPT von DISK, laut sgdisk selbst.
persist_free_number() {
	local out used n
	out=$(sudo sgdisk -p "$1" 2>/dev/null) || return 1
	used=$(awk '/^Number +Start/ {t = 1; next} t && $1 ~ /^[0-9]+$/ {print $1}' <<<"$out")
	for ((n = 1; n <= 128; n++)); do
		grep -qx "$n" <<<"$used" || { echo "$n"; return 0; }
	done
	return 1
}

# persist_new_part_ok DISK NUMMER PARTITION   Erst formatieren, wenn PARTITION nicht DISK selbst ist,
#   ihr Eintrag NUMMER in der GPT genau $PERSIST_LABEL heißt und sie dort die einzige Partition mit
#   dem Namen ist.
persist_new_part_ok() {
	local bd=$1 num=$2 part=$3
	[[ $num =~ ^[0-9]+$ && $part != "$bd" ]] || return 1
	[[ $(sudo sgdisk -i "$num" "$bd" 2>/dev/null | sed -n "s/^Partition name: '\(.*\)'\$/\1/p") == "$PERSIST_LABEL" ]] || return 1
	[[ $(persist_candidates "$bd") == "$part" ]]
}

# Der MBR des Sticks (#106): xorriso legt mit --mbr-force-bootable (make_iso in build/build.sh)
# neben dem Schutz-Eintrag einen zweiten Eintrag mit Boot-Flag an, 16 Byte ab Byte 462. Manche
# BIOS starten im Legacy-Modus nur von einer Disk mit aktiver Partition. sgdisk schreibt den
# Schutz-MBR bei jeder Änderung der GPT neu und lässt den Eintrag weg (sgdisk 1.0.10, -e und -n).
PERSIST_MBR_LEER=00000000000000000000000000000000

# persist_mbr_eintrag DISK   Eintrag 2 im MBR von DISK als 32 Hex-Zeichen.
persist_mbr_eintrag() {
	sudo dd if="$1" bs=512 count=1 status=none 2>/dev/null | od -An -v -tx1 -j 462 -N 16 | tr -d ' \n'
}

# persist_mbr_merken DISK   Eintrag 2, wenn er das Boot-Flag trägt, sonst nichts.
persist_mbr_merken() {
	local e
	e=$(persist_mbr_eintrag "$1")
	[[ $e =~ ^80[0-9a-f]{30}$ ]] && echo "$e"
	return 0
}

# persist_mbr_zurueck DISK EINTRAG   Schreibt den gemerkten Eintrag 2 zurück, wenn sgdisk ihn
#   geleert hat. Steht dort etwas anderes, bleibt es, und die Rückgabe ist 1, ebenso, wenn der
#   Eintrag danach nicht dasteht. Ohne gemerkten Eintrag tut es nichts.
persist_mbr_zurueck() {
	local bd=$1 alt=$2 jetzt
	[[ $alt =~ ^80[0-9a-f]{30}$ ]] || return 0
	jetzt=$(persist_mbr_eintrag "$bd")
	[[ $jetzt == "$alt" ]] && return 0
	if [[ $jetzt != "$PERSIST_MBR_LEER" ]]; then
		log "Persistenz: Eintrag 2 im MBR von $bd ist nicht leer (${jetzt:-nicht lesbar}), das Boot-Flag wird nicht zurückgeschrieben"
		return 1
	fi
	printf '%b' "$(sed 's/../\\x&/g' <<<"$alt")" | run sudo dd of="$bd" bs=1 seek=462 count=16 conv=notrunc,fsync status=none
	jetzt=$(persist_mbr_eintrag "$bd")
	if [[ $jetzt != "$alt" ]]; then
		log "Persistenz: Eintrag 2 im MBR von $bd ließ sich nicht zurückschreiben (${jetzt:-nicht lesbar})"
		return 1
	fi
	log "Persistenz: Boot-Flag im MBR von $bd zurückgeschrieben (Eintrag 2)"
}

# persist_mbr_sichern DISK EINTRAG   Wie persist_mbr_zurueck, sagt aber, wenn das nicht ging, einmal
#   je persist_create (mbr_gemeldet ist dort lokal).
persist_mbr_sichern() {
	persist_mbr_zurueck "$1" "$2" && return 0
	((${mbr_gemeldet:-0})) && return 0
	mbr_gemeldet=1
	ui_msg "Persistenz" "Das Boot-Flag im MBR des Sticks ließ sich nicht zurückschreiben (siehe Protokoll). Im Legacy-Modus (BIOS) starten ihn manche Rechner dann nicht mehr, per UEFI startet er wie bisher."
}

persist_create() {
	local bd mbr mbr_gemeldet=0
	bd=$(boot_disk) || { ui_msg "Persistenz" "Der Boot-Stick ist nicht sicher zu erkennen (Start aus dem RAM oder per Ventoy, oder mehrere Disks tragen das Label der ISO)."; return 1; }
	boot_medium_unique || { ui_msg "Persistenz" "Beim Start trug eine weitere Disk die Kennung dieses Sticks. Welche Disk der Stick ist, lässt sich nicht sicher sagen. Es wird kein Speicher angelegt.\n\nFremde Disks abziehen und neu starten."; return 1; }
	if [[ -n $(persist_candidates "$bd") ]]; then
		ui_msg "Persistenz" "Auf dem Stick gibt es schon eine Partition mit dem Namen $PERSIST_LABEL. Eine zweite wird nicht angelegt.\n\nEntsperren: Werkzeuge > Persistenter Speicher > Entsperren und einhängen."
		return 1
	fi
	# sgdisk lässt den Eintrag mit dem Boot-Flag im MBR weg (#106), er kommt danach zurück.
	mbr=$(persist_mbr_merken "$bd")
	sudo sgdisk -e "$bd" >/dev/null 2>&1 || true # Backup-GPT ans echte Ende
	persist_mbr_sichern "$bd" "$mbr"
	local free
	free=$(persist_free_bytes "$bd")
	free=${free:-0}
	if ((free < 536870912)); then
		ui_msg "Persistenz" "Auf dem Stick ist zu wenig freier Platz ($(human "$free")).\nEin Stick ab 8 GB ist empfehlenswert."
		return 1
	fi
	local maxg=$((free / 1073741824)) size
	size=$(ui_menu "Persistenz anlegen" "Auf dem Stick sind $(human "$free") frei.\nWie groß soll der persistente Speicher werden?" -- \
		2 "2 GiB (Configs, CLAUDE.md, Claude-Login) – empfohlen" \
		4 "4 GiB (inkl. Claude-Updates)" \
		8 "8 GiB" \
		max "Ganzer freier Platz ($maxg GiB)") || return 1
	[[ $size == max ]] && size=0
	if [[ $size != 0 ]] && ((size * 1073741824 > free)); then
		ui_msg "Persistenz" "So viel Platz ist nicht frei."
		return 1
	fi
	local crypt=1 pw pw2
	if ui_yesno "Verschlüsselung" "Den Speicher mit einer Passphrase verschlüsseln (LUKS2)?\n\nEmpfohlen: Dort liegen Claude-Login, WLAN-Passwörter und SSH-Schlüssel. Ohne Verschlüsselung kann jeder, der den Stick findet, sie lesen."; then
		while true; do
			pw=$(ui_password "Passphrase" "Neue Passphrase (mind. 8 Zeichen):") || return 1
			pw2=$(ui_password "Passphrase" "Passphrase wiederholen:") || return 1
			[[ $pw == "$pw2" && ${#pw} -ge 8 ]] && break
			ui_msg "Passphrase" "Passphrasen stimmen nicht überein oder sind zu kurz."
		done
	else
		crypt=0
	fi
	ui_info "Persistenz" "Lege Partition an …"
	local sz="0" num part
	[[ $size != 0 ]] && sz="+${size}G"
	# Die Nummer steht vorher fest (#102). Aus der Tabelle danach lässt sie sich nicht sicher lesen:
	# Auch andere Partitionen können LF-DATA im Namen tragen.
	num=$(persist_free_number "$bd") || { ui_msg "Persistenz" "In der Partitionstabelle des Sticks ist keine Nummer frei."; return 1; }
	if ! run sudo sgdisk -n "$num:0:$sz" -t "$num:8300" -c "$num:$PERSIST_LABEL" "$bd"; then
		persist_mbr_sichern "$bd" "$mbr"
		ui_msg "Persistenz" "Partition konnte nicht angelegt werden. Siehe Protokoll."
		return 1
	fi
	persist_mbr_sichern "$bd" "$mbr"
	run sudo partx -a -n "$num" "$bd" || run sudo partx -u "$bd" || true
	sudo udevadm settle
	part=$(part_path "$bd" "$num")
	is_blockdev "$part" || { ui_msg "Persistenz" "Die neue Partition $part ist noch nicht sichtbar. Bitte neu starten, der Speicher wird dann eingerichtet."; return 1; }
	if ! persist_new_part_ok "$bd" "$num" "$part"; then
		log "Persistenz: $part ist nicht sicher die neue Partition $num ($PERSIST_LABEL) auf $bd, nichts formatiert"
		ui_msg "Persistenz" "Die neue Partition $part lässt sich nicht sicher als $PERSIST_LABEL auf dem Stick erkennen. Es wird nichts formatiert.\n\nSiehe Protokoll."
		return 1
	fi
	local fsdev=$part
	if ((crypt)); then
		printf '%s' "$pw" | run sudo cryptsetup luksFormat --batch-mode --type luks2 --label "$PERSIST_LABEL" --key-file - "$part" || return 1
		printf '%s' "$pw" | sudo cryptsetup open --key-file - "$part" "$PERSIST_MAPPER" || return 1
		fsdev=/dev/mapper/$PERSIST_MAPPER
	fi
	run sudo mkfs.ext4 -q -L "$PERSIST_LABEL" "$fsdev" || return 1
	sudo install -d "$LF_PERSIST"
	run sudo mount -o noatime,nodev,nosuid "$fsdev" "$LF_PERSIST" || return 1
	persist_bind
	log_init
	ui_msg "Persistenz" "Persistenter Speicher ist eingerichtet ($(human "$(sudo blockdev --getsize64 "$part")")).\n\nDort liegen ab jetzt:\n - Claude-Login (CLI und Desktop) und ~/.claude/CLAUDE.md\n - /etc/lf/lf.conf und WLAN-Profile (/etc/lf/wifi/)\n - SSH-Schlüssel, rclone-Konfiguration\n - Protokolle (/persist/logs)"
}

# Beim Start: vorhandene Persistenz öffnen oder einmalig das Anlegen anbieten.
persist_startup() {
	persist_foreign_notice
	if [[ -n $(persist_find) ]]; then
		persist_open startup || true
		return 0
	fi
	persist_ambiguous_notice && return 0
	[[ -f $LF_RUN/persist-declined ]] && return 0
	local bd free
	bd=$(boot_disk 2>/dev/null) || return 0
	free=$(persist_free_bytes "$bd")
	if ((${free:-0} >= 536870912)); then
		if ui_yesno "Persistenter Speicher" "Auf dem Stick ist $(human "$free") ungenutzter Platz.\n\nSoll dort ein kleiner persistenter Speicher für Configs, CLAUDE.md und den Claude-Login angelegt werden?\nDie Rettungs-ISO selbst bleibt unverändert."; then
			persist_create || true
		else
			touch "$LF_RUN/persist-declined"
		fi
	fi
}

persist_menu() {
	local c
	c=$(ui_menu "Persistenter Speicher" "Status: $(persist_is_open && echo "eingehängt unter $LF_PERSIST ($(df -h --output=used,size "$LF_PERSIST" | tail -n1 | xargs) belegt)" || echo "nicht eingehängt")" -- \
		open "Entsperren und einhängen" \
		create "Neu anlegen" \
		edit "lf.conf bearbeiten" \
		claudemd "Eigene CLAUDE.md bearbeiten" \
		wifi "Aktuelle WLAN-Verbindungen dauerhaft speichern" \
		close "Aushängen und sperren") || return 0
	case $c in
	open) persist_open || ui_msg "Persistenz" "Kein persistenter Speicher gefunden oder nicht entsperrt." ;;
	create) persist_create ;;
	edit) persist_is_open && sudo nano /etc/lf/lf.conf ;;
	claudemd) persist_is_open && claude_as nano "$CLAUDE_HOME/.claude/CLAUDE.md" ;;
	wifi)
		persist_is_open || return 0
		sudo install -d -m 700 /etc/lf/wifi
		sudo sh -c 'cp /etc/NetworkManager/system-connections/*.nmconnection /etc/lf/wifi/ 2>/dev/null'
		ui_msg "WLAN" "Gespeichert: $(sudo ls /etc/lf/wifi | tr '\n' ' ')"
		;;
	close) persist_close ;;
	esac
}
