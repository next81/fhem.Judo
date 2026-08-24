# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package JudoTestEnv;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP qw(encode_json);

our @EXPORT_OK = qw(reset_env define_judo pending_requests complete_request
	fail_request reading_value log_entries scheduled_timers set_attribute
	key_values set_key_value_errors);
our (@REQUESTS, @LOG_ENTRIES, @TIMERS);
our %KEY_VALUES;
our ($SET_KEY_VALUE_ERROR, $GET_KEY_VALUE_ERROR);

# Setzt die simulierte FHEM-Laufzeit und alle aufgezeichneten Seiteneffekte zurueck.
sub reset_env {
	%main::defs = ();
	%main::attr = (global => { verbose => 5 });
	$main::readingFnAttributes = '';
	$main::init_done = 1;
	@REQUESTS = ();
	@LOG_ENTRIES = ();
	@TIMERS = ();
	%KEY_VALUES = ();
	$SET_KEY_VALUE_ERROR = undef;
	$GET_KEY_VALUE_ERROR = undef;
	return;
}

# Definiert eine Judo-Instanz mit optional bereits hinterlegten Zugangsdaten.
sub define_judo {
	my ($name, $host, $username, $password) = @_;
	my $hash = { NAME => $name, TYPE => 'Judo', READINGS => {} };
	$main::defs{$name} = $hash;
	$main::attr{$name}{username} = $username if defined $username;
	main::Judo_store_password($hash, $password) if defined $password;
	my $error = main::Judo_Define($hash, "$name Judo $host");
	return ($hash, $error);
}

# Liefert alle von HttpUtils entgegengenommenen, noch nicht beantworteten Requests.
sub pending_requests { return \@REQUESTS; }

# Beantwortet den aeltesten HTTP-Request mit einer erfolgreichen JSON-Antwort.
sub complete_request {
	my ($data, $code, $content) = @_;
	my $request = shift @REQUESTS or die 'Kein HTTP-Request wartet';
	$request->{code} = defined($code) ? $code : 200;
	$content = encode_json({ data => $data }) if !defined $content;
	$request->{callback}->($request, '', $content);
	return $request;
}

# Beantwortet den aeltesten HTTP-Request mit einem Transportfehler.
sub fail_request {
	my ($message) = @_;
	my $request = shift @REQUESTS or die 'Kein HTTP-Request wartet';
	$request->{callback}->($request, $message || 'simulierter Transportfehler', '');
	return $request;
}

# Liest ein simuliertes Reading mit optionalem Standardwert.
sub reading_value {
	my ($device, $reading, $default) = @_;
	return exists($main::defs{$device}{READINGS}{$reading})
		? $main::defs{$device}{READINGS}{$reading}{VAL} : $default;
}

# Stellt die strukturiert aufgezeichneten FHEM-Logmeldungen bereit.
sub log_entries { return \@LOG_ENTRIES; }

# Stellt alle aktuell geplanten internen Timer bereit.
sub scheduled_timers { return \@TIMERS; }

# Stellt den simulierten Key-Value-Speicher fuer gezielte Korruptionstests bereit.
sub key_values { return \%KEY_VALUES; }

# Injiziert Fehler fuer Schreib- und Lesezugriffe auf den Key-Value-Speicher.
sub set_key_value_errors {
	my ($set_error, $get_error) = @_;
	$SET_KEY_VALUE_ERROR = $set_error;
	$GET_KEY_VALUE_ERROR = $get_error;
	return;
}

# Uebernimmt ein Attribut vor einem optionalen simulierten AttrFn-Aufruf.
sub set_attribute {
	my ($hash, $attribute, $value) = @_;
	$main::attr{ $hash->{NAME} }{$attribute} = $value;
	return;
}

package main;

use strict;
use warnings;

our (%defs, %attr, $readingFnAttributes, $init_done);

# Bildet FHEMs AttrVal inklusive Standardwert ab.
sub AttrVal($$$) {
	my ($device, $attribute, $default) = @_;
	return exists($attr{$device}) && exists($attr{$device}{$attribute})
		? $attr{$device}{$attribute} : $default;
}

# Liefert die Ereignisliste eines simulierten FHEM-Devices.
sub deviceEvents {
	my ($device, undef) = @_;
	return $device->{CHANGED};
}

# Schreibt ein Reading mit festem Testzeitstempel in den Device-Hash.
sub readingsSingleUpdate($$$$) {
	my ($hash, $reading, $value, undef) = @_;
	$hash->{READINGS}{$reading} = { VAL => $value, TIME => '2026-08-23 12:00:00' };
	return undef;
}

# Sammelt Logmeldungen, ohne sie auf die Testkonsole auszugeben.
sub Log3 {
	push @JudoTestEnv::LOG_ENTRIES, [ @_ ];
	return undef;
}

# Liefert eine feste FHEM-Installationskennung fuer reproduzierbare Passworttests.
sub getUniqueId { return 'test-unique-id'; }

# Bildet FHEMs Key-Value-Speicher inklusive Loeschen durch undef ab.
sub setKeyValue {
	my ($key, $value) = @_;
	return $JudoTestEnv::SET_KEY_VALUE_ERROR
		if defined $JudoTestEnv::SET_KEY_VALUE_ERROR;

	# undef entfernt den Eintrag wie im FHEM-Key-Value-Speicher.
	if (defined $value) {
		$JudoTestEnv::KEY_VALUES{$key} = $value;
	} else {
		delete $JudoTestEnv::KEY_VALUES{$key};
	}
	return undef;
}

# Liest einen simulierten Key-Value-Eintrag.
sub getKeyValue {
	my ($key) = @_;
	return ($JudoTestEnv::GET_KEY_VALUE_ERROR, undef)
		if defined $JudoTestEnv::GET_KEY_VALUE_ERROR;
	return (undef, $JudoTestEnv::KEY_VALUES{$key});
}

# Zeichnet interne Timer mit Funktion und Argument auf.
sub InternalTimer {
	push @JudoTestEnv::TIMERS, [ @_ ];
	return undef;
}

# Entfernt Timer passend zu Argument und optionaler Funktion.
sub RemoveInternalTimer {
	my ($argument, $function) = @_;
	@JudoTestEnv::TIMERS = grep {
		my $same_argument = $_->[2] == $argument;
		my $same_function = !defined($function) || $_->[1] eq $function;
		!($same_argument && $same_function);
	} @JudoTestEnv::TIMERS;
	return undef;
}

# Liefert eine feste relative Timerbasis.
sub gettimeofday { return 1_000; }

# Zeichnet nichtblockierende HTTP-Requests zur kontrollierten Beantwortung auf.
sub HttpUtils_NonblockingGet {
	my ($request) = @_;
	push @JudoTestEnv::REQUESTS, $request;
	return undef;
}

package JudoTestEnv;

1;
