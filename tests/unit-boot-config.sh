#!/usr/bin/env bash
# Unit-Test: Beim Booten wird kein fremder Datenträger durchsucht, eingehängt oder gestartet.
#
# Die README sagt: "Fremde Disks werden nie automatisch eingehängt." Beim Start gilt das nur mit
# diesen Einstellungen zusammen:
#   - GRUB (UEFI): Auf der EFI-Partition liegt /boot/grub mit einem Start-Stub. Sonst durchsucht
#     der signierte GRUB von Ubuntu alle Disks nach /.disk/info und lädt die erste grub.cfg, die
#     er findet. Der Stub nimmt das ISO-Dateisystem nur von derselben Disk, über seine UUID.
#   - Die UUID setzt der Build für jede ISO neu (xorriso --modification-date).
#   - initrd: casper-premount/lf_medium wählt das Gerät mit dieser UUID, prüft die SHA-256-Summe
#     des squashfs und hängt es unter /run/lf-medium ein. Nur dieses Verzeichnis nennt das
#     Bootmenü (live-media=/run/lf-medium). Die Summe kommt nach dem squashfs in die initrd.
#   - LIVEMEDIA_TIMEOUT in /etc/casper.conf verhindert, dass casper alle Blockgeräte durchsucht.
# Dazu steht der Countdown im Bootmenü lesbar unter dem Balken, nicht darin (#127).
# Der Test prüft, dass der Build all das tut. Ob es in der gebauten ISO wirkt, prüfen der
# Selbsttest der ISO (selftest_boot) und die Boot-Tests (tests/qemu-smoke.sh, mit fremder Disk).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

SETUP=build/chroot-setup.sh
BUILD=build/build.sh
GRUB=build/grub/grub.cfg
STUB=build/grub/esp.cfg
PREMOUNT=build/overlay/etc/initramfs-tools/scripts/casper-premount/lf_medium
HOOK=build/overlay/etc/initramfs-tools/hooks/lf-medium

echo "casper sucht nicht über alle Geräte:"
conf=$(sed -n "/^cat >\/etc\/casper.conf <<'EOF'\$/,/^EOF\$/p" "$SETUP")
check "der Build schreibt /etc/casper.conf" '[[ -n $conf ]]'
check "darin steht LIVEMEDIA_TIMEOUT" 'grep -Eq "^export LIVEMEDIA_TIMEOUT=[0-9]+\$" <<<"$conf"'
t=$(sed -n 's/^export LIVEMEDIA_TIMEOUT=\([0-9]*\)$/\1/p' <<<"$conf")
check "der Wert liegt über den 60 Sekunden, die casper sucht: Die Suche über alle Geräte beginnt nie" '[[ ${t:-0} -gt 60 ]]'
line_conf=$(grep -n "^cat >/etc/casper.conf" "$SETUP" | cut -d: -f1)
line_init=$(grep -n "^update-initramfs " "$SETUP" | tail -n 1 | cut -d: -f1)
check "die initrd wird danach gebaut, die Datei kommt also hinein" '[[ -n $line_conf && -n $line_init && $line_conf -lt $line_init ]]'

echo "Jeder Eintrag des Bootmenüs nimmt nur das geprüfte Medium:"
args=$(sed -n 's/^set lf_args="\(.*\)"$/\1/p' "$GRUB")
check "die gemeinsamen Kernelparameter nennen live-media=/run/lf-medium" '[[ " $args " == *" live-media=/run/lf-medium "* ]]'
check "kein Label und kein Gerät als live-media" '! grep -q "live-media=/dev/" "$GRUB"'
check "kein Swap von fremden Disks, keine Prüfläufe auf fremden Dateisystemen" '[[ " $args " == *" noswap "* && " $args " == *" systemd.swap=0 "* && " $args " == *" fsck.mode=skip "* ]]'
n=$(grep -c '^[[:space:]]*linux /casper/vmlinuz ' "$GRUB")
with=$(grep -c '^[[:space:]]*linux /casper/vmlinuz \$lf_args ' "$GRUB")
check "alle $n Einträge, die das Rettungssystem starten, benutzen diese Parameter" '[[ $n -ge 3 && $n == "$with" ]]'
check "der Boot-Test der CI startet mit demselben Medium" 'grep -q "live-media=/run/lf-medium" tests/qemu-smoke.sh && ! grep -q "live-media=/dev/" tests/qemu-smoke.sh'

