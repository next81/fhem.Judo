# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

##############################################
# Lokale REST-API fuer Judo-Wasseraufbereitung
package main;

use strict;
use warnings;
use utf8;
use lib './lib/FHEM';
use POSIX qw(strftime);
use Judo::Auth qw(
	Judo_password_index Judo_password_key Judo_store_password
	Judo_read_password Judo_clear_password
);
use Judo::Connection qw(
	Judo_schedule_reconnect Judo_reconnect_timer Judo_clear_requests
	Judo_start Judo_schedule_heartbeat Judo_heartbeat_timer
	Judo_queue_get Judo_queue_poll Judo_enqueue_request
	Judo_dispatch_timer Judo_dispatch_next Judo_Callback
	Judo_parse_response Judo_mark_failure
);
use Judo::Protocol qw(
	Judo_number_in_range Judo_dec_to_hex Judo_dec_to_le_hex
	Judo_hex_to_dec Judo_le_hex_to_dec Judo_valid_date
	Judo_encode_get_arguments Judo_build_get_code Judo_encode_datetime
	Judo_build_set_code Judo_validate_data Judo_decode_model_id
	Judo_decode_data Judo_decode_statistics
);
use Judo::Runtime qw(
	Judo_profile Judo_get_descriptor Judo_handle_success Judo_apply_model
);
use vars qw(%defs %attr $readingFnAttributes $init_done);

our $Judo_VERSION = '1.2.0';
our $Judo_DEFAULT_INTERVAL = 60;
our $Judo_DEFAULT_OFFLINE_INTERVAL = 300;
our $Judo_DEFAULT_TIMEOUT = 60;
our $Judo_DEFAULT_MAX_FAILURES = 3;
our $Judo_REQUEST_DELAY = 5;

# --- FHEM-Zugriffe und Logging ------------------------------------------------

# Ermittelt die wirksame Verbose-Stufe des Devices ohne eine eigene parallele
# Logkonfiguration einzufuehren.
sub Judo_log_enabled($$) {
	my ($hash, $level) = @_;
	return 0 if ref($hash) ne 'HASH' || !defined($hash->{NAME});
	my $verbose = AttrVal($hash->{NAME}, 'verbose', AttrVal('global', 'verbose', 3));
	$verbose = 3 if !defined($verbose) || $verbose !~ /^\d+$/;
	return $verbose >= $level ? 1 : 0;
}

# Schreibt begrenzte einzeilige Meldungen mit einheitlichem Modul-Prefix. URLs
# enthalten grundsaetzlich keine Zugangsdaten und koennen sicher genannt werden.
sub Judo_log($$$) {
	my ($hash, $level, $message) = @_;
	return if !Judo_log_enabled($hash, $level);
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	my $truncated = '... <truncated>';
	$message = substr($message, 0, 4096 - length($truncated)) . $truncated
		if length($message) > 4096;
	Log3($hash->{NAME}, $level, "Judo $hash->{NAME}: $message");
	return;
}

# Liefert einen reproduzierbaren lokalen Zeitstempel fuer Heartbeat-, Kontakt-
# und Fehlerreadings.
sub Judo_now_text() {
	return strftime('%Y-%m-%d %H:%M:%S', localtime(time));
}

# Aktualisiert ein einzelnes Reading nur bei einer Wertaenderung. Die drei
# Zeitreadings dokumentieren dagegen jeden tatsaechlichen Kontaktzeitpunkt.
sub Judo_reading($$$) {
	my ($hash, $reading, $value) = @_;
	$value = '' if !defined $value;

	# Unveraenderte Werte bleiben ohne neuen Zeitstempel und ohne FHEM-Ereignis.
	if ($reading ne 'lastContact' && $reading ne 'heartbeat'
		&& exists($hash->{READINGS}{$reading})
		&& defined($hash->{READINGS}{$reading}{VAL})
		&& "$hash->{READINGS}{$reading}{VAL}" eq "$value") {
		return;
	}
	readingsSingleUpdate($hash, $reading, $value, 1);
	return;
}

# Aktualisiert mehrere zusammengehoerige Readings in stabiler Reihenfolge.
sub Judo_readings($$) {
	my ($hash, $updates) = @_;

	# Sortierte Readingnamen halten Tests, Logs und FHEM-Ereignisse reproduzierbar.
	for my $reading (sort keys %$updates) {
		Judo_reading($hash, $reading, $updates->{$reading});
	}

	return;
}

# Verwaltet aktuelle Fehler pro Kommando, damit ein fremder erfolgreicher
# Request einen noch bestehenden Fehler nicht verdeckt.
sub Judo_update_issue_readings($) {
	my ($hash) = @_;
	my $issues = $hash->{helper}{issues} ||= {};
	my @keys = sort {
		($issues->{$b}{time} || 0) <=> ($issues->{$a}{time} || 0)
	} keys %$issues;

	# Ohne offene Fehler werden alle sichtbaren Fehlerfelder konsistent geleert.
	if (!@keys) {
		Judo_readings($hash, {
			errorCount => 0,
			lastError => 'none',
			lastErrorCode => 'none',
			lastErrorCommand => 'none',
		});
		return;
	}
	my $latest = $issues->{ $keys[0] };
	Judo_readings($hash, {
		errorCount => scalar(@keys),
		lastError => $latest->{message},
		lastErrorCode => defined($latest->{code}) ? $latest->{code} : 'none',
		lastErrorCommand => $keys[0],
	});
	return;
}

# Speichert und protokolliert einen kontrollierten Modul- oder REST-Fehler.
# Identische Wiederholungen bleiben als aktueller Fehler sichtbar, werden aber
# nicht bei jedem Heartbeat erneut ins Log geschrieben.
sub Judo_record_issue($$$;$$) {
	my ($hash, $key, $message, $code, $level) = @_;
	$key = 'module' if !defined($key) || $key eq '';
	$message = 'Unbekannter Fehler' if !defined($message) || $message eq '';
	$level = 2 if !defined($level) || $level !~ /^[1-5]$/;
	my $previous = $hash->{helper}{issues}{$key};
	my $same_code = $previous
		&& ((!defined($previous->{code}) && !defined($code))
			|| (defined($previous->{code}) && defined($code)
				&& "$previous->{code}" eq "$code"));
	my $repeated = $previous && $previous->{message} eq $message && $same_code;
	$hash->{helper}{issues}{$key} = {
		message => $message, code => $code, time => time,
	};
	Judo_update_issue_readings($hash);
	Judo_log($hash, $level,
		"error command=$key" . (defined($code) ? " code=$code" : '') . ": $message")
		if !$repeated;
	return;
}

# Entfernt nur den Fehler des erfolgreich korrigierten Kommandos.
sub Judo_clear_issue($$) {
	my ($hash, $key) = @_;
	return if !exists $hash->{helper}{issues}{$key};
	delete $hash->{helper}{issues}{$key};
	Judo_update_issue_readings($hash);
	Judo_log($hash, 3, "issue resolved command=$key");
	return;
}

