#!/usr/bin/env bash
# Unit-Test: Der persistente Speicher kommt nur vom eigenen Stick und nie ungefragt.
#
# Wer den Speicher stellt, bestimmt die Sitzung: Aus ihm kommen Programme (~/.local/bin), Regeln
# und Einstellungen für Claude, SSH-Schlüssel und WLAN-Profile. Bisher galt jede Partition mit dem
# Namen LF-DATA als eigener Speicher, auf welcher Disk auch immer. War sie unverschlüsselt, wurde
# sie ohne Rückfrage eingehängt und ihre lf.conf als Shell-Code gelesen. Der Test prüft:
#   - der Boot-Stick ist das eingehängte Live-Medium, nicht irgendeine Disk mit dem Label der ISO,
#   - der Speicher ist nur die Partition LF-DATA auf diesem Stick,
#   - tragen dort mehrere Partitionen den Namen, wird keine verwendet und keine weitere angelegt,
#   - ein unverschlüsselter Speicher wird nie ohne Rückfrage eingebunden,
#   - lf.conf wird als Daten gelesen: Nichts daraus wird ausgeführt,
#   - das Anlegen lässt das Boot-Flag im MBR des Sticks stehen (#106).
# Ohne root und ohne Disks: lsblk, blkid, findmnt, sudo und die Dialoge sind Attrappen. lsblk
# gibt JSON aus wie util-linux 2.41 auf der ISO. Den MBR prüft am Ende das echte sgdisk an einem
# kleinen ISO, das xorriso partitioniert wie make_iso.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/persist.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh # part_path

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/MARKE-*" >/dev/null; }

LF_RUN="$T/run"
LF_PERSIST="$T/persist"
LF_LOG=/dev/null
HOME="$T/home"
# Aus claude.sh: Claude läuft als eigener Benutzer, sein Home kommt vom Speicher.
CLAUDE_USER=lf-claude
CLAUDE_HOME="$T/claude-home"
claude_as() { sudo -u "$CLAUDE_USER" -H "$@"; }
PERSIST_CONFIG="$T/etc-lf/lf.conf"
PERSIST_MAPPER_DEV="$T/mapper-lf-data"
mkdir -p "$LF_RUN" "$HOME" "$T/etc-lf"

