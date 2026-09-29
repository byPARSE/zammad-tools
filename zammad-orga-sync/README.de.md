# zammad-orga-sync

*Deutsch — [English version](README.md)*

> ## ⚠️ BENUTZUNG AUF EIGENE GEFAHR — KEINE GARANTIE, KEIN SUPPORT
>
> **Dieses Skript schreibt in deine Zammad-Installation.** Es legt
> Organisationen an und ändert die primäre Organisation von Benutzern, in
> großer Zahl und ohne Rückfrage. Ein falscher Feldname, eine falsche Rolle
> oder ein übersehener Tippfehler kann in einem einzigen Lauf tausende
> Benutzer umhängen.
>
> **Du allein trägst die Verantwortung für den Einsatz.** Es gibt
> **keinerlei Gewährleistung**, weder ausdrücklich noch stillschweigend, und
> **keine Haftung** für Schäden, Datenverlust oder Ausfälle. Maßgeblich ist
> der Wortlaut der MIT-Lizenz in [LICENSE](../LICENSE).
>
> **Dies ist kein offizielles Zammad-Produkt.** Es gehört nicht zu Zammad,
> stammt nicht von der Zammad GmbH und wird von ihr nicht unterstützt. Der
> Einsatz ist **von keinem Zammad-Abonnement, Wartungs- oder Supportvertrag
> abgedeckt**, und der Zammad-Support hilft bei Problemen daraus nicht
> weiter. Wenn es deine Instanz beschädigt, liegt die Reparatur bei dir.
>
> **Vor jedem Lauf gegen ein Produktivsystem:**
> eine Sicherung haben, die du mindestens einmal zurückgespielt hast; zuerst
> mit `--dry-run` laufen lassen und den Plan Zeile für Zeile lesen; mit
> `--limit` an einer Handvoll Benutzern anfangen.

Legt Organisationen aus einem Benutzerfeld an und weist sie als primäre
Organisation zu. Für den Lauf per Cron oder von Hand.

Lizenz: MIT, Copyright (c) 2026 Tobias Siudak, siehe [LICENSE](../LICENSE).

Ein Beispiel: Beim Anlegen von Benutzern kommt der Firmenname aus einem
Fremdsystem in ein freies Feld, etwa `company`. Zammad macht daraus von sich aus
keine Organisation. Dieses Skript schließt die Lücke.

## Auf einen Blick

Fünf Aufrufe in der Reihenfolge, in der sie gedacht sind. Vor Nummer drei wird
nichts geschrieben.

```sh
# 1  Läuft es überhaupt? Prüft Zugang, Token und Feld, sieht sich 50 Benutzer
#    an, schreibt nichts und rechnet hoch, wie lange der ganze Satz dauert.
./zammad-orga-sync.sh --field company --dry-run

# 2  Der vollständige Plan. Zeile für Zeile lesen — hier fällt ein falsches
#    Feld auf oder ein Firmenname, der auf die Ignorierliste gehört.
./zammad-orga-sync.sh --field company --dry-run --no-limit

# 3  Zwanzig wirklich schreiben und diese Benutzer in Zammad ansehen. Das ist
#    zugleich der erste Lauf, der misst, wie schnell dieses Zammad schreibt.
./zammad-orga-sync.sh --field company --limit 20

# 4  Eine größere gemessene Stichprobe. Je mehr geschrieben wird, desto besser
#    die Hochrechnung.
./zammad-orga-sync.sh --field company --limit 200

# 5  Der ganze Lauf.
./zammad-orga-sync.sh --field company
```

Schritt 1 und 2 ändern nichts, es gibt also keinen Grund, sie zu überspringen.
Schritt 3 und 4 gibt es, weil eine Hochrechnung aus zwanzig echten Schreib-
vorgängen auf der eigenen Maschine mehr wert ist als jede Zahl in dieser Datei.

## Wie lange dauert das

Jeder Lauf endet damit, was er gekostet hat und was das für einen größeren
bedeutet:

```
Timing: 200 user(s) in 54 s - 0.4 s once, 54 s for these users and 400 change(s)
Projection, reading and writing together - rough, and better the more this run did:
    100 user(s)                  27 s
    1000 user(s)                 4 min 29 s
    10000 user(s)                44 min 42 s
    1780 user(s) still in scope  7 min 58 s
```