# --- FHEM-Lebenszyklus und Benutzerbefehle -----------------------------------

# Registriert Lebenszyklus-, Get-, Set-, Attribut- und Notify-Schnittstellen.
sub Judo_Initialize($) {
	my ($hash) = @_;
	$hash->{DefFn} = 'Judo_Define';
	$hash->{UndefFn} = 'Judo_Undef';
	$hash->{GetFn} = 'Judo_Get';
	$hash->{SetFn} = 'Judo_Set';
	$hash->{AttrFn} = 'Judo_Attr';
	$hash->{NotifyFn} = 'Judo_Notify';
	$hash->{FW_deviceOverview} = 1;
	$hash->{AttrList} = 'interval offlineInterval timeout maxFailures username ssl:0,1 disable:0,1 '
		. $readingFnAttributes;
	return;
}

# Validiert den lokalen Hostnamen ohne Protokoll, Pfad oder eingebettete
# Zugangsdaten; dadurch bleibt der erzeugte Request immer im vorgesehenen Ziel.
sub Judo_valid_host($) {
	my ($host) = @_;
	return 0 if !defined($host) || $host eq '' || $host =~ m{[/@\s]};
	return 0 if $host !~ /^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|[A-Za-z0-9]|\[[0-9A-Fa-f:.]+\])(?::\d{1,5})?$/;
	my ($port) = $host =~ /:(\d+)$/;
	return 0 if defined($port) && ($port < 1 || $port > 65535);
	return 1;
}

# Prueft beide fuer HTTP Basic benoetigten Zugangsdaten, damit bereits der
# Startzustand eine noch unvollstaendige Konfiguration eindeutig anzeigt.
sub Judo_credentials_available($) {
	my ($hash) = @_;
	my $username = AttrVal($hash->{NAME}, 'username', '');
	my $password = Judo_read_password($hash);
	return $username ne '' && defined($password) && $password ne '' ? 1 : 0;
}

# Definiert ein Judo-Device, setzt einen nachvollziehbaren Startzustand und
# startet erst nach vorhandenen Zugangsdaten die sichere Modellerkennung.
sub Judo_Define($$) {
	my ($hash, $definition) = @_;
	my @parts = split /[ \t]+/, $definition;
	return "Usage: define <name> Judo <host[:port]>" if @parts != 3;
	my (undef, undef, $host) = @parts;
	return "Judo: Ungueltiger Host '$host'; erwartet wird host oder host:port"
		if !Judo_valid_host($host);
	$hash->{host} = $host;
	$hash->{helper} = { queue => [], issues => {}, generation => 0, request_id => 0 };
	$hash->{NOTIFYDEV} = 'global';
	my $state = AttrVal($hash->{NAME}, 'disable', 0) ? 'disabled'
		: Judo_credentials_available($hash) ? 'initialized' : 'credentialsMissing';
	Judo_readings($hash, {
		availability => 'offline', errorCount => 0, heartbeatFailures => 0,
		lastError => 'none', lastErrorCode => 'none', lastErrorCommand => 'none',
		state => $state,
		versionModule => $Judo_VERSION,
	});
	Judo_log($hash, 2, "defined host=$host state=$state version=$Judo_VERSION");

	# Waehrend des FHEM-Starts wartet das Modul auf INITIALIZED und damit auch auf
	# die aus dem statefile restaurierten Attribute und Readings.
	Judo_start($hash) if $init_done && !AttrVal($hash->{NAME}, 'disable', 0);
	return undef;
}

# Entfernt Timer und verwirft ausstehende Requests einer geloeschten Instanz.
sub Judo_Undef($$) {
	my ($hash, undef) = @_;
	RemoveInternalTimer($hash);
	Judo_clear_requests($hash);
	Judo_log($hash, 2, 'undefined');
	return undef;
}

# Validiert Laufzeitattribute und setzt disable sowie Intervallaenderungen ohne
# einen FHEM-save oder eine Konfigurationsdateiaenderung unmittelbar um.
sub Judo_Attr(@) {
	my ($operation, $name, $attribute, @values) = @_;
	return undef if $operation ne 'set' && $operation ne 'del';
	my $value = join(' ', @values);
	my $hash = $defs{$name};

	# Numerische Attribute erhalten enge Grenzen, damit Timer und HTTP-Timeouts
	# nicht durch Tippfehler blockiert oder unbrauchbar schnell ausgefuehrt werden.
	if ($operation eq 'set' && $attribute eq 'interval') {
		return 'interval muss 0 oder eine ganze Zahl zwischen 10 und 86400 Sekunden sein'
			if $value !~ /^\d+$/ || ($value != 0 && ($value < 10 || $value > 86400));
	} elsif ($operation eq 'set' && $attribute eq 'offlineInterval') {
		return 'offlineInterval muss eine ganze Zahl zwischen 10 und 86400 Sekunden sein'
			if $value !~ /^\d+$/ || $value < 10 || $value > 86400;
	} elsif ($operation eq 'set' && $attribute eq 'timeout') {
		return 'timeout muss eine ganze Zahl zwischen 1 und 300 Sekunden sein'
			if $value !~ /^\d+$/ || $value < 1 || $value > 300;
	} elsif ($operation eq 'set' && $attribute eq 'maxFailures') {
		return 'maxFailures muss eine ganze Zahl zwischen 1 und 10 sein'
			if $value !~ /^\d+$/ || $value < 1 || $value > 10;
	} elsif ($operation eq 'set' && $attribute eq 'username') {
		return 'username darf weder Doppelpunkt noch Steuerzeichen enthalten'
			if $value =~ /[:\x00-\x1f\x7f]/;
	} elsif ($operation eq 'set' && ($attribute eq 'ssl' || $attribute eq 'disable')) {
		return "$attribute muss 0 oder 1 sein" if $value !~ /^(?:0|1)$/;
	}
	return undef if !$hash;

	# disable stoppt Timer und Requests sofort; das Loeschen oder 0 aktiviert die
	# Instanz nach Abschluss der Attributaenderung erneut.
	if ($attribute eq 'disable') {
		my $disabled = $operation eq 'set' && $value eq '1';

		if ($disabled) {
			RemoveInternalTimer($hash);
			Judo_clear_requests($hash);
			Judo_readings($hash, { availability => 'offline', state => 'disabled' });
			Judo_log($hash, 2, 'disabled');
		} else {
			Judo_log($hash, 2, 'enabled; reconnect scheduled');
			Judo_schedule_reconnect($hash);
		}
		return undef;
	}

	# Verbindungs- und Timerattribute werden erst nach ihrer Uebernahme durch FHEM
	# in einem kurzen internen Timer neu ausgewertet.
	if ($attribute =~ /^(?:interval|offlineInterval|timeout|maxFailures|username|ssl)$/) {
		my $detail = $attribute eq 'username' ? '' : " value=$value";
		Judo_log($hash, 3,
			"attribute name=$attribute operation=$operation$detail; reconnect scheduled");
		Judo_schedule_reconnect($hash);
	}
	return undef;
}

