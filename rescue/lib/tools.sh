# shellcheck shell=bash
# Werkzeuge: SMART, Speichertest, Netzwerk, SSH, Protokolle, Shell.

tools_menu() {
	local c
	while true; do
		c=$(ui_menu "Werkzeuge" "" -- \
			smart "SMART-Details und Selbsttest" \
			mem "Arbeitsspeicher kurz testen (memtester)" \
			net "Netzwerk / WLAN verbinden (nmtui)" \
			ssh "Fernzugriff per SSH ein/aus" \
			persist "Persistenter Speicher" \
			freigabe "Claude-Freigabe (volles sudo, zeitlich begrenzt)" \
			logs "Protokolle ansehen" \
			hw "Hardware-Übersicht" \
			mc "Dateimanager (Midnight Commander)" \
			shell "Shell (Rückkehr mit exit)") || return 0
		case $c in
		smart) tools_smart ;;
		mem) tools_mem ;;
		net) nmtui ;;
		ssh) tools_ssh ;;
		persist) persist_menu ;;
		freigabe) claude_freigabe_menu ;;
		logs) tools_logs ;;
		hw) sudo lshw -short >"$LF_RUN/hw.txt" 2>&1; ui_textfile "Hardware" "$LF_RUN/hw.txt" ;;
		mc) mc ;;
		shell) clear; echo "Shell. Zurück zum Assistenten mit 'exit'."; bash -i ;;
		esac
	done
}

tools_smart() {
	local id dev a
	id=$(disk_pick "SMART" "Welche Disk?") || return 0
	dev=$(disk_resolve "$id")
	a=$(ui_menu "SMART" "$dev" -- \
		show "Alle SMART-Daten anzeigen" \
		short "Kurztest starten (ca. 2 Minuten)" \
		long "Langtest starten (Stunden; NICHT bei defekten Disks)" \
		result "Testergebnisse anzeigen") || return 0
	case $a in
	show | result)
		sudo smartctl -x "$dev" >"$LF_RUN/smart.txt" 2>&1
		ui_textfile "SMART $dev" "$LF_RUN/smart.txt"
		;;
	short) run sudo smartctl -t short "$dev"; ui_msg "SMART" "Kurztest läuft. Ergebnis in ca. 2 Minuten unter 'Testergebnisse'." ;;
	long)
		ui_yesno "Langtest" "Der Langtest liest die ganze Disk. Bei einer kranken Disk kann das den Zustand verschlechtern.\nVorher retten! Trotzdem starten?" --defaultno &&
			run sudo smartctl -t long "$dev" && ui_msg "SMART" "Langtest läuft im Laufwerk selbst."
		;;
	esac
	rm -f "$LF_RUN/smart-$(basename "$dev")"
}

tools_mem() {
	local free mb
	free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
	mb=$(ui_input "memtester" "Wie viele MB testen? (verfügbar: $free MB)\nFür einen gründlichen Test besser memtest86+ aus dem Bootmenü." "$((free * 7 / 10))") || return 0
	[[ $mb =~ ^[0-9]+$ ]] || return 0
	tmux_run "lf-memtest" bash -c 'sudo memtester "$1"M 1; read -r -p "Fertig. Enter … " _' _ "$mb"
}

