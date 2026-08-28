# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# Licensed under the GNU General Public License v2.0 only

package Judo::Connection;

use strict;
use warnings;
use Encode qw(encode);
use Exporter qw(import);
use HttpUtils;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Judo::Auth qw(Judo_read_password);
use Judo::Protocol qw(Judo_build_get_code);

our @EXPORT_OK = qw(
	Judo_schedule_reconnect Judo_reconnect_timer Judo_clear_requests
	Judo_start Judo_schedule_heartbeat Judo_heartbeat_timer
	Judo_queue_get Judo_queue_poll Judo_enqueue_request
	Judo_dispatch_timer Judo_dispatch_next Judo_Callback
	Judo_parse_response Judo_mark_failure
);

# Plant einen Reconnect hinter der laufenden Attributaenderung, damit AttrVal
# bereits den neuen Wert sieht.
sub Judo_schedule_reconnect($) {
	my ($hash) = @_;
	main::RemoveInternalTimer($hash, 'Judo_reconnect_timer');
	main::InternalTimer(main::gettimeofday() + 0.1, 'Judo_reconnect_timer', $hash, 0);
	main::Judo_log($hash, 4, 'reconnect scheduled delay=0.1s');
	return;
}

# Fuehrt den nach einer Attributaenderung geplanten Neustart aus.
sub Judo_reconnect_timer($) {
	my ($hash) = @_;
	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'reconnect skipped reason=disabled');
		return;
	}
	main::Judo_log($hash, 2, 'reconnect started');
	Judo_start($hash);
	return;
}

# Verwirft Queue und aktiven Request durch eine neue Generationsnummer. Der
# zugehoerige Socket wird vor der Freigabe geschlossen, damit ein Neustart
# niemals parallel zu einem alten Netzwerkauftrag laeuft.
sub Judo_clear_requests($) {
	my ($hash) = @_;
	my $queued = scalar @{ $hash->{helper}{queue} ||= [] };
	my $active = $hash->{helper}{active_request};
	my $active_id = $active ? ($active->{id} || 'unknown') : 'none';
	$hash->{helper}{generation} = ($hash->{helper}{generation} || 0) + 1;
	main::RemoveInternalTimer($hash, 'Judo_dispatch_timer');
	$hash->{helper}{queue} = [];
	my $http_param = delete $hash->{helper}{active_http_param};

	# Ein bereits an HttpUtils uebergebener Auftrag wird tatsaechlich beendet,
	# bevor active_request einen neuen Versand erlauben kann.
	if ($http_param) {
		main::HttpUtils_Close($http_param);
		$hash->{helper}{dispatch_not_before} =
			main::gettimeofday() + $main::Judo_REQUEST_DELAY;
		main::Judo_log($hash, 4,
			"active connection closed id=$active_id nextRequestDelay=$main::Judo_REQUEST_DELAY seconds");
	}
	delete $hash->{helper}{active_request};
	main::Judo_log($hash, 4,
		"requests cleared generation=$hash->{helper}{generation} queued=$queued activeId=$active_id");
	return;
}

# Startet ausschliesslich mit der sicheren Modellabfrage und plant unabhaengig
# davon den naechsten Heartbeat fuer einen automatischen Wiederanlauf.
sub Judo_start($) {
	my ($hash) = @_;
	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'connection start skipped reason=disabled');
		return;
	}
	main::Judo_log($hash, 2, "connection start host=$hash->{host}");
	main::RemoveInternalTimer($hash, 'Judo_reconnect_timer');
	main::RemoveInternalTimer($hash, 'Judo_heartbeat_timer');
	Judo_clear_requests($hash);
	delete $hash->{helper}{family};
	delete $hash->{helper}{model_id};

	# Fehlende Zugangsdaten werden sichtbar gemeldet, ohne wiederkehrende leere
	# HTTP-Aufrufe oder Passwortmeldungen im Log zu erzeugen.
	if (!main::Judo_credentials_available($hash)) {
		main::Judo_record_issue($hash, 'configuration', 'username oder Passwort fehlt');
		main::Judo_readings($hash, { availability => 'offline', state => 'credentialsMissing' });
		Judo_schedule_heartbeat($hash);
		return;
	}
	main::Judo_clear_issue($hash, 'configuration');
	main::Judo_readings($hash, { availability => 'offline', state => 'connecting' });
	Judo_queue_get($hash, 'model', 'discover');
	Judo_dispatch_next($hash);
	Judo_schedule_heartbeat($hash);
	return;
}