# Begrenzt Notify auf FHEMs Start- und Konfigurations-Lebenszyklus.
sub Judo_Notify($$) {
	my ($hash, $device) = @_;
	return undef if ($device->{NAME} || '') ne 'global';
	my $events = deviceEvents($device, 1) || [];

	# Nach INITIALIZED oder REREADCFG sind Attribute und gespeicherte Readings
	# verfuegbar und die Modellerkennung kann sicher neu beginnen.
	for my $event (@$events) {
		next if !defined($event) || $event !~ /^(?:INITIALIZED|REREADCFG)$/;
		Judo_log($hash, 2, "lifecycle event=$event");
		Judo_start($hash) if !AttrVal($hash->{NAME}, 'disable', 0);
		last;
	}

	return undef;
}

# Baut die dynamische Get-Liste aus dem bereits erkannten Geraeteprofil.
sub Judo_get_list($) {
	my ($hash) = @_;
	my %commands = ( heartbeat => 'noArg', model => 'noArg', profile => 'noArg' );
	my $profile = Judo_profile($hash);

	# Erst nach der Modellerkennung werden ausschliesslich dokumentierte
	# Familienkommandos angeboten.
	if ($profile) {

		for my $command (keys %{ $profile->{get} }) {
			$commands{$command} = $profile->{get}{$command}{list} || '';
		}

	}
	return join(' ', map { $commands{$_} ne '' ? "$_:$commands{$_}" : $_ } sort keys %commands);
}

# Baut die dynamische Set-Liste und behaelt nur lokale Verwaltungsbefehle vor
# der erfolgreichen Modellbestimmung bei.
sub Judo_set_list($) {
	my ($hash) = @_;
	my %commands = (
		clearPassword => 'noArg', password => '', reconnect => 'noArg',
	);
	my $profile = Judo_profile($hash);

	# Geraeteaktionen werden niemals fuer eine unbekannte Familie freigeschaltet.
	if ($profile) {

		for my $command (keys %{ $profile->{set} }) {
			$commands{$command} = $profile->{set}{$command}{list} || '';
		}

	}
	return join(' ', map { $commands{$_} ne '' ? "$_:$commands{$_}" : $_ } sort keys %commands);
}

# Verarbeitet lokale Informationen oder stellt einen validierten Leseauftrag in
# die serielle Request-Warteschlange.
sub Judo_Get($$$@) {
	my ($hash, $name, $command, @arguments) = @_;
	my $choices = Judo_get_list($hash);
	return "Unknown argument ?, choose one of $choices" if !defined($command) || $command eq '?';
	Judo_log($hash, 3, "get command=$command");
	return $hash->{helper}{family} || 'unknown' if $command eq 'profile' && !@arguments;

	# Ein manueller Heartbeat nutzt ausschliesslich das bei allen Familien sichere
	# Geraetetyp-Kommando FF00.
	if ($command eq 'heartbeat' && !@arguments) {
		Judo_queue_get($hash, 'model', 'heartbeat');
		Judo_dispatch_next($hash);
		return undef;
	}
	my $descriptor = Judo_get_descriptor($hash, $command);
	return "Unknown argument $command, choose one of $choices" if !$descriptor;
	my ($code, $error) = Judo_build_get_code($descriptor, \@arguments);
	return $error if $error;
	Judo_enqueue_request($hash, {
		command => $command, mode => 'get', code => $code,
		descriptor => $descriptor,
		reason => $command eq 'model' && !$hash->{helper}{family} ? 'discover' : 'manual',
	});
	Judo_dispatch_next($hash);
	return undef;
}

# Verarbeitet Passwortverwaltung, Reconnect oder ein profilgebundenes,
# validiertes REST-Schreibkommando.
sub Judo_Set($@) {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	my $choices = Judo_set_list($hash);
	return "Unknown argument ?, choose one of $choices" if !defined($command) || $command eq '?';
	Judo_log($hash, 3, "set command=$command");

	# Passwoerter erscheinen weder in Diagnosemeldungen noch im Request-URL.
	if ($command eq 'password') {
		my $password = join(' ', @arguments);
		return 'password darf nicht leer sein' if $password eq '';
		my $error = Judo_store_password($hash, $password);
		return $error if $error;
		Judo_reading($hash, 'passwordStored', 'yes');
		Judo_start($hash) if !AttrVal($hash->{NAME}, 'disable', 0);
		return undef;
	}

	# clearPassword entfernt nur den verschleierten Key-Value-Eintrag dieser
	# Instanz und stoppt anschliessend alle Netzwerkarbeit.
	if ($command eq 'clearPassword' && !@arguments) {
		my $error = Judo_clear_password($hash);
		return $error if $error;
		RemoveInternalTimer($hash);
		Judo_clear_requests($hash);
		Judo_readings($hash, {
			availability => 'offline', passwordStored => 'no', state => 'credentialsMissing',
		});
		return undef;
	}

	# reconnect verwirft alte Generationen und beginnt erneut mit FF00.
	if ($command eq 'reconnect' && !@arguments) {
		Judo_start($hash);
		return undef;
	}
	my $profile = Judo_profile($hash);
	my $descriptor = $profile ? $profile->{set}{$command} : undef;
	return "Unknown argument $command, choose one of $choices" if !$descriptor;
	my ($code, $display, $error) = Judo_build_set_code($descriptor, \@arguments);
	return $error if $error;
	Judo_enqueue_request($hash, {
		command => $command, mode => 'set', code => $code, display => $display,
		descriptor => $descriptor, reason => 'manual',
	});
	Judo_dispatch_next($hash);
	return undef;
}

# --- Verbrauchsdifferenzen ---------------------------------------------------

# Aktualisiert nur monotone Verbrauchsdifferenzen; Zaehlerresets oder Ruecklaeufe
# erzeugen keine negativen Verbrauchswerte.
sub Judo_update_deltas($$) {
	my ($hash, $updates) = @_;

	# Gesamt- und Weichwasser besitzen monotone Literzaehler in der API.
	for my $reading (qw(totalWater softWater)) {
		next if !exists $updates->{$reading} || $updates->{$reading} !~ /^(\d+) l$/;
		my $current = $1;
		my $previous = $hash->{helper}{counters}{$reading};

		if (defined($previous) && $current >= $previous) {
			my $delta = $current - $previous;
			Judo_reading($hash, $reading eq 'totalWater' ? 'usageTotalWater' : 'usageSoftWater',
				$delta . ' l');
			Judo_log($hash, 5,
				"counter reading=$reading previous=$previous current=$current delta=$delta");
		} elsif (!defined($previous)) {
			Judo_log($hash, 5, "counter initialized reading=$reading current=$current");
		} else {
			Judo_log($hash, 4,
				"counter reset reading=$reading previous=$previous current=$current");
		}
		$hash->{helper}{counters}{$reading} = $current;
	}

	return;
}

1;

=pod

=head1 NAME

Judo - lokale REST-API fuer Judo-Wasseraufbereitungsgeraete

