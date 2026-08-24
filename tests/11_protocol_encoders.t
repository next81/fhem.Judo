# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use Judo::Protocol qw(
	Judo_number_in_range Judo_dec_to_hex Judo_dec_to_le_hex
	Judo_hex_to_dec Judo_le_hex_to_dec Judo_valid_date
	Judo_encode_get_arguments Judo_build_get_code Judo_encode_datetime
	Judo_build_set_code
);

# Prueft einen Encoder mit Deskriptor und Argumentliste und liefert alle Ergebnisse.
sub encode_set {
	my ($descriptor, @arguments) = @_;
	return [ Judo_build_set_code($descriptor, \@arguments) ];
}

subtest 'Zahlen, Bytefolgen und Kalenderdaten' => sub {
	ok(Judo_number_in_range(0, 0, 10), 'untere Zahlengrenze ist gueltig');
	ok(Judo_number_in_range(10, 0, 10), 'obere Zahlengrenze ist gueltig');
	ok(!Judo_number_in_range(-1, 0, 10), 'negative Zahl wird abgelehnt');
	ok(!Judo_number_in_range('1.5', 0, 10), 'Dezimalbruch wird abgelehnt');
	ok(!Judo_number_in_range(11, 0, 10), 'Wert oberhalb der Grenze wird abgelehnt');
	is(Judo_dec_to_hex(4660, 2), '1234', 'Big Endian wird korrekt codiert');
	is(Judo_dec_to_le_hex(4660, 2), '3412', 'Little Endian wird korrekt codiert');
	is(Judo_hex_to_dec('1234'), 4660, 'Big Endian wird korrekt decodiert');
	is(Judo_le_hex_to_dec('3412'), 4660, 'Little Endian wird korrekt decodiert');
	ok(Judo_valid_date(2024, 2, 29), 'Schalttag 2024 ist gueltig');
	ok(!Judo_valid_date(2025, 2, 29), 'ungueltiger Schalttag wird abgelehnt');
	ok(!Judo_valid_date(1999, 12, 31), 'Jahr ausserhalb des API-Bereichs wird abgelehnt');
};

subtest 'Get-Argumente und Get-Kommandos' => sub {
	is([Judo_encode_get_arguments('none', [])], ['', undef], 'argumentloses Get erzeugt keine Nutzdaten');
	is([Judo_encode_get_arguments('date', ['2024-06-19'])], ['1306E807', undef],
		'Tagesdatum entspricht der dokumentierten Bytefolge');
	is([Judo_encode_get_arguments('week', ['2024-W25'])], ['19E807', undef],
		'Kalenderwoche wird korrekt codiert');
	is([Judo_encode_get_arguments('month', ['2024-06'])], ['06E807', undef],
		'Monat wird korrekt codiert');
	is([Judo_encode_get_arguments('year', ['2024'])], ['E807', undef],
		'Jahr wird Little Endian codiert');
	is([Judo_encode_get_arguments('byte', [6], { arg_min => 0, arg_max => 6 })], ['06', undef],
		'Index innerhalb des Profilbereichs wird codiert');
	like((Judo_encode_get_arguments('date', ['2025-02-29']))[1], qr/Ungueltiges Datum/,
		'ungueltiges Tagesdatum wird abgelehnt');
	like((Judo_encode_get_arguments('week', ['2024-W54']))[1], qr/Ungueltige Woche/,
		'Kalenderwoche 54 wird abgelehnt');
	like((Judo_encode_get_arguments('month', ['2024-13']))[1], qr/Ungueltiger Monat/,
		'Monat 13 wird abgelehnt');
	like((Judo_encode_get_arguments('year', ['2100']))[1], qr/Ungueltiges Jahr/,
		'Jahr ausserhalb des API-Bereichs wird abgelehnt');
	like((Judo_encode_get_arguments('byte', [7], { arg_min => 0, arg_max => 6 }))[1],
		qr/zwischen 0 und 6/, 'Index ausserhalb des Profilbereichs wird abgelehnt');
	like((Judo_encode_get_arguments('unknown', []))[1], qr/Unbekannter Argumenttyp/,
		'unbekannter Get-Argumenttyp wird gemeldet');
	is([Judo_build_get_code({ code => '0600', args => 'none' }, [])], ['0600', undef],
		'argumentloses Get verbindet Adresse ohne Nutzdaten');
	like((Judo_build_get_code({ code => '0600', args => 'none' }, [1]))[1],
		qr/erwartet keine Argumente/, 'unerlaubtes Argument wird vor dem Request abgelehnt');
};