echo "GRUB durchsucht keine anderen Disks (Start-Stub auf der EFI-Partition):"
check "der Stub liegt im Repository" '[[ -f $STUB ]]'
check "er wählt das ISO-Dateisystem über die UUID dieser ISO" 'grep -q "^set lf_uuid=\"@ISO_UUID@\"$" "$STUB" && grep -q "probe --set=lf_u --fs-uuid" "$STUB"'
check "er sucht nur auf derselben Disk, nie mit search" '! grep -Eq "^[[:space:]]*search( |$)" "$STUB" && grep -q "regexp --set=1:lf_disk" "$STUB"'
check "findet er das Medium nicht, startet nichts" 'sed -n "/^else$/,/^fi$/p" "$STUB" | grep -q "^[[:space:]]*exit$" && ! sed -n "/^else$/,/^fi$/p" "$STUB" | grep -q configfile'
if command -v grub-script-check >/dev/null; then
	check "der Stub ist gültiges GRUB-Skript" 'grub-script-check "$STUB"'
	check "das Bootmenü ist gültiges GRUB-Skript" 'grub-script-check "$GRUB"'
fi
check "der Build legt ihn auf der EFI-Partition unter /boot/grub ab, wo GRUB zuerst schaut" 'grep -q "mmd -i \"\$efi\" ::/boot ::/boot/grub ::/boot/grub/x86_64-efi" "$BUILD" && grep -q "::/boot/grub/grub.cfg" "$BUILD" && grep -q "::/boot/grub/x86_64-efi/grub.cfg" "$BUILD"'
check "der Build setzt die UUID in den Stub ein" 'grep -q "s/@ISO_UUID@/\$ISO_UUID/g\" \"\$SRC/build/grub/esp.cfg\"" "$BUILD"'

echo "Die UUID der ISO ist je Build fest:"
check "xorriso bekommt das Änderungsdatum, aus dem die UUID folgt" 'grep -q -- "--modification-date=\"\$ISO_DATE\"" "$BUILD"'
# Dieselbe Rechnung wie im Build, mit einem festen Datum.
ISO_DATE=2026111510024400
eval "$(grep '^ISO_UUID=' "$BUILD")"
check "die UUID hat die Form, die blkid und GRUB für ISO-Dateisysteme melden" '[[ $ISO_UUID == 2026-11-15-10-02-44-00 ]]'

echo "Die initrd prüft das Medium, bevor casper es benutzt:"
check "lf_medium liegt unter casper-premount und ist ausführbar" '[[ -x $PREMOUNT ]]'
check "der Hook bringt blkid, sha256sum und isofs in die initrd" '[[ -x $HOOK ]] && grep -q "copy_exec /sbin/blkid" "$HOOK" && grep -q "copy_exec /usr/bin/sha256sum" "$HOOK" && grep -q "manual_add_modules isofs" "$HOOK"'
check "die Dateien kommen über das Overlay vor update-initramfs ins chroot" 'grep -q "cp -a --no-preserve=ownership \"\$SRC/build/overlay/.\" \"\$CHROOT/\"" "$BUILD"'
l_sum=$(grep -n 'sha256sum "$ISO/casper/filesystem.squashfs"' "$BUILD" | cut -d: -f1)
l_sq=$(grep -n '^	mksquashfs ' "$BUILD" | cut -d: -f1)
l_iso=$(grep -n '^	xorriso -as mkisofs' "$BUILD" | cut -d: -f1)
check "die Prüfsumme wird nach dem squashfs und vor der ISO berechnet" '[[ -n $l_sum && $l_sq -lt $l_sum && $l_sum -lt $l_iso ]]'
check "UUID und Prüfsumme kommen als cpio-Archiv vor die initrd" 'grep -q "cat \"\$WORK/lf-medium.cpio\" \"\$ISO/casper/initrd\"" "$BUILD"'