=head1 SYNOPSIS

	define judo Judo 192.168.1.50
	attr judo username meinBenutzer
	set judo password meinPasswort

=head1 SECURITY

Das Passwort wird nur verschleiert im FHEM-Key-Value-Speicher abgelegt. Es wird
nicht in URLs oder Logs geschrieben. Das Modul fuehrt kein C<save> aus.

=over 4

=item device
=item summary Local REST integration for supported Judo water treatment devices
=item summary_DE Lokale REST-Anbindung fuer unterstuetzte Judo-Wasseraufbereitungsgeraete

=back

=begin html

<a id="Judo"></a>
<h3>Judo</h3>
<p>Connects supported Judo devices through their local REST API. The device type
is read before any family-specific request. Requests are serialized with a
five-second minimum gap, and <code>FF00</code> provides a non-mutating heartbeat.
Active HTTP requests are closed before reconnecting or disabling the device.</p>

<a id="Judo-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; Judo &lt;host[:port]&gt;</code></p>

<a id="Judo-heartbeat"></a>
<h4>Heartbeat and errors</h4>
<p><code>FF00</code> is used as a non-mutating heartbeat. <code>availability</code>,
<code>heartbeat</code>, <code>heartbeatCount</code>, <code>heartbeatFailures</code>
and <code>lastContact</code> show connectivity and heartbeat quality.
<code>lastError</code>, <code>lastErrorCode</code>,
<code>lastErrorCommand</code> and <code>errorCount</code> describe current errors
without exposing credentials. While offline, only <code>FF00</code> is requested;
profile polling resumes after a successful heartbeat.</p>

<a id="Judo-set"></a>
<h4>Set</h4>
<p>Device-specific commands are available only after the model has been detected
and only for the active device profile.</p>
<ul>
<a id="Judo-set-password"></a>
<li><code>password &lt;password&gt;</code><br>
Stores the password obfuscated in FHEM's key-value store and starts model
detection when the user name is also configured.</li>
<a id="Judo-set-clearPassword"></a>
<li><code>clearPassword</code><br>
Removes the stored password and stops timers and network requests.</li>
<a id="Judo-set-reconnect"></a>
<li><code>reconnect</code><br>
Discards queued requests and restarts model detection with <code>FF00</code>.</li>
<a id="Judo-set-desiredWaterHardness"></a>
<li><code>desiredWaterHardness &lt;0..20&gt;</code><br>
Sets the desired water hardness on supported softeners.</li>
<a id="Judo-set-regeneration"></a>
<li><code>regeneration</code><br>
Starts regeneration on supported softeners.</li>
<a id="Judo-set-saltSupply"></a>
<li><code>saltSupply &lt;0..65535&gt;</code><br>
Sets the salt supply in grams.</li>
<a id="Judo-set-saltSupplyWarning"></a>
<li><code>saltSupplyWarning &lt;0..255&gt;</code><br>
Sets the salt-supply warning threshold in days.</li>
<a id="Judo-set-serviceAddress"></a>
<li><code>serviceAddress &lt;text&gt;</code><br>
Sets 1 to 16 printable ASCII characters as the service contact.</li>
<a id="Judo-set-waterMaxDuration"></a>
<li><code>waterMaxDuration &lt;0..255&gt;</code><br>
Sets the maximum withdrawal duration in minutes.</li>
<a id="Judo-set-hardnessUnit"></a>
<li><code>hardnessUnit &lt;dH|eH|fH|gpg|ppm|mmol|mval&gt;</code><br>
Sets the hardness unit. The i-soft PRO profile supports only <code>dH</code> and
<code>fH</code>.</li>
<a id="Judo-set-waterMaxFlow"></a>
<li><code>waterMaxFlow &lt;value&gt;</code><br>
Sets the maximum flow. The range is 0..5000 for i-soft PRO and 0..65535 for the
other supported softener profiles.</li>
<a id="Judo-set-waterMaxAmount"></a>
<li><code>waterMaxAmount &lt;value&gt;</code><br>
Sets the maximum withdrawal amount. The range is 0..3000 for i-soft PRO and
0..65535 for the other supported softener profiles.</li>
<a id="Judo-set-leakageProtection"></a>
<li><code>leakageProtection &lt;close|open&gt;</code><br>
Closes or opens the leakage-protection valve on supported devices.</li>
<a id="Judo-set-holidayMode"></a>
<li><code>holidayMode &lt;value&gt;</code><br>
Uses <code>0..255</code> on i-soft/i-soft SAFE, <code>&lt;flags 0..255&gt;
&lt;days 0..255&gt;</code> on i-soft PRO, and <code>start|stop</code> on ZEWA.</li>
<a id="Judo-set-scene"></a>
<li><code>scene &lt;scene&gt; &lt;duration&gt;</code><br>
Selects an i-soft PRO scene from
<code>Alltag|Koerper|Garten|Urlaub|Waesche|Hochdruck|Pool|Heizung|Custom1|Custom2|Custom3</code>
for <code>15min|30min|45min|60min|2h|6h|12h|permanent</code>.</li>
<a id="Judo-set-sceneConfigurationRaw"></a>
<li><code>sceneConfigurationRaw &lt;hex payload&gt;</code><br>
Writes an i-soft PRO scene payload of 2 to 32 bytes as an even hexadecimal
string.</li>
<a id="Judo-set-sceneReset"></a>
<li><code>sceneReset &lt;0..10&gt;</code><br>
Resets the selected i-soft PRO scene index.</li>
<a id="Judo-set-resetMessage"></a>
<li><code>resetMessage</code><br>
Resets the current ZEWA message.</li>
<a id="Judo-set-sleepMode"></a>
<li><code>sleepMode &lt;start|stop&gt;</code><br>
Starts or stops ZEWA sleep mode.</li>
<a id="Judo-set-microLeakageTest"></a>
<li><code>microLeakageTest</code><br>
Starts the ZEWA micro-leakage test.</li>
<a id="Judo-set-learningMode"></a>
<li><code>learningMode</code><br>
Starts ZEWA learning mode.</li>
<a id="Judo-set-leakageSettings"></a>
<li><code>leakageSettings &lt;holiday mode 0..3&gt; &lt;flow&gt; &lt;amount&gt;
&lt;duration&gt;</code><br>
Sets the ZEWA holiday mode and three leakage limits; every limit accepts
0..65535.</li>
<a id="Judo-set-sleepDuration"></a>
<li><code>sleepDuration &lt;1..10&gt;</code><br>
Sets the ZEWA sleep duration in hours.</li>
<a id="Judo-set-holidayType"></a>
<li><code>holidayType &lt;0..3&gt;</code><br>
Sets the ZEWA holiday type.</li>
<a id="Judo-set-microLeakage"></a>
<li><code>microLeakage &lt;0..2&gt;</code><br>
Sets the ZEWA micro-leakage mode.</li>
<a id="Judo-set-absenceLimits"></a>
<li><code>absenceLimits &lt;flow&gt; &lt;amount&gt; &lt;duration&gt;</code><br>
Sets the three ZEWA absence limits; every value accepts 0..65535.</li>
<a id="Judo-set-datetime"></a>
<li><code>datetime &lt;now|YYYY-MM-DD HH:MM:SS&gt;</code><br>
Sets the local device date and time on ZEWA and i-dos.</li>
<a id="Judo-set-absenceSchedule"></a>
<li><code>absenceSchedule &lt;period 0..6&gt; &lt;start day 0..6&gt; &lt;HH:MM&gt;
&lt;stop day 0..6&gt; &lt;HH:MM&gt;</code><br>
Sets a ZEWA absence schedule.</li>
<a id="Judo-set-absenceScheduleDelete"></a>
<li><code>absenceScheduleDelete &lt;0..6&gt;</code><br>
Deletes the selected ZEWA absence period.</li>
<a id="Judo-set-dosageConcentration"></a>
<li><code>dosageConcentration &lt;minimum|normal|maximum&gt;</code><br>
Sets the i-dos dosage concentration.</li>
<a id="Judo-set-pumpMode"></a>
<li><code>pumpMode &lt;off|auto|manual|dose5ml&gt; [rpm]</code><br>
Sets the i-dos pump mode. An rpm value from 1 to 65535 is mandatory for
<code>manual</code> and optional for the other modes.</li>
<a id="Judo-set-limits"></a>
<li><code>limits &lt;13 values&gt;</code><br>
Sets the i-fill limits in this order: language, unit, correction, cartridge,
cycles, pressure, hysteresis, raw hardness, filling time, filling amount,
heating capacity, conductivity and cartridge capacity. Pressure and hysteresis
use API tenths.</li>
<a id="Judo-set-fillValve"></a>
<li><code>fillValve &lt;auto|open|close&gt;</code><br>
Sets the i-fill valve mode.</li>
<a id="Judo-set-alarmRelay"></a>
<li><code>alarmRelay &lt;auto|manualOff|manualOn&gt;</code><br>
Sets the i-fill alarm relay mode.</li>
</ul>