# Plant den naechsten Heartbeat online mit dem normalen und offline mit dem
# langsameren Wiederanlaufintervall.
sub Judo_schedule_heartbeat($) {
	my ($hash) = @_;
	main::RemoveInternalTimer($hash, 'Judo_heartbeat_timer');
	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'heartbeat scheduling skipped reason=disabled');
		return;
	}
	my $online_interval = main::AttrVal(
		$hash->{NAME}, 'interval', $main::Judo_DEFAULT_INTERVAL);

	# Ein Intervall von null deaktiviert die Automatik, aber keine manuellen Befehle.
	if (!$online_interval) {
		main::Judo_log($hash, 3, 'heartbeat scheduling disabled interval=0');
		return;
	}
	my $offline = ($hash->{READINGS}{availability}{VAL} || 'offline') eq 'offline';
	my $interval = $offline
		? main::AttrVal(
			$hash->{NAME}, 'offlineInterval', $main::Judo_DEFAULT_OFFLINE_INTERVAL)
		: $online_interval;
	my $mode = $offline ? 'offline' : 'online';
	main::InternalTimer(main::gettimeofday() + $interval, 'Judo_heartbeat_timer', $hash, 0);
	main::Judo_log($hash, 4,
		"heartbeat scheduled interval=$interval seconds mode=$mode");
	return;
}

# Fragt FF00 als sicheren Heartbeat ab. Profilwerte werden erst von der
# erfolgreichen und validierten Modellantwort eingereiht.
sub Judo_heartbeat_timer($) {
	my ($hash) = @_;
	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'heartbeat skipped reason=disabled');
		return;
	}
	main::Judo_log($hash, 4, 'heartbeat started');
	Judo_schedule_heartbeat($hash);
	my $username = main::AttrVal($hash->{NAME}, 'username', '');
	my $password = Judo_read_password($hash);

	# Fehlende Zugangsdaten werden ohne ihren Inhalt als Abbruchgrund sichtbar.
	if ($username eq '' || !defined($password) || $password eq '') {
		main::Judo_log($hash, 4, 'heartbeat skipped reason=credentialsMissing');
		return;
	}
	Judo_queue_get(
		$hash, 'model', $hash->{helper}{family} ? 'heartbeat' : 'discover', 1);
	Judo_dispatch_next($hash);
	return;
}

# Stellt einen profilgebundenen Get-Request ohne doppelte Queue-Eintraege an.
sub Judo_queue_get($$$;$) {
	my ($hash, $command, $reason, $poll_after_success) = @_;
	my $descriptor = main::Judo_get_descriptor($hash, $command);

	# Ein fehlender interner Deskriptor ist auf Verbose 4 nachvollziehbar, ohne
	# einen unvollstaendigen REST-Auftrag zu erzeugen.
	if (!$descriptor) {
		main::Judo_log($hash, 4,
			"request skipped command=$command reason=$reason descriptor=missing");
		return;
	}
	my ($code, $error) = Judo_build_get_code($descriptor, []);

	# Interne Pollingkommandos besitzen keine Pflichtargumente; ein Profilfehler
	# wird kontrolliert sichtbar statt mit einem unvollstaendigen Request fortgesetzt.
	if ($error) {
		main::Judo_record_issue($hash, $command, $error);
		return;
	}
	Judo_enqueue_request($hash, {
		command => $command, mode => 'get', code => $code,
		descriptor => $descriptor, reason => $reason,
		poll_after_success => $poll_after_success ? 1 : 0,
	});
	return;
}

# Reiht die Profilwerte ausschliesslich nach einem erfolgreichen automatischen
# Heartbeat ein und behaelt dabei die zentrale Deduplizierung bei.
sub Judo_queue_poll($) {
	my ($hash) = @_;
	my $profile = main::Judo_profile($hash);

	# Ohne erkanntes Profil existieren keine sicheren familienabhaengigen Pollwerte.
	if (!$profile) {
		main::Judo_log($hash, 4, 'polling skipped reason=profileMissing');
		return;
	}
	main::Judo_log($hash, 4,
		"polling queued count=" . scalar(@{ $profile->{poll} }));

	# Alle Profilwerte folgen seriell auf den bereits validierten Heartbeat.
	for my $command (@{ $profile->{poll} }) {
		Judo_queue_get($hash, $command, 'poll');
	}

	return;
}

