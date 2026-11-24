#!/usr/bin/env bash
# Unit-Test: "Dateien kopieren" aus einem Image wählt die Optionen von rsync nach dem Dateisystem,
# das eingehängt ist, und das Fenster zeigt sofort, was wohin kopiert wird.
#
# ntfs3 liefert Windows-Attribute wie $LXUID als erweiterte Attribute ohne Namensraum, auch für
# Dateien, die Linux angelegt hat. Mit -X konnte rsync sie auf ext4 nicht setzen: Jede Kopie von
# NTFS endete mit Exit-Code 23 und drei Fehlern je Datei (#78). Bis rsync die ersten Dateien
# überträgt, blieb das Fenster lf-kopie leer (#79).
# Eine fertige reparierte Kopie steht in "Dateien kopieren" zur Wahl. Repariert wird nur eine
# Kopie, die cp fehlerfrei angelegt hat, und nie, solange ihr Fenster noch offen ist (#87).
# Hängt die Partition der Kopie noch, wird sie vor der Reparatur ausgehängt (#130).
# Ohne Disks und ohne root: Einhängen, findmnt, tmux, sudo und die Menüs sind Attrappen.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
LF_RUN="$T/run"
LF_IMAGE_MNT="$T/mnt"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

image_attach() { echo /dev/loop7; }
image_pick_part() { echo /dev/loop7p2; }
part_mount_ro() { return 0; }
ui_menu() { echo all; }
target_fs() { echo "$ZIEL_FS"; }
findmnt() { echo "$QUELL_FS"; }
# Je Argument eine Zeile: 1 lf-kopie, 2 bash, 3 -c, 4 Befehlstext, 5 _, 6 Optionen, 7 Quelle,
# 8 Ziel, 9 Protokoll.
tmux_run() { printf '%s\n' "$@" >"$T/tmux"; }

# kopie QUELL-FS ZIEL-FS   Ergebnis: OPTS (Optionen von rsync), SKRIPT (Befehlstext im Fenster)
kopie() {
	QUELL_FS=$1 ZIEL_FS=$2
	rm -f "$T/tmux"
	image_copy_files "$T/fall" "$T/fall/image.img"
	SKRIPT=$(sed -n 4p "$T/tmux" 2>/dev/null)
	OPTS=$(sed -n 6p "$T/tmux" 2>/dev/null)
}

echo "Optionen von rsync nach eingehängtem Dateisystem (#78):"
kopie ntfs3 ext4
check "NTFS über ntfs3 auf ext4: ohne -A und -X" '[[ $OPTS == "-aH" ]]'
kopie fuseblk ext4
check "NTFS über ntfs-3g oder BitLocker (fuseblk) auf ext4: ohne -A und -X" '[[ $OPTS == "-aH" ]]'
kopie ext4 ext4
check "ext4 auf ext4: mit ACLs und erweiterten Attributen wie bisher" '[[ $OPTS == "-aHAX" ]]'
kopie ntfs3 exfat
check "Ziel exFAT: wie bisher nur Inhalt und Zeiten" '[[ $OPTS == "-rt --modify-window=2" ]]'

echo "Startzeile im Fenster lf-kopie (#79):"
kopie ntfs3 ext4
# Den Befehlstext so laufen lassen, wie tmux ihn startet. sudo ist eine Attrappe, die nur meldet.
sudo() { echo "AUFRUF $*"; }
export -f sudo
bash -c "$SKRIPT" _ "$OPTS" /quelle /ziel "$T/kopie.log" </dev/null >"$T/fenster" 2>&1
unset -f sudo
check "die erste Zeile nennt die Quelle, die zweite das Ziel" '[[ $(sed -n 1p "$T/fenster") == "Kopiere /quelle" && $(sed -n 2p "$T/fenster") == "nach /ziel" ]]'
check "der Hinweis auf Dateiliste und Protokoll steht vor dem Aufruf von rsync" '(($(grep -n "zählt zuerst" "$T/fenster" | cut -d: -f1) < $(grep -n "^AUFRUF rsync -aH --info=progress2" "$T/fenster" | cut -d: -f1))) && grep -q "Protokoll: $T/kopie.log" "$T/fenster"'
check "Pfade bleiben eigene Argumente von rsync" 'grep -qx "AUFRUF rsync -aH --info=progress2 --ignore-errors /quelle/ /ziel/" "$T/fenster"'