subtest 'Datum und Uhrzeit setzen' => sub {
	is([Judo_encode_datetime(['2026-08-23', '14:31:09'])], ['17081A0E1F09', undef],
		'explizite Datum/Uhrzeit wird korrekt codiert');
	like((Judo_encode_datetime(['now']))[0], qr/^[0-9A-F]{12}$/,
		'now erzeugt genau sechs gueltige Datenbytes');
	like((Judo_encode_datetime(['2026-02-29', '12:00:00']))[1], qr/Ungueltiges Datum/,
		'ungueltiges Kalenderdatum wird abgelehnt');
	like((Judo_encode_datetime(['2026-08-23', '24:00:00']))[1], qr/Ungueltiges Datum/,
		'ungueltige Uhrzeit wird abgelehnt');
	like((Judo_encode_datetime(['morgen']))[1], qr/Erwartet wird now/,
		'unbekanntes Datumsformat wird erklaert');
};

subtest 'Einfache und auswahlbasierte Set-Encoder' => sub {
	is(encode_set({ code => '3500', encoder => 'constant', data => '00' }),
		['350000', '', undef], 'konstante Regeneration wird codiert');
	like(encode_set({ code => '3500', encoder => 'constant' }, 1)->[2],
		qr/keine Argumente/, 'konstante Aktion lehnt Argumente ab');
	is(encode_set({ code => '3000', encoder => 'number', bytes => 1, min => 0, max => 20 }, 10),
		['30000A', '10', undef], 'Einbytezahl wird Big Endian codiert');
	like(encode_set({ code => '3000', encoder => 'number', bytes => 1, min => 0, max => 20 }, 21)->[2],
		qr/zwischen 0 und 20/, 'Zahl oberhalb der Profilgrenze wird abgelehnt');
	is(encode_set({ code => '3F00', encoder => 'number_le', bytes => 2, min => 0, max => 3000 }, 3000),
		['3F00B80B', '3000', undef], 'Mehrbytezahl wird Little Endian codiert');
	is(encode_set({ code => '5300', encoder => 'choice', choices => { auto => 0, open => 1 } }, 'open'),
		['530001', 'open', undef], 'Auswahl wird als Datenbyte codiert');
	like(encode_set({ code => '5300', encoder => 'choice', choices => { auto => 0 } }, 'open')->[2],
		qr/Erwartet wird einer/, 'unbekannter Auswahlwert wird abgelehnt');
	is(encode_set({ encoder => 'choice_code', choices => { close => '5100', open => '5200' } }, 'close'),
		['5100', 'close', undef], 'Auswahl kann eine vollstaendige Adresse bestimmen');
	like(encode_set({ encoder => 'choice_code', choices => { close => '5100' } }, 'open')->[2],
		qr/Erwartet wird einer/, 'unbekannter Adressauswahlwert wird abgelehnt');
};

subtest 'Text-, Rohdaten- und profilabhaengige Encoder' => sub {
	is(encode_set({ code => '5800', encoder => 'ascii_fixed', bytes => 4 }, 'AB'),
		['580041420000', 'AB', undef], 'ASCII-Feld wird mit Nullbytes aufgefuellt');
	like(encode_set({ code => '5800', encoder => 'ascii_fixed', bytes => 4 }, 'ABCDE')->[2],
		qr/1 bis 4/, 'zu langes ASCII-Feld wird abgelehnt');
	like(encode_set({ code => '5800', encoder => 'ascii_fixed', bytes => 4 }, "A\nB")->[2],
		qr/ASCII-Zeichen/, 'Steuerzeichen im ASCII-Feld werden abgelehnt');
	is(encode_set({ code => '3700', encoder => 'raw_hex', min_bytes => 2, max_bytes => 4 }, 'a1b2'),
		['3700A1B2', 'a1b2', undef], 'Rohpayload wird validiert und normalisiert');
	like(encode_set({ code => '3700', encoder => 'raw_hex', min_bytes => 2, max_bytes => 4 }, 'ABC')->[2],
		qr/gerade Hex/, 'ungerade Hexfolge wird abgelehnt');
	like(encode_set({ code => '3700', encoder => 'raw_hex', min_bytes => 2, max_bytes => 4 }, 'AA')->[2],
		qr/2 bis 4 Byte/, 'zu kurzer Rohpayload wird abgelehnt');
	is(encode_set({ code => '5A00', encoder => 'datetime' }, '2026-08-23', '14:31:09'),
		['5A0017081A0E1F09', '2026-08-23 14:31:09', undef], 'Datum wird an die Profiladresse angehaengt');
	is(encode_set({ code => '5F00', encoder => 'three_le_numbers', bytes => 2, min => 0, max => 65535 },
		1, 2, 3), ['5F00010002000300', '1 2 3', undef], 'drei ZEWA-Grenzwerte werden codiert');
	like(encode_set({ code => '5F00', encoder => 'three_le_numbers', bytes => 2, min => 0, max => 10 },
		1, 2, 11)->[2], qr/Jeder Wert/, 'ungueltiger ZEWA-Grenzwert wird abgelehnt');
	is(encode_set({ code => '4100', encoder => 'holiday_pro' }, 1, 2),
		['41000102', '1 2', undef], 'PRO-Urlaub kombiniert Flags und Dauer');
	like(encode_set({ code => '4100', encoder => 'holiday_pro' }, 1, 256)->[2],
		qr/Urlaubsdauer/, 'zu lange PRO-Urlaubsdauer wird abgelehnt');
};

