#!/usr/bin/env bash
# Unit-Test (GHSA-p86q-3456-f288, #91): lf-aufgabe nimmt keine Quelle, auf die gerade ein Job schreibt
# (dd oder partclone eines laufenden Klons), und kein Hilfsgerät (nbd: Overlay eines Klons,
# zram). Ein blockdev --setro darauf ließe den Job mitten im Lauf scheitern. Maßgeblich ist die
# Jobliste des Assistenten, denn zwischen zwei Kopierschritten hat niemand die Ziel-Disk offen;
# offene Schreibzugriffe und schreibbar eingehängte Dateisysteme fangen den Rest ab. Für retten,
# domain, fortsetzen und pruefen-rettung ist auch das Loop-Gerät einer Datei auf dem Ziel keine
# Quelle, etwa des Images eines Rettungsfalls (rescue_source_ok, #91). Die Suche nach offenen
# Schreibzugriffen liest nur die Verknüpfungen in /proc, mit einer Grenze von 10 s (#95).
#
# Hier wird nichts eingehängt: Die "Disk" sind gewöhnliche Dateien, lsblk, disk_of, boot_disk,
# target_disk und fail sind Attrappen. Ein losgelöster sleep hält eine Datei offen wie dd.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
echo "Quellen für lf-aufgabe:"
# Die Funktionen aus lf-aufgabe, mit Attrappen für Disks und fail. Die "Disk" sind gewöhnliche
# Dateien; ein losgelöster Prozess hält eine davon zum Schreiben offen wie dd im Klon.
sed -n '/^disk_written() {/,/^}/p; /^disk_mounted_rw() {/,/^}/p; /^source_ok() {/,/^}/p' rescue/bin/lf-aufgabe >"$T/aufgabe-fns.sh"
# Die Jobliste aus common.sh: eintragen (Assistent) und lesen (lf-aufgabe).
sed -n '/^tmux_size() {/,/^}/p; /^tmux_start() {/,/^}/p; /^tmux_run_writing() {/,/^}/p; /^job_register() {/,/^}/p; /^job_starttime() {/,/^}/p; /^job_disks() {/,/^}/p' rescue/lib/common.sh >>"$T/aufgabe-fns.sh"
# shellcheck disable=SC1091
. "$T/aufgabe-fns.sh"
LF_JOBS="$T/jobs"
findmnt() { cat "$T/mounts" 2>/dev/null; }
: >"$T/sdz" && : >"$T/sdz1" && : >"$T/sdz2" && : >"$T/sdz10" && : >"$T/dm-0" && ln -s "$T/dm-0" "$T/mapper-x"
# Wie das echte lsblk: KNAME nennt ein dm-Gerät beim Kernelnamen (dm-0), NAME unter /dev/mapper.
lsblk() {
	if [[ $* == *KNAME* ]]; then
		printf '%s\n' "$T/sdz" "$T/sdz1" "$T/sdz2" "$T/dm-0"
	else
		printf '%s\n' "$T/sdz" "$T/sdz1" "$T/sdz2" "$T/mapper-x"
	fi
}
disk_of() { echo "$1"; }
boot_disk() { echo /dev/sdy; }
target_disk() { echo /dev/sdx; }
fail() { echo "abgelehnt: $*"; exit 2; }
(exec 3<"$T/sdz2" && exec sleep 300) >/dev/null 2>&1 &
READER=$!
check "nur lesend offen (etwa ddrescue auf der Quelle): keine Schreib-Disk" '! disk_written "$T/sdz"'
(exec 3>>"$T/sdz1" && exec sleep 300) >/dev/null 2>&1 &
WRITER=$!
sleep 0.3
check "eine Partition zum Schreiben offen (dd, partclone): erkannt" 'disk_written "$T/sdz"'
check "source_ok lehnt diese Disk ab" '[[ $( (source_ok "$T/sdz") ; echo "rc=$?") == *"wird gerade beschrieben"*"rc=2" ]]'
kill "$WRITER" "$READER" 2>/dev/null
wait "$WRITER" "$READER" 2>/dev/null
check "source_ok lehnt nbd (Overlay des Klons) und zram ab" '[[ $( (source_ok /dev/nbd0); echo "rc=$?") == *"Hilfsgerät"*"rc=2" && $( (source_ok /dev/zram0); echo "rc=$?") == *"rc=2" ]]'
check "eine Disk ohne Schreibzugriff bleibt Quelle" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'