echo "Der Selbsttest prüft die initrd und das gewählte Medium des gebauten Systems:"
check "selftest_boot läuft im Selbsttest" 'grep -q "selftest_boot \"\$dir\" || ok=0" rescue/lf'
check "der Boot-Test der CI startet mit einer fremden Disk, die sich als Stick ausgibt" 'grep -q "^foreign() {" tests/qemu-smoke.sh && grep -q "uefi-usb" .github/workflows/build.yml'

echo "Bootmenü: Der Countdown steht lesbar unter dem Balken (#127):"
THEME=build/grub/theme/theme.txt
# komponente TYP   Die Zeilen der Komponente TYP mit der id __timeout__, ohne Einrückung.
komponente() {
	awk -v t="+ $1 {" '$0 == t { b = ""; drin = 1; next }
		drin && /^}/ { if (b ~ /id = "__timeout__"/) printf "%s", b; drin = 0; next }
		drin { sub(/^\t/, ""); b = b $0 "\n" }' "$THEME"
}
# wert NAME TEXT   Der Wert von NAME in den Zeilen TEXT, ohne Anführungszeichen.
wert() { sed -n "s/^$1 = //p" <<<"$2" | tr -d '"'; }
# kontrast FARBE FARBE   Kontrastverhältnis nach WCAG 2 zweier Farben #RRGGBB.
kontrast() {
	[[ $1 =~ ^#[0-9A-Fa-f]{6}$ && $2 =~ ^#[0-9A-Fa-f]{6}$ ]] || return 1
	LC_ALL=C awk -v a="$1" -v b="$2" 'function lin(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
		function hex(s, i) { return index("0123456789abcdef", tolower(substr(s, i, 1))) - 1 }
		function lum(s) { return 0.2126 * lin(hex(s, 2) * 16 + hex(s, 3)) + 0.7152 * lin(hex(s, 4) * 16 + hex(s, 5)) + 0.0722 * lin(hex(s, 6) * 16 + hex(s, 7)) }
		BEGIN { x = lum(a); y = lum(b); if (x < y) { t = x; x = y; y = t }; printf "%.2f\n", (x + 0.05) / (y + 0.05) }'
}
BALKEN=$(komponente progress_bar)
TEXT=$(komponente label)
GRUND=$(sed -n 's/^desktop-color: "\(.*\)"$/\1/p' "$THEME")
check "der Balken zeigt keinen Text mehr" '[[ -n $BALKEN && -z $(wert text "$BALKEN") && -z $(wert text_color "$BALKEN") ]]'
check "der Countdown steht als eigener Text darunter (label mit der id __timeout__)" '[[ -n $TEXT && $(wert top "$TEXT") == "$(wert top "$BALKEN")+"* ]]'
# Ein label setzt keine Platzhalter wie @TIMEOUT_NOTIFICATION_LONG@ ein, GRUB zeigt sie wörtlich.
# Sein Text ist eine Vorlage für printf, %d sind die verbleibenden Sekunden.
check "sein Text ist eine Vorlage mit genau einem %d, ohne Platzhalter" 't=$(wert text "$TEXT"); [[ $t == *%d* && ${t/\%d/} != *%* && $t != *@* ]]'
# GRUB zeichnet einen progress_bar nie niedriger als 28 Pixel (Mindestgröße in gui_progress_bar.c).
check "der Balken ist so hoch angegeben, wie GRUB ihn zeichnet (mindestens 28 Pixel)" 'h=$(wert height "$BALKEN"); [[ $h =~ ^[0-9]+$ ]] && ((h >= 28))'
check "der Text beginnt erst unter dem Balken" 'h=$(wert height "$BALKEN") o=$(wert top "$TEXT"); o=${o##*+}; [[ $h =~ ^[0-9]+$ && $o =~ ^[0-9]+$ ]] && { ((h >= 28)) || h=28; ((o >= h + 4)); }'
check "Stahl hell auf dem Grund: 10,26:1, mindestens 4,5:1 (WCAG AA)" '[[ $(wert color "$TEXT") == "#B4C6D1" && $(kontrast "$(wert color "$TEXT")" "$GRUND") == 10.26 ]]'

((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
