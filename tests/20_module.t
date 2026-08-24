# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'tests/lib';
use JudoTestEnv qw(reset_env define_judo pending_requests complete_request
	fail_request reading_value log_entries set_attribute);

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

sub request_codes {
	my ($hash) = @_;
	return [
		(map { $_->{request}{code} } @{ pending_requests() }),
		(map { $_->{code} } @{ $hash->{helper}{queue} || [] }),
	];
}

sub discard_requests {
	my ($hash) = @_;
	@{ pending_requests() } = ();
	main::Judo_clear_requests($hash);
}

subtest 'Readings werden nur bei Aenderungen geschrieben' => sub {
	reset_env();
	my $hash = { NAME => 'writePolicy', TYPE => 'Judo', READINGS => {
		status => { VAL => 'bereit', TIME => 'alter Zeitstempel' },
	} };
	$main::defs{writePolicy} = $hash;

	main::Judo_reading($hash, 'status', 'bereit');
	is($hash->{READINGS}{status}{TIME}, 'alter Zeitstempel',
		'unveraenderter Wert wird nicht erneut geschrieben');
	main::Judo_reading($hash, 'status', 'aktiv');
	is($hash->{READINGS}{status},
		{ VAL => 'aktiv', TIME => '2026-08-23 12:00:00' },
		'geaenderter Wert wird mit neuem Zeitstempel geschrieben');

	# Kontakt- und Heartbeat-Zeitpunkte muessen auch bei gleichem Text neu entstehen.
	for my $reading (qw(lastContact heartbeat)) {
		$hash->{READINGS}{$reading} = { VAL => 'gleich', TIME => 'alter Zeitstempel' };
		main::Judo_reading($hash, $reading, 'gleich');
		is($hash->{READINGS}{$reading}{TIME}, '2026-08-23 12:00:00',
			"$reading wird auch bei gleichem Wert erneut geschrieben");
	}
};

subtest 'sichere Modellerkennung und ZEWA-Profil' => sub {
	reset_env();
	my ($hash, $define_error) = define_judo('judo', 'judo.local', 'api-user', 'top-secret');
	is($define_error, undef, 'Device wird definiert');
	is(scalar(@{ pending_requests() }), 1, 'vor Modellantwort laeuft genau ein Request');
	my $first = pending_requests()->[0];
	like($first->{url}, qr{/api/rest/FF00$}, 'erster Request ist ausschliesslich FF00');
	unlike($first->{url}, qr/api-user|top-secret/, 'URL enthaelt keine Zugangsdaten');
	like($first->{header}{Authorization}, qr/^Basic /, 'Authentifizierung steht im Header');
	is(reading_value('judo', 'state'), 'connecting', 'Startzustand ist connecting');

	complete_request('44');
	is(reading_value('judo', 'modelID'), 68, 'ZEWA-Modellnummer erkannt');
	is(reading_value('judo', 'family'), 'zewa', 'ZEWA-Profil gesetzt');
	is(reading_value('judo', 'state'), 'online', 'valide Modellantwort setzt online');
	is(reading_value('judo', 'availability'), 'online', 'Erreichbarkeit ist online');
	my $codes = request_codes($hash);
	is($codes, [qw(0600 0100 0E00 2800 5E00 6600 6400 6500 5900)],
		'nur dokumentierte lesende ZEWA-Initialkommandos werden geplant');
	ok(!(grep { $_ eq '5700' || $_ eq '5100' || $_ eq '5200' || $_ eq '6300' } @$codes),
		'Initialisierung enthaelt keine ZEWA-Aktionskommandos');

	discard_requests($hash);
	is(main::Judo_Set($hash, 'judo', 'leakageProtection', 'close'), undef,
		'profilgebundener Schliessbefehl wird angenommen');
	like(pending_requests()->[0]{url}, qr{/api/rest/5100$},
		'ZEWA verwendet fuer Schliessen die korrekte Adresse 5100');
	complete_request(undef, 200, '');
	is(reading_value('judo', 'lastAction'), 'leakageProtection close',
		'erfolgreiche Aktion wird nachvollziehbar angezeigt');
};

