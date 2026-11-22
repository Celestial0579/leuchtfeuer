# shellcheck shell=bash
# Die Partition LF-SSH im Image (#99), für build.sh und tests/unit-lf-ssh-image.sh.
#
# Eine kleine FAT-Partition vom Typ „Basic data“, Partition und Dateisystem heißen LF-SSH. Nach dem
# Beschreiben mit Rufus (DD-Modus), balenaEtcher oder dd erscheint sie unter Windows, macOS und Linux
# als Laufwerk. Der Besitzer des Sticks legt dort seine öffentlichen SSH-Schlüssel ab
# (rescue/lib/sshkeys.sh). Im ISO ist sie leer bis auf LIESMICH.txt. Am Start ändert sie nichts: Der
# Stub von GRUB nimmt das ISO-Dateisystem nur über dessen UUID (build/grub/esp.cfg).

LFSSH_LABEL="LF-SSH"
LFSSH_KIB=4096
LFSSH_PART=3
# GPT-Typ „Basic data“ (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7) in der Bytefolge, die
# xorriso -append_partition erwartet
LFSSH_TYPE_XORRISO="a2a0d0ebe5b9334487c068b6b72699c7"
LFSSH_TYPE_GPT="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

# lfssh_image DATEI LIESMICH   Das FAT-Image: Label LF-SSH, darin nur LIESMICH.txt mit Zeilenenden
#   von Windows.
lfssh_image() {
	local img=$1 txt rc=0
	rm -f "$img"
	mkfs.vfat -C -n "$LFSSH_LABEL" "$img" "$LFSSH_KIB" >/dev/null || return 1
	txt=$(mktemp) || return 1
	if ! sed 's/\r*$/\r/' "$2" >"$txt" || ! mcopy -i "$img" "$txt" ::/LIESMICH.txt; then
		rc=1
	fi
	rm -f "$txt"
	return "$rc"
}

# lfssh_name ISO   xorriso nennt die angehängte Partition „Appended3“, ihr GPT-Eintrag soll LF-SSH
#   heißen. sfdisk schreibt dabei auch den Schutz-MBR neu und löscht den Eintrag mit Boot-Flag, den
#   --mbr-force-bootable für BIOS anlegt, die nur von einer Disk mit aktiver Partition starten
#   (#106). Der erste Sektor bleibt deshalb, wie xorriso ihn geschrieben hat.
lfssh_name() {
	local iso=$1 mbr rc=0
	mbr=$(mktemp) || return 1
	if ! dd if="$iso" of="$mbr" bs=512 count=1 status=none ||
		! sfdisk --no-reread --no-tell-kernel --part-label "$iso" "$LFSSH_PART" "$LFSSH_LABEL" >/dev/null 2>&1 ||
		! dd if="$mbr" of="$iso" bs=512 count=1 conv=notrunc status=none; then
		rc=1
	fi
	rm -f "$mbr"
	return "$rc"
}

# lfssh_check ISO MBR   Bauprüfung, MBR ist eine Datei mit dem ersten Sektor, wie xorriso ihn
#   geschrieben hat. Nennt jede Abweichung, Status 1 bei einer:
#   - Partition 3 ist „Basic data“, heißt LF-SSH und ist LFSSH_KIB groß,
#   - darin FAT mit dem Label LF-SSH, darin nur LIESMICH.txt,
#   - sfdisk --verify findet keinen Fehler,
#   - der erste Sektor ist unverändert.
lfssh_check() {
	local iso=$1 mbr=$2 line start size type name fs label files bad=0
	# sfdisk -d nennt die Partition ISO3, bei einem Namen mit Ziffer am Ende ISOp3
	line=$(sfdisk -d "$iso" 2>/dev/null | awk -v d="$iso" -v n="$LFSSH_PART" '$1 == d n || $1 == d "p" n')
	if [[ -z $line ]]; then
		echo "keine Partition $LFSSH_PART in $iso"
		return 1
	fi
	start=$(sed -n 's/.*start= *\([0-9]*\).*/\1/p' <<<"$line")
	size=$(sed -n 's/.*size= *\([0-9]*\).*/\1/p' <<<"$line")
	type=$(sed -n 's/.*type=\([0-9A-Fa-f-]*\).*/\1/p' <<<"$line")
	name=$(sed -n 's/.*name="\([^"]*\)".*/\1/p' <<<"$line")
	if [[ ${type^^} != "$LFSSH_TYPE_GPT" ]]; then
		echo "Partition $LFSSH_PART: Typ ${type:-?} statt Basic data"
		bad=1
	fi
	if [[ $name != "$LFSSH_LABEL" ]]; then
		echo "Partition $LFSSH_PART: Name ${name:-?} statt $LFSSH_LABEL"
		bad=1
	fi
	if [[ $size != $((LFSSH_KIB * 2)) ]]; then
		echo "Partition $LFSSH_PART: ${size:-?} Sektoren statt $((LFSSH_KIB * 2))"
		bad=1
	fi
	if [[ -n $start ]]; then
		fs=$(blkid -p -O $((start * 512)) -o value -s TYPE "$iso" 2>/dev/null)
		label=$(blkid -p -O $((start * 512)) -o value -s LABEL "$iso" 2>/dev/null)
		if [[ $fs != vfat || $label != "$LFSSH_LABEL" ]]; then
			echo "Partition $LFSSH_PART: Dateisystem ${fs:-?} mit Label ${label:-?} statt vfat mit $LFSSH_LABEL"
			bad=1
		fi
		files=$(mdir -i "$iso@@$((start * 512))" -/ -b :: 2>/dev/null)
		if [[ $files != "::/LIESMICH.txt" ]]; then
			echo "Partition $LFSSH_PART: Inhalt ${files//$'\n'/, } statt nur ::/LIESMICH.txt"
			bad=1
		fi
	fi
	if ! sfdisk --verify "$iso" >/dev/null 2>&1; then
		echo "sfdisk --verify findet einen Fehler in der Partitionstabelle"
		bad=1
	fi
	if ! cmp -s -n 512 "$iso" "$mbr"; then
		echo "Der erste Sektor (MBR) ist nicht mehr der von xorriso"
		bad=1
	fi
	((bad == 0))
}
