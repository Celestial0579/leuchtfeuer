#!/usr/bin/env bash
# Unit-Test: Ein Job-Fenster (tmux_start) ist so groß wie das Terminal, an das sich lf danach
# anhängt. Die erste Zeile des Jobs bleibt nach dem Anhängen zu sehen.
#
# tmux_start legte jedes Fenster mit 200×50 an. Hängte sich lf aus einem schmaleren Terminal an,
# brach tmux die Ausgabe neu um. Wurde dabei eine Zeile zweizeilig, schob tmux 3.6 oben Zeilen in
# den Verlauf: Im Fenster lf-kopie fehlte die Zeile "Kopiere <Quelle>" (#82).
# Ein Fenster, das noch offen ist (sein Job läuft oder wartet auf Enter), nimmt tmux_start nicht
# für einen neuen Job. Es startet nichts und endet mit 2, tmux_run und tmux_run_writing sagen das.
# Verglichen wird der ganze Name. Assistenten, die vor dem Start ihres Jobs fragen oder schreiben,
# prüfen das Fenster zuerst (tmux_job_frei, #87).
# Mit echtem tmux in einem Pseudo-Terminal (script von util-linux), mit eigenem tmux-Server im
# Testordner.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
export TMUX_TMPDIR=$T
unset TMUX

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
ende() {
	tmux kill-server 2>/dev/null
	wait
	rm -rf "$T"
	((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
}

for p in tmux script setsid; do
	command -v "$p" >/dev/null || { echo "  FAIL $p fehlt (Pakete tmux, util-linux)"; fails=$((fails + 1)); }
done
((fails == 0)) || ende

# im_terminal SPALTEN ZEILEN SKRIPT ARG …   Führt SKRIPT in einem Pseudo-Terminal dieser Größe aus.
im_terminal() {
	local c=$1 r=$2
	shift 2
	TERM=xterm-256color script -qec "stty cols $c rows $r; bash $*" /dev/null </dev/null
}

echo "Größe für ein neues Fenster (tmux_size):"
cat >"$T/groesse.sh" <<'EOF'
. rescue/lib/common.sh
tmux_size
EOF
check "Terminal 120×40: 120×39, eine Zeile bleibt für die Statuszeile" '[[ $(im_terminal 120 40 "$T/groesse.sh" | tr -d "\r") == "120 39" ]]'
check "Terminal 80×24: 80×23" '[[ $(im_terminal 80 24 "$T/groesse.sh" | tr -d "\r") == "80 23" ]]'
check "Terminal meldet 0×0 (serielle Konsole): bisherige 200×50" '[[ $(im_terminal 0 0 "$T/groesse.sh" | tr -d "\r") == "200 50" ]]'
check "ohne Terminal: bisherige 200×50, ohne Meldung" '[[ $(setsid bash "$T/groesse.sh" </dev/null 2>&1) == "200 50" ]]'

# Ein Job wie lf-kopie: Startzeile, Zielzeile, eine Hinweiszeile, die breiter ist als das
# Terminal, dann wartet er. Angehängt wird wie in tmux_run gleich nach tmux_start, hier aber erst,
# wenn die Ausgabe dasteht: In lf liegen dazwischen die Aufrufe von tmux set-option, und das
# Fenster hat seine Ausgabe meist schon. Hängt sich tmux früher an, kommt sie erst nach dem
# Anpassen der Größe, und es gibt nichts neu umzubrechen.
cat >"$T/job.sh" <<'EOF'
. rescue/lib/common.sh
hinweis="rsync zählt zuerst die Dateien, die Anzeige kommt danach. Protokoll: /mnt/lf-target/LF/$(printf 'x%.0s' {1..60})/kopie.log"
job='printf "%s\n" "Kopiere /mnt/lf-image/loop4p1" "nach /mnt/lf-target/LF/fall/dateien/loop4p1" "$1" ""; exec sleep 60'
if [[ ${1:-} == alt ]]; then
	# Gegenprobe: so, wie tmux_start das Fenster bisher anlegte
	tmux new-session -d -s lf-test -x 200 -y 50 bash -c "$job" _ "$hinweis"
else
	tmux_start lf-test bash -c "$job" _ "$hinweis"
fi
for i in $(seq 50); do
	tmux capture-pane -p -t lf-test | grep -q '^nach ' && break
	sleep 0.1
done
# Die Größe vor dem Anhängen. Danach passt tmux das Fenster ohnehin an den Client an.
tmux display-message -p -t lf-test '#{window_width}x#{window_height}' >"$TMUX_TMPDIR/vorher"
tmux attach -t lf-test
EOF

# angehaengt   Wartet, bis ein Client an lf-test hängt (höchstens 10 s).
angehaengt() {
	local i
	for i in $(seq 50); do
		[[ -n $(tmux list-clients -t lf-test 2>/dev/null) ]] && { sleep 0.5; return 0; }
		sleep 0.2
	done
	return 1
}
fenster() { tmux display-message -p -t lf-test "$1" 2>/dev/null; }

echo "Fenster lf-kopie, angehängt aus einem Terminal mit 120×40 (#82):"
im_terminal 120 40 "$T/job.sh" >/dev/null 2>&1 &
check "lf hängt sich an das Fenster an" 'angehaengt'
check "das Terminal ist 120×40 groß" '[[ $(fenster "#{client_width}x#{client_height}") == 120x40 ]]'
check "das Fenster ist schon vor dem Anhängen 120×39 groß und bleibt es, nichts wird neu umbrochen" '[[ $(cat "$T/vorher") == 120x39 && $(fenster "#{window_width}x#{window_height}") == 120x39 ]]'
check "nichts ist in den Verlauf gerutscht" '[[ $(fenster "#{history_size}") == 0 ]]'
check "die erste Zeile ist zu sehen: Kopiere <Quelle>" '[[ $(tmux capture-pane -p -t lf-test | head -n 1) == "Kopiere /mnt/lf-image/loop4p1" ]]'
check "die lange Hinweiszeile steht vollständig da (zweizeilig)" '[[ $(tmux capture-pane -p -J -t lf-test | grep -c "/kopie.log$") == 1 ]]'
tmux kill-server 2>/dev/null
wait

echo "Gegenprobe: Fenster fest mit 200×50 wie bisher:"
im_terminal 120 40 "$T/job.sh" alt >/dev/null 2>&1 &
check "lf hängt sich an das Fenster an" 'angehaengt'
check "vor dem Anhängen 200×50, beim Anhängen ändert tmux die Größe auf 120×39 und bricht die Ausgabe neu um" '[[ $(cat "$T/vorher") == 200x50 && $(fenster "#{window_width}x#{window_height}") == 120x39 ]]'
# Ob dabei oben eine Zeile in den Verlauf rutscht, hängt von der Version von tmux ab (3.6: ja).
echo "  info $(tmux -V): Verlauf $(fenster "#{history_size}") Zeile(n), erste sichtbare Zeile: $(tmux capture-pane -p -t lf-test | head -n 1)"

tmux kill-server 2>/dev/null
wait

# Ohne Terminal: tmux attach endet sofort mit einem Fehler, den lf mit || true übergeht.
# ui_msg und job_register schreiben nur mit.
cat >"$T/offen.sh" <<'EOF'
. rescue/lib/common.sh
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$TMUX_TMPDIR/meldungen"; }
job_register() { printf '%s\n' "$*" >>"$TMUX_TMPDIR/jobliste"; }
neu=': >"$1"; exec sleep 60'
case $1 in
start) tmux_start lf-test bash -c "$neu" _ "$TMUX_TMPDIR/neu-start" ;;
run) tmux_run lf-test bash -c "$neu" _ "$TMUX_TMPDIR/neu-run" ;;
writing) tmux_run_writing lf-test /dev/sdz bash -c "$neu" _ "$TMUX_TMPDIR/neu-writing" ;;
frei) tmux_job_frei "$2" ;;
esac
echo "rc=$?"
EOF
offen() { setsid bash "$T/offen.sh" "$@" </dev/null 2>/dev/null; }
# neu DATEI   Hat ein neu gestarteter Befehl DATEI angelegt? Wartet höchstens 1 s.
neu() {
	local i
	for i in $(seq 10); do
		[[ -e $T/$1 ]] && return 0
		sleep 0.1
	done
	return 1
}
# pid NAME   Prozess im Fenster NAME. Ein Ziel für Fenster braucht nach dem genauen Namen den
#   Doppelpunkt, sonst liefert display-message nichts.
pid() { tmux display-message -p -t "=$1:" '#{pane_pid}' 2>/dev/null; }

