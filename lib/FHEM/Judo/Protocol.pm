# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# Licensed under the GNU General Public License v2.0 only

package Judo::Protocol;

use strict;
use warnings;
use JSON::PP ();
use Time::Local qw(timelocal);
use Exporter qw(import);

our @EXPORT_OK = qw(
	Judo_number_in_range Judo_dec_to_hex Judo_dec_to_le_hex
	Judo_hex_to_dec Judo_le_hex_to_dec Judo_valid_date
	Judo_encode_get_arguments Judo_build_get_code Judo_encode_datetime
	Judo_build_set_code Judo_validate_data Judo_decode_model_id
	Judo_decode_data Judo_decode_statistics
);

# Prueft einen vorzeichenlosen Dezimalwert gegen die dokumentierten Grenzen.
sub Judo_number_in_range($$$) {
	my ($value, $min, $max) = @_;
	return 0 if !defined($value) || $value !~ /^\d+$/;
	return $value >= $min && $value <= $max ? 1 : 0;
}

# Codiert einen Dezimalwert in der angegebenen Bytebreite als Big Endian.
sub Judo_dec_to_hex($$) {
	my ($value, $bytes) = @_;
	return sprintf('%0' . ($bytes * 2) . 'X', $value);
}

# Codiert einen Dezimalwert in der angegebenen Bytebreite als Little Endian.
sub Judo_dec_to_le_hex($$) {
	my ($value, $bytes) = @_;
	my $hex = Judo_dec_to_hex($value, $bytes);
	return uc unpack('H*', reverse pack('H*', $hex));
}

# Decodiert eine Hexfolge in Big-Endian-Reihenfolge.
sub Judo_hex_to_dec($) {
	my ($hex) = @_;
	return hex($hex);
}

# Decodiert eine Hexfolge in Little-Endian-Reihenfolge.
sub Judo_le_hex_to_dec($) {
	my ($hex) = @_;
	return hex(unpack('H*', reverse pack('H*', $hex)));
}

# Validiert ein Kalenderdatum inklusive Monatslaengen und Schaltjahren.
sub Judo_valid_date($$$) {
	my ($year, $month, $day) = @_;
	return 0 if $year < 2000 || $year > 2099 || $month < 1 || $month > 12 || $day < 1 || $day > 31;
	my $timestamp = eval { timelocal(0, 0, 12, $day, $month - 1, $year) };
	return 0 if !defined($timestamp) || $@;
	my (undef, undef, undef, $check_day, $check_month, $check_year) = localtime($timestamp);
	return $check_day == $day && $check_month + 1 == $month && $check_year + 1900 == $year ? 1 : 0;
}

# Baut Statistik- und Indexargumente in der von Judo dokumentierten Bytefolge.
sub Judo_encode_get_arguments($$;$) {
	my ($type, $arguments, $descriptor) = @_;
	$descriptor ||= {};
	return ('', undef) if !defined($type) || $type eq 'none';

	# Tagesstatistiken erwarten YYYY-MM-DD und vier Datenbytes.
	if ($type eq 'date') {
		return (undef, 'Erwartet wird ein Datum im Format YYYY-MM-DD') if @$arguments != 1;
		my ($year, $month, $day) = $arguments->[0] =~ /^(\d{4})-(\d{2})-(\d{2})$/;
		return (undef, 'Ungueltiges Datum; erwartet wird YYYY-MM-DD')
			if !defined($year) || !Judo_valid_date($year, $month, $day);
		return (Judo_dec_to_hex($day, 1) . Judo_dec_to_hex($month, 1)
			. Judo_dec_to_le_hex($year, 2), undef);
	}

	# Wochenstatistiken erwarten Jahr und ISO-Kalenderwoche.
	if ($type eq 'week') {
		return (undef, 'Erwartet wird eine Woche im Format YYYY-Www') if @$arguments != 1;
		my ($year, $week) = $arguments->[0] =~ /^(\d{4})-W?(\d{1,2})$/i;
		return (undef, 'Ungueltige Woche; erwartet wird YYYY-Www mit Woche 1 bis 53')
			if !defined($year) || $year < 2000 || $year > 2099 || $week < 1 || $week > 53;
		return (Judo_dec_to_hex($week, 1) . Judo_dec_to_le_hex($year, 2), undef);
	}

	# Monatsstatistiken erwarten Jahr und Monat.
	if ($type eq 'month') {
		return (undef, 'Erwartet wird ein Monat im Format YYYY-MM') if @$arguments != 1;
		my ($year, $month) = $arguments->[0] =~ /^(\d{4})-(\d{2})$/;
		return (undef, 'Ungueltiger Monat; erwartet wird YYYY-MM')
			if !defined($year) || $year < 2000 || $year > 2099 || $month < 1 || $month > 12;
		return (Judo_dec_to_hex($month, 1) . Judo_dec_to_le_hex($year, 2), undef);
	}

	# Jahresstatistiken tragen nur das zweibyte Jahr.
	if ($type eq 'year') {
		return (undef, 'Erwartet wird ein Jahr im Format YYYY') if @$arguments != 1;
		my $year = $arguments->[0];
		return (undef, 'Ungueltiges Jahr; erwartet wird 2000 bis 2099')
			if !Judo_number_in_range($year, 2000, 2099);
		return (Judo_dec_to_le_hex($year, 2), undef);
	}

	# Einbyte-Indizes werden fuer Szenen- und Abwesenheitsabfragen verwendet.
	if ($type eq 'byte') {
		my $minimum = defined($descriptor->{arg_min}) ? $descriptor->{arg_min} : 0;
		my $maximum = defined($descriptor->{arg_max}) ? $descriptor->{arg_max} : 255;
		return (undef, "Erwartet wird genau ein Wert zwischen $minimum und $maximum")
			if @$arguments != 1 || !Judo_number_in_range($arguments->[0], $minimum, $maximum);
		return (Judo_dec_to_hex($arguments->[0], 1), undef);
	}
	return (undef, "Unbekannter Argumenttyp $type");
}