# Fuegt einen Request genau einmal pro Kommando, Modus und Grund in die serielle
# Warteschlange ein.
sub Judo_enqueue_request($$) {
	my ($hash, $request) = @_;
	my $key = join(':', $request->{mode}, $request->{command}, $request->{reason} || '');
	my $active = $hash->{helper}{active_request};

	# Aktive und bereits wartende identische Auftraege werden auf Verbose 5 als
	# bewusste Deduplizierung sichtbar.
	if ($active && ($active->{dedupe_key} || '') eq $key) {
		main::Judo_log($hash, 5, "request deduplicated key=$key location=active");
		return;
	}

	# Eine bereits wartende identische Abfrage wird nicht vervielfacht, wenn ein
	# langsames Geraet ein Heartbeatintervall ueberschreitet.
	for my $queued (@{ $hash->{helper}{queue} ||= [] }) {
		if (($queued->{dedupe_key} || '') eq $key) {
			main::Judo_log($hash, 5, "request deduplicated key=$key location=queue");
			return;
		}
	}

	$request->{dedupe_key} = $key;
	$request->{generation} = $hash->{helper}{generation};
	$request->{id} = ++$hash->{helper}{request_id};
	push @{ $hash->{helper}{queue} }, $request;
	main::Judo_log($hash, 5,
		"request queued id=$request->{id} key=$key queueSize="
			. scalar(@{ $hash->{helper}{queue} }));
	return;
}

# Fuehrt einen wegen des Mindestabstands aufgeschobenen Versand erneut aus.
sub Judo_dispatch_timer($) {
	my ($hash) = @_;
	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'dispatch timer skipped reason=disabled');
		return;
	}
	Judo_dispatch_next($hash);
	return;
}

# Sendet immer nur den ersten wartenden Request. Zwischen abgeschlossenen oder
# aktiv abgebrochenen Netzwerkauftraegen liegt ein fester Mindestabstand.
sub Judo_dispatch_next($) {
	my ($hash) = @_;

	if ($hash->{helper}{active_request}) {
		my $active_id = $hash->{helper}{active_request}{id} || 'unknown';
		main::Judo_log($hash, 5, "dispatch deferred activeId=$active_id");
		return;
	}

	if (main::AttrVal($hash->{NAME}, 'disable', 0)) {
		main::Judo_log($hash, 4, 'dispatch skipped reason=disabled');
		return;
	}
	my $queue = $hash->{helper}{queue} ||= [];
	return if !@$queue;
	my $now = main::gettimeofday();
	my $not_before = $hash->{helper}{dispatch_not_before} || 0;

	# Folgeauftraege warten bis zum Ende der Schutzpause; ein einzelner Timer
	# ersetzt dabei beliebig viele erneute Dispatch-Versuche.
	if ($not_before > $now) {
		main::RemoveInternalTimer($hash, 'Judo_dispatch_timer');
		main::InternalTimer($not_before, 'Judo_dispatch_timer', $hash, 0);
		main::Judo_log($hash, 5,
			"dispatch delayed seconds=" . sprintf('%.3f', $not_before - $now));
		return;
	}
	main::RemoveInternalTimer($hash, 'Judo_dispatch_timer');
	delete $hash->{helper}{dispatch_not_before};
	my $request = shift @$queue;
	my $username = main::AttrVal($hash->{NAME}, 'username', '');
	my $password = Judo_read_password($hash);

	# Ein zwischen Queue und Versand entferntes Passwort stoppt den Auftrag, ohne
	# einen Request mit leerer Authentifizierung zu erzeugen.
	if ($username eq '' || !defined($password) || $password eq '') {
		main::Judo_record_issue($hash, 'configuration', 'username oder Passwort fehlt');
		main::Judo_readings($hash, { availability => 'offline', state => 'credentialsMissing' });
		return;
	}
	my $protocol = main::AttrVal($hash->{NAME}, 'ssl', 0) ? 'https' : 'http';
	my $url = "$protocol://$hash->{host}/api/rest/$request->{code}";
	my $authorization = 'Basic ' . encode_base64(encode('UTF-8', "$username:$password"), '');
	my $timeout = main::AttrVal($hash->{NAME}, 'timeout', $main::Judo_DEFAULT_TIMEOUT);
	$request->{started_at} = main::gettimeofday();
	$hash->{helper}{active_request} = $request;
	main::Judo_log($hash, 4,
		"request id=$request->{id} command=$request->{command} mode=$request->{mode}"
			. " reason=" . ($request->{reason} || 'none')
			. " timeout=$timeout queueRemaining=" . scalar(@{ $hash->{helper}{queue} })
			. " url=$url");
	my $http_param = {
		url => $url,
		method => 'GET',
		timeout => $timeout,
		header => {
			Accept => 'application/json, text/plain, */*',
			Authorization => $authorization,
		},
		hash => $hash,
		request => $request,
		generation => $request->{generation},
		callback => \&Judo_Callback,
	};
	$hash->{helper}{active_http_param} = $http_param;
	main::HttpUtils_NonblockingGet($http_param);
	return;
}