echo "Suche ohne stat auf offene Dateien (#95):"
# Zum Schreiben offen über eine Verknüpfung wie /dev/mapper/x: /proc zeigt den Kernelnamen.
(exec 3>>"$T/mapper-x" && exec sleep 300) >/dev/null 2>&1 &
DM=$!
sleep 0.3
check "über /dev/mapper/… zum Schreiben offen: erkannt am Kernelnamen" 'disk_written "$T/sdz"'
kill "$DM" 2>/dev/null
wait "$DM" 2>/dev/null
# Wie ein Geräteknoten, den udev neu anlegt: Die Verknüpfung zeigt auf den alten mit "(deleted)".
(exec 3>>"$T/sdz1" && exec sleep 300) >/dev/null 2>&1 &
NEU=$!
sleep 0.3
rm "$T/sdz1" && : >"$T/sdz1"
check "gelöscht und neu angelegt, weiter zum Schreiben offen: erkannt" 'disk_written "$T/sdz"'
kill "$NEU" 2>/dev/null
wait "$NEU" 2>/dev/null
# Ein Gerät, dessen Name mit dem einer Partition anfängt, zählt nicht für sie.
(exec 3>>"$T/sdz10" && exec sleep 300) >/dev/null 2>&1 &
ZEHN=$!
sleep 0.3
check "zum Schreiben offen ist nur sdz10, nicht sdz1: keine Schreib-Disk (Rückgabe 1)" 'disk_written "$T/sdz"; [[ $? == 1 ]]'
kill "$ZEHN" 2>/dev/null
wait "$ZEHN" 2>/dev/null
# Eine Suche, die nicht zurückkommt, etwa an einem FUSE-Dateisystem, das nicht mehr antwortet: hier ein
# find, das nur schläft. timeout beendet es nach 10 s.
mkdir -p "$T/haengt" && printf '#!/bin/sh\nexec sleep 60\n' >"$T/haengt/find" && chmod +x "$T/haengt/find"
s=$SECONDS
(
	export PATH="$T/haengt:$PATH"
	disk_written "$T/sdz"
)
rc=$?
check "kommt die Suche nicht zurück: nach 10 s Rückgabe 2, nicht prüfbar" '((rc == 2 && SECONDS - s <= 15))'
# Ein find, das nichts ausgibt: Dann sah die Suche gar nichts, auch nicht sich selbst.
mkdir -p "$T/stumm" && printf '#!/bin/sh\nexit 1\n' >"$T/stumm/find" && chmod +x "$T/stumm/find"
check "sieht die Suche gar nichts: source_ok lehnt ab, mit eigener Meldung" '[[ $( (export PATH="$T/stumm:$PATH"; source_ok "$T/sdz"); echo "rc=$?") == *"lässt sich nicht prüfen"*"rc=2" ]]'
check "disk_written liest nur die Verknüpfungen, mit Grenze, und vergleicht mit KNAME, ohne -ef" 'b=$(sed -n "/^disk_written() {$/,/^}$/p" rescue/bin/lf-aufgabe); grep -qF "timeout -s KILL 10 find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf" <<<"$b" && grep -qF "lsblk -lnpo KNAME" <<<"$b" && ! grep -qF -- "-ef" <<<"$b"'