Ein Lauf hat zwei Arten von Kosten, und das Skript hält sie auseinander. Ein
Teil fällt einmal an, egal wie groß die Arbeit ist: Rails starten, die
Zählungen abfragen, die Organisationen holen. Der Rest wächst mit der Zahl der
Benutzer. Nur der zweite Teil wird hochgerechnet — sonst würde eine Stichprobe
von fünfzig einen einzelnen achtsekündigen Rails-Start zu einer Stunde
hochskalieren, die es nie gibt.

Ein Probelauf schreibt nichts, kann also nur Lesen und Entscheiden hochrechnen,
und sagt das auch. Die Schreibrate kommt aus dem ersten echten Lauf — dafür
sind Schritt 3 und 4 oben da.

**Ein Probelauf ohne `--limit` sieht sich 50 Benutzer an**, damit der erste
Aufruf einer Sitzung auch auf einer großen Installation schnell bleibt.
`--limit N` vergrößert die Stichprobe, `--no-limit` hebt sie auf. Ein echter
Lauf ohne `--limit` bearbeitet weiterhin alles, wie bisher.

## Die zwei Zugriffsarten

| Art | Wo das Skript läuft | Wie es zugreift |
|---|---|---|
| `local` (Vorgabe) | auf dem Zammad-Host | über die Rails-Konsole, `zammad run` |
| `api` | irgendwo | über die REST-Schnittstelle, auch auf einen fremden Host |

Die lokale Art braucht `root` oder den Benutzer `zammad` und ist schneller, weil
sie direkt auf die Datenbank geht. Die API-Art braucht Adresse und Token:

```sh
export ZAMMAD_TOKEN=...
./zammad-orga-sync.sh --access api --url https://zammad.example.com --field company
```

**Rechte des Tokens:** `admin.user` und `admin.organization`. Nur wenn
`--role` benutzt wird, kommt `admin.role` dazu.

**Selbstsignierte Zertifikate.** Kann der Rechner das Zertifikat des
Zammad-Servers nicht prüfen, etwa bei einem selbstsignierten Zertifikat oder
einer internen Zertifizierungsstelle, bricht der Lauf mit *The TLS certificate
was rejected* ab. Dann hilft `--no-ssl-verify` (gleichbedeutend `--insecure`
oder `-k`).

Das ist **unsicherer**: Die Verbindung bleibt verschlüsselt, aber es ist nicht
mehr belegt, dass am anderen Ende wirklich dein Zammad antwortet. Wer den
Verkehr umlenken kann, liest und verändert ihn, und dein API-Token landet bei
ihm. Man kennt das von `curl -k`. Solange die Prüfung aus ist, gibt das Skript
bei jedem Lauf eine Warnung auf die Fehlerausgabe, auch mit `--quiet`.

Der bessere Weg ist, das Zertifikat der internen Zertifizierungsstelle auf dem
Rechner zu hinterlegen: unter Debian und Ubuntu nach
`/usr/local/share/ca-certificates/` und dann `update-ca-certificates`, unter
RHEL und SUSE nach `/etc/pki/ca-trust/source/anchors/` und dann
`update-ca-trust`. Danach funktioniert die Prüfung von selbst und die Option
wird überflüssig.

Der Token gehört in die Umgebung, nicht in die Datei. Ein in der Umgebung
gesetzter Wert hat Vorrang vor dem Eintrag im Kopf des Skripts.

## Die vier Betriebsfälle

Sie ergeben sich aus zwei Schaltern, ohne dass man sie einzeln wählen müsste:

| Fall | Aufruf | Welche Benutzer | Was geschieht |
|---|---|---|---|
| 1 Vorgabe | `--field company` | ohne primäre Organisation, Feld gefüllt | Organisation anlegen falls nötig, zuweisen |
| 2 Überschreiben | `+ --overwrite` | alle mit gefülltem Feld | wie 1, zusätzlich wird eine abweichende bestehende Organisation ersetzt |
| 3 Rolle | `+ --role Customer` | wie 1, auf die Rollen eingeschränkt | wie 1 |
| 4 Rolle und Überschreiben | `+ beides` | wie 2, auf die Rollen eingeschränkt | wie 2 |