<a id="Judo-get"></a>
<h4>Get</h4>
<p>Most commands store the decoded result in a reading of the same name. The
available device commands depend on the detected profile.</p>
<ul>
<a id="Judo-get-heartbeat"></a>
<li><code>heartbeat</code><br>
Immediately performs the safe <code>FF00</code> model request as a heartbeat.</li>
<a id="Judo-get-model"></a>
<li><code>model</code><br>
Reads the model again and switches the active profile when necessary.</li>
<a id="Judo-get-profile"></a>
<li><code>profile</code><br>
Returns the active device-profile identifier without a network request.</li>
<a id="Judo-get-deviceNumber"></a>
<li><code>deviceNumber</code><br>Reads the device number.</li>
<a id="Judo-get-version"></a>
<li><code>version</code><br>Reads the device firmware version.</li>
<a id="Judo-get-commissioningDate"></a>
<li><code>commissioningDate</code><br>Reads the commissioning date.</li>
<a id="Judo-get-desiredWaterHardness"></a>
<li><code>desiredWaterHardness</code><br>Reads the desired water hardness.</li>
<a id="Judo-get-saltSupply"></a>
<li><code>saltSupply</code><br>Reads salt weight and calculated supply.</li>
<a id="Judo-get-saltSupplyWarning"></a>
<li><code>saltSupplyWarning</code><br>Reads the salt-supply warning threshold.</li>
<a id="Judo-get-hardnessUnit"></a>
<li><code>hardnessUnit</code><br>Reads the configured hardness unit.</li>
<a id="Judo-get-operatingHours"></a>
<li><code>operatingHours</code><br>Reads the operating hours.</li>
<a id="Judo-get-totalWater"></a>
<li><code>totalWater</code><br>Reads the total-water counter.</li>
<a id="Judo-get-softWater"></a>
<li><code>softWater</code><br>Reads the soft-water counter.</li>
<a id="Judo-get-serviceAddress"></a>
<li><code>serviceAddress</code><br>Reads the configured service contact.</li>
<a id="Judo-get-waterMaxDuration"></a>
<li><code>waterMaxDuration</code><br>Reads the maximum withdrawal duration.</li>
<a id="Judo-get-waterMaxFlow"></a>
<li><code>waterMaxFlow</code><br>Reads the maximum flow.</li>
<a id="Judo-get-waterMaxAmount"></a>
<li><code>waterMaxAmount</code><br>Reads the maximum withdrawal amount.</li>
<a id="Judo-get-waterDay"></a>
<li><code>waterDay &lt;YYYY-MM-DD&gt;</code><br>Reads daily water statistics.</li>
<a id="Judo-get-waterWeek"></a>
<li><code>waterWeek &lt;YYYY-Www&gt;</code><br>Reads weekly water statistics.</li>
<a id="Judo-get-waterMonth"></a>
<li><code>waterMonth &lt;YYYY-MM&gt;</code><br>Reads monthly water statistics.</li>
<a id="Judo-get-waterYear"></a>
<li><code>waterYear &lt;YYYY&gt;</code><br>Reads yearly water statistics.</li>
<a id="Judo-get-flowDay"></a>
<li><code>flowDay &lt;YYYY-MM-DD&gt;</code><br>Reads daily i-soft PRO flow statistics.</li>
<a id="Judo-get-flowWeek"></a>
<li><code>flowWeek &lt;YYYY-Www&gt;</code><br>Reads weekly i-soft PRO flow statistics.</li>
<a id="Judo-get-flowMonth"></a>
<li><code>flowMonth &lt;YYYY-MM&gt;</code><br>Reads monthly i-soft PRO flow statistics.</li>
<a id="Judo-get-flowYear"></a>
<li><code>flowYear &lt;YYYY&gt;</code><br>Reads yearly i-soft PRO flow statistics.</li>
<a id="Judo-get-saltUsageDay"></a>
<li><code>saltUsageDay &lt;YYYY-MM-DD&gt;</code><br>Reads daily i-soft PRO salt statistics.</li>
<a id="Judo-get-saltUsageWeek"></a>
<li><code>saltUsageWeek &lt;YYYY-Www&gt;</code><br>Reads weekly i-soft PRO salt statistics.</li>
<a id="Judo-get-saltUsageMonth"></a>
<li><code>saltUsageMonth &lt;YYYY-MM&gt;</code><br>Reads monthly i-soft PRO salt statistics.</li>
<a id="Judo-get-saltUsageYear"></a>
<li><code>saltUsageYear &lt;YYYY&gt;</code><br>Reads yearly i-soft PRO salt statistics.</li>
<a id="Judo-get-sceneConfiguration"></a>
<li><code>sceneConfiguration &lt;0..10&gt;</code><br>
Reads the selected i-soft PRO scene configuration as a raw payload.</li>
<a id="Judo-get-absenceLimits"></a>
<li><code>absenceLimits</code><br>Reads the three ZEWA absence limits.</li>
<a id="Judo-get-sleepDuration"></a>
<li><code>sleepDuration</code><br>Reads the ZEWA sleep duration.</li>
<a id="Judo-get-learningStatus"></a>
<li><code>learningStatus</code><br>Reads the ZEWA learning status.</li>
<a id="Judo-get-microLeakage"></a>
<li><code>microLeakage</code><br>Reads the ZEWA micro-leakage mode.</li>
<a id="Judo-get-datetime"></a>
<li><code>datetime</code><br>Reads the local device date and time on ZEWA or i-dos.</li>
<a id="Judo-get-absenceSchedule"></a>
<li><code>absenceSchedule &lt;0..6&gt;</code><br>Reads the selected ZEWA absence period.</li>
<a id="Judo-get-status"></a>
<li><code>status</code><br>Reads the detailed i-dos status.</li>
<a id="Judo-get-dosage"></a>
<li><code>dosage</code><br>Reads the current i-dos dosage data.</li>
<a id="Judo-get-limits"></a>
<li><code>limits</code><br>Reads the i-fill limit configuration.</li>
</ul>