echo "Dateien aus der reparierten Kopie (#87):"
# ui_menu beantwortet die Frage nach dem Image mit WAHL ("" bricht ab), jede andere mit "all".
ui_menu() {
	if [[ $2 == "Aus welchem Image kopieren?" ]]; then
		printf '%s\n' "$@" >"$T/frage"
		[[ -n $WAHL ]] || return 1
		echo "$WAHL"
	else
		echo all
	fi
}
image_attach() { echo "$1 $2" >"$T/attach"; echo /dev/loop7; }
part_mount_ro() { echo "$2" >"$T/mount"; }
# aus WAHL   Ergebnis: QUELLE und ZIEL der Kopie im Fenster lf-kopie
aus() {
	WAHL=$1
	rm -f "$T/frage" "$T/attach" "$T/mount" "$T/tmux"
	image_copy_files "$T/fall" "$T/fall/image.img"
	QUELLE=$(sed -n 7p "$T/tmux" 2>/dev/null)
	ZIEL=$(sed -n 8p "$T/tmux" 2>/dev/null)
}
QUELL_FS=ext4 ZIEL_FS=ext4
mkdir -p "$T/fall"
: >"$T/fall/image.img"
: >"$T/fall/image.img.repair"
aus repair
check "Kopie ohne den Vermerk fertig: keine Frage, kopiert wird aus dem Original" '[[ ! -e $T/frage && $(cat "$T/attach") == "$T/fall/image.img ro" && $QUELLE == "$T/mnt/loop7p2" && $ZIEL == "$T/fall/dateien/loop7p2" ]]'
: >"$T/fall/image.img.repair.fertig"
aus repair
check "fertige reparierte Kopie: lf fragt, aus welchem Image" 'grep -qx repair "$T/frage" && grep -qx orig "$T/frage"'
check "aus der reparierten Kopie: nur lesend eingebunden, die Partition hängt unter repair-<Partition>" '[[ $(cat "$T/attach") == "$T/fall/image.img.repair ro" && $(cat "$T/mount") == "$T/mnt/repair-loop7p2" && $QUELLE == "$T/mnt/repair-loop7p2" ]]'
check "ihre Dateien landen getrennt von denen aus dem Original" '[[ $ZIEL == "$T/fall/dateien/repair-loop7p2" ]]'
aus orig
check "aus dem Original: wie bisher" '[[ $(cat "$T/attach") == "$T/fall/image.img ro" && $(cat "$T/mount") == "$T/mnt/loop7p2" && $ZIEL == "$T/fall/dateien/loop7p2" ]]'
aus ""
check "Abbrechen: nichts wird eingebunden, nichts gestartet" '[[ ! -e $T/attach && ! -e $T/tmux ]]'
rm -f "$T/fall/image.img.repair"
aus repair
check "Vermerk ohne Kopie: keine Frage, kopiert wird aus dem Original" '[[ ! -e $T/frage && $(cat "$T/attach") == "$T/fall/image.img ro" ]]'