`--role` und `--blacklist` sind mehrfach angebbar. Stimmt beim Überschreiben
die bestehende Organisation bereits mit dem Feld überein, bleibt alles
unverändert; das Feld gewinnt nur bei einer echten Abweichung.

## Organisationen anlegen — oder eben nicht

Standardmäßig wird eine Organisation, die es noch nicht gibt, angelegt.
`--no-create-orgs` schaltet das ab: Das Skript weist dann nur Organisationen zu,
die bereits vorhanden sind, und lässt alle übrigen Benutzer unberührt.

Das ist die Betriebsart für eine Instanz, in der die Organisationen von Hand
gepflegt werden oder aus einem anderen System kommen und das Benutzerfeld nur
darauf zeigen soll.

Übersprungene Benutzer verschwinden dabei nicht stillschweigend, jeder wird
benannt:

```
Skipped: 6 (organization does not exist, --no-create-orgs)

  skipped Anna Fehlt <anna@example.com>: no organization named 'Fehlt eins GmbH'
  ...

Result: 0 organization(s) created, 4 user(s) assigned, 6 skipped for want of an organization, 0 error(s)
```

Die Zahl steht in der Zusammenfassung, die auch mit `--quiet` ausgegeben wird;
die Einzelzeilen landen im Protokoll. Ein Wiederholungslauf meldet *Nothing to
do: 6 user(s) skipped for want of an organization* statt eines schlichten
*Nothing to do* — damit ein nächtlicher Lauf nicht untätig aussieht, während er
in Wahrheit an fehlenden Organisationen hängt.

`--shared` hat in dieser Betriebsart keine Wirkung: Es galt immer nur für
Organisationen, die das Skript selbst anlegt.

## Einstellungen

Alles steht als Block im Kopf des Skripts und lässt sich zusätzlich auf der
Kommandozeile überschreiben.

| Einstellung | Option | Vorgabe |
|---|---|---|
| Zugriffsart | `--access` | `local` |
| Adresse | `--url` | leer |
| Token | `--token`, besser `ZAMMAD_TOKEN` | leer |
| Zertifikatsprüfung | `--no-ssl-verify` schaltet sie ab | an |
| Feldname | `--field` | `company` |
| Ignorierliste | `--blacklist` | private, -, n/a, unknown |
| Rollen | `--role` | leer, also alle |
| Überschreiben | `--overwrite` | aus |
| Fehlende Organisationen anlegen | `--no-create-orgs` schaltet es ab | an |
| Neue Organisationen geteilt | `--shared` | aus |
| Probelauf | `--dry-run` | aus |
| Stichprobe | `--limit N`, `--no-limit` | 50 im Probelauf, alles im echten Lauf |
| Nur Zusammenfassung | `--quiet`, auch `--silent` | aus |
| Protokollordner | `--log-dir`, `--no-log` | `log` neben dem Skript |
| Aufbewahrung | `--log-keep-days` | 30 Tage |

## Das Protokoll ist zum Auswerten gebaut

Jede Zeile, die einen Datensatz berührt, hat dieselben festen Felder:

```
2026-09-28 22:18:22 | unlink-secondary | Eva Zweit <eva@example.com> | Alpha AG | was a secondary organization
2026-09-28 22:18:22 | change           | Eva Zweit <eva@example.com> | Alpha AG | was Beta AG
2026-09-28 22:18:20 | create-orga      |                             | Gamma GmbH | id 10626, not shared
```

```
Zeitpunkt | Aktion | Benutzer | Organisation | Detail
```

Der Zeitpunkt ist der des Schreibvorgangs, die Aktion ein einzelnes Wort, die
Felder sind durch ` | ` getrennt. Damit lässt sich ein Protokoll später
zerlegen, ohne Fließtext zu lesen:

```sh
grep ' | create-orga | ' log/zammad-orga-sync-*.log          # jede angelegte Organisation
grep -c ' | change | '   log/zammad-orga-sync-*.log          # wie viele umgehängt wurden
cut -d'|' -f3 log/*.log | sort -u                            # jeder berührte Benutzer
```