echo "Das Fenster lf-test ist noch offen, sein Job wartet (#87):"
tmux new-session -d -s lf-test -x 80 -y 23 'exec sleep 60'
alt=$(pid lf-test)
check "tmux_start startet nichts und endet mit 2" '[[ $(offen start) == rc=2 ]] && ! neu neu-start'
check "tmux_run endet mit 2 und sagt, dass im Fenster noch ein Job offen ist" '[[ $(offen run) == rc=2 ]] && ! neu neu-run && grep -q "^Job noch offen|Im Fenster lf-test ist noch ein Job offen" "$T/meldungen"'
check "tmux_run_writing endet mit 2 und trägt keine Disk in die Jobliste ein" '[[ $(offen writing) == rc=2 ]] && ! neu neu-writing && [[ ! -e $T/jobliste ]]'
rm -f "$T/meldungen"
check "tmux_job_frei endet mit 1 und sagt es" '[[ $(offen frei lf-test) == rc=1 ]] && grep -q "^Job noch offen|" "$T/meldungen"'
check "das offene Fenster bleibt, wie es war" '[[ -n $alt && $(pid lf-test) == "$alt" && $(tmux list-sessions -F "#{session_name}" | grep -cx lf-test) == 1 ]]'

echo "Verglichen wird der ganze Name (#87):"
tmux kill-session -t =lf-test
tmux new-session -d -s lf-test-lang -x 80 -y 23 'exec sleep 60'
check "Gegenprobe: ohne = hält tmux das Fenster lf-test-lang für lf-test" 'tmux has-session -t lf-test 2>/dev/null'
rm -f "$T/meldungen"
check "tmux_job_frei lf-test endet mit 0, ohne Meldung" '[[ $(offen frei lf-test) == rc=0 && ! -e $T/meldungen ]]'
check "tmux_start lf-test öffnet ein eigenes Fenster, der Befehl darin läuft" '[[ $(offen start) == rc=0 ]] && neu neu-start && tmux has-session -t =lf-test 2>/dev/null'
tmux kill-server 2>/dev/null
wait

