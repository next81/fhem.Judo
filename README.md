<!-- Copyright (c) 2025-2026 Andreas Planer - https://github.com/next81/fhem.Judo -->

# fhem.Judo

`fhem.Judo` bindet unterstützte Judo-Wasseraufbereitungsgeräte über ihre lokale REST-API an FHEM an.

Das Modul erkennt zuerst über das bei allen dokumentierten Geräten lesbare Kommando `FF00` den Gerätetyp. Erst danach werden ausschließlich die REST-Kommandos des zugehörigen Geräteprofils freigeschaltet. Dadurch können identische REST-Adressen, die bei verschiedenen Produktfamilien unterschiedliche Funktionen haben, keine unbeabsichtigten Aktionen auslösen.

> `fhem.Judo` ist keine offizielle Judo-Integration. Firmwareänderungen können das Verhalten der lokalen REST-API beeinflussen. Schreibkommandos sollten zunächst kontrolliert am eigenen Gerät geprüft werden.

## Architektur

```text
            Judo-Gerät
                |
                | lokale REST-API
                | HTTP / optional HTTPS
                |
          FHEM/50_Judo.pm
                |
                +-- FHEM-Lebenszyklus und Benutzerbefehle
                +-- Readings und Fehlerdiagnose
                |
                +-- lib/FHEM/Judo/Auth.pm
                |      Passwortspeicher und Verschleierung
                |
                +-- lib/FHEM/Judo/Connection.pm
                |      Verbindung, Heartbeat und serielle HTTP-Queue
                |
                +-- lib/FHEM/Judo/Profiles.pm
                |      Geräte, Funktionen und REST-Adressen
                |
                +-- lib/FHEM/Judo/Protocol.pm
                |      Validierung, Kodierung und Dekodierung
                |
                +-- lib/FHEM/Judo/Runtime.pm
                       Modellbestimmung und Verarbeitung von Antworten
```

Alle HTTP-Aufträge werden bewusst seriell ausgeführt. Ein langsames Gerät erhält
deshalb nie mehrere konkurrierende REST-Anfragen derselben Modulinstanz. Zwischen
dem Ende oder Abbruch eines Requests und dem nächsten Request liegen mindestens
fünf Sekunden.

## Funktionen

- automatische Erkennung des Judo-Modells über `FF00`
- getrennte Adress- und Funktionsprofile für jede Gerätefamilie
- dynamische `get`- und `set`-Listen passend zum erkannten Gerät
- sicherer, nicht schreibender Heartbeat
- automatisches Polling der wichtigsten Betriebswerte
- Wasser-, Volumenstrom- und Salzstatistiken, soweit vom Gerät unterstützt
- serielle Request-Queue mit Deduplizierung
- nachvollziehbare Online-, Offline- und Fehlerzustände
- Fehlerregister pro Kommando, damit ein erfolgreicher Request einen anderen offenen Fehler nicht verdeckt
- Verbrauchsdifferenzen für Gesamt- und Weichwasser

## Installation in FHEM

### 1. Updatequelle installieren

Das Repository kann direkt als FHEM-Updatequelle registriert werden:

```text
update add https://raw.githubusercontent.com/next81/fhem.Judo/main/controls_Judo.txt
update all https://raw.githubusercontent.com/next81/fhem.Judo/main/controls_Judo.txt
```

Das Controlfile installiert folgende Dateien relativ zum FHEM-Hauptverzeichnis:

```text
FHEM/50_Judo.pm
lib/FHEM/Judo/Auth.pm
lib/FHEM/Judo/Connection.pm
lib/FHEM/Judo/Profiles.pm
lib/FHEM/Judo/Protocol.pm
lib/FHEM/Judo/Runtime.pm
```

Alternativ können genau diese sechs Dateien manuell in die entsprechenden Verzeichnisse der FHEM-Installation kopiert werden.

Nach einer Aktualisierung sollte FHEM neu gestartet werden, damit Hauptmodul und geladene Bibliotheken garantiert denselben Versionsstand verwenden. Bereits definierte Devices und ihre Readings bleiben erhalten.

### 2. Device definieren