<a id="Judo-attr"></a>
<h4>Attributes</h4>
<ul>
<a id="Judo-attr-username"></a>
<li><code>username &lt;user name&gt;</code><br>
Sets the HTTP Basic user name. Colons and control characters are rejected.</li>
<a id="Judo-attr-ssl"></a>
<li><code>ssl &lt;0|1&gt;</code><br>Uses HTTP with 0 (default) or HTTPS with 1.</li>
<a id="Judo-attr-interval"></a>
<li><code>interval &lt;0|10..86400&gt;</code><br>
Sets the heartbeat and polling interval in seconds. 0 disables the timer; the
default is 60.</li>
<a id="Judo-attr-offlineInterval"></a>
<li><code>offlineInterval &lt;10..86400&gt;</code><br>
Sets the heartbeat interval while the device is offline; the default is 300.
Profile values are not polled until this heartbeat succeeds.</li>
<a id="Judo-attr-timeout"></a>
<li><code>timeout &lt;1..300&gt;</code><br>
Sets the HTTP timeout in seconds; the default is 60.</li>
<a id="Judo-attr-maxFailures"></a>
<li><code>maxFailures &lt;1..10&gt;</code><br>
Sets the number of consecutive transport errors that mark the device offline;
the default is 3.</li>
<a id="Judo-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
With 1, stops requests and timers and marks the device disabled. 0 enables it.</li>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html

=begin html_DE

<a id="Judo"></a>
<h3>Judo</h3>
<p>Bindet unterstuetzte Judo-Geraete ueber deren lokale REST-API an. Vor jedem
familienabhaengigen Kommando wird zuerst der Geraetetyp ueber <code>FF00</code>
bestimmt. Alle Requests laufen seriell mit mindestens fuenf Sekunden Abstand.
Vor Reconnect oder Deaktivierung wird ein aktiver HTTP-Request geschlossen.</p>

<a id="Judo-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; Judo &lt;host[:port]&gt;</code></p>

<a id="Judo-heartbeat"></a>
<h4>Heartbeat und Fehler</h4>
<p><code>FF00</code> dient als schreibfreier Heartbeat. <code>availability</code>,
<code>heartbeat</code>, <code>heartbeatCount</code>, <code>heartbeatFailures</code>
und <code>lastContact</code> machen Erreichbarkeit und Heartbeat-Qualitaet
sichtbar. <code>lastError</code>, <code>lastErrorCode</code>,
<code>lastErrorCommand</code> und <code>errorCount</code> beschreiben aktuelle
Fehler, ohne Zugangsdaten offenzulegen. Offline wird ausschliesslich
<code>FF00</code> abgefragt; Profilwerte folgen erst wieder nach einem
erfolgreichen Heartbeat.</p>