echo "Jobliste des Assistenten:"
# Ein Klon zwischen zwei Schritten: Sein Prozess lebt, aber niemand hat die Ziel-Disk offen.
(exec sleep 300) >/dev/null 2>&1 &
JOB=$!
tmux() {
	case $1 in
	has-session) return 1 ;;
	display-message) echo "$JOB" ;;
	esac
	return 0
}
tmux_run_writing lf-klon "$T/sdz" sudo /run/lf/clone-job.sh
check "tmux_run_writing trägt den Prozess der Sitzung mit der Ziel-Disk ein" '[[ $(cut -d" " -f1,3 "$LF_JOBS/lf-klon") == "$JOB $T/sdz" && $(job_disks) == "$T/sdz" ]]'
check "source_ok lehnt das Ziel eines laufenden Klons ab, auch ohne offenen Schreibzugriff" '! disk_written "$T/sdz" && [[ $( (source_ok "$T/sdz"); echo "rc=$?") == *"Ziel eines laufenden Jobs"*"rc=2" ]]'
start=0
read -r _ start _ <"$LF_JOBS/lf-klon" 2>/dev/null
printf '%s %s %s\n' "$JOB" "$((start + 1))" "$T/sdz" >"$LF_JOBS/lf-klon"
check "eine neu vergebene PID (andere Startzeit) gilt nicht als derselbe Job" '[[ -z $(job_disks) && $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'
printf '%s %s %s\n' "$JOB" "$start" "$T/sdz" >"$LF_JOBS/lf-klon"
kill "$JOB" 2>/dev/null
wait "$JOB" 2>/dev/null
check "ist der Job beendet, ist die Disk wieder Quelle" '[[ -z $(job_disks) && $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'
check "beide Klon-Wege tragen ihre Ziel-Disk ein" '[[ $(grep -c "tmux_run_writing \"lf-klon\" \"\$tdev\" " rescue/lib/clone.sh) == 2 ]] && ! grep -q "tmux_run \"lf-klon\"" rescue/lib/clone.sh'

echo "Schreiber über ein Dateisystem:"
printf '%s rw,relatime\n' "$T/sdz1" >"$T/mounts"
check "eine schreibbar eingehängte Partition: abgelehnt" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == *"schreibbar eingehängt"*"rc=2" ]]'
printf '%s ro,nosuid,nodev,noexec\n' "$T/sdz1" >"$T/mounts"
check "nur lesend eingehängt (etwa von lf-aufgabe selbst): weiter Quelle" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'

