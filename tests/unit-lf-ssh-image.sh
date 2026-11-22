#!/usr/bin/env bash
# Unit-Test (#99): die Partition LF-SSH im ISO (build/lf-ssh/partition.sh).
#
# Baut ein kleines ISO mit denselben Angaben für Partitionen und Boot wie make_iso in build.sh, nur
# ohne GRUB, Kernel und squashfs, benennt LF-SSH und prüft es wie build.sh. Der erste Sektor muss
# danach derselbe sein, den xorriso geschrieben hat, mit dem Eintrag mit Boot-Flag für BIOS (#106).
# Ohne xorriso, mtools, mkfs.vfat, sfdisk oder blkid wird das Probe-ISO übersprungen.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck source=build/lf-ssh/partition.sh
. build/lf-ssh/partition.sh
B=build/build.sh
L=build/lf-ssh/LIESMICH.txt

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
# line DATEI TEXT   Erste Zeile mit genau diesem Text
line() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }
# p3start ISO   Startsektor von Partition 3
p3start() { sfdisk -d "$1" 2>/dev/null | awk -v d="$1" '$1 == d "3"' | sed -n 's/.*start= *\([0-9]*\).*/\1/p'; }
# mbr_boot ISO   Byte 462: der Eintrag, den --mbr-force-bootable mit Boot-Flag (80) anlegt
mbr_boot() { od -An -tx1 -j 462 -N 1 "$1" | tr -d ' \n'; }

echo "build.sh:"
l_src=$(line "$B" '. "$SRC/build/lf-ssh/partition.sh"')
l_img=$(line "$B" 'lfssh_image "$WORK/lf-ssh.img" "$SRC/build/lf-ssh/LIESMICH.txt"')
l_efi=$(line "$B" '-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$WORK/efi.img"')
l_app=$(line "$B" '-append_partition "$LFSSH_PART" "$LFSSH_TYPE_XORRISO" "$WORK/lf-ssh.img"')
l_gpt=$(line "$B" '-appended_part_as_gpt')
l_mbr=$(line "$B" 'dd if="$OUT/$ISO_NAME" of="$WORK/mbr-xorriso.bin" bs=512 count=1')
l_name=$(line "$B" 'lfssh_name "$OUT/$ISO_NAME"')
l_check=$(line "$B" 'lfssh_check "$OUT/$ISO_NAME" "$WORK/mbr-xorriso.bin"')
l_sum=$(line "$B" 'sha256sum "$ISO_NAME"')
l_xorriso=$(line "$B" 'xorriso -as mkisofs')
check "liest partition.sh und baut das Image mit LIESMICH.txt" '[[ -n $l_src && -n $l_img ]]'
check "xorriso hängt es als Partition 3 an, nach der EFI-Partition, beide in der GPT" '[[ -n $l_efi && -n $l_app && -n $l_gpt ]] && ((l_xorriso < l_efi && l_efi < l_app && l_app < l_gpt))'
check "nach xorriso: erster Sektor gesichert, benannt, geprüft, dann erst die Prüfsumme" '[[ -n $l_mbr && -n $l_name && -n $l_check && -n $l_sum ]] && ((l_xorriso < l_mbr && l_mbr < l_name && l_name < l_check && l_check < l_sum))'
check "ein Fehler bei Name oder Prüfung bricht den Build ab" 'sed -n "${l_name}p" "$B" | grep -q "|| die " && sed -n "$((l_check - 1)),$((l_check + 2))p" "$B" | grep -q "die "'
check "Typ für xorriso und Typ in der GPT sind derselbe (Basic data)" '[[ $LFSSH_TYPE_XORRISO == a2a0d0ebe5b9334487c068b6b72699c7 && $LFSSH_TYPE_GPT == EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 ]]'

echo "LIESMICH.txt:"
check "kein Schlüsselmaterial, nur ein Platzhalter" '! grep -Eq "AAAA[A-Za-z0-9+/]{8,}|PRIVATE KEY|PuTTY-User-Key" "$L" && grep -qF "ssh-ed25519 AAAA… name@rechner" "$L"'
check "nennt die Datei, nur öffentliche Schlüssel und den vertrauenswürdigen Rechner" 'grep -q "authorized_keys" "$L" && grep -q "ÖFFENTLICHER" "$L" && grep -q "vertrauenswürdigen Rechner" "$L"'

missing=""
for c in xorriso mkfs.vfat mcopy mdir mlabel sfdisk blkid cmp od; do
	command -v "$c" >/dev/null || missing+=" $c"
done
if [[ -n $missing ]]; then
	echo "  übersprungen: Probe-ISO (es fehlt:$missing)"