```text
define Judo Judo 192.168.1.50
```

Mit abweichendem Port:

```text
define Judo Judo 192.168.1.50:8080
```

Der Host wird ohne `http://`, `https://` oder Pfad angegeben. Das Protokoll bestimmt das Attribut `ssl`.

### 3. Zugangsdaten hinterlegen

```text
attr Judo username api-benutzer
set Judo password api-passwort
```

Sobald Benutzername und Passwort vorhanden sind, beginnt die Modellerkennung mit `FF00`.

## Konfiguration

| Attribut | Bedeutung | Standard |
|---|---|---:|
| `username` | Benutzername für HTTP Basic | – |
| `ssl` | `0` für HTTP, `1` für HTTPS | `0` |
| `interval` | Heartbeat- und Pollingintervall in Sekunden; `0` deaktiviert den Timer | `60` |
| `offlineInterval` | Heartbeatintervall im Offline-Zustand in Sekunden | `300` |
| `timeout` | HTTP-Timeout in Sekunden | `60` |
| `maxFailures` | aufeinanderfolgende Transportfehler bis `offline` | `3` |
| `disable` | `1` stoppt Requests und Timer, `0` aktiviert das Device | `0` |

Beispiel:

```text
attr Judo interval 120
attr Judo offlineInterval 300
attr Judo timeout 30
attr Judo maxFailures 3
attr Judo ssl 0
```

Zulässige Grenzen:

- `interval`: `0` oder `10` bis `86400` Sekunden
- `offlineInterval`: `10` bis `86400` Sekunden
- `timeout`: `1` bis `300` Sekunden
- `maxFailures`: `1` bis `10`
- `ssl` und `disable`: ausschließlich `0` oder `1`

## Unterstützte Geräte

| Modell | Modellnummern | Profil |
|---|---:|---|
| i-soft | 50, 83 | `soft_basic` |
| i-soft K | 67, 84 | `soft_basic` |
| i-soft SAFE+ | 51, 87 | `soft_safe` |
| i-soft K SAFE+ | 66, 103 | `soft_safe` |
| i-soft PRO | 75, 88 | `soft_pro` |
| i-soft PRO L | 76 | `soft_pro` |
| SOFTwell P | 52, 89 | `softwell` |
| SOFTwell S | 53, 99 | `softwell` |
| SOFTwell K | 54, 90 | `softwell` |
| SOFTwell KP | 71, 98 | `softwell` |
| SOFTwell KS | 72, 100 | `softwell` |
| i-fill 60 | 60 | `ifill` |
| i-dos eco | 65 | `idos` |
| ZEWA i-SAFE / FILT / PROM-i-SAFE | 68 | `zewa` |

Die Modellnummer stammt direkt aus der Antwort auf `FF00`. Bei einem Modellwechsel verwirft das Modul noch wartende Kommandos des alten Profils und initialisiert ausschließlich das neue Profil.

## Bedienung

Die tatsächlich verfügbaren Kommandos hängen vom erkannten Geräteprofil ab:

```text
get Judo ?
set Judo ?
```

### Allgemeine Kommandos

| Kommando | Funktion |
|---|---|
| `get Judo heartbeat` | sofortige sichere Modellabfrage über `FF00` |
| `get Judo model` | Modell erneut lesen und Profil bei Bedarf wechseln |
| `get Judo profile` | aktuell verwendetes Geräteprofil anzeigen |
| `set Judo reconnect` | Queue verwerfen und Modellerkennung neu starten |
| `set Judo password <Passwort>` | Passwort im Key-Value-Speicher hinterlegen |
| `set Judo clearPassword` | gespeichertes Passwort entfernen und Netzwerkzugriffe stoppen |

### Enthärter

Je nach Modell stehen unter anderem folgende Werte und Aktionen zur Verfügung:

- Wunschwasserhärte, Härteeinheit und Betriebsstunden
- Salzgewicht, Salzreichweite und Salzvorratswarnung
- Gesamtwasser und Weichwasser
- maximale Entnahmedauer, Entnahmemenge und Volumenstrom
- Regeneration und Leckageschutz
- Urlaubsmodus
- Wasserstatistiken nach Tag, Woche, Monat und Jahr