subtest 'Familien bieten nur ihre dokumentierte Funktionalitaet an' => sub {
	my @cases = (
		[88, 'soft_pro', qr/sceneConfiguration/, qr/saltUsageYear/, qr/sceneReset/],
		[87, 'soft_safe', qr/saltSupply/, qr/waterYear/, qr/regeneration/],
		[89, 'softwell', qr/softWater/, qr/waterMonth/, qr/^clearPassword/],
		[65, 'idos', qr/dosage/, qr/status/, qr/pumpMode/],
		[60, 'ifill', qr/limits/, qr/waterDay/, qr/alarmRelay/],
	);

	for my $case (@cases) {
		my ($model_id, $family, $get_one, $get_two, $set_one) = @$case;
		reset_env();
		my $hash = { NAME => 'profile', TYPE => 'Judo', READINGS => {}, helper => {
			queue => [], issues => {}, generation => 1, request_id => 0,
		} };
		$main::defs{profile} = $hash;
		main::Judo_apply_model($hash, $model_id);
		is(reading_value('profile', 'family'), $family, "Modell $model_id verwendet $family");
		like(main::Judo_get_list($hash), $get_one, "$family bietet erstes Get-Kommando");
		like(main::Judo_get_list($hash), $get_two, "$family bietet zweites Get-Kommando");
		like(main::Judo_set_list($hash), $set_one, "$family bietet erwartetes Set-Kommando");
	}
};

subtest 'korrigierte REST-Adressen und Payloads je Familie' => sub {
	reset_env();
	my ($idos) = define_judo('idos', 'idos.local', 'user', 'password');
	complete_request('41');
	discard_requests($idos);
	is(main::Judo_Get($idos, 'idos', 'dosage'), undef, 'i-dos-Dosierung wird abgefragt');
	like(pending_requests()->[0]{url}, qr{/api/rest/6300$}, 'Dosierung verwendet 6300 statt Statusadresse 4300');
	discard_requests($idos);
	is(main::Judo_Set($idos, 'idos', 'datetime', '2026-08-23', '14:31:09'), undef,
		'i-dos-Datum kann gesetzt werden');
	like(pending_requests()->[0]{url}, qr{/api/rest/710017081A0E1F09$},
		'i-dos-Datum verwendet Adresse 7100 und Monat 08');

	reset_env();
	my ($pro) = define_judo('pro', 'pro.local', 'user', 'password');
	complete_request('58');
	discard_requests($pro);
	is(main::Judo_Get($pro, 'pro', 'desiredWaterHardness'), undef,
		'Wunschwasserhaerte kann nach Modellerkennung gelesen werden');
	like(pending_requests()->[0]{url}, qr{/api/rest/5100$}, 'PRO liest Wunschwasserhaerte mit 5100');
	discard_requests($pro);
	is(main::Judo_Get($pro, 'pro', 'saltUsageDay', '2024-06-19'), undef,
		'Salzstatistik akzeptiert ein Datum');
	like(pending_requests()->[0]{url}, qr{/api/rest/F3001306E807$},
		'Salzstatistik enthaelt die vier erforderlichen Datumsbytes');
	discard_requests($pro);
	like(main::Judo_Set($pro, 'pro', 'waterMaxAmount', '3001'), qr/zwischen 0 und 3000/,
		'PRO-Entnahmemenge beachtet dokumentiertes Maximum');
	is(main::Judo_Set($pro, 'pro', 'waterMaxAmount', '3000'), undef,
		'PRO-Entnahmemenge 3000 ist gueltig');
	like(pending_requests()->[0]{url}, qr{/api/rest/3F00B80B$},
		'PRO-Entnahmemenge verwendet 3F und Little Endian');

	reset_env();
	my ($zewa) = define_judo('zewaDate', 'zewa.local', 'user', 'password');
	complete_request('44');
	discard_requests($zewa);
	is(main::Judo_Set($zewa, 'zewaDate', 'datetime', '2026-08-23', '14:31:09'), undef,
		'ZEWA-Datum kann gesetzt werden');
	like(pending_requests()->[0]{url}, qr{/api/rest/5A0017081A0E1F09$},
		'ZEWA verwendet die familiaere Datumsadresse 5A00');

	reset_env();
	my ($ifill) = define_judo('ifill', 'ifill.local', 'user', 'password');
	complete_request('3C');
	discard_requests($ifill);
	is(main::Judo_Set($ifill, 'ifill', 'fillValve', 'open'), undef,
		'i-fill-Fuellventil kann geoeffnet werden');
	like(pending_requests()->[0]{url}, qr{/api/rest/530001$},
		'i-fill-Fuellventil verwendet 5300 plus Modusbyte');
};