<a id="Judo-set"></a>
<h4>Set</h4>
<p>Geraetespezifische Befehle stehen erst nach der Modellerkennung und nur fuer
das aktive Geraeteprofil zur Verfuegung.</p>
<ul>
<a id="Judo-set-password"></a>
<li><code>password &lt;Passwort&gt;</code><br>
Speichert das Passwort verschleiert im FHEM-Key-Value-Speicher und startet bei
vorhandenem Benutzernamen die Modellerkennung.</li>
<a id="Judo-set-clearPassword"></a>
<li><code>clearPassword</code><br>
Entfernt das gespeicherte Passwort und stoppt Timer und Netzwerkanfragen.</li>
<a id="Judo-set-reconnect"></a>
<li><code>reconnect</code><br>
Verwirft wartende Requests und startet die Modellerkennung erneut mit
<code>FF00</code>.</li>
<a id="Judo-set-desiredWaterHardness"></a>
<li><code>desiredWaterHardness &lt;0..20&gt;</code><br>
Setzt die Wunschwasserhaerte bei unterstuetzten Enthaertern.</li>
<a id="Judo-set-regeneration"></a>
<li><code>regeneration</code><br>
Startet die Regeneration bei unterstuetzten Enthaertern.</li>
<a id="Judo-set-saltSupply"></a>
<li><code>saltSupply &lt;0..65535&gt;</code><br>
Setzt den Salzvorrat in Gramm.</li>
<a id="Judo-set-saltSupplyWarning"></a>
<li><code>saltSupplyWarning &lt;0..255&gt;</code><br>
Setzt die Warnschwelle fuer den Salzvorrat in Tagen.</li>
<a id="Judo-set-serviceAddress"></a>
<li><code>serviceAddress &lt;Text&gt;</code><br>
Setzt 1 bis 16 druckbare ASCII-Zeichen als Servicekontakt.</li>
<a id="Judo-set-waterMaxDuration"></a>
<li><code>waterMaxDuration &lt;0..255&gt;</code><br>
Setzt die maximale Entnahmedauer in Minuten.</li>
<a id="Judo-set-hardnessUnit"></a>
<li><code>hardnessUnit &lt;dH|eH|fH|gpg|ppm|mmol|mval&gt;</code><br>
Setzt die Haerteeinheit. Das i-soft-PRO-Profil unterstuetzt nur <code>dH</code>
und <code>fH</code>.</li>
<a id="Judo-set-waterMaxFlow"></a>
<li><code>waterMaxFlow &lt;Wert&gt;</code><br>
Setzt den maximalen Volumenstrom. Der Bereich ist 0..5000 beim i-soft PRO und
0..65535 bei den anderen unterstuetzten Enthaerterprofilen.</li>
<a id="Judo-set-waterMaxAmount"></a>
<li><code>waterMaxAmount &lt;Wert&gt;</code><br>
Setzt die maximale Entnahmemenge. Der Bereich ist 0..3000 beim i-soft PRO und
0..65535 bei den anderen unterstuetzten Enthaerterprofilen.</li>
<a id="Judo-set-leakageProtection"></a>
<li><code>leakageProtection &lt;close|open&gt;</code><br>
Schliesst oder oeffnet das Leckageschutzventil bei unterstuetzten Geraeten.</li>
<a id="Judo-set-holidayMode"></a>
<li><code>holidayMode &lt;Wert&gt;</code><br>
Verwendet <code>0..255</code> bei i-soft/i-soft SAFE, <code>&lt;Flags 0..255&gt;
&lt;Tage 0..255&gt;</code> beim i-soft PRO und <code>start|stop</code> bei ZEWA.</li>
<a id="Judo-set-scene"></a>
<li><code>scene &lt;Szene&gt; &lt;Dauer&gt;</code><br>
Waehlt beim i-soft PRO eine Szene aus
<code>Alltag|Koerper|Garten|Urlaub|Waesche|Hochdruck|Pool|Heizung|Custom1|Custom2|Custom3</code>
fuer <code>15min|30min|45min|60min|2h|6h|12h|permanent</code>.</li>
<a id="Judo-set-sceneConfigurationRaw"></a>
<li><code>sceneConfigurationRaw &lt;Hex-Payload&gt;</code><br>
Schreibt beim i-soft PRO einen 2 bis 32 Byte langen Szenen-Payload als gerade
Hex-Zeichenfolge.</li>
<a id="Judo-set-sceneReset"></a>
<li><code>sceneReset &lt;0..10&gt;</code><br>
Setzt den ausgewaehlten i-soft-PRO-Szenenindex zurueck.</li>
<a id="Judo-set-resetMessage"></a>
<li><code>resetMessage</code><br>
Setzt die aktuelle ZEWA-Meldung zurueck.</li>
<a id="Judo-set-sleepMode"></a>
<li><code>sleepMode &lt;start|stop&gt;</code><br>
Startet oder stoppt den ZEWA-Schlafmodus.</li>
<a id="Judo-set-microLeakageTest"></a>
<li><code>microLeakageTest</code><br>
Startet den ZEWA-Mikroleckagetest.</li>
<a id="Judo-set-learningMode"></a>
<li><code>learningMode</code><br>
Startet den ZEWA-Lernmodus.</li>
<a id="Judo-set-leakageSettings"></a>
<li><code>leakageSettings &lt;Urlaubsmodus 0..3&gt; &lt;Durchfluss&gt; &lt;Menge&gt;
&lt;Dauer&gt;</code><br>
Setzt den ZEWA-Urlaubsmodus und drei Leckagegrenzen; jede Grenze akzeptiert
0..65535.</li>
<a id="Judo-set-sleepDuration"></a>
<li><code>sleepDuration &lt;1..10&gt;</code><br>
Setzt die ZEWA-Schlafdauer in Stunden.</li>
<a id="Judo-set-holidayType"></a>
<li><code>holidayType &lt;0..3&gt;</code><br>
Setzt den ZEWA-Urlaubstyp.</li>
<a id="Judo-set-microLeakage"></a>
<li><code>microLeakage &lt;0..2&gt;</code><br>
Setzt den ZEWA-Mikroleckagemodus.</li>
<a id="Judo-set-absenceLimits"></a>
<li><code>absenceLimits &lt;Durchfluss&gt; &lt;Menge&gt; &lt;Dauer&gt;</code><br>
Setzt die drei ZEWA-Abwesenheitsgrenzen; jeder Wert akzeptiert 0..65535.</li>
<a id="Judo-set-datetime"></a>
<li><code>datetime &lt;now|YYYY-MM-DD HH:MM:SS&gt;</code><br>
Setzt bei ZEWA und i-dos das lokale Geraetedatum und die Uhrzeit.</li>
<a id="Judo-set-absenceSchedule"></a>
<li><code>absenceSchedule &lt;Zeitraum 0..6&gt; &lt;Starttag 0..6&gt; &lt;HH:MM&gt;
&lt;Stoptag 0..6&gt; &lt;HH:MM&gt;</code><br>
Setzt einen ZEWA-Abwesenheitszeitraum.</li>
<a id="Judo-set-absenceScheduleDelete"></a>
<li><code>absenceScheduleDelete &lt;0..6&gt;</code><br>
Loescht den ausgewaehlten ZEWA-Abwesenheitszeitraum.</li>
<a id="Judo-set-dosageConcentration"></a>
<li><code>dosageConcentration &lt;minimum|normal|maximum&gt;</code><br>
Setzt die i-dos-Dosierkonzentration.</li>
<a id="Judo-set-pumpMode"></a>
<li><code>pumpMode &lt;off|auto|manual|dose5ml&gt; [Drehzahl]</code><br>
Setzt den i-dos-Pumpenmodus. Fuer <code>manual</code> ist eine Drehzahl von 1 bis
65535 erforderlich, bei den anderen Modi ist sie optional.</li>
<a id="Judo-set-limits"></a>
<li><code>limits &lt;13 Werte&gt;</code><br>
Setzt die i-fill-Grenzwerte in dieser Reihenfolge: Sprache, Einheit, Korrektur,
Patrone, Zyklen, Druck, Hysterese, Rohhaerte, Fuellzeit, Fuellmenge,
Heizungsinhalt, Leitwert und Patronenkapazitaet. Druck und Hysterese werden als
API-Zehntelwerte uebergeben.</li>
<a id="Judo-set-fillValve"></a>
<li><code>fillValve &lt;auto|open|close&gt;</code><br>
Setzt den i-fill-Ventilmodus.</li>
<a id="Judo-set-alarmRelay"></a>
<li><code>alarmRelay &lt;auto|manualOff|manualOn&gt;</code><br>
Setzt den i-fill-Alarmrelaismodus.</li>
</ul>

