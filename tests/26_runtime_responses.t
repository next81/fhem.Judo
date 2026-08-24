# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use Judo::Profiles qw(profiles);
use lib 'tests/lib';
use JudoTestEnv qw(
	reset_env define_judo pending_requests complete_request fail_request
	reading_value set_attribute
);

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

# Entfernt simulierte HTTP-Auftraege und entwertet die interne Requestgeneration.
sub discard_requests {
	my ($hash) = @_;
	@{ pending_requests() } = ();
	main::Judo_clear_requests($hash);
	return;
}

# Liefert aktive und wartende REST-Codes in ihrer Ausfuehrungsreihenfolge.
sub request_codes {
	my ($hash) = @_;
	return [
		(map { $_->{request}{code} } @{ pending_requests() }),
		(map { $_->{code} } @{ $hash->{helper}{queue} || [] }),
	];
}

subtest 'Antwortcontainer werden streng validiert' => sub {
	is([main::Judo_parse_response({ mode => 'set' }, '')], ['', undef],
		'leere Set-Antwort ist laut API erlaubt');
	like((main::Judo_parse_response({ mode => 'get' }, ''))[1], qr/Leere Antwort/,
		'leere Get-Antwort wird abgelehnt');
	like((main::Judo_parse_response({ mode => 'get' }, 'kein-json'))[1], qr/Ungueltige JSON/,
		'ungueltiges JSON wird abgelehnt');
	like((main::Judo_parse_response({ mode => 'get' }, '[]'))[1], qr/Ungueltige JSON/,
		'JSON-Array wird statt eines Objekts abgelehnt');
	like((main::Judo_parse_response({ mode => 'get' }, '{}'))[1], qr/kein data-Feld/,
		'fehlendes data-Feld wird gemeldet');
	like((main::Judo_parse_response({ mode => 'get' }, '{"data":null}'))[1], qr/Leere Nutzdaten/,
		'null als Get-Nutzdaten wird abgelehnt');
	is([main::Judo_parse_response({ mode => 'get' }, '{"data":12}')], ['12', undef],
		'numerische JSON-Nutzdaten werden kontrolliert als Text uebernommen');
};

subtest 'Unbekannte und fehlerhafte Modellantworten' => sub {
	reset_env();
	my ($unknown) = define_judo('unknownModel', 'judo.local', 'user', 'password');
	complete_request('FF');
	is(reading_value('unknownModel', 'modelID'), 255, 'unbekannte Modellnummer bleibt sichtbar');
	is(reading_value('unknownModel', 'family'), 'unsupported', 'unbekanntes Modell erhaelt kein Profil');
	is(reading_value('unknownModel', 'state'), 'unsupported', 'unbekanntes Modell setzt eindeutigen Status');
	like(reading_value('unknownModel', 'lastError'), qr/Nicht unterstuetzter Judo-Geraetetyp 255/,
		'unbekanntes Modell wird verstaendlich gemeldet');
	is(scalar(@{ pending_requests() }), 0, 'unbekanntes Modell startet keine Folgekommandos');
	is(main::Judo_Get($unknown, 'unknownModel', 'profile'), 'unknown',
		'ohne Profil liefert get profile unknown');
	like(main::Judo_Set($unknown, 'unknownModel', 'leakageProtection', 'close'),
		qr/Unknown argument/, 'unbekanntes Modell kann keine Geraeteaktion ausloesen');

	reset_env();
	my ($malformed) = define_judo('badModel', 'judo.local', 'user', 'password');
	complete_request('4444');
	is(reading_value('badModel', 'state'), 'error', 'zu lange Modellantwort setzt Fehlerzustand');
	like(reading_value('badModel', 'lastError'), qr/genau ein Hex-Byte/,
		'fehlerhafte Modellantwort wird konkret erklaert');
	is(reading_value('badModel', 'modelID', undef), undef, 'fehlerhafte Modellantwort setzt keine Modellnummer');
};