echo "Reparatur auf einer Kopie (#87):"
# Die echten tmux_run und tmux_start, dazu eine Attrappe von tmux: Ein Fenster ist eine Datei in
# $T/sitzungen. new-session führt den Befehl gleich aus, mit ABGELOEST bleibt das Fenster offen
# und der Befehl läuft noch (Strg+B, D). attach zeigt das Fenster, mit SCHLIESSEN drückt man darin
# Enter, und es schließt sich.
eval "$(sed -n '/^tmux_run() {/,/^}/p; /^tmux_start() {/,/^}/p; /^tmux_job_offen() {/,/^}/p' rescue/lib/common.sh)"
mkdir -p "$T/sitzungen"
tmux() {
	case $1 in
	has-session) [[ -e $T/sitzungen/${3#=} ]] ;;
	new-session)
		local name=$4
		shift 8
		printf '%s\n' "$name" >>"$T/fenster"
		if [[ -n ${ABGELOEST:-} ]]; then
			: >"$T/sitzungen/$name"
		else
			"$@" </dev/null >>"$T/fenster-ausgabe" 2>&1
		fi
		return 0
		;;
	attach)
		printf '%s\n' "${3#=}" >>"$T/angezeigt"
		[[ -z ${SCHLIESSEN:-} ]] || rm -f "$T/sitzungen/${3#=}"
		return 0
		;;
	*) return 0 ;;
	esac
}
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/meldungen"; }
die() { printf 'Abbruch|%s\n' "$*" >>"$T/meldungen"; }
# ui_yesno nimmt die Antworten der Reihe nach aus ANTWORTEN, die letzte gilt weiter.
ui_yesno() {
	local a=${ANTWORTEN%% *}
	printf '%s\n' "$2" >>"$T/fragen"
	ANTWORTEN=${ANTWORTEN#* }
	[[ $a == ja ]]
}
# findmnt nennt als Einhängepunkte der Partition die Wörter aus EINGEHAENGT. umount schreibt nach
# $T/repariert mit, mit BELEGT scheitert es (#130).
findmnt() { [[ $* == "-rn -o TARGET -S /dev/loop9p1" ]] && printf '%s\n' ${EINGEHAENGT:-}; return 0; }
sudo() {
	case "$1 $2" in
	"blockdev --getro") echo 0 ;;
	"blkid -o") echo ext4 ;;
	"umount "*)
		printf 'umount %s\n' "$2" >>"$T/repariert"
		[[ -z ${BELEGT:-} ]]
		;;
	esac
}
image_attach() { echo "$1 $2" >>"$T/attach"; echo /dev/loop9; }
image_pick_part() { echo "${1}p1"; }
part_mount_ro() { echo "$1 $2" >"$T/mount"; }
runv() { printf '%s\n' "$*" >>"$T/repariert"; }
target_free() { echo 1000000000; }
pause() { :; }
clear() { :; }
# reparatur   image_repair für $T/fall/image.img. Was dabei geschah, steht in $T: fenster
#   (gestartet), angezeigt, fragen, meldungen, attach, repariert.
reparatur() {
	rm -f "$T/fenster" "$T/fenster-ausgabe" "$T/angezeigt" "$T/fragen" "$T/meldungen" "$T/attach" "$T/repariert" "$T/mount"
	image_repair "$T/fall" "$T/fall/image.img" >/dev/null
}
IMG=$T/fall/image.img KOPIE=$T/fall/image.img.repair FERTIG=$T/fall/image.img.repair.fertig
printf 'INHALT DES IMAGES' >"$IMG"
rm -f "$KOPIE" "$FERTIG"
# cp, dem das Ziel vollläuft: Es schreibt einen Teil und endet mit einem Fehler.
mkdir -p "$T/voll"
printf '%s\n' '#!/bin/sh' 'printf TEIL >"$3"' 'exit 1' >"$T/voll/cp"
chmod +x "$T/voll/cp"

ANTWORTEN=ja
reparatur
check "neue Kopie: lf fragt einmal, ob sie angelegt werden soll" '[[ $(wc -l <"$T/fragen") == 1 ]] && grep -q "Kopie jetzt anlegen?" "$T/fragen"'
check "die Kopie entsteht im eigenen Fenster lf-reparatur-kopie, nicht in lf-kopie" '[[ $(cat "$T/fenster") == lf-reparatur-kopie ]]'
check "cp endet fehlerfrei: Kopie und Vermerk liegen da" 'cmp -s "$IMG" "$KOPIE" && [[ -f $FERTIG ]] && grep -qx "Kopie fertig." "$T/fenster-ausgabe"'
check "erst danach wird die Kopie beschreibbar eingebunden und repariert" '[[ $(cat "$T/attach") == "$KOPIE rw" && $(cat "$T/repariert") == "sudo e2fsck -fy /dev/loop9p1" ]]'
check "der Hinweis danach nennt die reparierte Kopie in Dateien kopieren" 'grep -q "wähle dort die reparierte Kopie und die Partition loop9p1" "$T/meldungen"'
reparatur
check "fertige Kopie: keine Frage, kein Fenster, sie wird gleich repariert" '[[ ! -e $T/fragen && ! -e $T/fenster && $(cat "$T/attach") == "$KOPIE rw" && -s $T/repariert ]]'

