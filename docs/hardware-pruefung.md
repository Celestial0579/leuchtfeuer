Prüfung an echter Hardware
==========================

Die CI prüft Leuchtfeuer nur mit Attrappen, Loop-Geräten und in QEMU. Diese Anleitung ist
die Liste für einen Testrechner mit echten Disks (Issue #34). Hake erledigte Punkte im Issue ab.
Jede Abweichung wird ein eigenes Issue mit Version, Rechner und Foto oder Protokoll.

Bis alle Punkte geprüft sind, bleibt jedes Release eine Beta.

Vorbereitung
------------

- **Version:** das neueste Release, mit Prüfsumme (`sha256sum -c SHA256SUMS`) und Herkunft (`gh attestation verify <iso> --repo Celestial0579/leuchtfeuer`) geprüft
- **Sticks:** zwei USB-Sticks ab 8 GB, mit Rufus (DD-Modus), balenaEtcher oder `dd` beschrieben
- **Testrechner:**
  - einer mit UEFI, bei dem sich Secure Boot ein- und ausschalten lässt
  - einer mit BIOS oder CSM
- **Disks:**
  - eine Disk mit bekannten Lesefehlern, sonst eine alte HDD mit schlechten SMART-Werten
  - eine gesunde Windows-Disk mit BitLocker, dazu der Wiederherstellungsschlüssel
  - zwei Ziel-Disks: eine kleiner, eine größer als die Quelle
- **Adapter:** zwei baugleiche USB-SATA-Adapter
- **Fürs Protokoll:** ein Handy für Fotos vom Bildschirm. Die Protokolle des Assistenten liegen unter `/persist/logs` (mit persistentem Speicher) oder `/run/lf/logs` (ohne).

Notiere zu jedem Punkt die Version (`lf --version`), das Rechnermodell und das Ergebnis.

1 Start
-------

| Prüfung | Erwartet |
|---|---|
| UEFI mit Secure Boot, vom Stick | Bootmenü „Leuchtfeuer“, nach 10 s startet der Assistent auf tty1 |
| UEFI ohne Secure Boot | wie oben, zusätzlich der Eintrag memtest86+ |
| BIOS oder CSM | wie oben |
| Eintrag „in den RAM laden“, Stick danach abziehen | Der Assistent und die Werkzeuge laufen weiter |
| Sicherer Grafikmodus | Bild ohne Grafiktreiber |
| Alt+F2 … F6 | Eine Shell als `rescue`, ohne Anmeldung. Mit Strg+D kommt sie neu, wieder ohne Anmeldung |

Nach jedem Start in der Shell (Werkzeuge > Shell):

```bash
cat /run/lf-boot.env
```

`LF_BOOT_DEV` ist der Stick, `LF_BOOT_DISKS=1`.

2 Startkette mit fremden Disks (GHSA-fgc3-pr99-9chm)
----------------------------------------------------

Das Rettungssystem darf nur vom eigenen, geprüften Medium starten, auch wenn fremde Disks
angeschlossen sind.

1. **Fremde Disk mit GRUB-Konfiguration:**
   - Einen zweiten Stick mit FAT32 formatieren und die Dateien `/.disk/info` (beliebiger Text) und `/boot/grub/grub.cfg` mit diesem Inhalt anlegen:
     ```
     echo "GEKAPERT"
     sleep 30
     ```
   - Beide Sticks anstecken, den fremden möglichst an den ersten Anschluss, und per UEFI vom Leuchtfeuer-Stick starten.
   - Erwartet: Vor dem Bootmenü steht kurz „Leuchtfeuer: Startmedium (…) auf derselben Disk“, nie „GEKAPERT“.
2. **Zwei Sticks mit derselben ISO:**
   - Den zweiten Stick mit derselben ISO beschreiben. Beide anstecken und von einem starten.
   - Erwartet: Das System startet. `cat /run/lf-boot.env` zeigt `LF_BOOT_DISKS=2`. Der Assistent bindet keinen persistenten Speicher ein, und das Anlegen eines Speichers lehnt er mit einer Meldung ab.
3. **Nur der fremde Stick aus Schritt 1** und die Firmware startet von ihm: Er bootet nichts, was wie Leuchtfeuer aussieht. Das ist eine Gegenprobe, kein Fehler.

3 Persistenter Speicher
-----------------------

1. Frischen Stick starten. Beim ersten Start einen verschlüsselten Speicher mit 2 GiB anlegen, neu starten, Passphrase eingeben.
   Erwartet: `findmnt /persist` zeigt die Partition `LF-DATA` auf dem Stick, mit `nodev,nosuid`.
   - **Legacy-Start danach (#106):** Den Stick am Rechner mit BIOS oder CSM starten.
   - Erwartet: Er startet wie vor dem Anlegen. In der Shell zeigt `sudo od -An -tx1 -j 462 -N 1 /dev/sdX` den Wert `80`, das Boot-Flag im MBR. `sdX` ist `LF_BOOT_DISK` aus `/run/lf-boot.env`.
2. Dasselbe mit einem unverschlüsselten Speicher auf dem zweiten Stick: Der Assistent fragt vor dem Einbinden nach.
3. Eine Partition mit dem Label `LF-DATA` auf einer anderen Disk anlegen und anschließen: Der Assistent verwendet sie nie, er weist nur auf sie hin.
   - Auf dem Stick aus Schritt 2 an einem anderen Rechner eine zweite Partition mit dem Namen `LF-DATA` anlegen (`sudo sgdisk -n 0:0:+600M -c 0:LF-DATA /dev/sdX`, `/dev/sdX` ist der Stick), wie es frühere Betas bei einem „Ja“ beim Start taten. Dann davon starten.
   - Erwartet: Der Assistent bindet keine der beiden ein, sagt das beim Start und bietet keinen neuen Speicher an.
4. **Wirkung von `nosuid`.** Der Selbsttest läuft als root und kann das nicht prüfen. Als Live-Benutzer in der Shell:
   ```bash
   sudo cp /usr/bin/id /persist/id-probe && sudo chmod 4755 /persist/id-probe
   /persist/id-probe -u; sudo rm /persist/id-probe
   ```
   Erwartet: Die Zahl ist die eigene Benutzer-ID (meist 999), nicht 0.

4 Datenrettung
--------------

1. **Defekte Disk über einen USB-Adapter retten,** Ziel ist eine ext4-Disk.
   Erwartet:
   - Die Quelle ist sofort schreibgeschützt (`blockdev --getro` ergibt 1).
   - Alle drei Phasen laufen.
   - `report.txt` und `smart-before.txt`/`smart-after.txt` liegen unter `LF/…`.
2. **Während Phase 1 den USB-Adapter der Quelle abziehen, wieder anstecken** und „Unterbrochene Rettung fortsetzen“ wählen.
   Erwartet: Es geht an der Stelle weiter, an der der Lauf aufgehört hat. Mit einer anderen Disk statt der Quelle lehnt der Assistent ab.
3. **Neustart während der Rettung,** dann fortsetzen: wie Schritt 2.
4. **Ziel exFAT und Ziel NTFS** (eine vorhandene NTFS-Partition mit genug Platz): Die Rettung läuft, und das Image ist danach unter Windows lesbar. Das gilt auch ohne setuid für ntfs-3g (#153).

5 Klonen
--------

1. **Auf eine größere Disk**, mit „Ziel ersetzt die Quelle“, dann nur das Ziel einbauen und starten.
   Erwartet: Windows oder Linux startet, und die Hauptpartition ist gewachsen.
2. **Auf eine kleinere Disk**, wenn die Daten passen.
   Erwartet: Der Assistent verkleinert die Hauptpartition, die Quelle bleibt unverändert (Prüfsumme der Quelle vorher und nachher). Das Ziel startet.
3. Klon mit „Beide bleiben“, dann beide Disks gleichzeitig anschließen: Beide starten, ohne sich zu verwechseln.

6 Image weiterverwenden
-----------------------

1. **BitLocker-Disk retten,** dann aus dem Image Dateien kopieren: Die Partition lässt sich mit dem Wiederherstellungsschlüssel öffnen. `findmnt` zeigt `ro,nodev,nosuid,noexec`.
2. Image in VHDX umwandeln und unter Windows einbinden.

7 Zwei baugleiche USB-Adapter
-----------------------------

Quelle und Ziel hängen an zwei baugleichen Adaptern.

Erwartet:
- Der Assistent unterscheidet die Disks.
- Die Auswahl passt zu der Disk, die du meinst: Abziehen und Disk-Liste aktualisieren.
- Melden beide Adapter dieselbe feste Seriennummer, verwendet der Assistent sie für keine der beiden Disks als Kennung, sondern das nächste Merkmal.

Notiere, was `lsblk -d -o NAME,MODEL,SERIAL,WWN,TRAN` für beide Disks zeigt.

8 Claude
--------

Nur mit Internet und eigenem Konto.

1. **Claude (CLI) über das Menü starten, `/login`.**
   Erwartet: Claude liest `zustand.txt`. Bitte Claude, eine Quell-Disk mit `blockdev --setrw` beschreibbar zu machen: Das Rettungssystem lehnt ab, ohne Rückfrage.
2. **Einen schreibenden Befehl von Claude vorschlagen lassen,** zum Beispiel `dd` auf eine Testdatei.
   Erwartet: Die Rückfrage nennt den Grund, „nicht mehr fragen“ gibt es nicht.
3. **In der Shell in einem Ordner auf einem fremden Datenträger `claude` starten.** Der Ordner hat eine `.claude/settings.json` mit `{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}}`.
   Erwartet: Claude Code verbindet sich normal. Die Einstellung des Ordners gilt nicht.
4. **Neue Version der CLI:** Mit persistentem Speicher startet beim nächsten Start eine Aktualisierung.
   Erwartet: Vor dem ersten Start der neuen Version steht „Neue Version von Claude Code … wird geprüft“, danach „Bestanden.“. Das Ergebnis steht in `/var/lib/lf-claude/.local/state/lf/claude-check/`.
5. **Rechte von Claude:** Claude fragen, als wer es läuft und was `sudo -l` zeigt.
   Erwartet: Benutzer `lf-claude`, sudo nur für `lf-lesen` und `lf-aufgabe`. `sudo dd`, `sudo mkfs` und `sudo -i` lehnt sudo ab. Die Statuszeile von Claude Code zeigt „Claude arbeitet mit lf-lesen und lf-aufgabe“.
6. **Aufgaben selbständig:** Im Assistenten ein Ziel wählen und bestätigen, dann Claude bitten, eine kleine Testdisk zu retten und ein paar Dateien daraus aufs Ziel zu kopieren.
   Erwartet: Claude benutzt `sudo lf-aufgabe retten`, `image`, `einhaengen` und `kopieren`. Die Quelle ist danach schreibgeschützt, die Dateien liegen unter `LF/claude/`. Ein Versuch, auf eine andere Disk als das Ziel zu schreiben, scheitert.
7. **Claude-Freigabe:** Werkzeuge > Claude-Freigabe, 1 Minute.
   Erwartet: Das Hauptmenü und die Statuszeile zeigen „volles sudo“, `sudo -l` für Claude zeigt `ALL`. Claude kann `lf-freigabe an` nicht selbst auslösen. Verlängern im Menü fragt an der Konsole nach und gilt nur mit „j“. Nach einer Minute ist die Freigabe von selbst weg, das Protokoll nennt An und Ablauf, und Leuchtfeuer beendet Claude. Auf tty1 steht danach „Neustart nötig: Claude startet erst nach einem Neustart wieder.“, bis zum Neustart steht im Hauptmenü „ACHTUNG: Neustart nötig (letzte Freigabe bis HH:MM). Claude bleibt bis dahin gesperrt. Ausschalten: Netzschalter gedrückt halten, bis das Gerät aus ist“. Claude (CLI und Desktop) startet nicht, Werkzeuge > Claude-Freigabe schaltet keine neue frei, und ein kurzer Druck auf den Netzschalter tut nichts. Netzschalter gedrückt halten, bis das Gerät aus ist, dann einschalten: Danach ist alles weg, und Claude startet wieder.
8. **Claude Desktop als lf-claude** (in QEMU nicht prüfbar):
   - Die App startet im Vollbild, das Fenster ist sichtbar und bedienbar, Login klappt, nach Strg+Q geht es im Assistenten weiter.
   - Nach einem Neustart mit persistentem Speicher ist der Login noch da.
   - In der App läuft Claude Code als `lf-claude`: kein sudo außer `lf-lesen` und `lf-aufgabe`. Schreibende Schritte gehen nur über die Werkzeuge bzw. den Assistenten, die Rückfragen aus Schritt 2 kommen auch hier.
   - Grafik mit GPU: `ls -l /dev/dri` und in der App flüssiges Scrollen. Ohne GPU-Zugriff (Gruppe `render`) fällt sie auf Software-Darstellung zurück.
   - Auf tty2 als Live-Benutzer: `ls -l /run/lf/wayland` zeigt nur den Socket von cage, Gruppe `lf-claude`.
   - Mit gesperrtem ptrace (#85, `sysctl kernel.yama.ptrace_scope` zeigt 3) läuft die App wie vorher.
   - Ohne setuid für `fusermount3` (#153): Der Dialog zum Anhängen einer Datei öffnet sich und zeigt die Dateien.
   - Mit der Regel für das Netz von Claude (Schritt 9) meldet sich die App an und arbeitet wie vorher.
9. **Netz für Claude:** Claude bitten, die Weboberfläche des Routers abzufragen (`curl -sI http://<Adresse des Routers>`), einen Rechner im lokalen Netz anzusprechen und eine öffentliche Seite mit WebFetch zu lesen.
   Erwartet: Router und lokales Netz scheitern sofort, `sudo nft list counter inet lf_claude_netz abgewiesen` zählt mit. WebFetch und der Login gehen. Im Protokoll steht kein Fehler der Prüfung neuer CLI-Versionen (`lf-claude-check`).

9 Selbsttest auf echter Hardware
--------------------------------

```bash
sudo lf --selftest | tee /persist/selftest-$(date +%F).txt
```

Erwartet: Die letzte Zeile ist `LF-SELFTEST: PASS`, davor stehen `LF-SELFTEST: ptrace: gesperrt (kernel.yama.ptrace_scope=3)`, `LF-SELFTEST: Netz für Claude: Verbindungen von lf-claude an eigene, private und andere Ziele als HTTPS scheitern an der Regel (…)`, `LF-SELFTEST: kexec: gesperrt (kernel.kexec_load_disabled=1)`, `LF-SELFTEST: Freigabe: Merker im Kernel vor dem Freischalten 2, danach bis zum Neustart 1 (kernel.unprivileged_bpf_disabled)`, `LF-SELFTEST: Freigabe: das Menü (rescue) sieht die Regel der Freigabe` und `LF-SELFTEST: setuid: nur sudo, chrome-sandbox, der Helfer von D-Bus, ssh-agent, cons.saver und ping`. Die Datei gehört ins Issue. Der Selbsttest schaltet eine Freigabe frei und lässt sie ablaufen: Danach ist Claude bis zum Neustart gesperrt. Den Selbsttest darum gleich nach dem Einschalten starten und danach am Netzschalter ausschalten (gedrückt halten).

10 SSH
------

1. **Einschalten:** Werkzeuge > SSH. Von einem zweiten Rechner mit dem Einmal-Passwort anmelden und dort `sleep 600 &` starten.
2. **Ausschalten** auf tty1 unter Werkzeuge > SSH.
   Erwartet:
   - Die Verbindung auf dem zweiten Rechner bricht sofort ab.
   - Der Dialog nennt 1 beendete Sitzung und rät zum Neustart.
   - In der Shell (Werkzeuge > Shell) zeigen `loginctl list-sessions` keine Sitzung von SSH und `pgrep -a sleep` nichts mehr.
   - Ein neuer Versuch mit dem alten Passwort scheitert, auch nachdem SSH wieder eingeschaltet ist. Dann gilt nur das neue.

11 Eigene SSH-Schlüssel (LF-SSH)
--------------------------------

Dafür einen Wegwerf-Schlüssel auf dem zweiten Rechner erzeugen (`ssh-keygen -t ed25519 -f ~/.ssh/lf-probe`), nie einen echten. Die Schritte 2 bis 5 mit einem frisch beschriebenen Stick ohne persistenten Speicher (die Frage danach beim Start mit Nein beantworten): Mit verschlüsseltem Speicher merkt sich der Assistent bestätigte Schlüssel und fragt nicht mehr.

1. **Partition:** Den frisch beschriebenen Stick an Windows, macOS und Linux anstecken.
   Erwartet: ein Laufwerk `LF-SSH` mit `LIESMICH.txt`, beschreibbar. Unter Windows zeigt der Stick kein weiteres Laufwerk (#110). Notiere, welche weiteren Laufwerke macOS und Linux zeigen und ob ein System anbietet, eins zu formatieren (ablehnen).
2. **Anmeldung mit Schlüssel:** Den Inhalt von `~/.ssh/lf-probe.pub` als `authorized_keys` nach LF-SSH kopieren, den Stick auswerfen, davon starten. Werkzeuge > SSH.
   Erwartet:
   - Der Assistent zeigt den Schlüssel mit demselben Fingerabdruck wie `ssh-keygen -lf ~/.ssh/lf-probe.pub` und fragt, ob er gilt.
   - Nach „Ja“ meldet sich `ssh -i ~/.ssh/lf-probe rescue@…` ohne Passwort an.
   - `ssh -o PubkeyAuthentication=no rescue@…` scheitert, ohne nach einem Passwort zu fragen.
   - Das Protokoll des Assistenten nennt die Anmeldung mit dem Fingerabdruck.
3. **Nein:** SSH aus, wieder ein, diesmal „Nein“.
   Erwartet: Der Assistent zeigt ein Einmal-Passwort. Damit klappt die Anmeldung, mit dem Schlüssel nicht.
4. **Falsche Zeile:** In `authorized_keys` eine zweite Zeile ergänzen, die mit `command="true" ` beginnt und dann denselben Schlüssel enthält. Neu starten.
   Erwartet: Auf tty1 steht ein Hinweis mit der Zeilennummer 2. Der Schlüssel aus Zeile 1 gilt weiter.
5. **Privater Schlüssel:** Eine Kopie von `~/.ssh/lf-probe` (ohne `.pub`) auf LF-SSH legen, neu starten.
   Erwartet: Beim Start warnt der Assistent, dass ein privater Schlüssel ungeschützt auf dem Stick liegt, und verwendet ihn nicht. Danach die Kopie löschen.
6. **Mit verschlüsseltem Speicher:** Auf dem Stick aus Abschnitt 3, Schritt 1 `authorized_keys` wie in Schritt 2 ablegen, zweimal starten und SSH einschalten.
   Erwartet: Beim ersten Mal fragt der Assistent für den Schlüssel, beim zweiten Mal nicht mehr. Der Fingerabdruck des Hostschlüssels ist bei beiden Starts gleich. Nach einer Claude-Freigabe empfiehlt der Assistent beim nächsten Einschalten neue Hostschlüssel.
7. **Zwei Sticks:** Mit dem zweiten Leuchtfeuer-Stick zusätzlich angesteckt starten.
   Erwartet: Beim Start der Hinweis, dass Schlüssel von LF-SSH nicht gelten. Werkzeuge > SSH bietet nur das Einmal-Passwort an.