Beispiele:

```text
get Judo desiredWaterHardness
get Judo saltSupply
set Judo desiredWaterHardness 10
set Judo regeneration
set Judo leakageProtection close
set Judo serviceAddress Mein Fachbetrieb
```

Das i-soft-PRO-Profil besitzt eigene Grenzen und zusätzliche Szenen-, Volumenstrom- und Salzstatistiken:

```text
set Judo scene Garten 2h
set Judo holidayMode 1 14
get Judo sceneConfiguration 2
get Judo flowMonth 2026-08
get Judo saltUsageYear 2026
```

### ZEWA

Das ZEWA-Profil umfasst unter anderem Leckageschutz, Sleep- und Urlaubsmodus, Lernmodus, Mikroleckagetest, Leckagegrenzen, Abwesenheitszeiten und die lokale Gerätezeit.

```text
set Judo leakageProtection close
set Judo sleepMode start
set Judo sleepDuration 8
set Judo microLeakageTest
set Judo absenceLimits 1000 500 30
set Judo absenceSchedule 0 1 08:00 5 18:00
get Judo absenceSchedule 0
set Judo datetime now
```

Wochentage und Zeiträume der Abwesenheitsplanung verwenden die dokumentierten Werte `0` bis `6`.

### i-dos eco

```text
get Judo status
get Judo dosage
set Judo dosageConcentration normal
set Judo pumpMode auto
set Judo pumpMode manual 1200
set Judo datetime now
```

### i-fill 60

```text
get Judo limits
set Judo fillValve auto
set Judo fillValve open
set Judo leakageProtection close
set Judo alarmRelay manualOn
```

Der Schreibbefehl `limits` erwartet die 13 in der offiziellen API beschriebenen Werte in dieser Reihenfolge:

```text
Sprache Einheit Korrektur Patrone Zyklen Druck Hysterese Rohhärte
Füllzeit Füllmenge Heizungsinhalt Leitwert Patronenkapazität
```

Druck und Hysterese werden als API-Zehntelwerte übergeben.

## Automatisches Polling und Heartbeat

Der Timer arbeitet in folgender Reihenfolge:

```text
Intervall erreicht
      |
      +-- FF00 lesen
            |
            +-- erfolgreich: profilabhängige Pollwerte seriell lesen
            |                und nächsten Timer mit `interval` planen
            |
            +-- offline:     keine Profilwerte abfragen und nächsten
                             Timer mit `offlineInterval` planen
```

Standardmäßig werden folgende Werte automatisch gepollt:

| Profil | Pollwerte zusätzlich zu `FF00` |
|---|---|
| `soft_basic`, `soft_safe`, `soft_pro` | `totalWater`, `softWater`, `saltSupply` |
| `softwell` | `softWater` |
| `zewa` | `totalWater` |
| `idos` | `totalWater`, `status` |
| `ifill` | `totalWater` |

Im Offline-Zustand wird ausschließlich `FF00` als sicherer Heartbeat abgefragt.
Erst ein erfolgreicher Heartbeat aktiviert die profilabhängigen Pollwerte wieder.
Profil- und Initialabfragen laufen ebenfalls einzeln und mit fünf Sekunden Abstand.
Bei Reconnect, Deaktivierung oder Löschen des Devices wird ein aktiver
HttpUtils-Request geschlossen, bevor ein neuer Request zugelassen werden kann.
`interval 0` deaktiviert den automatischen Timer vollständig. Manuelle `get`-
und `set`-Kommandos bleiben verfügbar.

## Readings und Überwachung

### Allgemeine Readings