rm -f "$KOPIE" "$FERTIG"
ANTWORTEN=ja
PATH="$T/voll:$PATH" reparatur
check "cp scheitert (Ziel voll): kein Vermerk, nichts eingebunden, nichts repariert" '[[ ! -e $FERTIG && $(cat "$KOPIE") == TEIL && ! -e $T/attach && ! -e $T/repariert ]] && grep -qx "Die Kopie ist fehlgeschlagen." "$T/fenster-ausgabe"'
check "lf sagt, dass die Kopie nicht fertig geworden ist" 'grep -q "^Reparatur|Die Kopie ist nicht fertig geworden. Repariert wird nichts" "$T/meldungen"'
ANTWORTEN=nein
reparatur
check "unfertige Kopie beim nächsten Mal: lf fragt, Nein lässt alles, wie es ist" 'grep -q "ist nicht fertig geworden" "$T/fragen" && [[ $(cat "$KOPIE") == TEIL && ! -e $T/fenster && ! -e $T/attach && ! -e $T/repariert ]]'
ANTWORTEN="ja ja"
reparatur
check "Ja: die unfertige Kopie wird verworfen und neu angelegt, erst die fertige wird repariert" '[[ $(wc -l <"$T/fragen") == 2 && $(cat "$T/fenster") == lf-reparatur-kopie && -f $FERTIG && $(cat "$T/attach") == "$KOPIE rw" && -s $T/repariert ]] && cmp -s "$IMG" "$KOPIE"'
rm -f "$KOPIE"
ANTWORTEN=ja
reparatur
check "Vermerk ohne Kopie gilt nicht: die Kopie wird neu angelegt" '[[ $(cat "$T/fenster") == lf-reparatur-kopie && -f $FERTIG && $(cat "$T/attach") == "$KOPIE rw" ]] && cmp -s "$IMG" "$KOPIE"'

rm -f "$KOPIE" "$FERTIG"
ANTWORTEN=ja ABGELOEST=1
reparatur
check "Strg+B, D, solange cp läuft: nichts wird eingebunden, lf sagt, dass die Kopie weiterläuft" '[[ ! -e $T/attach && ! -e $T/repariert ]] && grep -q "^Reparatur|Die Kopie läuft im Hintergrund weiter (Fenster lf-reparatur-kopie)" "$T/meldungen"'
ABGELOEST=""
reparatur
check "Fenster noch offen beim nächsten Mal: lf zeigt es an, startet nichts und bindet nichts ein" '[[ $(cat "$T/angezeigt") == lf-reparatur-kopie && ! -e $T/fenster && ! -e $T/attach && ! -e $T/repariert ]] && grep -q "^Reparatur|Das Fenster lf-reparatur-kopie ist noch offen" "$T/meldungen"'
# cp ist inzwischen im Fenster fertig geworden. Enter schließt es.
cp "$IMG" "$KOPIE" && : >"$FERTIG"
SCHLIESSEN=1
reparatur
check "schließt man es dabei mit Enter, geht es mit der fertigen Kopie weiter" '[[ $(cat "$T/angezeigt") == lf-reparatur-kopie && ! -e $T/fenster && $(cat "$T/attach") == "$KOPIE rw" && -s $T/repariert ]]'
SCHLIESSEN=""

echo "Reparatur einer Partition, die noch eingehängt ist (#130):"
EINGEHAENGT="$T/mnt/repair-loop9p1"
reparatur
check "die Partition der fertigen Kopie hängt noch: erst ausgehängt, dann repariert" '[[ $(sed -n 1p "$T/repariert") == "umount $T/mnt/repair-loop9p1" && $(sed -n 2p "$T/repariert") == "sudo e2fsck -fy /dev/loop9p1" ]]'
EINGEHAENGT="$T/mnt/repair-loop9p1 $T/mnt/loop9p1"
reparatur
check "an zwei Stellen eingehängt: beide ausgehängt, dann repariert" '[[ $(grep -c "^umount " "$T/repariert") == 2 && $(tail -n1 "$T/repariert") == "sudo e2fsck -fy /dev/loop9p1" ]]'
BELEGT=1
reparatur
check "lässt sie sich nicht aushängen (eine Kopie liest noch daraus): nichts repariert, nichts weiter ausgehängt, lf sagt es" '[[ $(cat "$T/repariert") == "umount $T/mnt/repair-loop9p1" && ! -e $T/mount ]] && grep -q "^Reparatur|loop9p1 ist unter $T/mnt/repair-loop9p1 eingehängt und lässt sich nicht aushängen" "$T/meldungen"'
BELEGT="" EINGEHAENGT=""
reparatur
check "hängt sie nirgends: kein umount, repariert wie bisher" '[[ $(cat "$T/repariert") == "sudo e2fsck -fy /dev/loop9p1" ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