| Aktion | was geschehen ist |
|---|---|
| `create-orga` | eine Organisation wurde angelegt |
| `assign` | primäre Organisation gesetzt, der Benutzer hatte keine |
| `change` | primäre Organisation durch eine andere ersetzt |
| `unlink-secondary` | die Organisation wurde aus den sekundären des Benutzers entfernt, damit sie die primäre werden konnte |
| `skip-no-orga` | Benutzer unberührt gelassen: die Organisation fehlt und `--no-create-orgs` verbietet das Anlegen |
| `error-orga` | das Anlegen einer Organisation ist fehlgeschlagen |
| `error-user` | das Schreiben eines Benutzers ist fehlgeschlagen |
| `plan-*` | dasselbe im Probelauf, wo nichts geschrieben wurde |

Ein senkrechter Strich innerhalb eines Organisationsnamens würde genau diese
Zeile mehrdeutig machen. Das Skript maskiert ihn nicht, weil Maskierung
schwerer zu lesen wäre, als dieser Fall wahrscheinlich ist.

Die Zeilen folgen `--quiet` wie jede andere Ausgabe je Datensatz; nur Fehler
und die Zusammenfassung erscheinen in jedem Fall. Zusammenfassung und
Zeitblock bleiben Fließtext — die sind für Menschen gedacht.

## Wie ein Benutzer in der Ausgabe erscheint

Jede Zeile, die einen Benutzer benennt — geplant, geschrieben, übersprungen
oder fehlgeschlagen —, zeigt Vorname, Nachname und E-Mail-Adresse, weil ein
Administrator ihn daran in Zammad wiedererkennt:

```
  Max Mustermann <max@example.com>: ACME Ltd
  Erika Musterfrau: ACME Ltd
  nurmail@example.com: ACME Ltd
```

Ein Benutzer ohne E-Mail-Adresse erscheint allein mit Namen, einer ohne Namen
allein mit Adresse. Nur ein Datensatz, der weder das eine noch das andere hat,
fällt auf den Anmeldenamen zurück, damit er trotzdem auffindbar bleibt.

## Wie Namen verglichen werden

Vor dem Vergleich wird der Feldwert am Rand beschnitten und innere
Leerzeichenfolgen werden zu einem zusammengezogen. Verglichen wird ohne
Rücksicht auf Groß- und Kleinschreibung, weil Zammad die Eindeutigkeit von
Organisationsnamen genauso prüft.

Aus `"  ACME   GmbH  "` wird also die Organisation `ACME GmbH`, und ein
vorhandenes `acme gmbh` gilt als dieselbe. Angelegt wird mit der bereinigten
Schreibweise des Feldes.

Brauchen zwanzig Benutzer dieselbe neue Organisation, wird sie einmal angelegt.

## Was das Skript nicht tut

- Es legt **keine** Benutzer an und löscht nichts.
- Es rührt **sekundäre** Organisationen nicht an, mit einer Ausnahme: Soll eine
  Organisation primär werden, die beim selben Benutzer als sekundäre eingetragen
  ist, wird sie dort entfernt. Zammad verbietet beides gleichzeitig.
- Es verändert **bestehende** Organisationen nicht, auch nicht deren Schalter
  „geteilt". `--shared` gilt nur für neu angelegte — und mit
  `--no-create-orgs` für gar nichts.
- Ohne `--overwrite` fasst es Benutzer mit vorhandener Organisation nicht an.

## Protokoll

Jeder echte Lauf schreibt seine vollständige Ausgabe zusätzlich zur Konsole in
eine Protokolldatei. Sie landet standardmäßig in einem Ordner `log` neben dem
Skript, der beim ersten Mal angelegt wird:

```
log/zammad-orga-sync-20260924-194147.log
```