subtest 'HTTP-Statusfehler und fehlender Status' => sub {
	reset_env();
	my ($busy) = define_judo('busy', 'judo.local', 'user', 'password');
	complete_request(undef, 429, '');
	is(reading_value('busy', 'state'), 'error', 'HTTP 429 ist kein fachlicher Erfolg');
	is(reading_value('busy', 'availability'), 'online', 'HTTP 429 beweist erreichbaren HTTP-Dienst');
	is(reading_value('busy', 'lastErrorCode'), 429, 'HTTP 429 bleibt als Fehlercode sichtbar');
	like(reading_value('busy', 'lastError'), qr/HTTP-Fehler 429/, 'HTTP 429 wird benannt');

	reset_env();
	my ($server) = define_judo('serverError', 'judo.local', 'user', 'password');
	complete_request(undef, 500, '');
	like(reading_value('serverError', 'lastError'), qr/HTTP-Fehler 500/,
		'HTTP 500 wird ohne Nutzdatenverarbeitung gemeldet');
	is(reading_value('serverError', 'model', undef), undef, 'HTTP 500 setzt kein Modellreading');

	reset_env();
	my ($missing) = define_judo('missingStatus', 'judo.local', 'user', 'password');
	my $request = shift @{ pending_requests() };
	$request->{callback}->($request, '', '');
	like(reading_value('missingStatus', 'lastError'), qr/HTTP-Status fehlt/,
		'fehlender HTTP-Status wird kontrolliert gemeldet');
	is(reading_value('missingStatus', 'lastErrorCode'), 'none',
		'fehlender HTTP-Status erfindet keinen Fehlercode');
};

subtest 'Protokollfehler setzen keine fachlichen Readings' => sub {
	reset_env();
	my ($hash) = define_judo('protocolErrors', 'judo.local', 'user', 'password');
	complete_request('44');
	discard_requests($hash);
	main::Judo_Get($hash, 'protocolErrors', 'totalWater');
	complete_request('GG');
	like(reading_value('protocolErrors', 'lastError'), qr/keine gerade Hex-Zeichenfolge/,
		'Nicht-Hex-Nutzdaten werden gemeldet');
	is(reading_value('protocolErrors', 'totalWater', undef), undef,
		'Nicht-Hex-Nutzdaten setzen keinen Zaehler');
	main::Judo_Get($hash, 'protocolErrors', 'totalWater');
	complete_request('00');
	like(reading_value('protocolErrors', 'lastError'), qr/kleiner als 4 Byte/,
		'zu kurze Antwort wird gemeldet');
	is(reading_value('protocolErrors', 'totalWater', undef), undef,
		'zu kurze Antwort setzt keinen Zaehler');
	main::Judo_Get($hash, 'protocolErrors', 'heartbeat');
	complete_request('44');
	is(reading_value('protocolErrors', 'errorCount'), 1,
		'Erfolg eines anderen Kommandos verdeckt offenen Zaehlerfehler nicht');
	main::Judo_Get($hash, 'protocolErrors', 'totalWater');
	complete_request('64000000');
	is(reading_value('protocolErrors', 'totalWater'), '100 l', 'gueltige Folgeantwort setzt den Zaehler');
	is(reading_value('protocolErrors', 'lastError'), 'none', 'gueltige Folgeantwort beseitigt ihren Kommandofehler');

	reset_env();
	my ($missing_data) = define_judo('missingData', 'judo.local', 'user', 'password');
	complete_request(undef, 200, '{}');
	like(reading_value('missingData', 'lastError'), qr/kein data-Feld/,
		'JSON ohne data-Feld wird im Device sichtbar');
};

subtest 'Queue dedupliziert und bleibt seriell' => sub {
	reset_env();
	my ($hash) = define_judo('dedupe', 'judo.local', 'user', 'password');
	complete_request('44');
	discard_requests($hash);
	main::Judo_Get($hash, 'dedupe', 'heartbeat');
	main::Judo_Get($hash, 'dedupe', 'heartbeat');
	is(request_codes($hash), ['FF00'], 'doppelter manueller Heartbeat wird nur einmal eingereiht');
	is(scalar(@{ pending_requests() }), 1, 'es ist immer nur ein HTTP-Request gleichzeitig aktiv');
	discard_requests($hash);
	main::Judo_heartbeat_timer($hash);
	main::Judo_heartbeat_timer($hash);
	is(request_codes($hash), ['FF00', '2800'],
		'doppelter Timerlauf vervielfacht weder Heartbeat noch Profilpolling');
	is(scalar(@{ pending_requests() }), 1, 'Pollingfolge bleibt seriell');
	complete_request('44');
	is(scalar(@{ pending_requests() }), 1, 'nach Heartbeat startet genau der naechste Pollrequest');
	like(pending_requests()->[0]{url}, qr{/api/rest/2800$}, 'Profilpoll folgt erst nach dem Heartbeat');
};