<a id="Judo-get"></a>
<h4>Get</h4>
<p>Die meisten Befehle speichern das dekodierte Ergebnis in einem gleichnamigen
Reading. Die verfuegbaren Geraetebefehle haengen vom erkannten Profil ab.</p>
<ul>
<a id="Judo-get-heartbeat"></a>
<li><code>heartbeat</code><br>
Fuehrt sofort die sichere Modellabfrage <code>FF00</code> als Heartbeat aus.</li>
<a id="Judo-get-model"></a>
<li><code>model</code><br>
Liest das Modell erneut und wechselt bei Bedarf das aktive Profil.</li>
<a id="Judo-get-profile"></a>
<li><code>profile</code><br>
Liefert ohne Netzwerkanfrage die Kennung des aktiven Geraeteprofils.</li>
<a id="Judo-get-deviceNumber"></a>
<li><code>deviceNumber</code><br>Liest die Geraetenummer.</li>
<a id="Judo-get-version"></a>
<li><code>version</code><br>Liest die Geraete-Firmwareversion.</li>
<a id="Judo-get-commissioningDate"></a>
<li><code>commissioningDate</code><br>Liest das Inbetriebnahmedatum.</li>
<a id="Judo-get-desiredWaterHardness"></a>
<li><code>desiredWaterHardness</code><br>Liest die Wunschwasserhaerte.</li>
<a id="Judo-get-saltSupply"></a>
<li><code>saltSupply</code><br>Liest Salzgewicht und berechneten Vorrat.</li>
<a id="Judo-get-saltSupplyWarning"></a>
<li><code>saltSupplyWarning</code><br>Liest die Warnschwelle fuer den Salzvorrat.</li>
<a id="Judo-get-hardnessUnit"></a>
<li><code>hardnessUnit</code><br>Liest die eingestellte Haerteeinheit.</li>
<a id="Judo-get-operatingHours"></a>
<li><code>operatingHours</code><br>Liest die Betriebsstunden.</li>
<a id="Judo-get-totalWater"></a>
<li><code>totalWater</code><br>Liest den Gesamtwasserzaehler.</li>
<a id="Judo-get-softWater"></a>
<li><code>softWater</code><br>Liest den Weichwasserzaehler.</li>
<a id="Judo-get-serviceAddress"></a>
<li><code>serviceAddress</code><br>Liest den eingestellten Servicekontakt.</li>
<a id="Judo-get-waterMaxDuration"></a>
<li><code>waterMaxDuration</code><br>Liest die maximale Entnahmedauer.</li>
<a id="Judo-get-waterMaxFlow"></a>
<li><code>waterMaxFlow</code><br>Liest den maximalen Volumenstrom.</li>
<a id="Judo-get-waterMaxAmount"></a>
<li><code>waterMaxAmount</code><br>Liest die maximale Entnahmemenge.</li>
<a id="Judo-get-waterDay"></a>
<li><code>waterDay &lt;YYYY-MM-DD&gt;</code><br>Liest die taegliche Wasserstatistik.</li>
<a id="Judo-get-waterWeek"></a>
<li><code>waterWeek &lt;YYYY-Www&gt;</code><br>Liest die woechentliche Wasserstatistik.</li>
<a id="Judo-get-waterMonth"></a>
<li><code>waterMonth &lt;YYYY-MM&gt;</code><br>Liest die monatliche Wasserstatistik.</li>
<a id="Judo-get-waterYear"></a>
<li><code>waterYear &lt;YYYY&gt;</code><br>Liest die jaehrliche Wasserstatistik.</li>
<a id="Judo-get-flowDay"></a>
<li><code>flowDay &lt;YYYY-MM-DD&gt;</code><br>Liest die taegliche i-soft-PRO-Volumenstromstatistik.</li>
<a id="Judo-get-flowWeek"></a>
<li><code>flowWeek &lt;YYYY-Www&gt;</code><br>Liest die woechentliche i-soft-PRO-Volumenstromstatistik.</li>
<a id="Judo-get-flowMonth"></a>
<li><code>flowMonth &lt;YYYY-MM&gt;</code><br>Liest die monatliche i-soft-PRO-Volumenstromstatistik.</li>
<a id="Judo-get-flowYear"></a>
<li><code>flowYear &lt;YYYY&gt;</code><br>Liest die jaehrliche i-soft-PRO-Volumenstromstatistik.</li>
<a id="Judo-get-saltUsageDay"></a>
<li><code>saltUsageDay &lt;YYYY-MM-DD&gt;</code><br>Liest die taegliche i-soft-PRO-Salzstatistik.</li>
<a id="Judo-get-saltUsageWeek"></a>
<li><code>saltUsageWeek &lt;YYYY-Www&gt;</code><br>Liest die woechentliche i-soft-PRO-Salzstatistik.</li>
<a id="Judo-get-saltUsageMonth"></a>
<li><code>saltUsageMonth &lt;YYYY-MM&gt;</code><br>Liest die monatliche i-soft-PRO-Salzstatistik.</li>
<a id="Judo-get-saltUsageYear"></a>
<li><code>saltUsageYear &lt;YYYY&gt;</code><br>Liest die jaehrliche i-soft-PRO-Salzstatistik.</li>
<a id="Judo-get-sceneConfiguration"></a>
<li><code>sceneConfiguration &lt;0..10&gt;</code><br>
Liest die ausgewaehlte i-soft-PRO-Szenenkonfiguration als Rohpayload.</li>
<a id="Judo-get-absenceLimits"></a>
<li><code>absenceLimits</code><br>Liest die drei ZEWA-Abwesenheitsgrenzen.</li>
<a id="Judo-get-sleepDuration"></a>
<li><code>sleepDuration</code><br>Liest die ZEWA-Schlafdauer.</li>
<a id="Judo-get-learningStatus"></a>
<li><code>learningStatus</code><br>Liest den ZEWA-Lernstatus.</li>
<a id="Judo-get-microLeakage"></a>
<li><code>microLeakage</code><br>Liest den ZEWA-Mikroleckagemodus.</li>
<a id="Judo-get-datetime"></a>
<li><code>datetime</code><br>Liest bei ZEWA oder i-dos das lokale Geraetedatum und die Uhrzeit.</li>
<a id="Judo-get-absenceSchedule"></a>
<li><code>absenceSchedule &lt;0..6&gt;</code><br>Liest den ausgewaehlten ZEWA-Abwesenheitszeitraum.</li>
<a id="Judo-get-status"></a>
<li><code>status</code><br>Liest den detaillierten i-dos-Status.</li>
<a id="Judo-get-dosage"></a>
<li><code>dosage</code><br>Liest die aktuellen i-dos-Dosierdaten.</li>
<a id="Judo-get-limits"></a>
<li><code>limits</code><br>Liest die i-fill-Grenzwertkonfiguration.</li>
</ul>

<a id="Judo-attr"></a>
<h4>Attribute</h4>
<ul>
<a id="Judo-attr-username"></a>
<li><code>username &lt;Benutzername&gt;</code><br>
Setzt den Benutzernamen fuer HTTP Basic. Doppelpunkte und Steuerzeichen werden
abgelehnt.</li>
<a id="Judo-attr-ssl"></a>
<li><code>ssl &lt;0|1&gt;</code><br>
Verwendet HTTP mit 0 (Standard) oder HTTPS mit 1.</li>
<a id="Judo-attr-interval"></a>
<li><code>interval &lt;0|10..86400&gt;</code><br>
Setzt das Heartbeat- und Pollingintervall in Sekunden. 0 deaktiviert den Timer;
Standard ist 60.</li>
<a id="Judo-attr-offlineInterval"></a>
<li><code>offlineInterval &lt;10..86400&gt;</code><br>
Setzt das Heartbeatintervall im Offline-Zustand; Standard ist 300 Sekunden.
Profilwerte werden erst nach einem erfolgreichen Heartbeat wieder abgefragt.</li>
<a id="Judo-attr-timeout"></a>
<li><code>timeout &lt;1..300&gt;</code><br>
Setzt den HTTP-Timeout in Sekunden; Standard ist 60.</li>
<a id="Judo-attr-maxFailures"></a>
<li><code>maxFailures &lt;1..10&gt;</code><br>
Setzt die Zahl aufeinanderfolgender Transportfehler bis zum Offline-Status;
Standard ist 3.</li>
<a id="Judo-attr-disable"></a>
<li><code>disable &lt;0|1&gt;</code><br>
Stoppt mit 1 Requests und Timer und setzt das Device auf deaktiviert. 0 aktiviert
es.</li>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html_DE

=cut