# Verbindet die feste Kommandoadresse mit validierten Get-Argumenten.
sub Judo_build_get_code($$) {
	my ($descriptor, $arguments) = @_;
	my $type = $descriptor->{args} || 'none';
	return (undef, 'Dieses Get-Kommando erwartet keine Argumente') if $type eq 'none' && @$arguments;
	my ($data, $error) = Judo_encode_get_arguments($type, $arguments, $descriptor);
	return (undef, $error) if $error;
	return ($descriptor->{code} . $data, undef);
}

# Wandelt Datum/Uhrzeit oder now in die sechs dokumentierten Einzelbytes um.
sub Judo_encode_datetime($) {
	my ($arguments) = @_;
	my $value = join(' ', @$arguments);
	my ($second, $minute, $hour, $day, $month, $year);

	# now verwendet die lokale Systemzeit des FHEM-Hosts.
	if ($value eq 'now') {
		($second, $minute, $hour, $day, $month, $year) = localtime(time);
		$month += 1;
		$year += 1900;
	} elsif ($value =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
		($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);
		return (undef, 'Ungueltiges Datum oder Uhrzeit')
			if !Judo_valid_date($year, $month, $day) || $hour > 23 || $minute > 59 || $second > 59;
	} else {
		return (undef, 'Erwartet wird now oder YYYY-MM-DD HH:MM:SS');
	}
	return (
		Judo_dec_to_hex($day, 1) . Judo_dec_to_hex($month, 1)
			. Judo_dec_to_hex($year - 2000, 1) . Judo_dec_to_hex($hour, 1)
			. Judo_dec_to_hex($minute, 1) . Judo_dec_to_hex($second, 1),
		undef,
	);
}