echo "Loop-Gerät einer Datei auf dem Ziel (#91):"
# aktionen FN   Die Aktionen von lf-aufgabe, deren Zweig FN aufruft, sortiert.
aktionen() { awk -v fn="$1" '/^[a-z-]+\)$/ { a = substr($0, 1, length($0) - 1) } $1 == fn && a != "" { print a }' rescue/bin/lf-aufgabe | sort | tr '\n' ' '; }
check "retten, domain, fortsetzen und pruefen-rettung prüfen das, einhaengen und timeout nicht (Partitionen eines Images)" '[[ $(aktionen rescue_source_ok) == "domain fortsetzen pruefen-rettung retten " && $(aktionen source_ok) == "einhaengen timeout " ]]'
check "der Selbsttest bindet die Images zweier Fälle ein und prüft das" 'grep -qF "lehnen das Loop-Gerät des Images eines Falls ab, auch als Partition" rescue/lf'
# rescue_source_ok aus lf-aufgabe. Attrappen: source_ok lässt alles durch (oben geprüft), disk_of
# kennt die Partitionen von Loop-Geräten, losetup antwortet aus $T/loop-NAME ("MAJ:MIN|DATEI") und
# schreibt jeden Aufruf mit, stat nennt für das Ziel $ZIEL_MM.
sed -n '/^rescue_source_ok() {/,/^}/p' rescue/bin/lf-aufgabe >"$T/rescue-fn.sh"
# shellcheck disable=SC1091
. "$T/rescue-fn.sh"
LF_TARGET_MNT=/mnt/lf-target
ZIEL_MM=0:47
source_ok() { :; }
disk_of() { if [[ $1 =~ ^(/dev/loop[0-9]+)p[0-9]+$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$1"; fi; }
losetup() {
	local mm f
	echo "losetup $*" >>"$T/losetup-aufrufe"
	[[ $# == 4 && $1 == -n && $2 == -O && -f $T/loop-${4##*/} ]] || return 1
	IFS='|' read -r mm f <"$T/loop-${4##*/}"
	case $3 in
	BACK-MAJ:MIN) printf '%s\n' "$mm" ;;
	BACK-FILE) printf '%s\n' "$f" ;;
	*) return 1 ;;
	esac
}
stat() { [[ $# == 3 && $1 == -c && $2 == %Hd:%Ld && $3 == "$LF_TARGET_MNT" ]] && echo "$ZIEL_MM"; }
# quelle GERÄT   Was rescue_source_ok sagt, dahinter rc=…
quelle() { (rescue_source_ok "$1") 2>&1; echo "rc=$?"; }
NEIN="ist das Loop-Gerät einer Datei auf dem Ziel"
UNKLAR="lässt sich nicht prüfen. Keine Quelle."
echo "0:47|/mnt/lf-target/LF/20261123-1200_Disk_x/image.img" >"$T/loop-loop5"
check "das Image eines Falls (lf-aufgabe image): abgelehnt" '[[ $(quelle /dev/loop5) == *"$NEIN"*"rc=2" ]]'
check "eine Partition davon: abgelehnt, geprüft wird das Loop-Gerät dazu" ': >"$T/losetup-aufrufe"; [[ $(quelle /dev/loop5p1) == *"$NEIN"*"rc=2" ]] && grep -qx "losetup -n -O BACK-FILE /dev/loop5" "$T/losetup-aufrufe"'
echo "0:47|/mnt/lf-target/LF/20261123-1200_Disk_x/image.img (deleted)" >"$T/loop-loop5"
check "das Image ist inzwischen gelöscht (deleted): abgelehnt" '[[ $(quelle /dev/loop5) == *"$NEIN"*"rc=2" ]]'
echo "0:52|/mnt/lf-target/LF/20261123-1200_Disk_x/image.img" >"$T/loop-loop5"
check "Pfad unter dem Ziel, andere Gerätenummer (verschachteltes Subvolume von btrfs): abgelehnt" '[[ $(quelle /dev/loop5) == *"$NEIN"*"rc=2" ]]'
echo "  0:47 |/mnt/anderswo/LF/20261123-1200_Disk_x/image.img" >"$T/loop-loop5"
check "Gerätenummer des Ziels (mit Leerzeichen), anderer Einhängepunkt: abgelehnt" '[[ $(quelle /dev/loop5) == *"$NEIN"*"rc=2" ]]'
echo "0:25|/run/lf/selftest/retten.raw" >"$T/loop-loop6"
check "Loop-Gerät des Selbsttests (Datei unter /run): weiter Quelle, auch als Partition (--domain)" '[[ $(quelle /dev/loop6) == "rc=0" && $(quelle /dev/loop6p1) == "rc=0" ]]'
echo "0:48|/mnt/lf-target2/x.img" >"$T/loop-loop6"
check "ein Pfad, der nur mit dem Namen des Ziels anfängt: weiter Quelle" '[[ $(quelle /dev/loop6) == "rc=0" ]]'
check "ein Loop-Gerät, zu dem losetup nichts sagt: abgelehnt" '[[ $(quelle /dev/loop7) == *"$UNKLAR"*"rc=2" ]]'
echo "|/run/lf/selftest/retten.raw" >"$T/loop-loop7"
check "ohne Gerätenummer der Datei: abgelehnt" '[[ $(quelle /dev/loop7) == *"$UNKLAR"*"rc=2" ]]'
echo "0:25|" >"$T/loop-loop7"
check "ohne Pfad der Datei: abgelehnt" '[[ $(quelle /dev/loop7) == *"$UNKLAR"*"rc=2" ]]'
ZIEL_MM=""
check "ohne Gerätenummer des Ziels: abgelehnt" '[[ $(quelle /dev/loop6) == *"$UNKLAR"*"rc=2" ]]'
check "eine Disk, die kein Loop-Gerät ist: weiter Quelle, ohne losetup" ': >"$T/losetup-aufrufe"; [[ $(quelle /dev/sdz) == "rc=0" && ! -s $T/losetup-aufrufe ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