tools_ssh() {
	local rest
	if systemctl is-active -q ssh; then
		ui_yesno "SSH" "SSH ist an. Ausschalten?\n\nDas beendet auch alle offenen SSH-Sitzungen." && tools_ssh_off
		return 0
	fi
	# SSH ist aus, aber es läuft noch etwas davon, etwa nach systemctl stop ssh in einer Shell:
	# Das endet zuerst, wie beim Ausschalten.
	rest=$(tools_ssh_rest)
	if [[ -n $rest ]]; then
		ui_yesno "SSH" "SSH ist aus, aber noch läuft:\n\n${rest//$'\n'/\\n}\n\nBeenden? Das sperrt auch das Einmal-Passwort." && tools_ssh_off
		return 0
	fi
	is_online || { ui_msg "SSH" "Keine Netzwerkverbindung."; return 0; }
	local pw ips fps
	# Die Hostschlüssel dieses Starts (lf-ssh-hostkeys.service). Fehlen sie noch, entstehen sie
	# hier, nie aus dem Image (GHSA-72hw-w482-prv6).
	run sudo ssh-keygen -A || { ui_msg "SSH" "Die SSH-Hostschlüssel ließen sich nicht erzeugen. SSH bleibt aus."; return 0; }
	fps=$(tools_ssh_fingerprints)
	[[ -n $fps ]] || { ui_msg "SSH" "Die SSH-Hostschlüssel fehlen. SSH bleibt aus."; return 0; }
	# Erst die Regel, die lf-claude den Weg zu sshd auf diesem Rechner sperrt, frisch geladen und
	# geprüft, dann das Passwort (GHSA-cmcp-h343-c4gj).
	tools_ssh_sperre || return 0
	pw=$(tr -dc 'a-km-zA-HJ-NP-Z2-9' </dev/urandom | head -c 12)
	echo "$(id -un):$pw" | sudo chpasswd
	# ssh startet nur mit der Regel, die lf-claude den Weg zu sshd auf diesem Rechner sperrt
	# (lf-claude-ssh-sperre.service, GHSA-cmcp-h343-c4gj). Scheitert der Start, gilt das Passwort nicht.
	if ! run sudo systemctl start ssh; then
		run sudo usermod -p '!' "$(id -un)"
		log "SSH ließ sich nicht starten, das Einmal-Passwort ist wieder gesperrt"
		ui_msg "SSH" "SSH ließ sich nicht starten. Das Einmal-Passwort gilt nicht.\n\nDetails: journalctl -u ssh -u lf-claude-ssh-sperre"
		return 0
	fi
	ips=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
	log "SSH eingeschaltet (Einmal-Passwort gesetzt), Hostschlüssel: ${fps//$'\n'/, }"
	ui_msg "SSH ist an" "Verbinden mit:\n\n   ssh $(id -un)@${ips%% *}\n\nAdressen: $ips\nPasswort (nur für diese Sitzung): $pw\n\nSchlüssel dieses Rechners. Beim ersten Verbinden mit dem vergleichen, den ssh nennt:\n${fps//$'\n'/\\n}\n\nLaufende Rettung ansehen: tmux attach -t lf-rettung"
}

# Die Prozesse von sshd: der wartende, der je Verbindung und der bei der Anmeldung.
TOOLS_SSH_RE='sshd|sshd-session|sshd-auth'

