# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

sub decode_value {
	my ($family, $command, $descriptor, $data) = @_;
	my $hash = { NAME => 'test', helper => { family => $family } };
	return main::Judo_decode_data($hash, {
		command => $command, descriptor => $descriptor, mode => 'get',
	}, $data);
}

is(main::Judo_dec_to_le_hex(2500, 2), 'C409', '2500 wird als Little Endian codiert');
is(main::Judo_le_hex_to_dec('EC221000'), 1_057_516, 'offizielles Gesamtwasserbeispiel decodiert');

my ($date_data, $date_error) = main::Judo_encode_get_arguments('date', ['2024-06-19']);
is($date_error, undef, 'Statistikdatum ist gueltig');
is($date_data, '1306E807', 'Statistikdatum entspricht offizieller Bytefolge');
my ($week_data) = main::Judo_encode_get_arguments('week', ['2024-W25']);
is($week_data, '19E807', 'Kalenderwoche entspricht offizieller Bytefolge');

my ($updates, $error) = decode_value('soft_safe', 'operatingHours', {
	decoder => 'operating_hours', bytes => 4,
}, '060C7500');
is($error, undef, 'Betriebsstunden werden akzeptiert');
is($updates->{operatingHours}, '117d 12h 6m', 'Little-Endian-Tage werden korrekt decodiert');

($updates, $error) = decode_value('soft_safe', 'deviceNumber', {
	decoder => 'device_number', bytes => 4,
}, '64D90100');
is($updates->{deviceNumber}, 121188, 'Geraetenummer des SAFE-Beispiels ist Little Endian');
($updates, $error) = decode_value('soft_pro', 'deviceNumber', {
	decoder => 'device_number', bytes => 4,
}, '10D36F28');
is($updates->{deviceNumber}, 282292008, 'Geraetenummer des PRO-Beispiels ist Big Endian');

($updates, $error) = decode_value('soft_safe', 'version', {
	decoder => 'version', bytes => 3,
}, '6B1502');
is($updates->{version}, '2.21k', 'Buchstabensuffix der Softwareversion bleibt erhalten');
($updates, $error) = decode_value('soft_pro', 'version', {
	decoder => 'version', bytes => 3,
}, '0C0001');
is($updates->{version}, '1.0.12', 'numerischer Patch wird mit Trenner ausgegeben');

($updates, $error) = decode_value('idos', 'dosage', {
	decoder => 'idos_dosage', min_bytes => 2, max_bytes => 6,
}, '0102');
is($updates, { dosageLitres => '6 l', dosageType => 'JUL-W' },
	'i-dos-Dosierbeispiel wird fachlich decodiert');

my ($datetime, $datetime_error) = main::Judo_encode_datetime(['2026-08-23', '14:31:09']);
is($datetime_error, undef, 'explizite Datum/Uhrzeit ist gueltig');
is($datetime, '17081A0E1F09', 'August wird als Monat 08 und nicht 07 codiert');

my ($scene_code, undef, $scene_error) = main::Judo_build_set_code({
	code => '3600', encoder => 'scene',
}, ['Garten', '2h']);
is($scene_error, undef, 'Szene kann codiert werden');
is($scene_code, '3600020200', 'Szene 2 fuer zwei Stunden hat fuenf Byte');

my ($ifill_code, undef, $ifill_error) = main::Judo_build_set_code({
	code => '5000', encoder => 'ifill_limits',
}, [0, 0, 0, 0, 5, 20, 1, 20, 5, 20, 5, 200, 7500]);
is($ifill_error, undef, 'strukturierte i-fill-Grenzwerte sind gueltig');
is(length($ifill_code), 48, 'i-fill-Kommando besteht aus Adresse und 22 Datenbytes');

($updates, $error) = decode_value('ifill', 'limits', {
	decoder => 'ifill_limits', min_bytes => 22, max_bytes => 24,
}, '00000000000514011400050014000500C80064004C1D0000');
is($error, undef, 'abweichendes offizielles i-fill-Beispiel mit 24 Byte wird akzeptiert');
is($updates->{ifillCartridgeCapacity}, 7500, 'Patronenkapazitaet des i-fill-Beispiels wird korrekt gelesen');
is($updates->{ifillAdditionalLimit}, 100, 'zusaetzlicher undokumentierter Beispielwert bleibt sichtbar');

done_testing;