# Codiert alle dokumentierten Set-Payloads und liefert einen ungefaehrlichen
# Anzeigewert fuer lastAction mit.
sub Judo_build_set_code($$) {
	my ($descriptor, $arguments) = @_;
	my $encoder = $descriptor->{encoder} || '';
	my $data = '';
	my $display = join(' ', @$arguments);

	# Jeder Encoder nimmt nur seine dokumentierte Argumentform an.
	if ($encoder eq 'constant') {
		# Konstante Aktionen akzeptieren keine frei uebergebenen Nutzdaten.
		return (undef, undef, 'Dieses Kommando erwartet keine Argumente') if @$arguments;
		$data = defined($descriptor->{data}) ? $descriptor->{data} : '';
	} elsif ($encoder eq 'number' || $encoder eq 'number_le') {
		# Numerische Werte werden innerhalb ihrer Grenzen in der geforderten Bytefolge codiert.
		return (undef, undef, "Erwartet wird ein Wert zwischen $descriptor->{min} und $descriptor->{max}")
			if @$arguments != 1 || !Judo_number_in_range($arguments->[0], $descriptor->{min}, $descriptor->{max});
		$data = $encoder eq 'number_le'
			? Judo_dec_to_le_hex($arguments->[0], $descriptor->{bytes})
			: Judo_dec_to_hex($arguments->[0], $descriptor->{bytes});
	} elsif ($encoder eq 'choice') {
		# Auswahlwerte werden auf ein Datenbyte innerhalb derselben Kommandoadresse abgebildet.
		return (undef, undef, 'Erwartet wird einer der Werte: '
			. join(', ', sort keys %{ $descriptor->{choices} }))
			if @$arguments != 1 || !exists $descriptor->{choices}{ $arguments->[0] };
		$data = Judo_dec_to_hex($descriptor->{choices}{ $arguments->[0] }, 1);
	} elsif ($encoder eq 'choice_code') {
		# Manche Auswahlen verwenden je Option eine vollstaendig andere Kommandoadresse.
		return (undef, undef, 'Erwartet wird einer der Werte: '
			. join(', ', sort keys %{ $descriptor->{choices} }))
			if @$arguments != 1 || !exists $descriptor->{choices}{ $arguments->[0] };
		return ($descriptor->{choices}{ $arguments->[0] }, $display, undef);
	} elsif ($encoder eq 'ascii_fixed') {
		# Textfelder werden auf die dokumentierte ASCII-Laenge mit Nullbytes aufgefuellt.
		my $value = join(' ', @$arguments);
		return (undef, undef, 'Erwartet werden 1 bis ' . $descriptor->{bytes} . ' druckbare ASCII-Zeichen')
			if $value eq '' || $value =~ /[^\x20-\x7e]/ || length($value) > $descriptor->{bytes};
		$data = uc unpack('H*', $value . ("\0" x ($descriptor->{bytes} - length($value))));
	} elsif ($encoder eq 'raw_hex') {
		# Rohdaten sind nur als gerade Hexfolge innerhalb der dokumentierten Laenge erlaubt.
		return (undef, undef, 'Erwartet wird genau eine gerade Hex-Zeichenfolge')
			if @$arguments != 1 || $arguments->[0] !~ /^(?:[0-9A-Fa-f]{2})+$/;
		my $bytes = length($arguments->[0]) / 2;
		return (undef, undef, "Hex-Payload muss $descriptor->{min_bytes} bis $descriptor->{max_bytes} Byte lang sein")
			if $bytes < $descriptor->{min_bytes} || $bytes > $descriptor->{max_bytes};
		$data = uc $arguments->[0];
	} elsif ($encoder eq 'datetime') {
		# Datumswerte durchlaufen die gemeinsame Kalender- und Uhrzeitvalidierung.
		my $error;
		($data, $error) = Judo_encode_datetime($arguments);
		return (undef, undef, $error) if $error;
	} elsif ($encoder eq 'three_le_numbers') {
		# ZEWA-Grenzwerte bestehen aus genau drei gleich breiten Little-Endian-Zahlen.
		return (undef, undef, 'Erwartet werden drei Zahlen: Durchfluss Menge Dauer') if @$arguments != 3;

		# Alle drei Grenzwerte besitzen dieselbe Breite und denselben Wertebereich.
		for my $value (@$arguments) {
			return (undef, undef, "Jeder Wert muss zwischen $descriptor->{min} und $descriptor->{max} liegen")
				if !Judo_number_in_range($value, $descriptor->{min}, $descriptor->{max});
			$data .= Judo_dec_to_le_hex($value, $descriptor->{bytes});
		}

	} elsif ($encoder eq 'holiday_pro') {
		# Der PRO-Urlaubsmodus kombiniert ein Flagbyte mit der Urlaubsdauer.
		return (undef, undef, 'Erwartet werden Flags 0..255 und Urlaubsdauer 0..255 Tage')
			if @$arguments != 2 || !Judo_number_in_range($arguments->[0], 0, 255)
				|| !Judo_number_in_range($arguments->[1], 0, 255);
		$data = Judo_dec_to_hex($arguments->[0], 1) . Judo_dec_to_hex($arguments->[1], 1);
	} elsif ($encoder eq 'scene') {
		# Szenen und Laufzeiten werden auf die fest dokumentierten Codes begrenzt.
		my %scenes = (
			Alltag => 0, Koerper => 1, Garten => 2, Urlaub => 3, Waesche => 4,
			Hochdruck => 5, Pool => 6, Heizung => 7, Custom1 => 8, Custom2 => 9, Custom3 => 10,
		);
		my %durations = (
			'15min' => '000F', '30min' => '001E', '45min' => '002D', '60min' => '0100',
			'2h' => '0200', '6h' => '0600', '12h' => '0C00', permanent => 'FFFF',
		);
		return (undef, undef, 'Erwartet werden Szene und Dauer, z. B. Garten 2h')
			if @$arguments != 2 || !exists($scenes{$arguments->[0]}) || !exists($durations{$arguments->[1]});
		$data = Judo_dec_to_hex($scenes{$arguments->[0]}, 1) . $durations{$arguments->[1]};
	} elsif ($encoder eq 'zewa_leakage_settings') {
		# ZEWA kombiniert Urlaubsmodus und drei zweibyte Leckagegrenzwerte.
		return (undef, undef, 'Erwartet werden Urlaubsmodus, Volumenstrom, Menge und Dauer') if @$arguments != 4;
		return (undef, undef, 'Urlaubsmodus muss zwischen 0 und 3 liegen')
			if !Judo_number_in_range($arguments->[0], 0, 3);

		# Die drei ZEWA-Grenzwerte werden einzeln validiert.
		for my $index (1 .. 3) {
			return (undef, undef, 'Grenzwerte muessen zwischen 0 und 65535 liegen')
				if !Judo_number_in_range($arguments->[$index], 0, 65535);
		}

		$data = Judo_dec_to_hex($arguments->[0], 1)
			. join('', map { Judo_dec_to_le_hex($_, 2) } @$arguments[1 .. 3]);
	} elsif ($encoder eq 'absence_schedule') {
		# Abwesenheitszeiten werden nur mit gueltigen Wochentagen und Uhrzeiten codiert.
		return (undef, undef, 'Erwartet werden Zeitraum Starttag HH:MM Stoptag HH:MM') if @$arguments != 5;
		my ($period, $start_day, $start_time, $stop_day, $stop_time) = @$arguments;
		my ($start_hour, $start_minute) = $start_time =~ /^(\d{1,2}):(\d{2})$/;
		my ($stop_hour, $stop_minute) = $stop_time =~ /^(\d{1,2}):(\d{2})$/;
		return (undef, undef, 'Zeitraum und Wochentage muessen zwischen 0 und 6 liegen')
			if !Judo_number_in_range($period, 0, 6) || !Judo_number_in_range($start_day, 0, 6)
				|| !Judo_number_in_range($stop_day, 0, 6);
		return (undef, undef, 'Uhrzeiten muessen als HH:MM zwischen 00:00 und 23:59 angegeben werden')
			if !defined($start_hour) || !defined($stop_hour) || $start_hour > 23 || $stop_hour > 23
				|| $start_minute > 59 || $stop_minute > 59;
		$data = join('', map { Judo_dec_to_hex($_, 1) }
			($period, $start_day, $start_hour, $start_minute, $stop_day, $stop_hour, $stop_minute));
	} elsif ($encoder eq 'idos_concentration') {
		# i-dos-Konzentrationen werden auf die drei dokumentierten Stufen abgebildet.
		my %values = ( minimum => 1, normal => 2, maximum => 3 );
		return (undef, undef, 'Erwartet wird minimum, normal oder maximum')
			if @$arguments != 1 || !exists $values{$arguments->[0]};
		$data = '00' . Judo_dec_to_hex($values{$arguments->[0]}, 1);
	} elsif ($encoder eq 'idos_pump') {
		# Der Pumpenmodus enthaelt einen Moduscode und eine optionale Drehzahl.
		my %modes = ( off => 0, auto => 1, manual => 2, dose5ml => 3 );
		return (undef, undef, 'Erwartet werden Modus und optional Drehzahl, z. B. manual 1200')
			if !@$arguments || @$arguments > 2 || !exists $modes{$arguments->[0]};
		my $rpm = defined($arguments->[1]) ? $arguments->[1] : 0;
		return (undef, undef, 'Drehzahl muss zwischen 0 und 65535 liegen')
			if !Judo_number_in_range($rpm, 0, 65535);
		return (undef, undef, 'Im manuellen Modus muss eine Drehzahl groesser 0 angegeben werden')
			if $arguments->[0] eq 'manual' && $rpm == 0;
		$data = Judo_dec_to_hex($modes{$arguments->[0]}, 1) . Judo_dec_to_le_hex($rpm, 2);
	} elsif ($encoder eq 'ifill_limits') {
		# i-fill erwartet eine feste Feldfolge mit unterschiedlichen Bytebreiten.
		my $usage = 'Erwartet werden 13 Werte: Sprache Einheit Korrektur Patrone '
			. 'Zyklen Druck Hysterese Rohhaerte Fuellzeit Fuellmenge Heizungsinhalt '
			. 'Leitwert Patronenkapazitaet';
		return (undef, undef, $usage)
			if @$arguments != 13;
		my @maximum = (4, 6, 255, 255, 255, 255, 255, 65535, 65535, 65535, 65535, 65535, 4294967295);

		# Jeder Wert besitzt laut API eine eigene Obergrenze.
		for my $index (0 .. $#maximum) {
			return (undef, undef, 'i-fill-Wert ' . ($index + 1)
				. " liegt ausserhalb 0..$maximum[$index]")
				if !Judo_number_in_range($arguments->[$index], 0, $maximum[$index]);
		}

		$data = join('', map { Judo_dec_to_hex($_, 1) } @$arguments[0 .. 3]) . '00'
			. join('', map { Judo_dec_to_hex($_, 1) } @$arguments[4 .. 6])
			. join('', map { Judo_dec_to_le_hex($_, 2) } @$arguments[7 .. 11])
			. Judo_dec_to_le_hex($arguments->[12], 4);
	} else {
		# Nicht registrierte Encoder sind ein kontrolliert gemeldeter Profilfehler.
		return (undef, undef, "Unbekannter Encoder $encoder");
	}
	return (($descriptor->{code} || '') . $data, $display, undef);
}

