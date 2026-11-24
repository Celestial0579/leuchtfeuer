# shellcheck shell=bash
# Die Partition LF-SSH im Image (#99) und der GPT-Typ der Partition mit dem ISO-Dateisystem (#110),
# für build.sh und tests/unit-lf-ssh-image.sh.
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

# GPT-Typ von Partition 1 mit dem ISO-Dateisystem (#110): „Linux filesystem data“
# (0FC63DAF-8483-4772-8E79-3D69D8477DE4), für xorriso -iso_mbr_part_type in derselben Bytefolge wie
# oben. Windows vergibt Laufwerksbuchstaben nur an Partitionen vom Typ „Basic data“ und lässt diese
# Partition deshalb aus. Am Start ändert der Typ nichts: GRUB und die initrd (lf_medium) finden das
# ISO-Dateisystem über dessen UUID.
ISO_TYPE_XORRISO="af3dc60f838472478e793d69d8477de4"
ISO_TYPE_GPT="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

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
#   (#106). Der erste Sektor bleibt deshalb, wie xorriso ihn geschrieben hat. Die Warnungen von
#   sfdisk (Hybrid-MBR, Größe im Schutz-MBR) kommen nur, wenn es fehlschlägt, dann auf stderr.
lfssh_name() {
	local iso=$1 mbr err rc=0
	mbr=$(mktemp) || return 1
	err=$(mktemp) || { rm -f "$mbr"; return 1; }
	if ! dd if="$iso" of="$mbr" bs=512 count=1 status=none; then
		rc=1
	elif ! sfdisk --no-reread --no-tell-kernel --part-label "$iso" "$LFSSH_PART" "$LFSSH_LABEL" >/dev/null 2>"$err"; then
		cat "$err" >&2
		rc=1
	elif ! dd if="$mbr" of="$iso" bs=512 count=1 conv=notrunc status=none; then
		rc=1
	fi
	rm -f "$mbr" "$err"
	return "$rc"
}

# lfssh_check ISO MBR   Bauprüfung, MBR ist eine Datei mit dem ersten Sektor, wie xorriso ihn
#   geschrieben hat. Nennt jede Abweichung, Status 1 bei einer:
#   - Partition 1 hat den Typ ISO_TYPE_GPT, und es gibt nur die Partitionen 1 bis 3 (#110),
#   - Partition 3 ist „Basic data“, heißt LF-SSH und ist LFSSH_KIB groß,
#   - darin FAT mit dem Label LF-SSH, darin nur LIESMICH.txt,
#   - sfdisk --verify findet keinen Fehler,
#   - der erste Sektor ist unverändert.
lfssh_check() {
	local iso=$1 mbr=$2 dump line start size type type1 n names name fs label files bad=0
	dump=$(sfdisk -d "$iso" 2>/dev/null)
	# sfdisk -d nennt die Partition ISO3, bei einem Namen mit Ziffer am Ende ISOp3
	line=$(awk -v d="$iso" -v n="$LFSSH_PART" '$1 == d n || $1 == d "p" n' <<<"$dump")
	if [[ -z $line ]]; then
		echo "keine Partition $LFSSH_PART in $iso"
		return 1
	fi
	type1=$(awk -v d="$iso" '$1 == d "1" || $1 == d "p1"' <<<"$dump" | sed -n 's/.*type=\([0-9A-Fa-f-]*\).*/\1/p')
	if [[ ${type1^^} != "$ISO_TYPE_GPT" ]]; then
		echo "Partition 1: Typ ${type1:-?} statt Linux filesystem data"
		bad=1
	fi
	# Ohne -no-pad trägt xorriso seine Polsterung als weitere Partition Gap1 ein
	n=$(grep -c ' : start=' <<<"$dump")
	if [[ $n != "$LFSSH_PART" ]]; then
		names=$(sed -n 's/.* : start=.*name="\([^"]*\)".*/\1/p' <<<"$dump" | tr '\n' ' ')
		echo "$n Partitionen statt $LFSSH_PART: ${names% }"
		bad=1
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