subtest 'Heartbeat und Offline-Schwelle' => sub {
	reset_env();
	my ($hash) = define_judo('heartbeatJudo', '192.168.1.50', 'user', 'password');
	complete_request('44');
	discard_requests($hash);

	is(main::Judo_Get($hash, 'heartbeatJudo', 'heartbeat'), undef,
		'manueller Heartbeat wird gestartet');
	complete_request('44');
	is(reading_value('heartbeatJudo', 'heartbeatCount'), 1, 'Heartbeatzaehler steigt');
	like(reading_value('heartbeatJudo', 'heartbeat'), qr/^\d{4}-\d{2}-\d{2} /,
		'Heartbeatzeit wird gesetzt');
	is(reading_value('heartbeatJudo', 'heartbeatFailures'), 0, 'Erfolg setzt Fehlerfolge zurueck');

	for my $failure (1 .. 3) {
		main::Judo_Get($hash, 'heartbeatJudo', 'heartbeat');
		fail_request("timeout $failure");
	}

	is(reading_value('heartbeatJudo', 'heartbeatFailures'), 3, 'drei Transportfehler werden gezaehlt');
	is(reading_value('heartbeatJudo', 'availability'), 'offline', 'Fehlerschwelle setzt offline');
	is(reading_value('heartbeatJudo', 'state'), 'offline', 'sichtbarer Status ist offline');
	like(reading_value('heartbeatJudo', 'lastError'), qr/Transportfehler: timeout 3/,
		'letzter Transportfehler ist verstaendlich');

	main::Judo_Get($hash, 'heartbeatJudo', 'heartbeat');
	complete_request('44');
	is(reading_value('heartbeatJudo', 'availability'), 'online', 'naechster Erfolg setzt online');
	is(reading_value('heartbeatJudo', 'heartbeatFailures'), 0, 'naechster Erfolg leert Fehlerfolge');
};

subtest 'Modellwechsel verwirft Kommandos des alten Profils' => sub {
	reset_env();
	my ($hash) = define_judo('changingJudo', 'judo.local', 'user', 'password');
	complete_request('44');
	discard_requests($hash);
	main::Judo_heartbeat_timer($hash);
	is(request_codes($hash), [qw(FF00 2800)], 'ZEWA-Heartbeat hat Modell und Gesamtwasser geplant');
	complete_request('34');
	is(reading_value('changingJudo', 'family'), 'softwell', 'neues SOFTwell-Profil ist aktiv');
	is(request_codes($hash), [qw(0600 0100 0E00 2500 2900)],
		'alter ZEWA-Poll wurde vor SOFTwell-Initialisierung verworfen');
};

