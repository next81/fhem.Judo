# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'tests/lib';
use JudoTestEnv qw(
	reset_env define_judo pending_requests complete_request reading_value log_entries
	scheduled_timers set_attribute key_values set_key_value_errors
);

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

# Entfernt simulierte HTTP-Auftraege und die interne Queue einer Instanz.
sub discard_requests {
	my ($hash) = @_;
	@{ pending_requests() } = ();
	main::Judo_clear_requests($hash);
	return;
}

subtest 'Logging und Fehlerregister' => sub {
	reset_env();
	my $hash = {
		NAME => 'logging', TYPE => 'Judo', READINGS => {},
		helper => { issues => {}, queue => [], generation => 1, request_id => 0 },
	};
	$main::defs{logging} = $hash;
	ok(!main::Judo_log_enabled({}, 1), 'Logging ohne Devicekontext bleibt aus');
	$main::attr{logging}{verbose} = 2;
	ok(main::Judo_log_enabled($hash, 2), 'aktive Verbosestufe erlaubt Meldung');
	ok(!main::Judo_log_enabled($hash, 3), 'zu hohe Verbosestufe unterdrueckt Meldung');
	main::Judo_log($hash, 2, "erste\nzweite");
	is(scalar(@{ log_entries() }), 1, 'genau eine erlaubte Logmeldung wird geschrieben');
	unlike(log_entries()->[0][2], qr/[\r\n]/, 'Logmeldung wird auf eine Zeile begrenzt');
	main::Judo_log($hash, 3, 'unsichtbar');
	is(scalar(@{ log_entries() }), 1, 'unterdrueckte Meldung erzeugt keinen Logeintrag');
	$main::attr{logging}{verbose} = 'ungueltig';
	ok(main::Judo_log_enabled($hash, 3), 'ungueltige Verbosestufe faellt auf den sicheren Standard zurueck');
	main::Judo_log($hash, 3, undef);
	is(log_entries()->[-1][2], 'Judo logging: ', 'undef wird als leere und sichere Logmeldung behandelt');
	$main::attr{logging}{verbose} = 5;
	main::Judo_log($hash, 5, 'x' x 5000);
	like(log_entries()->[-1][2], qr/<truncated>$/, 'sehr lange Logmeldung wird gekuerzt');
	main::Judo_reading($hash, 'undefinedValue', undef);
	is(reading_value('logging', 'undefinedValue'), '', 'undef wird als leerer Readingwert gespeichert');
	main::Judo_record_issue($hash, undef, undef);
	is(reading_value('logging', 'lastErrorCommand'), 'module', 'fehlender Fehlerkontext nutzt den Modulschluessel');
	is(reading_value('logging', 'lastError'), 'Unbekannter Fehler', 'fehlender Fehlertext wird verstaendlich ersetzt');
	main::Judo_clear_issue($hash, 'module');
	main::Judo_record_issue($hash, 'first', 'erster Fehler', 400);
	main::Judo_record_issue($hash, 'second', 'zweiter Fehler', 500);
	$hash->{helper}{issues}{first}{time} = 1;
	$hash->{helper}{issues}{second}{time} = 2;
	main::Judo_update_issue_readings($hash);
	is(reading_value('logging', 'errorCount'), 2, 'mehrere offene Fehler werden gezaehlt');
	is(reading_value('logging', 'lastError'), 'zweiter Fehler', 'neuester Fehler bleibt sichtbar');
	is(reading_value('logging', 'lastErrorCode'), 500, 'HTTP-Fehlercode bleibt erhalten');
	main::Judo_clear_issue($hash, 'second');
	is(reading_value('logging', 'lastError'), 'erster Fehler', 'aelterer offener Fehler wird wieder sichtbar');
	main::Judo_clear_issue($hash, 'first');
	is(reading_value('logging', 'lastError'), 'none', 'letzter beseitigter Fehler leert die Diagnose');
	is(reading_value('logging', 'errorCount'), 0, 'Fehlerzaehler wird auf null gesetzt');
	main::Judo_record_issue($hash, 'repeat', 'wiederholter Fehler');
	main::Judo_record_issue($hash, 'repeat', 'wiederholter Fehler');
	my @repeat_logs = grep { $_->[2] =~ /error command=repeat/ } @{ log_entries() };
	is(scalar(@repeat_logs), 1, 'identische Fehler werden nur einmal protokolliert');
	is($repeat_logs[0][1], 2, 'kontrollierte Laufzeitfehler verwenden Verbose 2');
	main::Judo_clear_issue($hash, 'repeat');
	like(log_entries()->[-1][2], qr/issue resolved command=repeat/,
		'Fehlerbehebung wird auf Verbose 3 protokolliert');
};

