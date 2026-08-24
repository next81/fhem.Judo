# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use Judo::Protocol qw(
	Judo_validate_data Judo_decode_model_id Judo_decode_data
	Judo_decode_statistics
);

# Decodiert Testdaten mit einem minimalen Device- und Requestkontext.
sub decode_value {
	my ($family, $command, $descriptor, $data) = @_;
	my $hash = { NAME => 'decoder', helper => { family => $family } };
	return Judo_decode_data($hash, {
		command => $command,
		descriptor => $descriptor,
		mode => 'get',
	}, $data);
}

subtest 'Antwortformat und Modellnummer' => sub {
	like(Judo_validate_data({ bytes => 1 }, undef), qr/keine gerade Hex/,
		'fehlende Nutzdaten werden abgelehnt');
	like(Judo_validate_data({ bytes => 1 }, '0'), qr/keine gerade Hex/,
		'ungerade Hexfolge wird abgelehnt');
	like(Judo_validate_data({ bytes => 1 }, 'GG'), qr/keine gerade Hex/,
		'Nicht-Hexzeichen werden abgelehnt');
	like(Judo_validate_data({ bytes => 2 }, '00'), qr/1 statt 2 Byte/,
		'feste Antwortlaenge wird geprueft');
	like(Judo_validate_data({ min_bytes => 2 }, '00'), qr/kleiner als 2 Byte/,
		'Mindestlaenge wird geprueft');
	like(Judo_validate_data({ max_bytes => 1 }, '0000'), qr/groesser als 1 Byte/,
		'Maximallaenge wird geprueft');
	like(Judo_validate_data({ decoder => 'stat_fixed' }, '000000'), qr/nicht durch vier Byte/,
		'Statistikbloecke muessen vier Byte lang sein');
	is(Judo_validate_data({ bytes => 1 }, '7F'), undef, 'gueltige Einbyteantwort wird akzeptiert');
	is([Judo_decode_model_id('44')], [68, undef], 'ZEWA-Modellnummer wird aus FF00 decodiert');
	like((Judo_decode_model_id('4444'))[1], qr/genau ein Hex-Byte/,
		'zu lange Modellantwort wird abgelehnt');
};

subtest 'Einfache Werte und Geraeteinformationen' => sub {
	my ($updates, $error) = decode_value('soft_safe', 'totalWater', {
		decoder => 'uint_le', min_bytes => 4, take_bytes => 2, unit => 'l',
	}, 'E803AABB');
	is($error, undef, 'Little-Endian-Zaehler ist gueltig');
	is($updates, { totalWater => '1000 l' }, 'nur die dokumentierten Zaehlerbytes werden genutzt');
	($updates, $error) = decode_value('soft_safe', 'waterMaxAmount', {
		decoder => 'limit', bytes => 2, unit => 'l',
	}, '0000');
	is($updates, { waterMaxAmount => 'disabled' }, 'Grenzwert null wird als deaktiviert ausgegeben');
	($updates, $error) = decode_value('soft_safe', 'waterMaxAmount', {
		decoder => 'limit', bytes => 2, unit => 'l',
	}, '6400');
	is($updates, { waterMaxAmount => '100 l' }, 'aktiver Grenzwert enthaelt Wert und Einheit');
	($updates, $error) = decode_value('soft_safe', 'commissioningDate', {
		decoder => 'commissioning_date', bytes => 4,
	}, '1108EA07');
	is($updates, { commissioningDate => '17.08.2026' },
		'klassisches Inbetriebnahmedatum verwendet Little-Endian-Jahr');
	($updates, $error) = decode_value('soft_pro', 'commissioningDate', {
		decoder => 'commissioning_date', bytes => 4,
	}, '110807EA');
	is($updates, { commissioningDate => '17.08.2026' },
		'PRO-Inbetriebnahmedatum akzeptiert Big-Endian-Jahr');
	($updates, $error) = decode_value('soft_safe', 'commissioningDate', {
		decoder => 'commissioning_date', bytes => 4,
	}, '1F02E907');
	like($error, qr/Ungueltiges Inbetriebnahmedatum/,
		'ungueltiges klassisches Inbetriebnahmedatum wird abgelehnt');
	my $epoch = 1_700_000_000;
	my (undef, undef, undef, $day, $month, $year) = localtime($epoch);
	my $expected_date = sprintf('%02d.%02d.%04d', $day, $month + 1, $year + 1900);
	($updates, $error) = decode_value('zewa', 'commissioningDate', {
		decoder => 'commissioning_date', bytes => 4,
	}, sprintf('%08X', $epoch));
	is($updates, { commissioningDate => $expected_date },
		'ZEWA-Inbetriebnahmedatum verwendet den dokumentierten Unix-Zeitstempel');
	($updates, $error) = decode_value('soft_safe', 'saltSupply', {
		decoder => 'salt_supply', bytes => 4,
	}, 'E8031E00');
	is($updates, { saltWeight => '1000 g', saltRange => '30 days' },
		'Salzgewicht und Reichweite werden getrennt decodiert');
	($updates, $error) = decode_value('soft_safe', 'hardnessUnit', {
		decoder => 'hardness_unit', bytes => 1,
	}, '02');
	is($updates, { hardnessUnit => 'fH' }, 'Haerteeinheit wird benannt');
	($updates, $error) = decode_value('soft_safe', 'hardnessUnit', {
		decoder => 'hardness_unit', bytes => 1,
	}, '07');
	like($error, qr/Unbekannte Haerteeinheit 7/, 'unbekannte Haerteeinheit wird gemeldet');
	($updates, $error) = decode_value('soft_safe', 'serviceAddress', {
		decoder => 'ascii', bytes => 8,
	}, '4142430000000000');
	is($updates, { serviceAddress => 'ABC' }, 'ASCII-Antwort endet am ersten Nullbyte');
	($updates, $error) = decode_value('soft_pro', 'serviceAddress', {
		decoder => 'ascii', min_bytes => 1, max_bytes => 16,
	}, '2B34392037313935203639');
	is($updates, { serviceAddress => '+49 7195 69' },
		'PRO-Serviceadresse darf ohne Auffuellbytes kuerzer als 16 Byte sein');
	($updates, $error) = decode_value('soft_pro', 'waterMaxDuration', {
		decoder => 'limit', min_bytes => 1, max_bytes => 2, unit => 'min',
	}, '2800');
	is($updates, { waterMaxDuration => '40 min' },
		'PRO-Entnahmedauer akzeptiert eine Zweibyteantwort');
};