# tools_ssh_off   Schaltet SSH aus (GHSA-45m7-28wq-mxq8): Das Einmal-Passwort gilt nicht mehr, sshd
#   nimmt keine Verbindung mehr an, und jede SSH-Sitzung endet samt allem, was in ihr läuft, auch
#   eine Verbindung, die noch bei der Anmeldung ist. systemctl stop allein beendet nur den sshd, der
#   auf Verbindungen wartet: Angemeldete Sitzungen liegen in eigenen Scopes von logind, und für
#   ssh.service gilt bei Ubuntu KillMode=process. Was sshd ohne Sitzung von logind startet, bleibt
#   im cgroup von ssh.service: Darum endet dort zuerst alles mit SIGKILL. Bleibt etwas übrig, sagt
#   das der Dialog.
tools_ssh_off() {
	local re=$TOOLS_SSH_RE id n=0 sessions procs cg msg="SSH ist aus."
	local -a left=()
	if run sudo usermod -p '!' "$(id -un)"; then
		msg+=" Das Einmal-Passwort gilt nicht mehr."
	else
		left+=("Das Einmal-Passwort ließ sich nicht sperren.")
	fi
	# Zuerst der Socket: Danach startet keine Verbindung ssh.service neu.
	run sudo systemctl stop ssh.socket
	run sudo systemctl kill --signal=SIGKILL ssh.service
	run sudo systemctl stop ssh.service
	# Dann alle Prozesse von sshd: Danach entsteht keine Sitzung mehr. Dann, was in den Sitzungen
	# noch läuft, auch im Hintergrund.
	run sudo pkill -KILL -x "$re"
	for id in $(tools_ssh_sessions); do
		run sudo loginctl kill-session --signal=SIGKILL "$id"
		run sudo loginctl terminate-session "$id"
		n=$((n + 1))
	done
	# logind räumt eine Sitzung erst ab, wenn ihr Scope leer ist.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		sessions=$(tools_ssh_sessions)
		procs=$(sudo pgrep -l -x "$re")
		cg=$(tools_ssh_cgroup)
		[[ -z $sessions && -z $procs && $cg == 0 ]] && break
		sleep 0.3
	done
	[[ -n $sessions ]] && left+=("Noch offene SSH-Sitzungen: ${sessions//$'\n'/, }")
	[[ -n $procs ]] && left+=("Noch laufende Prozesse von sshd: ${procs//$'\n'/, }")
	[[ $cg != 0 ]] && left+=("Noch laufende Prozesse in ssh.service: $cg")
	log "SSH ausgeschaltet, beendete SSH-Sitzungen: $n${left[*]:+. ${left[*]}}"
	((n == 1)) && msg+="\n\n1 offene SSH-Sitzung wurde beendet."
	((n > 1)) && msg+="\n\n$n offene SSH-Sitzungen wurden beendet."
	((${#left[@]})) && msg+="\n\nNicht alles ist beendet:$(printf '\\n   %s' "${left[@]}")"
	((n || ${#left[@]})) && msg+="\n\nWer per SSH angemeldet war, hatte root. Was er gestartet hat, kann weiterlaufen. Sicher endet das nur mit einem Neustart (Beenden > Neustart)."
	ui_msg "SSH" "$msg"
	return 0
}

# tools_ssh_rest   Was von SSH noch läuft, je Art eine Zeile: Sitzungen von logind aus sshd,
#   Prozesse von sshd und alle Prozesse im cgroup von ssh.service. Leer, wenn nichts mehr läuft.
tools_ssh_rest() {
	local s p n
	s=$(tools_ssh_sessions)
	p=$(sudo pgrep -x "$TOOLS_SSH_RE" | grep -c .)
	n=$(tools_ssh_cgroup)
	[[ -n $s ]] && echo "SSH-Sitzungen: ${s//$'\n'/, }"
	((p)) && echo "Prozesse von sshd: $p"
	((n)) && echo "Prozesse in ssh.service: $n"
	return 0
}

# tools_ssh_cgroup   Wie viele Prozesse im cgroup von ssh.service laufen (0, wenn es keins gibt).
#   LF_SSH_CGROUP nennt für Tests eine andere Datei als cgroup.procs.
tools_ssh_cgroup() {
	local f=${LF_SSH_CGROUP:-/sys/fs/cgroup/system.slice/ssh.service/cgroup.procs}
	if [[ -r $f ]]; then grep -c . "$f"; else echo 0; fi
	return 0
}

# tools_ssh_sessions   IDs der Sitzungen von logind, die sshd angelegt hat (PAM-Dienst sshd), je
#   Zeile eine. Dazu zählen auch Sitzungen, die gerade enden, solange in ihnen noch etwas läuft.
tools_ssh_sessions() {
	local id
	for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
		[[ $id =~ ^[[:alnum:]]+$ ]] || continue
		[[ $(loginctl show-session "$id" -p Service --value 2>/dev/null) == sshd ]] && echo "$id"
	done
	return 0
}

# tools_ssh_fingerprints   SHA256-Fingerabdrücke der Hostschlüssel, je Zeile "   SHA256:… (TYP)".
tools_ssh_fingerprints() {
	local k d=${LF_SSH_DIR:-/etc/ssh}
	for k in "$d/ssh_host_ed25519_key.pub" "$d/ssh_host_ecdsa_key.pub" "$d/ssh_host_rsa_key.pub"; do
		[[ -r $k ]] || continue
		ssh-keygen -l -E sha256 -f "$k" 2>/dev/null | awk '$2 ~ /^SHA256:/ {print "   " $2 " " $NF}'
	done
}

# tools_ssh_sperre   Vor dem Einschalten (GHSA-cmcp-h343-c4gj): lädt die Regel aus lf-claude-ssh.nft
#   neu (lf-claude-ssh-sperre.service) und prüft, dass genau sie geladen ist und neben ssh.service
#   kein Weg zu sshd führt. Sonst sagt es das und gibt 1 zurück: SSH bleibt aus, ein Einmal-Passwort
#   gibt es nicht.
tools_ssh_sperre() {
	local uid weg
	if ! run sudo systemctl restart lf-claude-ssh-sperre.service; then
		log "SSH bleibt aus: lf-claude-ssh-sperre.service ließ sich nicht starten"
		ui_msg "SSH" "Die Regel, die Claude den Weg zu SSH auf diesem Rechner sperrt, ließ sich nicht laden. SSH bleibt aus.\n\nDetails: journalctl -u lf-claude-ssh-sperre"
		return 1
	fi
	if ! uid=$(id -u lf-claude 2>/dev/null) || ! sudo nft -j list table inet lf_claude_ssh 2>/dev/null | tools_ssh_regel "$uid"; then
		log "SSH bleibt aus: geladen ist nicht die Regel aus lf-claude-ssh.nft"
		ui_msg "SSH" "Geladen ist nicht genau die Regel aus lf-claude-ssh.nft, die Claude den Weg zu SSH auf diesem Rechner sperrt. SSH bleibt aus.\n\nDetails: sudo nft list table inet lf_claude_ssh"
		return 1
	fi
	weg=$(tools_ssh_nebenwege)
	if [[ -n $weg ]]; then
		log "SSH bleibt aus: Wege zu sshd neben ssh.service: ${weg//$'\n'/, }"
		ui_msg "SSH" "Neben ssh.service führt ein Weg zu sshd, an der Regel vorbei:\n\n${weg//$'\n'/\\n}\n\nSSH bleibt aus."
		return 1
	fi
	return 0
}

# tools_ssh_regel UID   Liest nft -j list table inet lf_claude_ssh von der Eingabe: Darin steht
#   genau, was lf-claude-ssh.nft lädt, die Kette ausgang am Ausgang (filter, Priorität 0, policy
#   accept), darin nur die Regel lf-claude-ssh: skuid UID, TCP-Port 22, Ziel eine eigene Adresse,
#   Zähler, Abweisen mit TCP-Reset. Für den Assistenten und den Selbsttest (selftest_ssh_lokal).
tools_ssh_regel() {
	jq -e --argjson uid "$1" '
		[.nftables[] | .chain? // empty] as $k | [.nftables[] | .rule? // empty] as $r |
		($k | length) == 1 and ($r | length) == 1 and
		($k[0] | .family == "inet" and .name == "ausgang" and .type == "filter" and .hook == "output" and .prio == 0 and .policy == "accept") and
		($r[0] | .chain == "ausgang" and .comment == "lf-claude-ssh") and
		($r[0].expr | map(if .counter then "counter" elif .match.left.fib then .match.left.fib.flags |= ([.] | flatten) else . end)) == [
			{match: {op: "==", left: {meta: {key: "skuid"}}, right: $uid}},
			{match: {op: "==", left: {payload: {protocol: "tcp", field: "dport"}}, right: 22}},
			{match: {op: "==", left: {fib: {result: "type", flags: ["daddr"]}}, right: "local"}},
			"counter",
			{reject: {type: "tcp reset"}}
		]' >/dev/null
}

# tools_ssh_nebenwege   Wege zu sshd neben ssh.service und ssh.socket, je Zeile einer, leer, wenn es
#   keine gibt (GHSA-cmcp-h343-c4gj). systemd-ssh-generator bindet sshd sonst bei jedem Start an den
#   AF_UNIX-Socket /run/ssh-unix-local/socket (Modus 0666), in einer VM mit /dev/vsock auch an
#   vsock-Port 22, beides unabhängig vom Menü und an der Regel vorbei, die nur TCP sieht.
#   chroot-setup.sh maskiert ihn. Geprüft werden die Maske, der Socket und jede Einheit
#   sshd-*.socket, geladen oder als Datei. LF_SSH_GENERATOR und LF_SSH_UNIX_SOCKET nennen für Tests
#   andere Pfade.
tools_ssh_nebenwege() {
	local g=${LF_SSH_GENERATOR:-/etc/systemd/system-generators/systemd-ssh-generator}
	local s=${LF_SSH_UNIX_SOCKET:-/run/ssh-unix-local/socket} geladen dateien
	[[ -L $g && $(readlink "$g") == /dev/null ]] || echo "systemd-ssh-generator ist nicht maskiert ($g)"
	[[ -e $s || -L $s ]] && echo "Socket $s"
	# list-unit-files endet mit 1, wenn keine Datei passt. Ob systemctl antwortet, zeigt list-units.
	if ! geladen=$(systemctl list-units --all --plain --no-legend 'sshd-*.socket' 2>/dev/null); then
		echo "systemctl nennt die Einheiten sshd-*.socket nicht"
		return 0
	fi
	dateien=$(systemctl list-unit-files --no-legend 'sshd-*.socket' 2>/dev/null)
	# Je Zeile die erste Spalte mit dem Namen der Einheit, ohne die, die es nicht gibt (not-found).
	printf '%s\n%s\n' "$geladen" "$dateien" | awk '{
		for (i = 1; i <= NF; i++) if ($i ~ /^sshd-.*\.socket$/) break
		if (i <= NF && $(i + 1) != "not-found") print "Einheit " $i
	}' | sort -u
	return 0
}

tools_logs() {
	local items=() f
	for f in "$LF_PERSIST"/logs/*.log "$LF_RUN"/logs/*.log; do
		[[ -f $f ]] && items+=("$f" "$(date -r "$f" '+%F %T') $(human "$(stat -c %s "$f")")")
	done
	((${#items[@]})) || { ui_msg "Protokolle" "Keine Protokolle gefunden."; return 0; }
	f=$(ui_menu "Protokolle" "Welches Protokoll?" -- "${items[@]}") || return 0
	ui_textfile "$(basename "$f")" "$f"
}