subtest 'Host- und Attributvalidierung' => sub {
	reset_env();
	ok(main::Judo_valid_host('judo.local'), 'lokaler DNS-Name ist gueltig');
	ok(main::Judo_valid_host('192.168.1.50:8080'), 'IPv4-Adresse mit Port ist gueltig');
	ok(main::Judo_valid_host('[fd00::50]:8080'), 'IPv6-Adresse mit Port ist gueltig');
	ok(!main::Judo_valid_host('http://judo.local'), 'Protokoll im Host wird abgelehnt');
	ok(!main::Judo_valid_host('user\@judo.local'), 'Zugangsdaten im Host werden abgelehnt');
	ok(!main::Judo_valid_host('judo.local:70000'), 'ungueltiger Port wird abgelehnt');
	my $invalid_hash = { NAME => 'invalidDefinition', TYPE => 'Judo', READINGS => {} };
	like(main::Judo_Define($invalid_hash, 'invalidDefinition Judo'), qr/^Usage:/,
		'unvollstaendige Definition liefert die Syntaxhilfe');
	my ($hash) = define_judo('attributes', 'judo.local', undef, undef);
	is(main::Judo_Attr('unknown', 'attributes', 'timeout', '10'), undef,
		'unbekannte Attributoperation wird ohne Nebenwirkung ignoriert');
	is(main::Judo_Attr('set', 'missingDevice', 'timeout', '10'), undef,
		'Attributvalidierung bleibt bei bereits geloeschtem Device sicher');
	like(main::Judo_Attr('set', 'attributes', 'interval', '9'), qr/zwischen 10 und 86400/,
		'zu kurzes Intervall wird abgelehnt');
	is(main::Judo_Attr('set', 'attributes', 'interval', '0'), undef,
		'Intervall null ist zum Abschalten erlaubt');
	like(main::Judo_Attr('set', 'attributes', 'timeout', '0'), qr/zwischen 1 und 300/,
		'Timeout null wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'timeout', '301'), qr/zwischen 1 und 300/,
		'zu grosser Timeout wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'maxFailures', '0'), qr/zwischen 1 und 10/,
		'Fehlerschwelle null wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'maxFailures', '11'), qr/zwischen 1 und 10/,
		'zu grosse Fehlerschwelle wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'ssl', '2'), qr/muss 0 oder 1 sein/,
		'ungueltiger SSL-Schalter wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'disable', 'yes'), qr/muss 0 oder 1 sein/,
		'ungueltiger Disable-Schalter wird abgelehnt');
	like(main::Judo_Attr('set', 'attributes', 'username', "bad\nuser"), qr/Steuerzeichen/,
		'Steuerzeichen im Benutzernamen werden abgelehnt');
	main::Judo_Attr('set', 'attributes', 'timeout', '17');
	ok(grep($_->[1] eq 'Judo_reconnect_timer', @{ scheduled_timers() }),
		'gueltiges Verbindungsattribut plant einen Reconnect');
	@{ scheduled_timers() } = ();
	is(main::Judo_Attr('del', 'attributes', 'disable'), undef,
		'Loeschen des Disable-Attributs aktiviert das Device wieder');
	ok(grep($_->[1] eq 'Judo_reconnect_timer', @{ scheduled_timers() }),
		'Reaktivierung plant die erneute Verbindung');
};