echo "Assistenten prüfen das Fenster ihres Jobs, bevor sie fragen oder schreiben (#87):"
# Was ein Assistent zuerst täte (anzeigen, fragen, anlegen), schreibt nur mit und bricht ab.
cat >"$T/assistent.sh" <<'EOF'
. rescue/lib/common.sh
. rescue/lib/clone.sh
. rescue/lib/p2v.sh
. rescue/lib/recover.sh
LF_RUN=$TMUX_TMPDIR/run
P2V_DIR=$LF_RUN/p2v
tmux_job_offen() { printf '%s\n' "$1" >>"$TMUX_TMPDIR/offen"; }
for f in ui_msg ui_info ui_yesno ui_menu disk_pick safety_set_ro p2v_create casefile_create install; do
	eval "$f() { echo $f >>\"\$TMUX_TMPDIR/getan\"; return 1; }"
done
"$@"
echo "rc=$?"
EOF
assistent() {
	rm -f "$T/offen" "$T/getan"
	setsid bash "$T/assistent.sh" "$@" </dev/null 2>/dev/null
}
mkdir -p "$T/run/p2v"
echo ALT >"$T/run/p2v/kopie.sh"
for s in lf-klon lf-p2v lf-rettung; do tmux new-session -d -s "$s" -x 80 -y 23 'exec sleep 60'; done
check "Klonen und Image auf neue Disk (clone_from_device): kein Ziel gefragt, nichts geschrieben, solange lf-klon offen ist" '[[ $(assistent clone_from_device /dev/sda Quelle) == rc=0 && $(cat "$T/offen") == lf-klon && ! -e $T/getan ]]'
check "P2V: der Assistent zeigt nichts und legt nichts an, solange lf-p2v offen ist" '[[ $(assistent p2v_wizard) == rc=0 && $(cat "$T/offen") == lf-p2v && ! -e $T/getan ]]'
check "P2V: auch direkt vor dem Anlegen der VM, Skript der Kopie unberührt" '[[ $(assistent p2v_run_step) == rc=1 && $(cat "$T/offen") == lf-p2v && ! -e $T/getan && $(cat "$T/run/p2v/kopie.sh") == ALT ]]'
check "Datenrettung: keine Frage, kein neuer Fall, solange lf-rettung offen ist" '[[ $(assistent recover_wizard) == rc=0 && $(cat "$T/offen") == lf-rettung && ! -e $T/getan ]]'
tmux kill-server 2>/dev/null
wait
check "Gegenprobe: sind die Fenster zu, fragen Klonen und Datenrettung wie bisher" '[[ $(assistent clone_from_device /dev/sda Quelle) == rc=0 && ! -e $T/offen && $(cat "$T/getan") == disk_pick ]] && [[ $(assistent recover_wizard) == rc=0 && ! -e $T/offen && $(tr "\n" " " <"$T/getan") == "ui_msg disk_pick " ]]'

ende