subtest 'Datum und ZEWA-Zustaende' => sub {
	my ($updates, $error) = decode_value('zewa', 'datetime', {
		decoder => 'datetime', bytes => 6,
	}, '11081A0E1F09');
	is($updates, { datetime => '2026-08-17 14:31:09' }, 'Geraetedatum wird lesbar formatiert');
	($updates, $error) = decode_value('zewa', 'datetime', {
		decoder => 'datetime', bytes => 6,
	}, '110D1A0E1F09');
	like($error, qr/Ungueltige Datum\/Uhrzeit/, 'ungueltiger Monat wird abgelehnt');
	($updates, $error) = decode_value('zewa', 'absenceLimits', {
		decoder => 'zewa_limits', bytes => 6,
	}, '6400C8002C01');
	is($updates, {
		absenceMaxFlow => '100 l/h',
		absenceMaxAmount => '200 l',
		absenceMaxDuration => '300 min',
	}, 'ZEWA-Grenzwerte werden einzeln benannt');
	($updates, $error) = decode_value('zewa', 'learningStatus', {
		decoder => 'learning_status', bytes => 3,
	}, '01F401');
	is($updates, { learningStatus => 'active', learningRemaining => '500 l' },
		'aktiver Lernstatus und Restmenge werden decodiert');
	($updates, $error) = decode_value('zewa', 'microLeakage', {
		decoder => 'micro_leakage', bytes => 1,
	}, '02');
	is($updates, { microLeakage => 'notifyAndClose' }, 'Mikroleckagecode wird benannt');
	($updates, $error) = decode_value('zewa', 'microLeakage', {
		decoder => 'micro_leakage', bytes => 1,
	}, '03');
	like($error, qr/Unbekannter Mikroleckagemodus 3/,
		'unbekannter Mikroleckagemodus wird gemeldet');
	($updates, $error) = decode_value('zewa', 'absenceSchedule', {
		decoder => 'absence_schedule', bytes => 6,
	}, '010203040506');
	is($updates, { absenceSchedule => 'day1 02:03 - day4 05:06' },
		'Abwesenheitszeit wird lesbar formatiert');
	($updates, $error) = decode_value('zewa', 'absenceSchedule', {
		decoder => 'absence_schedule', bytes => 6,
	}, '071900040506');
	like($error, qr/Ungueltige Abwesenheitszeit/, 'ungueltige Wochentage und Uhrzeiten werden abgelehnt');
};