# Prueft Hexformat und dokumentierte Antwortlaenge vor jedem Decoderzugriff.
sub Judo_validate_data($$) {
	my ($descriptor, $data) = @_;
	return 'Nutzdaten sind keine gerade Hex-Zeichenfolge'
		if !defined($data) || $data !~ /^(?:[0-9A-Fa-f]{2})+$/;
	my $bytes = length($data) / 2;
	return "Antwortlaenge $bytes statt $descriptor->{bytes} Byte"
		if defined($descriptor->{bytes}) && $bytes != $descriptor->{bytes};
	return "Antwortlaenge $bytes ist kleiner als $descriptor->{min_bytes} Byte"
		if defined($descriptor->{min_bytes}) && $bytes < $descriptor->{min_bytes};
	return "Antwortlaenge $bytes ist groesser als $descriptor->{max_bytes} Byte"
		if defined($descriptor->{max_bytes}) && $bytes > $descriptor->{max_bytes};
	return 'Antwortlaenge ist nicht durch vier Byte teilbar'
		if ($descriptor->{decoder} || '') =~ /^stat_/ && $bytes % 4 != 0;
	return undef;
}

# Extrahiert und validiert die einbyte Modellnummer aus FF00.
sub Judo_decode_model_id($) {
	my ($data) = @_;
	return (undef, 'Geraetetyp muss genau ein Hex-Byte enthalten')
		if !defined($data) || $data !~ /^[0-9A-Fa-f]{2}$/;
	return (Judo_hex_to_dec($data), undef);
}