**Der Pfad wird vor jeder Arbeit geprüft, indem tatsächlich hineingeschrieben
wird.** Rechtebits sagen nichts über eine volle Platte, ein nur lesbar
eingehängtes Dateisystem, ein Kontingent oder SELinux; nur ein echter
Schreibvorgang tut das. Schlägt er fehl, verweigert das Skript den Dienst und
ändert nichts. Die Begründung erscheint immer auf der Konsole, auch mit
`--quiet` oder `--silent`, denn ein Auftrag, der stumm die Arbeit verweigert,
ist schlimmer als ein lauter.

Ein Probelauf schreibt keine Datei, prüft den Pfad aber trotzdem. So fällt ein
kaputtes Protokollverzeichnis beim Ausprobieren auf und nicht mitten in der
Nacht.

| Option | Bedeutung | Vorgabe |
|---|---|---|
| `--log-dir PFAD` | wohin geschrieben wird | `log` neben dem Skript |
| `--log-keep-days N` | eigene Protokolle älter als N Tage löschen, 0 behält alle | 30 |
| `--no-log` | gar kein Protokoll schreiben | Protokoll ist an |

Beim Aufräumen werden ausschließlich Dateien namens `zammad-orga-sync-*.log`
in diesem Ordner entfernt. Ein gemeinsam genutzter Protokollpfad bleibt damit
unangetastet.

Der API-Token wird nie ins Protokoll geschrieben.

Liegt das Skript in einem Systemverzeichnis, in das du nicht schreiben darfst,
lenke die Protokolle um, etwa mit `--log-dir /var/log/zammad-orga-sync`.

## Wiederholbarkeit

Der zweite Lauf mit denselben Einstellungen findet nichts mehr zu tun. Das
Skript eignet sich damit für den Betrieb per Cron, etwa nächtlich:

```cron
30 2 * * * /usr/local/sbin/zammad-orga-sync.sh --field company --quiet >> /var/log/zammad-orga-sync.log 2>&1
```

Rückgabewert 0 wenn alles lief, 1 bei Fehlern während der Verarbeitung, 2 bei
falscher Konfiguration. Einzelne Fehler brechen den Lauf nicht ab; sie werden
gezählt und am Ende gemeldet.

In der lokalen Art erscheinen die Änderungen in der Zammad-Historie als
Änderungen des Systembenutzers, wie bei Zammads eigenen Hintergrundaufträgen.
In der API-Art erscheinen sie unter dem Benutzer, dem der Token gehört.

**Ein Wiederholungslauf kostet fast nichts.** Beide Zugriffsarten lassen
Zammad filtern, statt die Benutzer selbst zu durchsuchen. Die lokale Art tut
das seit jeher: „Feld gefüllt und keine Organisation" ist eine `WHERE`-Klausel,
und sobald alle eine Organisation haben, trifft sie auf keine Zeile mehr.

Seit 2.1 macht die API-Art dasselbe. Sie fragt zuerst mit
`/api/v1/users/search` und einer Bedingung auf `organization_id`, wie viele
Benutzer überhaupt in Frage kommen — eine billige Anfrage. Lautet die Antwort
„keiner", und das ist der Normalfall eines nächtlichen Laufs, wird kein
einziger Benutzer geholt. Gemessen an 10 000 Benutzern: **0,5 s statt 21 s**.

Zwei Einzelheiten machen das verlässlich. Die Anfrage trägt keinen
`query`-Parameter, deshalb beantwortet Zammad sie aus der Datenbank statt aus
Elasticsearch — ein veralteter Suchindex kann also niemals dazu führen, dass
ein Benutzer übersehen wird. Und wenn der Server die Bedingung nicht annimmt —
ein älteres Zammad, ein Token ohne die Berechtigung, ein Feld das es nicht
gibt — fällt das Skript stillschweigend auf die vollständige Liste zurück, also
auf das bisherige Verhalten.

Der Filter wird nur benutzt, wenn er Arbeit spart. Eine Anfrage kostet ungefähr
gleich viel, egal was sie trägt; 9 000 von 10 000 Benutzern seitenweise über
den gedeckelten Suchendpunkt zu holen wäre deshalb langsamer als die einfache
Liste. Das Skript vergleicht die beiden Zählungen und nimmt die einfache Liste,
solange der Filter nicht mindestens die Hälfte der Benutzer wegnimmt. Beim
allerersten Lauf gegen ein frisches Feld ist das immer so — ein Erstlauf ist
also nicht langsamer als vorher.