# Verarbeitet Transport, HTTP-Status, JSON und Nutzdaten strikt in dieser
# Reihenfolge und startet anschliessend den naechsten seriellen Request.
sub Judo_Callback($) {
	my ($param, $transport_error, $content) = @_;
	my $hash = $param->{hash};
	my $request = $param->{request};
	return if !$hash || !$request;

	# Spaete Callbacks einer verworfenen Verbindungsgeneration duerfen weder Queue
	# noch Readings der aktuellen Verbindung beeinflussen.
	if (($param->{generation} || 0) != ($hash->{helper}{generation} || 0)) {
		main::Judo_log($hash, 4, "ignored stale callback id=$request->{id}");
		return;
	}
	delete $hash->{helper}{active_request};
	delete $hash->{helper}{active_http_param};
	$hash->{helper}{dispatch_not_before} =
		main::gettimeofday() + $main::Judo_REQUEST_DELAY;
	my $http_code = $param->{code};
	my $duration = defined($request->{started_at})
		? main::gettimeofday() - $request->{started_at} : 0;
	my $duration_text = sprintf('%.3f', $duration);
	my $code_text = defined($http_code) ? $http_code : 'none';
	my $content_length = defined($content) ? length($content) : 0;
	main::Judo_log($hash, 4,
		"response id=$request->{id} command=$request->{command} code=$code_text"
			. " bytes=$content_length duration=$duration_text seconds"
			. " transportError="
			. (defined($transport_error) && $transport_error ne '' ? 'yes' : 'no'));
	main::Judo_log($hash, 5, "response payload id=$request->{id} content=$content")
		if defined($content) && $content ne '';

	# Transportfehler besitzen keinen verlaesslichen HTTP-Kontakt und zaehlen fuer
	# die Offline-Erkennung.
	if (defined($transport_error) && $transport_error ne '') {
		main::Judo_record_issue($hash, $request->{command}, "Transportfehler: $transport_error");
		Judo_mark_failure($hash, $request, 1);
		Judo_dispatch_next($hash);
		return;
	}
	my $previous_availability = $hash->{READINGS}{availability}{VAL} || '';
	main::Judo_reading($hash, 'lastContact', main::Judo_now_text());
	main::Judo_reading($hash, 'availability', 'online');
	main::Judo_log($hash, 2, "availability $previous_availability -> online")
		if $previous_availability ne 'online';

	# Der erste wieder erreichbare HTTP-Dienst wechselt sofort vom langsamen
	# Offline- auf das normale Online-Intervall.
	if ($previous_availability ne 'online') {
		Judo_schedule_heartbeat($hash);
	}

	# Nur erfolgreiche 2xx-Antworten duerfen Nutzdaten oder Aktionsreadings setzen.
	if (!defined($http_code) || $http_code < 200 || $http_code >= 300) {
		my $message = defined($http_code) ? "HTTP-Fehler $http_code" : 'HTTP-Status fehlt';
		$message .= ' (Authentifizierung fehlgeschlagen)'
			if defined($http_code) && $http_code == 401;
		main::Judo_record_issue($hash, $request->{command}, $message, $http_code);
		main::Judo_reading($hash, 'state', 'error');
		Judo_dispatch_next($hash);
		return;
	}
	my ($data, $response_error) = Judo_parse_response($request, $content);

	# JSON- oder Datenfehler beweisen zwar einen erreichbaren HTTP-Dienst, duerfen
	# aber keinen fachlichen Erfolg vortaeuschen.
	if ($response_error) {
		main::Judo_record_issue($hash, $request->{command}, $response_error, $http_code);
		main::Judo_reading($hash, 'state', 'error');
		Judo_dispatch_next($hash);
		return;
	}
	main::Judo_handle_success($hash, $request, $data);
	main::Judo_log($hash, 4,
		"request completed id=$request->{id} command=$request->{command} mode=$request->{mode}");
	Judo_dispatch_next($hash);
	return;
}