# ---------------------------------------------------------------------------
# Die gedachte Maschine. Jede Variable beschreibt, was ein Werkzeug meldet.
#   CDROM         Quelle von /cdrom laut findmnt
#   BLOCKDEVS     Pfade, die Blockgeräte sind
#   ISO_LABEL     Geräte mit dem Label LEUCHTFEUER laut blkid, in dieser Reihenfolge
#   PARTS         Zeilen "PFAD DISK PARTLABEL LABEL TYP": Partitionen und ihr Inhalt laut blkid
#   HOLDERS       Zeilen "PFAD ELTERN LABEL TYP": Geräte auf einer Partition, etwa der entsperrte
#                 Speicher (crypt) mit dem Dateisystem darin
# ---------------------------------------------------------------------------
HOLDERS=""
findmnt() { [[ -n $CDROM ]] && echo "$CDROM"; }
is_blockdev() { [[ " $BLOCKDEVS " == *" $1 "* ]]; }
# blkid -t NAME=WERT -o device: alle Geräte mit diesem Merkmal, wie das echte blkid ohne
# Rücksicht darauf, auf welcher Disk sie liegen.
blkid() {
	local d path disk partlabel label type
	case "$*" in
	*LABEL=LEUCHTFEUER*) for d in $ISO_LABEL; do echo "$d"; done ;;
	*PARTLABEL=LF-DATA*)
		while read -r path disk partlabel label type; do
			[[ $partlabel == LF-DATA ]] && echo "$path"
		done <<<"$PARTS"
		;;
	*LABEL=LF-DATA*)
		while read -r path disk partlabel label type; do
			[[ $label == LF-DATA ]] && echo "$path"
		done <<<"$PARTS"
		;;
	esac
	return 0
}
# Eltern-Disk eines Geräts: bei sdb1 ist das sdb, bei einer ganzen Disk nichts.
parent() {
	case $1 in
	/dev/sr0 | /dev/sda | /dev/sdb | /dev/sdc) ;;
	*) sed -E 's|^/dev/([a-z]+)[0-9]+$|\1|' <<<"$1" ;;
	esac
}
# Die Blockgeräte der gedachten Maschine, je Zeile eines: die Disks aus PARTS, ihre Partitionen
# und die Geräte aus HOLDERS. "eltern" ist das Gerät, auf dem es liegt. Die Disks tragen das
# Label der ISO, wenn ISO_LABEL sie nennt.
geraete() {
	local path disk partlabel label type
	while read -r path disk partlabel label type; do
		[[ -n $path ]] || continue
		jq -cn --arg p "$disk" --arg l "$([[ " $ISO_LABEL " == *" $disk "* ]] && echo LEUCHTFEUER)" \
			'{path: $p, type: "disk", label: $l}'
		jq -cn --arg p "$path" --arg e "$disk" --arg pl "${partlabel#-}" --arg l "${label#-}" \
			'{path: $p, eltern: $e, type: "part", partlabel: $pl, label: $l}'
	done <<<"$PARTS"
	while read -r path disk label type; do
		[[ -n $path ]] || continue
		jq -cn --arg p "$path" --arg e "$disk" --arg l "${label#-}" --arg t "$type" \
			'{path: $p, eltern: $e, type: $t, label: $l}'
	done <<<"$HOLDERS"
}
# lsblk -J wie util-linux 2.41 auf der ISO: Jede Spalte aus -o ist ein Schlüssel in
# Kleinbuchstaben, ein leerer Wert ist null. Als children unter ihre Eltern kommen Geräte nur
# mit der Spalte NAME oder mit --tree (man lsblk), sonst ist die Liste flach: jede Disk, dahinter
# ihre Partitionen und was darauf liegt. Mit einem Gerät zeigt lsblk nur dieses und was darauf
# liegt. LSBLK_BAUM=1 verschachtelt immer, auch ohne NAME und --tree.
LSBLK_JQ='
def leer: if . == "" then null else . end;
def name: .path | ltrimstr("/dev/") | ltrimstr("mapper/");
reduce .[] as $g ([]; if any(.[]; .path == $g.path) then . else . + [$g] end) | . as $alle
| def wert($s):
	if $s == "name" then name
	elif $s == "pkname" then (.eltern as $e | first($alle[] | select(.path == $e) | name) // null)
	else (.[$s] // null | leer) end;
  def zeile: . as $g | reduce ($cols | ascii_downcase | split(","))[] as $s ({}; .[$s] = ($g | wert($s)));
  def kinder: .path as $p | $alle[] | select(.eltern == $p);
  def baum: zeile + ([kinder | baum] | if length > 0 then {children: .} else {} end);
  def flach: zeile, (kinder | flach);
  [if $dev == "" then $alle[] | select(.eltern == null) else $alle[] | select(.path == $dev) end] as $wurzeln
| if $dev != "" and $wurzeln == [] then "lsblk: \($dev): not a block device\n" | halt_error(32)
  else {blockdevices: [$wurzeln[] | if $verschachtelt then baum else flach end]} end'
lsblk() {
	local cols="" baum=false dev=""
	if [[ $* == "-no PKNAME "* ]]; then
		parent "$3"
		return
	fi
	while (($#)); do
		case $1 in
		-J) ;;
		-o)
			cols=$2
			shift
			;;
		-T | --tree) baum=true ;;
		/dev/*) dev=$1 ;;
		*)
			echo "lsblk-Attrappe: $1 ist nicht nachgebildet" >&2
			return 2
			;;
		esac
		shift
	done
	[[ ,$cols, == *,NAME,* || ${LSBLK_BAUM:-} == 1 ]] && baum=true
	geraete | jq -cs --arg cols "$cols" --arg dev "$dev" --argjson verschachtelt "$baum" "$LSBLK_JQ"
}
# Der MBR je Disk liegt in $T/mbr-NAME (512 Byte). sgdisk -e und -n schreiben den Schutz-MBR neu
# wie sgdisk 1.0.10: Eintrag 2 (16 Byte ab Byte 462) wird leer. SGDISK_MBR2: stattdessen diese
# 16 Byte (Hex). DD_OHNE_WIRKUNG=1: dd schreibt nichts.
XORRISO_MBR2=80000100000001000000000001000000
mbr_datei() { echo "$T/mbr-${1##*/}"; }
mbr_setzen() { printf '%b' "$(sed 's/../\\x&/g' <<<"$2")" | command dd of="$(mbr_datei "$1")" bs=1 seek=462 count=16 conv=notrunc status=none; }
mbr_leeren() { [[ ! -f $(mbr_datei "$1") ]] || mbr_setzen "$1" "${SGDISK_MBR2:-$PERSIST_MBR_LEER}"; }
mbr_eintrag() { od -An -v -tx1 -j 462 -N 16 "$(mbr_datei "$1")" | tr -d ' \n'; }
# mbr_neu DISK [EINTRAG]   Ein MBR wie von xorriso, Eintrag 2 = EINTRAG (Vorgabe: mit Boot-Flag).
mbr_neu() {
	head -c 512 /dev/zero >"$(mbr_datei "$1")"
	mbr_setzen "$1" "${2:-$XORRISO_MBR2}"
}
# mbr_reihenfolge   Im Protokoll von sudo stehen sgdisk -e, dd auf Eintrag 2, sgdisk -n und wieder
#   dd auf Eintrag 2, in dieser Reihenfolge, dd genau zweimal.
mbr_reihenfolge() {
	local e n
	local -a dd_of
	e=$(grep -n '^sgdisk -e ' "$T/sudo" | cut -d: -f1 | head -n1)
	n=$(grep -n '^sgdisk -n ' "$T/sudo" | cut -d: -f1 | head -n1)
	mapfile -t dd_of < <(grep -n '^dd of=/dev/sda ' "$T/sudo" | cut -d: -f1)
	[[ ${#dd_of[@]} == 2 && -n $e && -n $n ]] && ((e < dd_of[0] && dd_of[0] < n && n < dd_of[1]))
}
sudo() {
	local path disk partlabel label type
	printf '%s\n' "$*" >>"$T/sudo"
	case "$*" in
	"blkid -o value -s TYPE "*)
		while read -r path disk partlabel label type; do
			[[ $path == "$6" ]] && echo "$type"
		done <<<"$PARTS"
		;;
	"cryptsetup open "*) : >"$PERSIST_MAPPER_DEV" ;;
	"dd if=/dev/"*" bs=512 count=1 status=none") cat "$(mbr_datei "${2#if=}")" 2>/dev/null ;;
	"dd of=/dev/"*" bs=1 seek=462 count=16 conv=notrunc,fsync status=none")
		if [[ ${DD_OHNE_WIRKUNG:-0} == 1 ]]; then cat >/dev/null; else command dd of="$(mbr_datei "${2#of=}")" bs=1 seek=462 count=16 conv=notrunc status=none; fi
		;;
	"sgdisk -e "*) mbr_leeren "$3" ;;
	"sgdisk -p "*) sgdisk_p "$3" ;;
	"sgdisk -n "*) sgdisk_n "$@" || return ;;
	"sgdisk -i "*) sgdisk_i "$3" "$4" ;;
	esac
	return 0
}
# sgdisk wie gdisk 1.0.10, nur was persist_create braucht. Die Nummer einer Partition ist die Zahl
# am Ende ihres Pfads in PARTS.
#   -p DISK   Kopf, dann je Partition eine Zeile, nach Nummer sortiert. SGDISK_P_LEER=1: keine Zeile.
#   -n N:0:GRÖSSE -t N:TYP -c N:NAME DISK   legt Partition N an, mit N=0 die erste freie. Eine
#             belegte Nummer oder eine über 128 lehnt es ab. NEU_UNSICHTBAR=1: kein Blockgerät.
#             SGDISK_N_NAME: Diesen Namen sehen lsblk und blkid statt NAME.
#   -i N DISK der Name von Partition N. SGDISK_I_NAME ersetzt ihn.
sgdisk_p() {
	local path disk partlabel label type
	printf 'Disk %s: 30031872 sectors, 14.3 GiB\nModel: USB Flash Disk\nPartition table holds up to 128 entries\n\nNumber  Start (sector)    End (sector)  Size       Code  Name\n' "$1"
	[[ ${SGDISK_P_LEER:-0} == 1 ]] && return 0
	while read -r path disk partlabel label type; do
		[[ $disk == "$1" ]] && printf '%4s %15s %15s   %-10s %-5s %s\n' "${path##*[!0-9]}" 2048 4095 "1024.0 KiB" 8300 "${partlabel#-}"
	done <<<"$PARTS" | sort -n
	return 0
}
sgdisk_n() {
	local n=${3%%:*} name=${SGDISK_N_NAME:-${7#*:}} disk=$8
	if [[ $n == 0 ]]; then
		n=1
		while grep -q "^$(part_path "$disk" "$n") " <<<"$PARTS"; do n=$((n + 1)); done
	fi
	((n <= 128)) && ! grep -q "^$(part_path "$disk" "$n") " <<<"$PARTS" || return 4
	PARTS+=$'\n'"$(part_path "$disk" "$n") $disk $name - -"
	[[ ${NEU_UNSICHTBAR:-0} == 1 ]] || BLOCKDEVS+=" $(part_path "$disk" "$n")"
	mbr_leeren "$disk"
}
sgdisk_i() {
	local p path disk partlabel label type
	p=$(part_path "$2" "$1")
	while read -r path disk partlabel label type; do
		[[ $path == "$p" ]] || continue
		printf "Partition GUID code: 0FC63DAF-8483-4772-8E79-3D69D8477DE4 (Linux filesystem)\nPartition name: '%s'\n" "${SGDISK_I_NAME:-${partlabel#-}}"
		return 0
	done <<<"$PARTS"
	echo "Partition #$1 does not exist."
}
ui_menu() { echo 2; }
ui_info() { :; }
mountpoint() { return 1; }
log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
log_init() { :; }
# Maskiert Wiederherstellungsschlüssel in den Verläufen von Claude (common.sh, geprüft in
# unit-bitlocker-key.sh). Hier zählt nur, womit es aufgerufen wird und ob das Home von Claude
# dann schon vom Speicher kommt.
log_scrub_tree() {
	local home=live
	grep -qF "mount --bind $LF_PERSIST/claude-home $CLAUDE_HOME" "$T/sudo" 2>/dev/null && home=Speicher
	printf '%s|%s\n' "$home" "$*" >>"$T/scrub"
}
human() { echo "1GiB"; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
ui_yesno() {
	printf '%s|%s\n' "$1" "$2" >>"$T/yesno"
	return "$YESNO_RC"
}
ui_password() {
	echo x >>"$T/password"
	[[ -n $PASSPHRASE ]] || return 1
	echo "$PASSPHRASE"
}

# fresh   Vergisst, was frühere Aufrufe hinterlassen haben.
fresh() {
	rm -f "$T/sudo" "$T/log" "$T/msg" "$T/yesno" "$T/password" "$T/bind" "$T/scrub" "$PERSIST_MAPPER_DEV"
	rm -f "$LF_RUN"/persist-*
}
# Ergebnis des letzten Aufrufs: SUDO (Aufrufe hinter sudo), MSG, YESNO, BIND, SCRUB (log_scrub_tree).
result() {
	SUDO=$(cat "$T/sudo" 2>/dev/null)
	MSG=$(cat "$T/msg" 2>/dev/null)
	YESNO=$(cat "$T/yesno" 2>/dev/null)
	BIND=$(cat "$T/bind" 2>/dev/null)
	SCRUB=$(cat "$T/scrub" 2>/dev/null)
}
YESNO_RC=1 PASSPHRASE=""

# Normalfall: gestartet vom Stick sdb. Dort liegt der eigene, verschlüsselte Speicher sdb3.
# Die interne Disk sda des Kundenrechners trägt eine unverschlüsselte Partition gleichen Namens
# und zusätzlich eine mit dem Label der ISO. blkid nennt sda vor sdb.
normal() {
	CDROM=/dev/sdb1
	BLOCKDEVS="/dev/sdb1 /dev/sdb /dev/sr0"
	ISO_LABEL="/dev/sda2 /dev/sdb /dev/sdb1"
	PARTS="/dev/sda2 /dev/sda - LEUCHTFEUER iso9660
/dev/sda9 /dev/sda LF-DATA LF-DATA ext4
/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA crypto_LUKS"
	HOLDERS=""
}
# Ein Stick, wie die ISO ihn anlegt: hinter der ISO die EFI-Partition, eine Lücke und LF-DATA.
stick() {
	CDROM=/dev/sda1
	BLOCKDEVS="/dev/sda1 /dev/sda /dev/sr0"
	ISO_LABEL="/dev/sda /dev/sda1"
	PARTS="/dev/sda1 /dev/sda ISO9660 LEUCHTFEUER iso9660
/dev/sda2 /dev/sda Appended2 LF_EFI vfat
/dev/sda3 /dev/sda Gap1 - -
/dev/sda4 /dev/sda LF-DATA LF-DATA ext4"
	HOLDERS=""
}
# So gab lsblk -J -o PATH,PARTLABEL,LABEL /dev/sda auf der ISO diesen Stick aus (util-linux 2.41).
STICK_LSBLK='{"blockdevices":[{"path":"/dev/sda","partlabel":null,"label":"LEUCHTFEUER"},{"path":"/dev/sda1","partlabel":"ISO9660","label":"LEUCHTFEUER"},{"path":"/dev/sda2","partlabel":"Appended2","label":"LF_EFI"},{"path":"/dev/sda3","partlabel":"Gap1","label":null},{"path":"/dev/sda4","partlabel":"LF-DATA","label":"LF-DATA"}]}'

# ---------------------------------------------------------------------------
echo "Boot-Stick:"
normal
check "das eingehängte Live-Medium zählt, nicht die erste Disk mit dem Label" '[[ $(boot_disk) == /dev/sdb ]]'
CDROM=/dev/sr0
check "Start von CD: das Laufwerk selbst" '[[ $(boot_disk) == /dev/sr0 ]]'
CDROM=/dev/shm ISO_LABEL="/dev/sdb /dev/sdb1"
check "in den RAM geladen, eine Disk mit dem Label: diese Disk" '[[ $(boot_disk) == /dev/sdb ]]'
ISO_LABEL="/dev/sda2 /dev/sdb /dev/sdb1"
check "in den RAM geladen, zwei Disks mit dem Label: kein Boot-Stick" '! boot_disk >/dev/null && [[ -z $(boot_disk) ]]'
CDROM="" ISO_LABEL=""
check "kein Live-Medium, kein Label: kein Boot-Stick" '! boot_disk >/dev/null'

# ---------------------------------------------------------------------------
echo "Welche Partition ist der eigene Speicher:"
stick
check "die Attrappe gibt aus, was lsblk 2.41 auf der ISO ausgab: eine flache Liste ohne children" \
	'[[ $(lsblk -J -o PATH,PARTLABEL,LABEL /dev/sda | jq -c .) == "$STICK_LSBLK" ]]'
check "LF-DATA hinter der EFI-Partition und der Lücke wird gefunden" '[[ $(persist_find) == /dev/sda4 ]]'
fresh
persist_create
rc=$?
result
check "Anlegen sieht sie auch: kein zweiter Speicher (die Sperre in persist_create)" '[[ $rc != 0 && $SUDO != *sgdisk* && $MSG == *"schon eine Partition"* ]]'
# Seit #99 liegt hinter der EFI-Partition die Partition LF-SSH für eigene SSH-Schlüssel, dahinter
# die Lücke. Ein neu angelegter Speicher LF-DATA bekommt die Nummer 5.
stick
PARTS="/dev/sda1 /dev/sda ISO9660 LEUCHTFEUER iso9660
/dev/sda2 /dev/sda Appended2 LF_EFI vfat
/dev/sda3 /dev/sda LF-SSH LF-SSH vfat
/dev/sda4 /dev/sda Gap1 - -
/dev/sda5 /dev/sda LF-DATA LF-DATA ext4"
check "Stick mit LF-SSH (#99): LF-DATA dahinter wird gefunden, keine Partition gilt als fremd" '[[ $(persist_find) == /dev/sda5 && -z $(persist_foreign) ]]'
PARTS="/dev/sda1 /dev/sda ISO9660 LEUCHTFEUER iso9660
/dev/sda2 /dev/sda Appended2 LF_EFI vfat
/dev/sda3 /dev/sda LF-SSH LF-SSH vfat
/dev/sda4 /dev/sda Gap1 - -"
check "ohne LF-DATA ist LF-SSH kein Speicher" '! persist_find >/dev/null && [[ -z $(persist_find) ]]'
normal
check "LF-DATA auf dem Stick, nicht die gleichnamige auf der internen Disk" '[[ $(persist_find) == /dev/sdb3 ]]'
check "die fremde Partition wird als fremd erkannt" '[[ $(persist_foreign) == /dev/sda9 ]]'
HOLDERS="/dev/mapper/lf-data /dev/sdb3 LF-DATA crypt"
check "entsperrt trägt auch das Dateisystem im Speicher den Namen, es zählt nicht als zweite Partition" \
	'[[ $(persist_find) == /dev/sdb3 && $(persist_foreign) == /dev/sda9 ]]'
HOLDERS=""
LSBLK_BAUM=1
check "verschachtelt lsblk die Geräte (NAME oder --tree), gilt dasselbe" \
	'[[ $(persist_find) == /dev/sdb3 && $(persist_foreign) == /dev/sda9 ]]'
unset LSBLK_BAUM
PARTS="/dev/sda9 /dev/sda LF-DATA LF-DATA ext4
/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660"
check "nur auf der fremden Disk: kein eigener Speicher" '! persist_find >/dev/null && [[ -z $(persist_find) ]]'
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA ext4
/dev/sdb4 /dev/sdb LF-DATA - ext4"
check "zwei Partitionen mit dem Namen auf dem Stick: kein eigener Speicher" '[[ -z $(persist_find) ]]'
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb - LF-DATA ext4"
check "nur das Dateisystem trägt den Namen: gilt auf dem Stick auch" '[[ $(persist_find) == /dev/sdb3 ]]'
echo "Übergang von firestrike-rescue (eine Beta lang): FRS-DATA gilt wie LF-DATA:"
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb FRS-DATA FRS-DATA crypto_LUKS"
check "FRS-DATA auf dem Stick ist der eigene Speicher" '[[ $(persist_find) == /dev/sdb3 ]]'
PARTS="/dev/sda9 /dev/sda FRS-DATA FRS-DATA ext4
/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660"
check "FRS-DATA auf der fremden Disk: kein eigener Speicher" '[[ -z $(persist_find) ]]'
check "FRS-DATA auf der fremden Disk wird als fremd erkannt" '[[ $(persist_foreign) == /dev/sda9 ]]'
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA ext4
/dev/sdb4 /dev/sdb FRS-DATA FRS-DATA ext4"
check "LF-DATA und FRS-DATA auf dem Stick: kein eigener Speicher" '[[ -z $(persist_find) ]]'
normal
CDROM=/dev/shm
check "Boot-Stick nicht sicher erkennbar: kein eigener Speicher" '[[ -z $(persist_find) ]]'
check "dann gelten alle gleichnamigen Partitionen als fremd" '[[ $(persist_foreign | tr "\n" " ") == "/dev/sda9 /dev/sdb3 " ]]'
normal
printf 'LF_BOOT_DEV=/dev/sdb\nLF_BOOT_DISKS=2\n' >"$T/lf-boot.env"
LF_BOOT_ENV="$T/lf-boot.env"
check "trug beim Start eine weitere Disk die UUID der ISO: kein eigener Speicher" '! persist_find >/dev/null && [[ -z $(persist_find) ]]'
printf 'LF_BOOT_DEV=/dev/sdb\nLF_BOOT_DISKS=1\n' >"$T/lf-boot.env"
check "nur der Stick trug sie: Speicher wie bisher" '[[ $(persist_find) == /dev/sdb3 ]]'
LF_BOOT_ENV="$T/fehlt"

# ---------------------------------------------------------------------------
# Ab hier zählt, ob eingebunden wird. persist_bind wird dafür nur mitgeschrieben.
persist_bind() { echo bind >>"$T/bind"; }

echo "Angriff: nur die fremde Disk trägt eine unverschlüsselte Partition LF-DATA:"
normal
PARTS="/dev/sda9 /dev/sda LF-DATA LF-DATA ext4
/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660"
# Auf dem Stick ist kein Platz für einen neuen Speicher, es folgt also kein Angebot zum Anlegen.
persist_free_bytes() { echo 0; }
fresh
YESNO_RC=0
persist_startup
result
check "nichts wird eingehängt" '[[ $SUDO != *mount* ]]'
check "nichts wird eingebunden" '[[ -z $BIND ]]'
check "keine Frage, die sich mit Ja beantworten ließe" '[[ -z $YESNO ]]'
check "der Techniker erfährt von der fremden Partition" '[[ $MSG == "Persistenter Speicher|"*"/dev/sda9"*"wird nicht verwendet"* ]]'
check "im Protokoll steht, dass sie nicht verwendet wird" '[[ $(cat "$T/log") == *"wird nicht verwendet: /dev/sda9"* ]]'
rm -f "$T/msg"
persist_startup
result
check "der Hinweis kommt je Sitzung nur einmal" '[[ -z $MSG ]]'
fresh
persist_open
rc=$?
result
check "auch \"Entsperren und einhängen\" fasst sie nicht an" '[[ $rc != 0 && $SUDO != *mount* && -z $BIND ]]'

echo "Eigener Speicher, verschlüsselt:"
normal
fresh
PASSPHRASE="geheim" YESNO_RC=1
persist_startup
result
check "die Passphrase wird verlangt, keine Ja-Nein-Frage" '[[ -s $T/password && -z $YESNO ]]'
check "entsperrt wird die Partition auf dem Stick" '[[ $SUDO == *"cryptsetup open --key-file - /dev/sdb3 lf-data"* ]]'
check "eingehängt ohne Gerätedateien und Setuid" '[[ $SUDO == *"mount -o noatime,nodev,nosuid $PERSIST_MAPPER_DEV $LF_PERSIST"* ]]'
check "eingebunden" '[[ $BIND == bind ]]'
check "die fremde Partition wird trotzdem gemeldet und nie eingehängt" '[[ $MSG == *"/dev/sda9"* && $SUDO != *"/dev/sda9"* ]]'
fresh
PASSPHRASE=""
persist_startup
result
check "Passphrase abgebrochen: nichts eingehängt, nichts eingebunden" '[[ $SUDO != *mount* && -z $BIND ]]'

echo "Eigener Speicher, unverschlüsselt:"
normal
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA ext4"
fresh
YESNO_RC=1
persist_startup
result
check "Rückfrage, Vorgabe ist Nein" '[[ $YESNO == "Speicher nicht verschlüsselt|"*"/dev/sdb3"* ]]'
check "Nein: nichts eingehängt, nichts eingebunden" '[[ $SUDO != *mount* && -z $BIND ]]'
rm -f "$T/yesno"
persist_startup
result
check "beim nächsten Start des Assistenten keine zweite Frage" '[[ -z $YESNO && -z $BIND ]]'
persist_open
result
check "über das Menü wird wieder gefragt" '[[ $YESNO == "Speicher nicht verschlüsselt|"* ]]'
fresh
YESNO_RC=0
persist_startup
result
check "Ja: eingehängt ohne Gerätedateien und Setuid, eingebunden" '[[ $SUDO == *"mount -o noatime,nodev,nosuid /dev/sdb3 $LF_PERSIST"* && $BIND == bind ]]'

echo "Anlegen:"
fresh
persist_create
rc=$?
result
check "gibt es auf dem Stick schon einen Speicher, wird kein zweiter angelegt" '[[ $rc != 0 && $SUDO != *sgdisk* && $MSG == *"schon eine Partition"* ]]'

echo "Zwei Partitionen mit dem Namen auf dem Stick, aus der Zeit, als der Speicher nicht gefunden wurde:"
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA ext4
/dev/sdb4 /dev/sdb LF-DATA LF-DATA ext4"
# Platz für einen weiteren Speicher wäre da.
persist_free_bytes() { echo 1073741824; }
fresh
YESNO_RC=0
persist_startup
result
check "der Start sagt es, statt anzubieten, einen Speicher anzulegen" '[[ $MSG == "Persistenter Speicher|"*"mehrere Partitionen"*":\n\n   /dev/sdb3 /dev/sdb4\n\n"* && -z $YESNO ]]'
check "nichts wird angelegt, eingehängt oder eingebunden" '[[ $SUDO != *sgdisk* && $SUDO != *mount* && -z $BIND ]]'
check "im Protokoll stehen beide" '[[ $(grep -F "keine wird verwendet" "$T/log") == *"keine wird verwendet: /dev/sdb3 /dev/sdb4" ]]'
rm -f "$T/msg"
persist_startup
result
check "der Hinweis kommt je Sitzung nur einmal, ein Angebot auch danach nicht" '[[ -z $MSG && -z $YESNO ]]'
fresh
persist_create
rc=$?
result
check "auch über das Menü wird kein weiterer angelegt" '[[ $rc != 0 && $SUDO != *sgdisk* && $MSG == *"schon eine Partition"* ]]'
PARTS="/dev/sdb1 /dev/sdb - LEUCHTFEUER iso9660
/dev/sdb3 /dev/sdb LF-DATA LF-DATA ext4"
printf 'LF_BOOT_DEV=/dev/sdb\nLF_BOOT_DISKS=2\n' >"$T/lf-boot.env"
LF_BOOT_ENV="$T/lf-boot.env"
fresh
YESNO_RC=1
persist_startup
result
check "nur eine, aber der Stick ist nicht sicher erkannt: kein Hinweis auf mehrere" '[[ $MSG != *"mehrere Partitionen"* ]]'
LF_BOOT_ENV="$T/fehlt"

# ---------------------------------------------------------------------------
echo "Anlegen: formatiert wird genau die neue Partition (#102):"
# formatiert   Geräte, auf denen luksFormat oder mkfs lief, in dieser Reihenfolge.
formatiert() { grep -E '^(cryptsetup luksFormat|mkfs)' "$T/sudo" 2>/dev/null | awk '{print $NF}' | tr '\n' ' '; }
# neu [ZEILE…]   Ein Stick wie stick(), noch ohne LF-DATA, mit 4 GiB frei und weiteren Partitionen
#   (Zeilen wie in PARTS). Ja zur Verschlüsselung.
neu() {
	local z
	stick
	PARTS="/dev/sda1 /dev/sda ISO9660 LEUCHTFEUER iso9660
/dev/sda2 /dev/sda Appended2 LF_EFI vfat
/dev/sda3 /dev/sda Gap1 - -"
	for z in "$@"; do PARTS+=$'\n'"$z"; done
	fresh
	mbr_neu /dev/sda
	PASSPHRASE="geheim-genug" YESNO_RC=0
}
persist_free_bytes() { echo $((4 * 1073741824)); }
neu
check "die Nummer kommt aus der Tabelle von sgdisk: die erste freie" '[[ $(persist_free_number /dev/sda) == 4 ]]'
persist_create
rc=$?
result
check "frischer Stick: Partition 4 hinter der Lücke, mit fester Nummer angelegt" '[[ $SUDO == *"sgdisk -n 4:0:+2G -t 4:8300 -c 4:LF-DATA /dev/sda"* ]]'
check "verschlüsselt und formatiert wird nur sie, dann eingebunden" '[[ $rc == 0 && $(formatiert) == "/dev/sda4 /dev/mapper/lf-data " && $BIND == bind ]]'
check "das Boot-Flag im MBR steht danach wieder da (#106), nach sgdisk -e und nach sgdisk -n zurückgeschrieben" '[[ $(mbr_eintrag /dev/sda) == "$XORRISO_MBR2" ]] && mbr_reihenfolge'
check "ohne Hinweis zum Boot-Flag, mit Zeile im Protokoll" '[[ $MSG != *Boot-Flag* ]] && grep -q "Boot-Flag im MBR von /dev/sda zurückgeschrieben" "$T/log"'
neu
YESNO_RC=1
persist_create
rc=$?
result
check "ohne Verschlüsselung: mkfs nur auf ihr" '[[ $rc == 0 && $(formatiert) == "/dev/sda4 " ]]'
neu "/dev/sda5 /dev/sda LF-DATA-alt - ext4"
persist_create
rc=$?
result
check "eine Partition LF-DATA-alt hinter einer Lücke bleibt unberührt" '[[ $rc == 0 && $(formatiert) == "/dev/sda4 /dev/mapper/lf-data " ]]'
neu
SGDISK_P_LEER=1
persist_create
rc=$?
result
check "nennt sgdisk keine Partition: nichts formatiert, auch nicht der ganze Stick" '[[ $rc != 0 && -z $(formatiert) ]]'
unset SGDISK_P_LEER
neu
SGDISK_I_NAME=Gap9
persist_create
rc=$?
result
check "heißt der neue Eintrag nicht genau LF-DATA: nichts formatiert, mit Meldung" '[[ $rc != 0 && -z $(formatiert) && $MSG == *"nicht sicher als LF-DATA"* ]]'
unset SGDISK_I_NAME
neu
NEU_UNSICHTBAR=1
persist_create
rc=$?
result
check "erscheint die neue Partition nicht: nichts formatiert" '[[ $rc != 0 && -z $(formatiert) && $MSG == *"noch nicht sichtbar"* ]]'
unset NEU_UNSICHTBAR
neu
SGDISK_N_NAME=Gap9 SGDISK_I_NAME=LF-DATA
persist_create
rc=$?
result
check "sieht lsblk die neue Partition nicht als einzige LF-DATA: nichts formatiert" '[[ $rc != 0 && -z $(formatiert) && $MSG == *"nicht sicher als LF-DATA"* ]]'
unset SGDISK_N_NAME SGDISK_I_NAME
neu
PARTS=""
for n in {1..128}; do PARTS+="/dev/sda$n /dev/sda P$n - -"$'\n'; done
check "sind alle 128 Nummern belegt, gibt es keine" '! persist_free_number /dev/sda >/dev/null'

# ---------------------------------------------------------------------------
echo "Anlegen: das Boot-Flag im MBR des Sticks bleibt (#106):"
neu
mbr_neu /dev/sda "$PERSIST_MBR_LEER"
persist_create
rc=$?
result
check "trug Eintrag 2 vorher kein Boot-Flag, schreibt das Anlegen keins hinein" '[[ $rc == 0 && $(mbr_eintrag /dev/sda) == "$PERSIST_MBR_LEER" && $SUDO != *"dd of="* && $MSG != *Boot-Flag* ]]'
neu
SGDISK_MBR2=00fe0100000001000000000001000000
persist_create
rc=$?
result
check "steht nach sgdisk etwas anderes in Eintrag 2, bleibt es, mit einem Hinweis" '[[ $rc == 0 && $(mbr_eintrag /dev/sda) == "$SGDISK_MBR2" && $SUDO != *"dd of="* && $(grep -c "Boot-Flag im MBR des Sticks" <<<"$MSG") == 1 ]] && grep -q "ist nicht leer (00fe" "$T/log"'
unset SGDISK_MBR2
neu
DD_OHNE_WIRKUNG=1
persist_create
rc=$?
result
check "wirkt das Zurückschreiben nicht, sagt der Assistent das einmal, der Speicher entsteht trotzdem" '[[ $rc == 0 && $(mbr_eintrag /dev/sda) == "$PERSIST_MBR_LEER" && $(grep -c "Boot-Flag im MBR des Sticks" <<<"$MSG") == 1 && $(formatiert) == "/dev/sda4 /dev/mapper/lf-data " ]]'
unset DD_OHNE_WIRKUNG
neu
persist_free_bytes() { echo 0; }
persist_create
rc=$?
result
check "bricht das Anlegen nach sgdisk -e ab (zu wenig Platz), steht das Boot-Flag trotzdem wieder da" '[[ $rc != 0 && $MSG == *"zu wenig freier Platz"* && $(mbr_eintrag /dev/sda) == "$XORRISO_MBR2" ]]'

# ---------------------------------------------------------------------------
echo "lf.conf wird gelesen, nicht ausgeführt:"
cat >"$PERSIST_CONFIG" <<EOF
# Eigene Einstellungen
LF_TECHNIKER="Tim Beispiel"

  LF_TARGET_FS=exfat
touch $T/MARKE-zeile
LF_TARGET_FS=\$(touch $T/MARKE-ersetzung)
PATH=$T/fremd:/usr/bin
LF_TECHNIKER="a"; touch $T/MARKE-semikolon
export LF_TARGET_FS=ext4
LF_TECHNIKER=\`touch $T/MARKE-backtick\`
LF_TARGET_FS=ntfs
LF_TARGET_FS=ext4 # Kommentar hinter dem Wert
LF_SSH_AUTOSTART=1
. $T/fremd.sh
EOF
echo "touch $T/MARKE-eingebunden" >"$T/fremd.sh"
old_path=$PATH
unset LF_TECHNIKER LF_TARGET_FS LF_SSH_AUTOSTART
persist_config_load "$PERSIST_CONFIG"
rc=$?
check "gelesen" '[[ $rc == 0 ]]'
check "gültige Zeilen setzen ihre Einstellung" '[[ ${LF_TECHNIKER:-} == "Tim Beispiel" && ${LF_TARGET_FS:-} == exfat ]]'
check "ein Name, den der Assistent nicht kennt, setzt nichts" '[[ -z ${LF_SSH_AUTOSTART:-} ]]'
check "jede andere Zeile ist als nicht übernommen vermerkt" '[[ ${PERSIST_CONFIG_REJECTED-} == " 5 6 7 8 9 10 11 12 13 14" ]]'
check "PATH bleibt, wie er war" '[[ $PATH == "$old_path" ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# Dasselbe über das echte persist_bind: Dort wurde die Datei bisher per "." eingelesen.
# shellcheck disable=SC1091
. rescue/lib/persist.sh
PERSIST_CONFIG="$T/etc-lf/lf.conf"
fresh
unset LF_TECHNIKER LF_TARGET_FS LF_SSH_AUTOSTART
persist_bind
result
check "persist_bind: Einstellungen übernommen" '[[ ${LF_TECHNIKER:-} == "Tim Beispiel" && ${LF_TARGET_FS:-} == exfat ]]'
check "persist_bind: nichts ausgeführt" '! markers && [[ $PATH == "$old_path" ]]'
check "persist_bind: der Techniker erfährt, welche Zeilen nicht übernommen wurden" '[[ $MSG == "lf.conf|"*"nicht übernommen: 5 6 7 8 9 10 11 12 13 14"* ]]'
check "persist_bind: das Home von Claude kommt vom Speicher" '[[ $SUDO == *"mount --bind $LF_PERSIST/claude-home $CLAUDE_HOME"* ]]'
check "persist_bind: die eigene CLAUDE.md legt Claude selbst an, nicht der Live-Benutzer" '[[ $SUDO == *"-u lf-claude -H test -f $CLAUDE_HOME/.claude/CLAUDE.md"* ]]'
check "persist_bind: die Verläufe in seinem Home vom Speicher bereinigt Claude selbst" '[[ $(sed -n 1p <<<"$SCRUB") == "Speicher|claude_as -- $CLAUDE_HOME" ]]'
check "persist_bind: die alten Ordner auf dem Speicher bereinigt der Live-Benutzer, sonst nichts" '[[ $(sed -n 2p <<<"$SCRUB") == "Speicher|-- $LF_PERSIST/home/.claude $LF_PERSIST/home/.config/Claude" && $(grep -c . <<<"$SCRUB") == 2 ]]'
rm -f "$PERSIST_CONFIG"
fresh
persist_bind
result
check "fehlt die Datei, legt persist_bind die Vorlage an, und sie ist gültig" '[[ -s $PERSIST_CONFIG && -z $MSG ]] && persist_config_load "$PERSIST_CONFIG" && [[ -z ${PERSIST_CONFIG_REJECTED-} ]]'
printf 'LF_TARGET_FS=ext4\r\nLF_TECHNIKER="Erika Muster"\r\n' >"$PERSIST_CONFIG"
unset LF_TARGET_FS LF_TECHNIKER
persist_config_load "$PERSIST_CONFIG"
check "Zeilenenden von Windows, Wert mit und ohne Anführungszeichen" '[[ ${LF_TARGET_FS:-} == ext4 && ${LF_TECHNIKER:-} == "Erika Muster" && -z $PERSIST_CONFIG_REJECTED ]]'
rm -f "$PERSIST_CONFIG"
echo 'LF_TARGET_FS=exfat' >"$T/woanders.conf"
ln -s "$T/woanders.conf" "$PERSIST_CONFIG"
unset LF_TARGET_FS
persist_config_load "$PERSIST_CONFIG"
rc=$?
check "eine Verknüpfung an Stelle der Datei wird nicht gelesen" '[[ $rc != 0 && -z ${LF_TARGET_FS:-} ]]'
rm -f "$PERSIST_CONFIG"

echo "Übergang von firestrike-rescue (eine Beta lang): frs.conf:"
PERSIST_CONFIG_OLD="$T/etc-lf/frs.conf"
printf 'FRS_TECHNIKER="Erika Muster"\nFRS_TARGET_FS=exfat\nFRS_SSH_AUTOSTART=1\n' >"$PERSIST_CONFIG_OLD"
fresh
unset LF_TARGET_FS LF_TECHNIKER LF_SSH_AUTOSTART
persist_bind
result
check "fehlt die lf.conf, wird die frs.conf übernommen" '[[ -f $PERSIST_CONFIG ]] && cmp -s "$PERSIST_CONFIG" "$PERSIST_CONFIG_OLD"'
check "die frs.conf selbst bleibt" '[[ -f $PERSIST_CONFIG_OLD ]]'
check "ihre FRS-Namen gelten als die LF-Namen" '[[ ${LF_TECHNIKER:-} == "Erika Muster" && ${LF_TARGET_FS:-} == exfat ]]'
check "ein FRS-Name, den der Assistent nicht kennt, setzt nichts und wird gemeldet" '[[ -z ${LF_SSH_AUTOSTART:-} && $MSG == "lf.conf|"*"nicht übernommen: 3"* ]]'
echo 'LF_TARGET_FS=ext4' >"$PERSIST_CONFIG"
fresh
unset LF_TARGET_FS LF_TECHNIKER
persist_bind
check "gibt es die lf.conf schon, gilt nur sie" '[[ ${LF_TARGET_FS:-} == ext4 && -z ${LF_TECHNIKER:-} ]]'
rm -f "$PERSIST_CONFIG" "$PERSIST_CONFIG_OLD"
echo 'FRS_TARGET_FS=exfat' >"$T/woanders.conf"
ln -s "$T/woanders.conf" "$PERSIST_CONFIG_OLD"
fresh
unset LF_TARGET_FS
persist_bind
check "eine Verknüpfung an Stelle der frs.conf wird nicht übernommen" '[[ -z ${LF_TARGET_FS:-} ]] && ! grep -q FRS_ "$PERSIST_CONFIG"'

# ---------------------------------------------------------------------------
echo "Boot-Flag im MBR mit dem echten sgdisk (#106):"
if command -v sgdisk >/dev/null && command -v xorriso >/dev/null; then
	# Ein kleines ISO, partitioniert wie make_iso in build/build.sh (ohne Bootloader), auf 64 MiB
	# vergrößert wie ein Stick.
	img=$T/stick.img
	mkdir -p "$T/iso"
	echo x >"$T/iso/x"
	head -c 1048576 /dev/zero >"$T/efi.img"
	xorriso -as mkisofs -quiet -V LEUCHTFEUER -o "$img" -partition_offset 16 --mbr-force-bootable \
		-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$T/efi.img" -appended_part_as_gpt "$T/iso" >/dev/null 2>&1
	truncate -s 64M "$img"
	sudo() { "$@"; }
	mbr=$(persist_mbr_merken "$img")
	check "xorriso legt Eintrag 2 mit dem Boot-Flag an" '[[ $mbr == "$XORRISO_MBR2" ]]'
	command sgdisk -e "$img" >/dev/null 2>&1
	check "sgdisk -e leert Eintrag 2: So ging das Boot-Flag verloren" '[[ $(persist_mbr_eintrag "$img") == "$PERSIST_MBR_LEER" ]]'
	persist_mbr_zurueck "$img" "$mbr"
	check "persist_mbr_zurueck schreibt ihn zurück" '[[ $(persist_mbr_eintrag "$img") == "$mbr" ]]'
	command sgdisk -n 4:0:+8M -t 4:8300 -c 4:LF-DATA "$img" >/dev/null 2>&1
	check "sgdisk -n leert ihn wieder" '[[ $(persist_mbr_eintrag "$img") == "$PERSIST_MBR_LEER" ]]'
	persist_mbr_zurueck "$img" "$mbr"
	check "danach steht er wieder da, die GPT ist gültig, LF-DATA ist Partition 4" '[[ $(persist_mbr_eintrag "$img") == "$mbr" ]] && command sgdisk -v "$img" 2>&1 | grep -q "No problems found" && command sgdisk -i 4 "$img" | grep -qx "Partition name: '"'"'LF-DATA'"'"'"'
	check "Eintrag 1 bleibt der Schutz-Eintrag (Typ EE)" '[[ $(od -An -tx1 -j 450 -N 1 "$img" | tr -d " ") == ee ]]'
	unset -f sudo
else
	echo "  übersprungen: sgdisk oder xorriso fehlt"
fi

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