subtest 'Startzustand zeigt fehlende Zugangsdaten' => sub {
	reset_env();
	$main::init_done = 0;
	my ($missing) = define_judo('missingCredentials', 'judo.local', undef, undef);
	is(reading_value('missingCredentials', 'state'), 'credentialsMissing',
		'fehlender Benutzername und fehlendes Passwort sind sofort sichtbar');
	my ($username_only) = define_judo('usernameOnly', 'judo.local', 'user', undef);
	is(reading_value('usernameOnly', 'state'), 'credentialsMissing',
		'fehlendes Passwort ist sofort sichtbar');
	my ($password_only) = define_judo('passwordOnly', 'judo.local', undef, 'password');
	is(reading_value('passwordOnly', 'state'), 'credentialsMissing',
		'fehlender Benutzername ist sofort sichtbar');
	my ($configured) = define_judo('configured', 'judo.local', 'user', 'password');
	is(reading_value('configured', 'state'), 'initialized',
		'vollstaendige Zugangsdaten behalten vor INITIALIZED den Startzustand');
};

subtest 'Notify, Reconnect, Heartbeatplanung und Undef' => sub {
	reset_env();
	$main::init_done = 0;
	my ($hash, $define_error) = define_judo('lifecycle', 'judo.local', 'user', 'password');
	is($define_error, undef, 'Device wird waehrend des FHEM-Starts definiert');
	is(scalar(@{ pending_requests() }), 0, 'vor INITIALIZED wird kein HTTP-Request gesendet');
	is(scalar(@{ scheduled_timers() }), 0, 'vor INITIALIZED wird kein Timer geplant');
	main::Judo_Notify($hash, { NAME => 'other', CHANGED => ['INITIALIZED'] });
	is(scalar(@{ pending_requests() }), 0, 'Ereignis eines fremden Devices wird ignoriert');
	main::Judo_Notify($hash, { NAME => 'global', CHANGED => ['SAVED'] });
	is(scalar(@{ pending_requests() }), 0, 'irrelevantes globales Ereignis wird ignoriert');
	main::Judo_Notify($hash, { NAME => 'global', CHANGED => ['INITIALIZED'] });
	is(scalar(@{ pending_requests() }), 1, 'INITIALIZED startet die sichere Modellabfrage');
	ok(grep($_->[1] eq 'Judo_heartbeat_timer', @{ scheduled_timers() }),
		'INITIALIZED plant den Heartbeat');
	discard_requests($hash);
	main::Judo_schedule_reconnect($hash);
	ok(grep($_->[1] eq 'Judo_reconnect_timer', @{ scheduled_timers() }),
		'Reconnect wird als kurzer interner Timer geplant');
	main::Judo_reconnect_timer($hash);
	is(scalar(@{ pending_requests() }), 1, 'Reconnect beginnt erneut mit genau einem Request');
	like(pending_requests()->[0]{url}, qr{/api/rest/FF00$}, 'Reconnect beginnt ausschliesslich mit FF00');
	discard_requests($hash);
	is(main::Judo_Set($hash, 'lifecycle', 'reconnect'), undef,
		'manuelles reconnect startet die Modellerkennung');
	like(pending_requests()->[0]{url}, qr{/api/rest/FF00$},
		'manuelles reconnect beginnt ebenfalls mit FF00');
	discard_requests($hash);
	set_attribute($hash, 'disable', 1);
	@{ scheduled_timers() } = ();
	main::Judo_start($hash);
	main::Judo_reconnect_timer($hash);
	main::Judo_heartbeat_timer($hash);
	is(scalar(@{ pending_requests() }), 0, 'deaktiviertes Device startet ueber keinen Laufzeitpfad Requests');
	is(scalar(@{ scheduled_timers() }), 0, 'deaktiviertes Device plant ueber keinen Laufzeitpfad Timer');
	delete $main::attr{lifecycle}{disable};
	set_attribute($hash, 'interval', 0);
	main::Judo_schedule_heartbeat($hash);
	ok(!grep($_->[1] eq 'Judo_heartbeat_timer', @{ scheduled_timers() }),
		'Intervall null entfernt den automatischen Heartbeat');
	set_attribute($hash, 'interval', 60);
	main::Judo_schedule_heartbeat($hash);
	ok(grep($_->[1] eq 'Judo_heartbeat_timer', @{ scheduled_timers() }),
		'positives Intervall plant den Heartbeat erneut');
	my $generation = $hash->{helper}{generation};
	is(main::Judo_Undef($hash, ''), undef, 'Undef beendet die Instanz ohne Fehler');
	is(scalar(@{ scheduled_timers() }), 0, 'Undef entfernt alle internen Timer');
	ok($hash->{helper}{generation} > $generation, 'Undef entwertet spaete HTTP-Callbacks');
};