# Extrahiert data aus einer erfolgreichen JSON-Antwort; leere Set-Antworten sind
# laut API erlaubt, waehrend Get-Kommandos zwingend Nutzdaten benoetigen.
sub Judo_parse_response($$) {
	my ($request, $content) = @_;
	$content = '' if !defined $content;
	return ('', undef) if $request->{mode} eq 'set' && $content eq '';
	return (undef, 'Leere Antwort auf Lesekommando') if $content eq '';
	my $decoded;
	my $ok = eval {
		$decoded = JSON::PP->new->decode($content);
		1;
	};
	return (undef, 'Ungueltige JSON-Antwort') if !$ok || ref($decoded) ne 'HASH';
	return (undef, 'JSON-Antwort enthaelt kein data-Feld') if !exists $decoded->{data};
	my $data = defined($decoded->{data}) ? "$decoded->{data}" : '';
	return (undef, 'Leere Nutzdaten auf Lesekommando') if $request->{mode} eq 'get' && $data eq '';
	return ($data, undef);
}

# Zaehlt fehlgeschlagene Transportkontakte und setzt erst nach der konfigurierten
# Anzahl auf offline; beim ersten Verbindungsaufbau existiert noch kein alter
# Erfolg und der Status wird sofort ehrlich offline dargestellt.
sub Judo_mark_failure($$$) {
	my ($hash, $request, $connectivity_failure) = @_;
	return if !$connectivity_failure;
	my $failures = ++$hash->{helper}{heartbeat_failures};
	main::Judo_reading($hash, 'heartbeatFailures', $failures);
	my $limit = main::AttrVal(
		$hash->{NAME}, 'maxFailures', $main::Judo_DEFAULT_MAX_FAILURES);
	my $command = $request->{command} || 'unknown';
	main::Judo_log($hash, 4,
		"transport failure command=$command count=$failures limit=$limit");

	# Ohne jemals erfolgreichen Request oder nach Erreichen der Fehlerschwelle ist
	# die Erreichbarkeit nicht mehr gegeben.
	if (!$hash->{helper}{last_success_epoch} || $failures >= $limit) {
		my $previous_state = $hash->{READINGS}{state}{VAL} || '';
		my $previous_availability = $hash->{READINGS}{availability}{VAL} || '';
		main::Judo_readings($hash, { availability => 'offline', state => 'offline' });
		main::Judo_log($hash, 2,
			"state $previous_state -> offline failures=$failures limit=$limit")
			if $previous_state ne 'offline';

		# Nach dem Offline-Uebergang duerfen nur manuelle Auftraege und sichere
		# Heartbeats in der Queue verbleiben.
		my $queue = $hash->{helper}{queue} ||= [];
		my $queued_before = scalar(@$queue);
		@$queue = grep {
			($_->{reason} || '') !~ /^(?:poll|init|refresh)$/
		} @$queue;
		my $removed = $queued_before - scalar(@$queue);
		main::Judo_log($hash, 4, "automatic requests discarded count=$removed")
			if $removed;

		# Beim ersten Offline-Uebergang ersetzt das langsamere Intervall den bereits
		# online geplanten Folgetermin.
		if ($previous_availability ne 'offline') {
			Judo_schedule_heartbeat($hash);
		}
	}
	return;
}

1;