subtest 'Komplexe ZEWA-, i-dos- und i-fill-Encoder' => sub {
	is(encode_set({ code => '3600', encoder => 'scene' }, 'Garten', '2h'),
		['3600020200', 'Garten 2h', undef], 'PRO-Szene und Laufzeit werden codiert');
	like(encode_set({ code => '3600', encoder => 'scene' }, 'Unbekannt', '2h')->[2],
		qr/Szene und Dauer/, 'unbekannte PRO-Szene wird abgelehnt');
	is(encode_set({ code => '5000', encoder => 'zewa_leakage_settings' }, 2, 100, 200, 300),
		['5000026400C8002C01', '2 100 200 300', undef], 'ZEWA-Leckageeinstellungen werden codiert');
	like(encode_set({ code => '5000', encoder => 'zewa_leakage_settings' }, 4, 1, 2, 3)->[2],
		qr/Urlaubsmodus/, 'ungueltiger ZEWA-Urlaubsmodus wird abgelehnt');
	is(encode_set({ code => '6100', encoder => 'absence_schedule' }, 1, 2, '03:04', 5, '06:07'),
		['610001020304050607', '1 2 03:04 5 06:07', undef], 'ZEWA-Abwesenheitszeit wird codiert');
	like(encode_set({ code => '6100', encoder => 'absence_schedule' }, 1, 2, '24:00', 5, '06:07')->[2],
		qr/Uhrzeiten/, 'ungueltige ZEWA-Uhrzeit wird abgelehnt');
	is(encode_set({ code => '5200', encoder => 'idos_concentration' }, 'maximum'),
		['52000003', 'maximum', undef], 'i-dos-Konzentration wird codiert');
	like(encode_set({ code => '5200', encoder => 'idos_concentration' }, 'turbo')->[2],
		qr/minimum, normal oder maximum/, 'unbekannte i-dos-Konzentration wird abgelehnt');
	is(encode_set({ code => '5300', encoder => 'idos_pump' }, 'manual', 1200),
		['530002B004', 'manual 1200', undef], 'manuelle i-dos-Pumpe enthaelt Drehzahl');
	like(encode_set({ code => '5300', encoder => 'idos_pump' }, 'manual')->[2],
		qr/Drehzahl groesser 0/, 'manuelle Pumpe ohne Drehzahl wird abgelehnt');
	is(encode_set({ code => '5300', encoder => 'idos_pump' }, 'auto'),
		['5300010000', 'auto', undef], 'automatische i-dos-Pumpe verwendet Drehzahl null');
	my $ifill = encode_set({ code => '5000', encoder => 'ifill_limits' },
		0, 0, 0, 0, 5, 20, 1, 20, 5, 20, 5, 200, 7500);
	is($ifill->[0], '500000000000000514011400050014000500C8004C1D0000',
		'i-fill-Grenzwerte ergeben die vollstaendige dokumentierte Bytefolge');
	is($ifill->[2], undef, 'gueltige i-fill-Grenzwerte haben keinen Fehler');
	like(encode_set({ code => '5000', encoder => 'ifill_limits' }, 1, 2)->[2],
		qr/Erwartet werden 13 Werte/, 'unvollstaendige i-fill-Grenzwerte werden abgelehnt');
	like(encode_set({ code => '5000', encoder => 'ifill_limits' },
		5, 0, 0, 0, 5, 20, 1, 20, 5, 20, 5, 200, 7500)->[2],
		qr/i-fill-Wert 1/, 'i-fill-Feldgrenze wird einzeln validiert');
	like(encode_set({ code => '0000', encoder => 'unknown' })->[2], qr/Unbekannter Encoder/,
		'unbekannter Encoder wird kontrolliert gemeldet');
};

done_testing;