subtest 'Operatives Verbose-Logging und Geheimnisschutz' => sub {
	reset_env();
	my ($hash) = define_judo('verboseJudo', 'judo.local', 'api-user', 'top-secret');
	complete_request('44');
	my $log = join("\n", map { $_->[2] } @{ log_entries() });
	like($log, qr/defined host=judo\.local/, 'Define protokolliert Host und Startzustand');
	like($log, qr/connection start host=judo\.local/, 'Verbindungsstart ist sichtbar');
	like($log, qr/heartbeat scheduled interval=60 seconds/, 'Heartbeatplanung ist sichtbar');
	like($log, qr/request id=\d+ command=model/, 'Requestmetadaten werden protokolliert');
	like($log, qr/response id=\d+ command=model code=200/, 'Responsemetadaten werden protokolliert');
	like($log, qr/response payload id=\d+ content=.*44/, 'Verbose 5 zeigt begrenzte Nutzdaten');
	ok(grep($_->[1] == 4 && $_->[2] =~ /response id=\d+ command=model/, @{ log_entries() }),
		'Responsemetadaten verwenden Verbose 4');
	ok(grep($_->[1] == 5 && $_->[2] =~ /response payload id=\d+/, @{ log_entries() }),
		'REST-Nutzdaten verwenden ausschliesslich Verbose 5');
	like($log, qr/state connecting -> online command=model/, 'Statusuebergang wird protokolliert');
	like($log, qr/model=ZEWA i-SAFE/, 'erkannte Modell- und Familienzuordnung ist sichtbar');
	unlike($log, qr/top-secret|Authorization|Basic\s/i,
		'Logging enthaelt weder Passwort noch Authorization-Header');
};