else
	echo "Probe-ISO:"
	mkdir -p "$T/iso"
	echo probe >"$T/iso/probe.txt"
	head -c 4096 /dev/zero >"$T/iso/eltorito.img"
	head -c 512 /dev/zero >"$T/mbr.bin" # statt boot_hybrid.img von GRUB
	mkfs.vfat -C -n LF_EFI "$T/efi.img" 1024 >/dev/null
	lfssh_image "$T/lf-ssh.img" "$L"
	img_rc=$?
	mcopy -i "$T/lf-ssh.img" ::/LIESMICH.txt "$T/liesmich.txt" 2>/dev/null
	crlf=$(grep -c $'\r$' "$T/liesmich.txt" 2>/dev/null)
	lines=$(wc -l <"$T/liesmich.txt" 2>/dev/null)
	check "Image: FAT mit Label LF-SSH, darin nur LIESMICH.txt" '((img_rc == 0)) && [[ $(blkid -p -o value -s LABEL "$T/lf-ssh.img") == LF-SSH && $(mdir -i "$T/lf-ssh.img" -/ -b ::) == "::/LIESMICH.txt" ]]'
	check "LIESMICH.txt mit Zeilenenden von Windows, sonst unverändert" '[[ -n $lines && $crlf == "$lines" ]] && cmp -s <(tr -d "\r" <"$T/liesmich.txt") "$L"'
	check "Image ist so groß wie LFSSH_KIB" '[[ $(stat -c %s "$T/lf-ssh.img") == $((LFSSH_KIB * 1024)) ]]'

	xorriso -as mkisofs -r -V LEUCHTFEUER -o "$T/probe.iso" -J -joliet-long -l -iso-level 3 \
		--grub2-mbr "$T/mbr.bin" \
		-partition_offset 16 --mbr-force-bootable \
		-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$T/efi.img" \
		-append_partition "$LFSSH_PART" "$LFSSH_TYPE_XORRISO" "$T/lf-ssh.img" \
		-appended_part_as_gpt \
		-iso_mbr_part_type a2a0d0eb-e5b9-3344-87c0-68b6b72699c7 \
		-c boot.catalog \
		-b eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
		-eltorito-alt-boot \
		-e '--interval:appended_partition_2:::' -no-emul-boot \
		"$T/iso" >"$T/xorriso.log" 2>&1
	x_rc=$?
	check "xorriso baut das Probe-ISO" '((x_rc == 0)) || { tail -n 5 "$T/xorriso.log"; false; }'
	dd if="$T/probe.iso" of="$T/mbr-xorriso.bin" bs=512 count=1 status=none
	cp "$T/probe.iso" "$T/ohne-name.iso"
	check "xorriso legt den Eintrag mit Boot-Flag an" '[[ $(mbr_boot "$T/probe.iso") == 80 ]]'

	lfssh_name "$T/probe.iso"
	name_rc=$?
	out=$(lfssh_check "$T/probe.iso" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "benannt und geprüft: keine Abweichung" '((name_rc == 0 && check_rc == 0)) && [[ -z $out ]] || { echo "$out"; false; }'
	check "Partition 3 heißt LF-SSH und ist Basic data" 'sfdisk -d "$T/probe.iso" | awk -v d="$T/probe.iso" '"'"'$1 == d "3"'"'"' | grep -q "type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, .*name=\"LF-SSH\""'
	check "der erste Sektor ist der von xorriso, mit Boot-Flag (#106)" 'cmp -s -n 512 "$T/probe.iso" "$T/mbr-xorriso.bin" && [[ $(mbr_boot "$T/probe.iso") == 80 ]]'
	check "die anderen Partitionen bleiben, wie xorriso sie anlegt" '[[ $(sfdisk -d "$T/probe.iso" | grep -c "name=\"ISO9660\"\|name=\"Appended2\"\|name=\"Gap1\"") == 3 ]]'
	off=$(($(p3start "$T/probe.iso") * 512))
	check "blkid findet in Partition 3 FAT mit dem Label LF-SSH" '((off > 0)) && [[ $(blkid -p -O "$off" -o value -s TYPE "$T/probe.iso") == vfat && $(blkid -p -O "$off" -o value -s LABEL "$T/probe.iso") == LF-SSH ]]'

	echo "Bauprüfung findet Abweichungen:"
	out=$(lfssh_check "$T/ohne-name.iso" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "ohne Namen" '((check_rc == 1)) && grep -q "Name Appended3 statt LF-SSH" <<<"$out"'
	cp "$T/probe.iso" "$T/mbr.iso"
	printf '\0' | dd of="$T/mbr.iso" bs=1 seek=462 conv=notrunc status=none
	out=$(lfssh_check "$T/mbr.iso" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "ein geänderter erster Sektor (Boot-Flag weg)" '((check_rc == 1)) && grep -q "erste Sektor" <<<"$out"'
	cp "$T/probe.iso" "$T/datei.iso"
	echo x >"$T/x.txt"
	mcopy -i "$T/datei.iso@@$off" "$T/x.txt" ::/authorized_keys
	out=$(lfssh_check "$T/datei.iso" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "eine weitere Datei auf LF-SSH" '((check_rc == 1)) && grep -q "Inhalt .*authorized_keys" <<<"$out"'
	cp "$T/probe.iso" "$T/label.iso"
	mlabel -i "$T/label.iso@@$off" ::ANDERS
	out=$(lfssh_check "$T/label.iso" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "ein anderes Label" '((check_rc == 1)) && grep -q "Label ANDERS" <<<"$out"'
	cp "$T/probe.iso" "$T/ziffer9"
	out=$(lfssh_check "$T/ziffer9" "$T/mbr-xorriso.bin")
	check_rc=$?
	check "ein Dateiname mit Ziffer am Ende (sfdisk nennt die Partition dann …p3)" '((check_rc == 0)) || { echo "$out"; false; }'
fi

((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