# Decodiert ein validiertes Get-Ergebnis in einen oder mehrere Readingwerte.
sub Judo_decode_data($$$) {
	my ($hash, $request, $data) = @_;
	my $descriptor = $request->{descriptor};
	my $command = $request->{command};
	my $error = Judo_validate_data($descriptor, $data);
	return (undef, $error) if $error;
	$data = uc $data;
	my $decoder = $descriptor->{decoder};

	# Little-Endian-Werte koennen nur den dokumentierten Beginn einer laengeren Antwort nutzen.
	if ($decoder eq 'uint_le' || $decoder eq 'limit') {
		my $hex = defined($descriptor->{take_bytes})
			? substr($data, 0, $descriptor->{take_bytes} * 2) : $data;
		my $value = Judo_le_hex_to_dec($hex);
		$value = 'disabled' if $decoder eq 'limit' && $value == 0;
		$value .= ' ' . $descriptor->{unit}
			if $value ne 'disabled' && defined($descriptor->{unit}) && $descriptor->{unit} ne '';
		return ({ $command => $value }, undef);
	}

	# Geraetenummern sind beim i-soft PRO Big Endian, sonst Little Endian.
	if ($decoder eq 'device_number') {
		my $value = ($hash->{helper}{family} || '') eq 'soft_pro'
			? Judo_hex_to_dec($data) : Judo_le_hex_to_dec($data);
		return ({ $command => $value }, undef);
	}

	# Der Patchteil der Softwareversion kann Zahl oder ASCII-Buchstabe sein.
	if ($decoder eq 'version') {
		my ($patch_hex, $minor_hex, $major_hex) = $data =~ /^(..)(..)(..)$/;
		my ($patch, $minor, $major) = map { Judo_hex_to_dec($_) } ($patch_hex, $minor_hex, $major_hex);
		my $minor_text = $minor > 0 && $minor < 10 ? sprintf('%02d', $minor) : $minor;
		my $version = $patch >= 0x20 && $patch <= 0x7E
			? "$major.$minor_text" . chr($patch) : "$major.$minor_text.$patch";
		return ({ $command => $version }, undef);
	}

	# ZEWA und i-dos liefern einen Unix-Zeitstempel; andere Familien Einzelwerte.
	if ($decoder eq 'commissioning_date') {
		my $family = $hash->{helper}{family} || '';

		if ($family eq 'zewa' || $family eq 'idos') {
			my (undef, undef, undef, $day, $month, $year) = localtime(Judo_hex_to_dec($data));
			return ({ $command => sprintf('%02d.%02d.%04d', $day, $month + 1, $year + 1900) }, undef);
		}
		my ($day_hex, $month_hex, $year_hex) = $data =~ /^(..)(..)(....)$/;
		my ($day, $month, $year) = (
			Judo_hex_to_dec($day_hex), Judo_hex_to_dec($month_hex), Judo_le_hex_to_dec($year_hex),
		);

		# Neuere PRO-Steuerungen liefern das zweibyte Jahr abweichend als Big Endian.
		if (!Judo_valid_date($year, $month, $day)) {
			my $big_endian_year = Judo_hex_to_dec($year_hex);
			$year = $big_endian_year if Judo_valid_date($big_endian_year, $month, $day);
		}

		return (undef, 'Ungueltiges Inbetriebnahmedatum') if !Judo_valid_date($year, $month, $day);
		return ({ $command => sprintf('%02d.%02d.%04d', $day, $month, $year) }, undef);
	}

	# Betriebsstunden bestehen aus Minuten, Stunden und Little-Endian-Tagen.
	if ($decoder eq 'operating_hours') {
		my ($minutes_hex, $hours_hex, $days_hex) = $data =~ /^(..)(..)(....)$/;
		return ({ $command => Judo_le_hex_to_dec($days_hex) . 'd '
			. Judo_hex_to_dec($hours_hex) . 'h ' . Judo_hex_to_dec($minutes_hex) . 'm' }, undef);
	}

	# Salzgewicht und Reichweite werden als getrennte Readings ausgegeben.
	if ($decoder eq 'salt_supply') {
		my ($weight_hex, $range_hex) = $data =~ /^(....)(....)$/;
		return ({
			saltWeight => Judo_le_hex_to_dec($weight_hex) . ' g',
			saltRange => Judo_le_hex_to_dec($range_hex) . ' days',
		}, undef);
	}

	# Die Haerteeinheit wird aus dem dokumentierten Einbyte-Code abgebildet.
	if ($decoder eq 'hardness_unit') {
		my @units = qw(dH eH fH gpg ppm mmol mval);
		my $index = Judo_hex_to_dec($data);
		return (undef, "Unbekannte Haerteeinheit $index") if !defined $units[$index];
		return ({ $command => $units[$index] }, undef);
	}

	# ASCII-Felder enden am ersten Nullbyte und enthalten keine Binaerdaten.
	if ($decoder eq 'ascii') {
		my $value = pack('H*', $data);
		$value =~ s/\x00.*$//s;
		return ({ $command => $value }, undef);
	}

	# Datumsantworten enthalten sechs einzelne Bytes in lokaler Geraetezeit.
	if ($decoder eq 'datetime') {
		my @parts = map { Judo_hex_to_dec($_) } ($data =~ /(..)/g);
		my ($day, $month, $year, $hour, $minute, $second) = @parts;
		$year += 2000;
		return (undef, 'Ungueltige Datum/Uhrzeit-Antwort')
			if !Judo_valid_date($year, $month, $day) || $hour > 23 || $minute > 59 || $second > 59;
		return ({ $command => sprintf('%04d-%02d-%02d %02d:%02d:%02d',
			$year, $month, $day, $hour, $minute, $second) }, undef);
	}

	# ZEWA-Grenzwerte sind drei Little-Endian-Zweibytewerte.
	if ($decoder eq 'zewa_limits') {
		my @parts = $data =~ /(....)/g;
		return ({
			absenceMaxFlow => Judo_le_hex_to_dec($parts[0]) . ' l/h',
			absenceMaxAmount => Judo_le_hex_to_dec($parts[1]) . ' l',
			absenceMaxDuration => Judo_le_hex_to_dec($parts[2]) . ' min',
		}, undef);
	}

	# Lernstatus kombiniert Aktivflag und verbleibende Lernwassermenge.
	if ($decoder eq 'learning_status') {
		my ($active_hex, $remaining_hex) = $data =~ /^(..)(....)$/;
		return ({
			learningStatus => Judo_hex_to_dec($active_hex) ? 'active' : 'inactive',
			learningRemaining => Judo_le_hex_to_dec($remaining_hex) . ' l',
		}, undef);
	}

	# Mikroleckagecodes werden in sprechende Werte uebersetzt.
	if ($decoder eq 'micro_leakage') {
		my @modes = ('off', 'notify', 'notifyAndClose');
		my $index = Judo_hex_to_dec($data);
		return (undef, "Unbekannter Mikroleckagemodus $index") if !defined $modes[$index];
		return ({ $command => $modes[$index] }, undef);
	}

	# Abwesenheitszeiten enthalten Start- und Stopptag samt Uhrzeit.
	if ($decoder eq 'absence_schedule') {
		my @parts = map { Judo_hex_to_dec($_) } ($data =~ /(..)/g);
		return (undef, 'Ungueltige Abwesenheitszeit-Antwort')
			if $parts[0] > 6 || $parts[1] > 23 || $parts[2] > 59
				|| $parts[3] > 6 || $parts[4] > 23 || $parts[5] > 59;
		return ({ $command => sprintf('day%d %02d:%02d - day%d %02d:%02d', @parts) }, undef);
	}

	# i-dos-Dosierung besteht aus Typ und Behaeltergroesse.
	if ($decoder eq 'idos_dosage') {
		my %types = (1 => 'JUL-W', 2 => 'JUL-C', 3 => 'JUL-H', 4 => 'JUL-S', 5 => 'JUL-SW');
		my %sizes = (1 => '3 l', 2 => '6 l', 3 => '25 l', 4 => '60 l');
		my ($type, $size) = map { Judo_hex_to_dec($_) } (substr($data, 0, 4) =~ /(..)/g);
		return (undef, "Unbekannte Dosierkonfiguration Typ=$type Inhalt=$size")
			if !exists($types{$type}) || !exists($sizes{$size});
		return ({ dosageType => $types{$type}, dosageLitres => $sizes{$size} }, undef);
	}

	# Die 29 i-dos-Statusbytes werden nach der offiziellen Feldaufteilung zerlegt.
	if ($decoder eq 'idos_status') {
		my ($circuit, $mode, undef, $concentration, undef, $error_hex, $warning_hex,
			undef, $dosage_hex, $flow_hex, $remaining_hex, $usage_hex, undef)
			= unpack('(a2)5 (a4)2 a12 (a4)3 (a8)2', $data);
		my @concentrations = ('unknown', 'minimum', 'normal', 'maximum');
		my $concentration_value = Judo_hex_to_dec($concentration);
		return (undef, "Unbekannte Konzentration $concentration_value")
			if !defined $concentrations[$concentration_value];
		return ({
			circuitType => Judo_hex_to_dec($circuit),
			operatingMode => Judo_hex_to_dec($mode),
			concentration => $concentrations[$concentration_value],
			errorCode => Judo_le_hex_to_dec($error_hex),
			warningCode => Judo_le_hex_to_dec($warning_hex),
			dosageQuantity => Judo_le_hex_to_dec($dosage_hex),
			waterFlow => Judo_le_hex_to_dec($flow_hex) . ' l/h',
			dosageRemaining => Judo_le_hex_to_dec($remaining_hex) . ' l',
			waterUsage => Judo_le_hex_to_dec($usage_hex) . ' l',
		}, undef);
	}

	# i-fill-Grenzwerte werden in einzeln nutzbare Readings aufgeteilt.
	if ($decoder eq 'ifill_limits') {
		my @bytes = $data =~ /(..)/g;
		my $capacity_start = @bytes == 24 ? 20 : 18;
		my $updates = {
			ifillLanguage => Judo_hex_to_dec($bytes[0]),
			ifillUnit => Judo_hex_to_dec($bytes[1]),
			ifillHardnessCorrection => Judo_hex_to_dec($bytes[2]),
			ifillCartridgeType => Judo_hex_to_dec($bytes[3]),
			ifillMaxCycles => Judo_hex_to_dec($bytes[5]),
			ifillMaxPressure => Judo_hex_to_dec($bytes[6]) / 10,
			ifillPressureHysteresis => Judo_hex_to_dec($bytes[7]) / 10,
			ifillRawWaterHardness => Judo_le_hex_to_dec(join('', @bytes[8 .. 9])),
			ifillMaxFillTime => Judo_le_hex_to_dec(join('', @bytes[10 .. 11])) . ' min',
			ifillMaxFillAmount => Judo_le_hex_to_dec(join('', @bytes[12 .. 13])) . ' l',
			ifillHeatingVolume => Judo_le_hex_to_dec(join('', @bytes[14 .. 15])) . ' l',
			ifillMaxConductivity => Judo_le_hex_to_dec(join('', @bytes[16 .. 17])),
			ifillCartridgeCapacity => Judo_le_hex_to_dec(join('', @bytes[$capacity_start .. $capacity_start + 3])),
		};

		# Das offizielle Beispiel hat trotz angegebener 22 Byte zwei Zusatzbytes.
		if (@bytes == 24) {
			$updates->{ifillAdditionalLimit} = Judo_le_hex_to_dec(join('', @bytes[18 .. 19]));
		}
		return ($updates, undef);
	}

	# Statistikantworten werden als kanonisches JSON-Objekt abgelegt.
	if ($decoder eq 'stat_sparse' || $decoder eq 'stat_fixed') {
		my ($values, $stat_error) = Judo_decode_statistics($descriptor, $data);
		return (undef, $stat_error) if $stat_error;
		return ({ $command => JSON::PP->new->canonical(1)->encode($values) }, undef);
	}

	# Rohdaten sind nur fuer variable, dokumentierte Szenenkonfigurationen erlaubt.
	return ({ $command => $data }, undef) if $decoder eq 'raw';
	return (undef, "Unbekannter Decoder $decoder");
}

