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
	Judo_queue_get Judo_enqueue_request Judo_dispatch_next Judo_Callback
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

our $Judo_VERSION = '1.1.0';
our $Judo_DEFAULT_INTERVAL = 60;
our $Judo_DEFAULT_TIMEOUT = 60;
our $Judo_DEFAULT_MAX_FAILURES = 3;

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
	$hash->{AttrList} = 'interval timeout maxFailures username ssl:0,1 disable:0,1 ' . $readingFnAttributes;
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
	if ($attribute =~ /^(?:interval|timeout|maxFailures|username|ssl)$/) {
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
is read before any family-specific request. Requests are serialized and
<code>FF00</code> provides a non-mutating heartbeat.</p>

=end html

=begin html_DE

<a id="Judo"></a>
<h3>Judo</h3>
<p>Bindet unterstuetzte Judo-Geraete ueber deren lokale REST-API an. Vor jedem
familienabhaengigen Kommando wird zuerst der Geraetetyp ueber <code>FF00</code>
bestimmt. Alle Requests laufen seriell.</p>

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
Fehler, ohne Zugangsdaten offenzulegen.</p>

<a id="Judo-set"></a>
<h4>Set</h4>
<ul>
<li><code>set &lt;name&gt; password &lt;Passwort&gt;</code> - Passwort speichern.</li>
<li><code>set &lt;name&gt; clearPassword</code> - Passwort entfernen.</li>
<li><code>set &lt;name&gt; reconnect</code> - Modell neu erkennen und Profil neu laden.</li>
<li>Weitere Kommandos erscheinen nach der Modellbestimmung dynamisch und nur
fuer die erkannte Geraetefamilie.</li>
</ul>

<h5>Enthaerter</h5>
<ul>
<li><code>desiredWaterHardness &lt;0..20&gt;</code></li>
<li><code>regeneration</code></li>
<li><code>saltSupply &lt;Gramm&gt;</code> und <code>saltSupplyWarning &lt;Tage&gt;</code></li>
<li><code>hardnessUnit &lt;dH|eH|fH|gpg|ppm|mmol|mval&gt;</code>;
das PRO-Profil bietet nur dokumentierte Einheiten an.</li>
<li><code>waterMaxDuration</code>, <code>waterMaxAmount</code> und
<code>waterMaxFlow</code> mit profilabhaengigen Grenzen.</li>
<li><code>leakageProtection &lt;close|open&gt;</code></li>
<li><code>serviceAddress &lt;maximal 16 ASCII-Zeichen&gt;</code></li>
</ul>

<h5>i-soft PRO</h5>
<ul>
<li><code>scene
&lt;Alltag|Koerper|Garten|Urlaub|Waesche|Hochdruck|Pool|Heizung|Custom1|Custom2|Custom3&gt;
&lt;15min|30min|45min|60min|2h|6h|12h|permanent&gt;</code></li>
<li><code>sceneConfigurationRaw &lt;Hex-Payload&gt;</code> und <code>sceneReset &lt;0..10&gt;</code></li>
<li><code>holidayMode &lt;Flags 0..255&gt; &lt;Tage 0..255&gt;</code></li>
</ul>

<h5>ZEWA</h5>
<ul>
<li><code>leakageProtection close|open</code>, <code>resetMessage</code>,
<code>sleepMode start|stop</code>, <code>holidayMode start|stop</code></li>
<li><code>microLeakageTest</code>, <code>learningMode</code>, <code>microLeakage &lt;0..2&gt;</code></li>
<li><code>absenceLimits &lt;Durchfluss&gt; &lt;Menge&gt; &lt;Dauer&gt;</code></li>
<li><code>leakageSettings &lt;Urlaubsmodus 0..3&gt; &lt;Durchfluss&gt; &lt;Menge&gt; &lt;Dauer&gt;</code></li>
<li><code>absenceSchedule &lt;Zeitraum 0..6&gt; &lt;Starttag 0..6&gt;
&lt;HH:MM&gt; &lt;Stoptag 0..6&gt; &lt;HH:MM&gt;</code></li>
<li><code>absenceScheduleDelete &lt;0..6&gt;</code> und <code>datetime now|YYYY-MM-DD HH:MM:SS</code></li>
</ul>

<h5>i-dos und i-fill</h5>
<ul>
<li>i-dos: <code>dosageConcentration minimum|normal|maximum</code>,
<code>pumpMode off|auto|manual|dose5ml [Drehzahl]</code> und <code>datetime</code>.</li>
<li>i-fill: <code>fillValve auto|open|close</code>,
<code>leakageProtection close|open</code> und
<code>alarmRelay auto|manualOff|manualOn</code>.</li>
<li>i-fill-Grenzwerte: <code>limits Sprache Einheit Korrektur Patrone Zyklen Druck
Hysterese Rohhaerte Fuellzeit Fuellmenge Heizungsinhalt Leitwert
Patronenkapazitaet</code>. Druck und Hysterese werden als API-Zehntelwerte
uebergeben.</li>
</ul>

<a id="Judo-get"></a>
<h4>Get</h4>
<p><code>get &lt;name&gt; heartbeat</code> fuehrt sofort eine sichere Modellabfrage aus.
Statistiken erwarten je nach Zeitraum <code>YYYY-MM-DD</code>,
<code>YYYY-Www</code>, <code>YYYY-MM</code> oder <code>YYYY</code>.</p>
<p>ZEWA-Abwesenheitszeiten werden mit <code>get &lt;name&gt; absenceSchedule &lt;0..6&gt;</code>
gelesen. Beim i-soft PRO liest <code>get &lt;name&gt; sceneConfiguration &lt;0..10&gt;</code>
die vorhandene Szenenkonfiguration als dokumentierten Rohpayload.</p>

<a id="Judo-attr"></a>
<h4>Attribute</h4>
<ul>
<li><code>username</code> - Benutzername fuer HTTP Basic.</li>
<li><code>ssl</code> - 0 fuer HTTP, 1 fuer HTTPS; Standard 0.</li>
<li><code>interval</code> - Heartbeatintervall in Sekunden, 0 deaktiviert den Timer; Standard 60.</li>
<li><code>timeout</code> - HTTP-Timeout in Sekunden; Standard 60.</li>
<li><code>maxFailures</code> - Transportfehler bis offline; Standard 3.</li>
<li><code>disable</code> - stoppt Requests und Timer.</li>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html_DE

=cut