subtest 'HTTP- und JSON-Fehler setzen keine fachlichen Erfolgsreadings' => sub {
	reset_env();
	my ($auth_hash) = define_judo('authJudo', 'judo.local', 'user', 'wrong');
	complete_request(undef, 401, '');
	is(reading_value('authJudo', 'availability'), 'online', 'HTTP-Antwort beweist erreichbaren Dienst');
	is(reading_value('authJudo', 'state'), 'error', 'HTTP 401 ist kein fachlicher Erfolg');
	like(reading_value('authJudo', 'lastError'), qr/Authentifizierung fehlgeschlagen/,
		'401 wird als Authentifizierungsfehler benannt');
	is(reading_value('authJudo', 'model', undef), undef, '401 setzt kein Modellreading');

	reset_env();
	my ($json_hash) = define_judo('jsonJudo', 'judo.local', 'user', 'password');
	complete_request(undef, 200, 'kein-json');
	is(reading_value('jsonJudo', 'state'), 'error', 'ungueltiges JSON setzt error');
	like(reading_value('jsonJudo', 'lastError'), qr/Ungueltige JSON-Antwort/,
		'JSON-Fehler ist verstaendlich');
	is(reading_value('jsonJudo', 'model', undef), undef, 'ungueltiges JSON setzt kein Modell');
	my $log = join("\n", map { $_->[2] } @{ log_entries() });
	unlike($log, qr/password|top-secret/, 'Log enthaelt kein Passwort');
};

subtest 'Eingaben und Attribute werden eng validiert' => sub {
	reset_env();
	my ($hash) = define_judo('validationJudo', 'judo.local', undef, undef);
	like(main::Judo_Get($hash, 'validationJudo', 'des'), qr/Unknown argument des/,
		'Get akzeptiert keine Teiltreffer');
	like(main::Judo_Attr('set', 'validationJudo', 'interval', '5'), qr/zwischen 10 und 86400/,
		'zu kurzes Intervall wird abgelehnt');
	like(main::Judo_Attr('set', 'validationJudo', 'username', 'bad:user'), qr/Doppelpunkt/,
		'ungueltiger Basic-Auth-Benutzer wird abgelehnt');
	like(main::Judo_Define({ NAME => 'bad' }, 'bad Judo http://judo.local'), qr/Ungueltiger Host/,
		'Protokoll im Host wird abgelehnt');
};

subtest 'Passwortverwaltung und disable stoppen Netzwerkarbeit' => sub {
	reset_env();
	my ($hash) = define_judo('managedJudo', 'judo.local', undef, undef);
	is(reading_value('managedJudo', 'state'), 'credentialsMissing',
		'ohne Zugangsdaten wird kein Request gestartet');
	is(scalar(@{ pending_requests() }), 0, 'ohne Zugangsdaten bleibt HTTP leer');
	set_attribute($hash, 'username', 'user');
	is(main::Judo_Set($hash, 'managedJudo', 'password', 'secret value'), undef,
		'Passwort wird gespeichert');
	is(reading_value('managedJudo', 'passwordStored'), 'yes', 'Passwortstatus ist sichtbar');
	is(scalar(@{ pending_requests() }), 1, 'nach vollstaendigen Zugangsdaten beginnt FF00');
	like(pending_requests()->[0]{url}, qr{/api/rest/FF00$}, 'Passwortstart bleibt bei sicherer Modellabfrage');

	is(main::Judo_Attr('set', 'managedJudo', 'disable', '1'), undef, 'disable=1 wird akzeptiert');
	is(reading_value('managedJudo', 'state'), 'disabled', 'disable setzt sichtbaren Zustand');
	is(reading_value('managedJudo', 'availability'), 'offline', 'disable setzt Erreichbarkeit offline');
	my $stale = shift @{ pending_requests() };
	$stale->{code} = 200;
	$stale->{callback}->($stale, '', '{"data":"44"}');
	is(reading_value('managedJudo', 'state'), 'disabled', 'spaeter Callback kann disable nicht ueberschreiben');

	set_attribute($hash, 'disable', 0);
	is(main::Judo_Set($hash, 'managedJudo', 'clearPassword'), undef, 'Passwort kann entfernt werden');
	is(reading_value('managedJudo', 'passwordStored'), 'no', 'entferntes Passwort ist sichtbar');
	is(reading_value('managedJudo', 'state'), 'credentialsMissing', 'ohne Passwort stoppt das Modul');
};

done_testing;