# Decodiert feste oder indexierte Vierbyte-Statistikbloecke.
sub Judo_decode_statistics($$) {
	my ($descriptor, $data) = @_;
	my %values;
	my $period = $descriptor->{statistic};
	my @weekdays = qw(Mon Tue Wed Thu Fri Sat Sun);
	my @blocks = $data =~ /(.{8})/g;

	# Sparse PRO-Daten tragen Index und einen Big-Endian-Dreibytewert je Block.
	if ($descriptor->{decoder} eq 'stat_sparse') {

		for my $block (@blocks) {
			my ($index_hex, $value_hex) = $block =~ /^(..)(......)$/;
			my $index = Judo_hex_to_dec($index_hex);
			my $key = $period eq 'week' ? ($weekdays[$index] // "day$index")
				: $period eq 'day' ? sprintf('%02d:00', $index)
				: $period eq 'month' ? "day$index" : "month$index";
			$values{$key} = Judo_hex_to_dec($value_hex);
		}

		return (\%values, undef);
	}

	# Feste Daten ordnen die Blockposition dem dokumentierten Zeitraster zu.
	for my $index (0 .. $#blocks) {
		my $key = $period eq 'week' ? ($weekdays[$index] // "day$index")
			: $period eq 'day' ? sprintf('%02d:00', $index * 3)
			: $period eq 'month' ? 'day' . ($index + 1) : 'month' . ($index + 1);
		$values{$key} = Judo_le_hex_to_dec($blocks[$index]);
	}

	return (\%values, undef);
}

1;