| Reading | Bedeutung |
|---|---|
| `state` | aktueller Modul- und Verbindungszustand |
| `availability` | `online` oder `offline` |
| `model`, `modelID`, `family` | erkanntes Modell und verwendetes Profil |
| `heartbeat` | Zeitpunkt des letzten erfolgreichen Heartbeats |
| `heartbeatCount` | Anzahl erfolgreicher Heartbeats |
| `heartbeatFailures` | aufeinanderfolgende Transportfehler |
| `lastContact` | letzter erreichter HTTP-Dienst, auch bei HTTP-Fehlern |
| `lastAction`, `lastActionTime` | zuletzt erfolgreich ausgeführtes Schreibkommando |
| `lastError` | verständliche aktuelle Fehlermeldung |
| `lastErrorCode` | HTTP-Code, sofern vorhanden |
| `lastErrorCommand` | Kommando oder Modulbereich des neuesten offenen Fehlers |
| `errorCount` | Anzahl aktuell offener Fehler |
| `passwordStored` | ob ein Passwort hinterlegt ist |
| `usageTotalWater` | Differenz zum vorherigen Gesamtwasserzähler |
| `usageSoftWater` | Differenz zum vorherigen Weichwasserzähler |
| `versionModule` | Version des geladenen FHEM-Moduls |

Weitere Readings werden ausschließlich durch die Funktionen des erkannten Profils erzeugt.

### Zustände

| Zustand | Bedeutung |
|---|---|
| `initialized` | Device ist angelegt, Start steht noch aus |
| `connecting` | Modellerkennung oder Verbindungsaufbau läuft |
| `online` | letzte REST-Antwort war vollständig gültig |
| `error` | Gerät antwortet, die Antwort oder Aktion war aber fehlerhaft |
| `offline` | Transportfehler haben die konfigurierte Schwelle erreicht |
| `credentialsMissing` | Benutzername oder Passwort fehlt |
| `unsupported` | Modellnummer ist nicht dokumentiert |
| `disabled` | Device ist über das Attribut `disable` abgeschaltet |

Ein HTTP-Fehler wie `401` setzt `state` auf `error`, lässt `availability` aber auf `online`: Der HTTP-Dienst des Geräts ist erreichbar, nur die Anmeldung oder Anfrage ist fehlgeschlagen. Reine Transportfehler setzen das Device nach `maxFailures` auf `offline`.

Die Readings `availability`, `heartbeat`, `heartbeatFailures` und `lastError` eignen sich als Grundlage für einen Watchdog oder eine Benachrichtigung in FHEM.

### Verbose-Logging

Das Standardattribut `verbose` steuert die Diagnose pro Device; ohne
Devicewert gilt die globale Verbose-Stufe.

| Stufe | Protokollierte Informationen |
|---|---|
| `1` | kritische Passwortspeicher- und unerwartete Laufzeitfehler |
| `2` | Lebenszyklus, Modell-, Online-/Offline- und andere Statusübergänge |
| `3` | Benutzeraktionen, Attributänderungen und behobene Fehler |
| `4` | Timer, Queue, Request-/Response-Metadaten und Laufzeiten |
| `5` | Deduplizierung, Decodergebnisse, Zählerdetails und begrenzte REST-Nutzdaten |

Identische Fehler werden bis zu einer Änderung oder Behebung nur einmal
protokolliert. Der Nutztext jeder Logmeldung wird auf eine Zeile und 4096 Zeichen begrenzt.
Passwörter, abgeleitete Schlüssel und der HTTP-`Authorization`-Header werden
auf keiner Verbose-Stufe ausgegeben.

## Statistikabfragen

Statistikabfragen erwarten einen Zeitraum:

```text
get Judo waterDay 2026-08-23
get Judo waterWeek 2026-W34
get Judo waterMonth 2026-08
get Judo waterYear 2026
```

Beim i-soft PRO stehen zusätzlich `flowDay` bis `flowYear` sowie `saltUsageDay` bis `saltUsageYear` zur Verfügung. Statistikantworten werden als kanonisches JSON-Objekt im jeweiligen Reading abgelegt.

## API-Quellen

- [Judo API-KOMMANDOZEILEN (2024)](https://www.judo.eu/app/uploads/2024/11/API-KOMMANDOZEILEN.pdf)
- [Judo RESTAPI Kommandos/Gerätetypen SW3.07 (2023)](https://www.judo.eu/app/uploads/2023/10/2023-10-09_RESTAPI_Kommandos_Geraetetypen-SW3.07_1.pdf)