## Voraussetzungen

Bash und **jq**; die API-Zugriffsart braucht zusätzlich **curl**. Mehr nicht.
Ruby muss nirgendwo installiert werden.

| System | Befehl |
|---|---|
| Debian, Ubuntu, Mint | `apt install jq curl` |
| RHEL, Alma, Rocky, Fedora | `dnf install jq curl` (`yum` bei RHEL 7) |
| SLES, openSUSE | `zypper install jq curl` |
| Alpine, Container-Abbilder | `apk add bash jq curl` |
| Arch | `pacman -S jq curl` |

Unter Debian 13 zieht jq 3 Pakete und rund 1 MB; curl ist meist schon
vorhanden. Zum Vergleich: Eine Ruby-Installation zieht dort 19 Pakete und
45 MB, samt Web-Schriftarten und jQuery.

**Warum es so gebaut ist.** Die Entscheidungslogik steckt in einem einzigen
jq-Programm, damit beide Zugriffsarten gleich entscheiden. Darum herum liegen
zwei dünne Ein- und Ausgabeschichten: curl für die API und zwei kurze
Ruby-Schnipsel für die lokale Zugriffsart. Diese Schnipsel laufen über
`zammad run` und benutzen damit das Ruby, das Zammad ohnehin mitbringt. Auf
dem Zammad-Host ist deshalb außer jq nichts zu installieren.

Bei einer Quell-Installation ohne den Befehl `zammad` oder bei einem Zammad im
Container trägst du `RAILS_CMD` im Einstellungsblock ein:

```sh
# Quell-Installation
RAILS_CMD="su - zammad -c 'cd /opt/zammad && bundle exec rails r %s'"
# Zammad im Container
RAILS_CMD="docker exec -i zammad-railsserver-1 rails r %s"
```

## Geprüft gegen

Stand 28.09.2026, Fassung 2.5.0 (Kern in jq), beide Zugriffsarten, alle vier
Betriebsfälle:

- **Zammad 7.2.0** auf Debian 13: zehn Testbenutzer, die jeden
  Sonderfall abdecken, danach restlos entfernt
- **Zammad 6.5.4** auf Ubuntu 24.04: rein lesender Probelauf über
  1134 Benutzer, zwei Seiten der API-Paginierung, 15 Sekunden
- **Im Container**: das Skript selbst in `debian:13-slim` und in `alpine:3.22`,
  gegen ein Zammad außerhalb des Containers über die API. Ein Probelauf über
  alle 1134 Benutzer, beide Seiten der Paginierung, in 3 Sekunden — beide
  Images lieferten denselben Plan

Die API-Art wurde als echter Fremdzugriff geprüft: Skript auf dem einen Server,
Zammad auf dem anderen, über zwei Hauptversionen hinweg. Lokale und API-Art
lieferten dasselbe Ergebnis bis auf die Zeile genau.

Abgedeckte Sonderfälle: doppelte Firmennamen werden zu einer Organisation
zusammengefasst, Leerzeichen werden bereinigt, die Ignorierliste greift, ein
leeres Feld wird übersprungen, eine bereits passende Zuweisung bleibt
unverändert, der Rollenfilter schließt fremde Rollen aus, und die Umwandlung
einer sekundären in die primäre Organisation läuft ohne Verstoß gegen Zammads
Prüfregel.

Der Umgang mit Zertifikaten wurde gegen einen selbstsignierten HTTPS-Endpunkt
geprüft: Der Lauf ohne Option bricht mit einer verständlichen Meldung ab, mit
`--no-ssl-verify` läuft er unter Warnung durch, und die Warnung überlebt
`--quiet`.

Die Protokollzeilen aus 2.5 wurden in beiden Zugriffsarten gegen einen
Datensatz geprüft, der jede Aktion auslöst: Organisation angelegt und
zugewiesen, zwei Benutzer teilen sich eine neue, primäre Organisation ersetzt,
und einer, bei dem die gewünschte Organisation in seinen sekundären stand und
erst dort heraus musste.