subtest 'HTTPS, Timeout und Header' => sub {
	reset_env();
	$main::attr{secure}{ssl} = 1;
	$main::attr{secure}{timeout} = 17;
	$main::attr{secure}{interval} = 0;
	my ($hash) = define_judo('secure', 'judo.local:8443', 'api-user', 'secret');
	is(scalar(@{ pending_requests() }), 1, 'sicheres Device startet genau einen Request');
	my $request = pending_requests()->[0];
	like($request->{url}, qr{^https://judo\.local:8443/api/rest/FF00$},
		'SSL-Attribut erzeugt HTTPS-URL mit Port');
	is($request->{timeout}, 17, 'konfigurierter HTTP-Timeout wird uebernommen');
	is($request->{method}, 'GET', 'REST-Kommandos verwenden HTTP GET');
	like($request->{header}{Authorization}, qr/^Basic /, 'Basic-Authentifizierung steht im Header');
	unlike($request->{url}, qr/api-user|secret/, 'URL enthaelt keine Zugangsdaten');
	is(scalar(@{ scheduled_timers() }), 0, 'Intervall null plant keinen Heartbeat');
};

subtest 'Passwortspeicher und Verbrauchsdifferenzen' => sub {
	reset_env();
	my $hash = {
		NAME => 'storage', TYPE => 'Judo', READINGS => {},
		helper => { issues => {}, queue => [], generation => 1, request_id => 0 },
	};
	$main::defs{storage} = $hash;
	is(main::Judo_store_password($hash, "p\x{00E4}ssw\x{00F6}rt"), undef,
		'UTF-8-Passwort wird gespeichert');
	is(main::Judo_read_password($hash), "p\x{00E4}ssw\x{00F6}rt",
		'UTF-8-Passwort wird unveraendert gelesen');
	my $index = main::Judo_password_index($hash);
	unlike(key_values()->{$index}, qr/pass|ssw/i, 'Key-Value-Speicher enthaelt keinen Klartext');
	key_values()->{$index} = 'kein-hex';
	is(main::Judo_read_password($hash), undef, 'beschaedigter Hexspeicher wird verworfen');
	set_key_value_errors('Datentraeger voll', undef);
	like(main::Judo_store_password($hash, 'secret'), qr/Datentraeger voll/,
		'Schreibfehler des Key-Value-Speichers wird gemeldet');
	like(main::Judo_clear_password($hash), qr/Datentraeger voll/,
		'Loeschfehler des Key-Value-Speichers wird gemeldet');
	like(main::Judo_Set($hash, 'storage', 'password'), qr/darf nicht leer sein/,
		'leeres Passwort wird bereits am Set-Befehl abgelehnt');
	like(main::Judo_Set($hash, 'storage', 'password', 'secret'), qr/Datentraeger voll/,
		'Set password gibt einen Speicherfehler unveraendert aus');
	like(main::Judo_Set($hash, 'storage', 'clearPassword'), qr/Datentraeger voll/,
		'Set clearPassword gibt einen Speicherfehler unveraendert aus');
	set_key_value_errors(undef, 'Lesefehler');
	is(main::Judo_read_password($hash), undef, 'Lesefehler gibt kein Passwort zurueck');
	my $storage_log = join("\n", map { $_->[2] } @{ log_entries() });
	like($storage_log, qr/Passwortspeicher enthaelt ungueltige Hexdaten/,
		'beschaedigter Speicherwert wird ohne seinen Inhalt protokolliert');
	like($storage_log, qr/Key-Value-Schreibfehler: Datentraeger voll/,
		'kritischer Schreibfehler ist diagnostizierbar');
	like($storage_log, qr/Key-Value-Lesefehler: Lesefehler/,
		'kritischer Lesefehler ist diagnostizierbar');
	ok(grep($_->[1] == 1 && $_->[2] =~ /passwordStorage/, @{ log_entries() }),
		'kritische Passwortspeicherfehler verwenden Verbose 1');
	unlike($storage_log, qr/secret|p\x{00E4}ssw\x{00F6}rt/,
		'Passwortspeicherlogging enthaelt keinen Klartext');
	set_key_value_errors(undef, undef);
	main::Judo_update_deltas($hash, { totalWater => '100 l', softWater => '40 l' });
	is(reading_value('storage', 'usageTotalWater', undef), undef,
		'erster Zaehlerstand erzeugt noch keine Differenz');
	main::Judo_update_deltas($hash, { totalWater => '125 l', softWater => '50 l' });
	is(reading_value('storage', 'usageTotalWater'), '25 l', 'Gesamtwasserdifferenz wird berechnet');
	is(reading_value('storage', 'usageSoftWater'), '10 l', 'Weichwasserdifferenz wird berechnet');
	main::Judo_update_deltas($hash, { totalWater => '90 l' });
	is(reading_value('storage', 'usageTotalWater'), '25 l', 'Zaehlerreset erzeugt keinen negativen Verbrauch');
	main::Judo_update_deltas($hash, { totalWater => '95 l' });
	is(reading_value('storage', 'usageTotalWater'), '5 l', 'nach Zaehlerreset entsteht wieder eine positive Differenz');
};

done_testing;