subtest 'Erfolgreiches Set plant gezielten Refresh' => sub {
	reset_env();
	my ($hash) = define_judo('refresh', 'judo.local', 'user', 'password');
	complete_request('33');
	discard_requests($hash);
	is(main::Judo_Set($hash, 'refresh', 'desiredWaterHardness', 10), undef,
		'Wunschwasserhaerte wird angenommen');
	like(pending_requests()->[0]{url}, qr{/api/rest/30000A$}, 'Set verwendet die Schreibadresse und Nutzdaten');
	complete_request(undef, 200, '');
	is(reading_value('refresh', 'lastAction'), 'desiredWaterHardness 10',
		'erfolgreiche Aktion wird protokolliert');
	is(scalar(@{ pending_requests() }), 1, 'nach Set wird genau ein Refresh gestartet');
	like(pending_requests()->[0]{url}, qr{/api/rest/5100$}, 'Refresh verwendet die passende Leseadresse');
	complete_request('0A00');
	is(reading_value('refresh', 'desiredWaterHardness'), "10 \xC2\xB0dH",
		'Refresh aktualisiert das fachliche Reading mit UTF-8-kodiertem Gradzeichen');
};

subtest 'Konfigurierbare Offline-Schwelle und Erholung' => sub {
	reset_env();
	my ($hash) = define_judo('threshold', 'judo.local', 'user', 'password');
	complete_request('44');
	discard_requests($hash);
	set_attribute($hash, 'maxFailures', 2);
	main::Judo_Get($hash, 'threshold', 'heartbeat');
	fail_request('timeout 1');
	is(reading_value('threshold', 'heartbeatFailures'), 1, 'erster Transportfehler wird gezaehlt');
	is(reading_value('threshold', 'availability'), 'online',
		'erster Fehler nach einem Erfolg bleibt unterhalb der Schwelle online');
	main::Judo_Get($hash, 'threshold', 'heartbeat');
	fail_request('timeout 2');
	is(reading_value('threshold', 'availability'), 'offline',
		'konfigurierte zweite Fehlermeldung setzt offline');
	main::Judo_Get($hash, 'threshold', 'heartbeat');
	complete_request('44');
	is(reading_value('threshold', 'availability'), 'online', 'naechster Erfolg stellt online wieder her');
	is(reading_value('threshold', 'heartbeatFailures'), 0, 'naechster Erfolg setzt die Fehlerfolge zurueck');
};

subtest 'Defensive interne Laufzeitpfade' => sub {
	reset_env();
	my ($hash) = define_judo('defensive', 'judo.local', 'user', 'password');
	complete_request('44');
	discard_requests($hash);
	my $profile_data = profiles();

	# Ein versehentlich argumentpflichtiges Pollingprofil darf keinen unvollstaendigen
	# REST-Auftrag erzeugen und wird als interner Profilfehler sichtbar.
	{
		local $profile_data->{zewa}{get}{totalWater}{args} = 'date';
		main::Judo_queue_get($hash, 'totalWater', 'poll');
	}
	like(reading_value('defensive', 'lastError'), qr/Datum im Format YYYY-MM-DD/,
		'interner Fehler eines Pollingdeskriptors wird kontrolliert gemeldet');
	is(scalar(@{ pending_requests() }), 0, 'fehlerhafter Pollingdeskriptor erzeugt keinen HTTP-Request');

	# Zugangsdaten koennen zwischen dem Einreihen und dem Versand verschwinden.
	main::Judo_clear_issue($hash, 'totalWater');
	main::Judo_enqueue_request($hash, {
		command => 'model', mode => 'get', code => 'FF00',
		descriptor => main::Judo_get_descriptor($hash, 'model'), reason => 'manual',
	});
	delete $main::attr{defensive}{username};
	main::Judo_dispatch_next($hash);
	is(reading_value('defensive', 'state'), 'credentialsMissing',
		'zwischenzeitlich entfernte Zugangsdaten setzen einen eindeutigen Status');
	is(scalar(@{ pending_requests() }), 0, 'ohne Zugangsdaten wird kein HTTP-Request versendet');

	my $callback_ok = eval {
		main::Judo_Callback({});
		1;
	};
	ok($callback_ok, 'Callback ohne Device und Request wird sicher ignoriert');
	main::Judo_mark_failure($hash, {}, 0);
	is(reading_value('defensive', 'heartbeatFailures'), 0,
		'fachlicher Fehler wird nicht als Transportausfall gezaehlt');
};

done_testing;