Genau dieser letzte Fall hat während der Arbeit einen echten Fehler ans Licht
gebracht, der jetzt behoben ist: Ein Benutzer **ohne** primäre Organisation,
der die gewünschte aber unter den sekundären führt, ist der ganz normale erste
Betriebsfall — und Zammad verweigert den Schreibvorgang mit *Secondary
organizations cannot include the primary organization*, wenn der Eintrag stehen
bleibt. Beide Zugriffsarten entscheiden das jetzt aus demselben Plan.

Die Ausgabe aus 2.4 benennt Benutzer mit Vorname, Nachname und E-Mail. Geprüft
in beiden Zugriffsarten gegen Datensätze jeder Bauart: Name mit Adresse, Name
ohne, Adresse ohne Namen, weder noch (fällt auf den Anmeldenamen zurück) sowie
ein Name mit Umlauten und Bindestrich.

`--no-create-orgs` (2.3) wurde in beiden Zugriffsarten gegen zehn Benutzer
geprüft: bei vieren gab es die Organisation bereits — darunter eine in anderer
Groß-/Kleinschreibung und eine mit überzähligen Leerzeichen, die beide korrekt
zugeordnet wurden —, bei sechs nicht. Vier wurden zugewiesen, sechs übersprungen
und einzeln benannt, keine Organisation wurde angelegt, und der
Wiederholungslauf meldete sie erneut, statt Untätigkeit zu behaupten.

Stichprobe und Hochrechnung aus 2.2 wurden gegen Zammad 7.2 mit 2 000 Benutzern
geprüft, in beiden Zugriffsarten: ein Probelauf ohne `--limit` holt 50 Benutzer
und ist in unter einer Sekunde durch, `--no-limit` läuft über alle 2 000, und
die Hochrechnung für 10 000 Benutzer wurde von 1 h 10 min auf 45 min genauer,
als die gemessene Stichprobe von 20 auf 200 echte Schreibvorgänge wuchs. In der
lokalen Art werden die beiden Rails-Starts (17 s) als einmalige Kosten
ausgewiesen und richtigerweise nicht hochgerechnet.

Der serverseitige Filter aus 2.1 wurde gegen Zammad 7.2 mit 10 000 Benutzern
geprüft: gefilterter und ungefilterter Weg liefern denselben Plan, ein
unbekanntes Feld meldet weiterhin *This Zammad has no user field called …*,
weil Zammad die Bedingung ablehnt und das Skript zurückfällt, und
`--overwrite` überspringt den Filter wie vorgesehen. Ein Wiederholungslauf über
diese 10 000 Benutzer fiel von 21 s auf 0,5 s.

Dabei kam ein Fehler ans Licht, behoben in 2.0.1: Die API-Art reichte die
gesammelten Listen als Befehlszeilenargument an jq, und Linux begrenzt ein
einzelnes Argument auf 128 KiB — das sind etwa sechzig Benutzer. Alles darüber
starb mit *Argument list too long*. Die Listen laufen jetzt über Dateien.

Auch die Protokollierung wurde geprüft: Ein echter Lauf enthält zwischen Kopf
und Fuß die vollständige Ausgabe, ein nicht beschreibbarer Protokollordner
führt zum Abbruch mit Rückgabewert 2 samt Begründung auch unter `--silent`,
und das Aufräumen mit `--log-keep-days 20` löschte nur die eigene 40 Tage alte
Datei — die 5 Tage alte und eine fremde `fremd.log` im selben Ordner blieben
unberührt.

## Bekannte Grenzen

- Das Feld muss ein Textfeld am Benutzerobjekt sein. Auswahlfelder mit
  Schlüssel-Wert-Paaren liefern den Schlüssel, nicht die Beschriftung.
- Sehr große Installationen laden alle Benutzer und Organisationen in den
  Speicher. Bei einigen zehntausend Benutzern ist das spürbar, aber tragbar;
  gedacht ist das Skript für einen Lauf pro Nacht.
- Umbenennungen erkennt es nicht. Wird eine Firma im Feld anders geschrieben,
  entsteht eine zweite Organisation, sofern sie sich nicht nur in Groß- und
  Kleinschreibung oder Leerzeichen unterscheidet.