subtest 'i-dos-Status und i-fill-Grenzwerte' => sub {
	my $status = join('',
		'01', '02', '00', '03', '00',
		'3401', '0200', '000000000000',
		'0A00', 'E803', 'F401', '10270000', '00000000',
	);
	is(length($status) / 2, 29, 'Statusvektor besitzt die dokumentierten 29 Byte');
	my ($updates, $error) = decode_value('idos', 'status', {
		decoder => 'idos_status', bytes => 29,
	}, $status);
	is($error, undef, 'vollstaendiger i-dos-Status ist gueltig');
	is($updates, {
		circuitType => 1,
		operatingMode => 2,
		concentration => 'maximum',
		errorCode => 308,
		warningCode => 2,
		dosageQuantity => 10,
		waterFlow => '1000 l/h',
		dosageRemaining => '500 l',
		waterUsage => '10000 l',
	}, 'alle dokumentierten i-dos-Statusfelder werden decodiert');
	my $bad_status = $status;
	substr($bad_status, 6, 2, '04');
	($updates, $error) = decode_value('idos', 'status', {
		decoder => 'idos_status', bytes => 29,
	}, $bad_status);
	like($error, qr/Unbekannte Konzentration 4/, 'unbekannte i-dos-Konzentration wird gemeldet');
	($updates, $error) = decode_value('idos', 'dosage', {
		decoder => 'idos_dosage', min_bytes => 2, max_bytes => 6,
	}, '0909');
	like($error, qr/Unbekannte Dosierkonfiguration/, 'unbekannte Dosierkonfiguration wird abgelehnt');
	($updates, $error) = decode_value('ifill', 'limits', {
		decoder => 'ifill_limits', bytes => 22,
	}, '00000000000514011400050014000500C8004C1D0000');
	is($error, undef, 'dokumentierte 22-Byte-i-fill-Antwort ist gueltig');
	is($updates->{ifillCartridgeCapacity}, 7500, '22-Byte-Antwort liest die Patronenkapazitaet');
	ok(!exists($updates->{ifillAdditionalLimit}), '22-Byte-Antwort erfindet keinen Zusatzgrenzwert');
};

subtest 'Feste und sparse Statistiken' => sub {
	my ($values, $error) = Judo_decode_statistics({
		decoder => 'stat_fixed', statistic => 'day',
	}, '0100000002000000');
	is($error, undef, 'feste Tagesstatistik ist gueltig');
	is($values, { '00:00' => 1, '03:00' => 2 }, 'feste Tagesbloecke erhalten Drei-Stunden-Schluessel');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_fixed', statistic => 'week',
	}, '0100000002000000');
	is($values, { Mon => 1, Tue => 2 }, 'feste Wochenbloecke erhalten Wochentage');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_fixed', statistic => 'month',
	}, '0100000002000000');
	is($values, { day1 => 1, day2 => 2 }, 'feste Monatsbloecke erhalten Kalendertage');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_fixed', statistic => 'year',
	}, '0100000002000000');
	is($values, { month1 => 1, month2 => 2 }, 'feste Jahresbloecke erhalten Monate');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_sparse', statistic => 'day',
	}, '02000064');
	is($values, { '02:00' => 100 }, 'sparse Tagesstatistik nutzt Index und Big-Endian-Wert');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_sparse', statistic => 'week',
	}, '00000064070000C8');
	is($values, { Mon => 100, day7 => 200 }, 'sparse Woche behandelt bekannte und unbekannte Indizes');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_sparse', statistic => 'month',
	}, '05000064');
	is($values, { day5 => 100 }, 'sparser Monat verwendet den gelieferten Kalendertag');
	($values, $error) = Judo_decode_statistics({
		decoder => 'stat_sparse', statistic => 'year',
	}, '02000064');
	is($values, { month2 => 100 }, 'sparsames Jahr verwendet den gelieferten Monat');
	my $updates;
	($updates, $error) = decode_value('soft_safe', 'waterDay', {
		decoder => 'stat_fixed', statistic => 'day',
	}, '01000000');
	is($updates, { waterDay => '{"00:00":1}' }, 'Statistikdecoder schreibt kanonisches JSON');
};

subtest 'Rohdaten und unbekannte Decoder' => sub {
	my ($updates, $error) = decode_value('soft_pro', 'sceneConfiguration', {
		decoder => 'raw', bytes => 2,
	}, 'A1B2');
	is($updates, { sceneConfiguration => 'A1B2' }, 'dokumentierter Rohpayload bleibt unveraendert');
	($updates, $error) = decode_value('soft_safe', 'unknown', {
		decoder => 'unknown', bytes => 1,
	}, '00');
	like($error, qr/Unbekannter Decoder unknown/, 'unbekannter Decoder wird kontrolliert gemeldet');
};

done_testing;
