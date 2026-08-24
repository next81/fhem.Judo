# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use Judo::Profiles qw(models profiles);

# Verdichtet Lesedeskriptoren auf die fachlich entscheidende Zuordnung aus
# Funktionsname, REST-Adresse und Decoder.
sub get_contract {
	my ($profile) = @_;
	return {
		map {
			$_ => join('|', $profile->{get}{$_}{code}, $profile->{get}{$_}{decoder})
		} sort keys %{ $profile->{get} }
	};
}

# Verdichtet Schreibdeskriptoren auf Adresse und Encoder. Auswahlbefehle mit
# eigenen Vollcodes behalten zusaetzlich jede erlaubte Aktion im Vertrag.
sub set_contract {
	my ($profile) = @_;
	return {
		map {
			my $descriptor = $profile->{set}{$_};
			my $address = $descriptor->{encoder} eq 'choice_code'
				? join(',', map { "$_=$descriptor->{choices}{$_}" } sort keys %{ $descriptor->{choices} })
				: $descriptor->{code};
			$_ => join('|', $address, $descriptor->{encoder});
		} sort keys %{ $profile->{set} }
	};
}

my %expected_models = (
	50 => 'i-soft|soft_basic',
	51 => 'i-soft SAFE+|soft_safe',
	52 => 'SOFTwell P|softwell',
	53 => 'SOFTwell S|softwell',
	54 => 'SOFTwell K|softwell',
	60 => 'i-fill 60|ifill',
	65 => 'i-dos eco|idos',
	66 => 'i-soft K SAFE+|soft_safe',
	67 => 'i-soft K|soft_basic',
	68 => 'ZEWA i-SAFE / FILT / PROM-i-SAFE|zewa',
	71 => 'SOFTwell KP|softwell',
	72 => 'SOFTwell KS|softwell',
	75 => 'i-soft PRO|soft_pro',
	76 => 'i-soft PRO L|soft_pro',
	83 => 'i-soft|soft_basic',
	84 => 'i-soft K|soft_basic',
	87 => 'i-soft SAFE+|soft_safe',
	88 => 'i-soft PRO|soft_pro',
	89 => 'SOFTwell P|softwell',
	90 => 'SOFTwell K|softwell',
	98 => 'SOFTwell KP|softwell',
	99 => 'SOFTwell S|softwell',
	100 => 'SOFTwell KS|softwell',
	103 => 'i-soft K SAFE+|soft_safe',
);

my %common_get = (
	commissioningDate => '0E00|commissioning_date',
	deviceNumber => '0600|device_number',
	model => 'FF00|model',
	version => '0100|version',
);
my %water_stats_fixed = (
	waterDay => 'FB00|stat_fixed',
	waterMonth => 'FD00|stat_fixed',
	waterWeek => 'FC00|stat_fixed',
	waterYear => 'FE00|stat_fixed',
);
my %water_stats_sparse = (
	waterDay => 'FB00|stat_sparse',
	waterMonth => 'FD00|stat_sparse',
	waterWeek => 'FC00|stat_sparse',
	waterYear => 'FE00|stat_sparse',
);
my %softener_get = (
	desiredWaterHardness => '5100|uint_le',
	hardnessUnit => '2300|hardness_unit',
	operatingHours => '2500|operating_hours',
	saltSupply => '5600|salt_supply',
	saltSupplyWarning => '5700|uint_le',
	serviceAddress => '5800|ascii',
	softWater => '2900|uint_le',
	totalWater => '2800|uint_le',
	waterMaxDuration => '3E00|limit',
);
my %softener_set = (
	desiredWaterHardness => '3000|number',
	regeneration => '3500|constant',
	saltSupply => '5600|number_le',
	saltSupplyWarning => '5700|number',
	serviceAddress => '5800|ascii_fixed',
	waterMaxDuration => '3E00|number',
);

my %expected_get = (
	soft_basic => {
		%common_get, %water_stats_fixed, %softener_get,
		waterMaxAmount => '4000|limit',
		waterMaxFlow => '3F00|limit',
	},
	soft_safe => {
		%common_get, %water_stats_fixed, %softener_get,
		waterMaxAmount => '4000|limit',
		waterMaxFlow => '3F00|limit',
	},
	soft_pro => {
		%common_get, %water_stats_sparse, %softener_get,
		flowDay => 'F700|stat_sparse',
		flowMonth => 'F900|stat_sparse',
		flowWeek => 'F800|stat_sparse',
		flowYear => 'FA00|stat_sparse',
		saltUsageDay => 'F300|stat_sparse',
		saltUsageMonth => 'F500|stat_sparse',
		saltUsageWeek => 'F400|stat_sparse',
		saltUsageYear => 'F600|stat_sparse',
		sceneConfiguration => '3700|raw',
		waterMaxAmount => '3F00|limit',
		waterMaxFlow => '4000|limit',
	},
	softwell => {
		%common_get, %water_stats_fixed,
		operatingHours => '2500|operating_hours',
		softWater => '2900|uint_le',
	},
	zewa => {
		%common_get, %water_stats_fixed,
		absenceLimits => '5E00|zewa_limits',
		absenceSchedule => '6000|absence_schedule',
		datetime => '5900|datetime',
		learningStatus => '6400|learning_status',
		microLeakage => '6500|micro_leakage',
		sleepDuration => '6600|uint_le',
		totalWater => '2800|uint_le',
	},
	idos => {
		%common_get, %water_stats_fixed,
		datetime => '6100|datetime',
		dosage => '6300|idos_dosage',
		status => '4300|idos_status',
		totalWater => '2800|uint_le',
	},
	ifill => {
		%common_get, %water_stats_fixed,
		limits => '4200|ifill_limits',
		totalWater => '2800|uint_le',
	},
);

my %expected_set = (
	soft_basic => {
		%softener_set,
		hardnessUnit => '2400|choice',
		holidayMode => '4100|number',
		leakageProtection => 'close=3C00,open=3D00|choice_code',
		waterMaxAmount => '4000|number_le',
		waterMaxFlow => '3F00|number_le',
	},
	soft_safe => {
		%softener_set,
		hardnessUnit => '2400|choice',
		holidayMode => '4100|number',
		leakageProtection => 'close=3C00,open=3D00|choice_code',
		waterMaxAmount => '4000|number_le',
		waterMaxFlow => '3F00|number_le',
	},
	soft_pro => {
		%softener_set,
		hardnessUnit => '2400|choice',
		holidayMode => '4100|holiday_pro',
		leakageProtection => 'close=3C00,open=3D00|choice_code',
		scene => '3600|scene',
		sceneConfigurationRaw => '3700|raw_hex',
		sceneReset => '3800|number',
		waterMaxAmount => '3F00|number_le',
		waterMaxFlow => '4000|number_le',
	},
	softwell => {},
	zewa => {
		absenceLimits => '5F00|three_le_numbers',
		absenceSchedule => '6100|absence_schedule',
		absenceScheduleDelete => '6200|number',
		datetime => '5A00|datetime',
		holidayMode => 'start=5700,stop=5800|choice_code',
		holidayType => '5600|number',
		leakageProtection => 'close=5100,open=5200|choice_code',
		leakageSettings => '5000|zewa_leakage_settings',
		learningMode => '5D00|constant',
		microLeakage => '5B00|number',
		microLeakageTest => '5C00|constant',
		resetMessage => '6300|constant',
		sleepDuration => '5300|number',
		sleepMode => 'start=5400,stop=5500|choice_code',
	},
	idos => {
		datetime => '7100|datetime',
		dosageConcentration => '5200|idos_concentration',
		pumpMode => '5300|idos_pump',
	},
	ifill => {
		alarmRelay => '5400|choice',
		fillValve => '5300|choice',
		leakageProtection => 'close=5100,open=5200|choice_code',
		limits => '5000|ifill_limits',
	},
);

my %expected_init = (
	soft_basic => [qw(deviceNumber version commissioningDate desiredWaterHardness saltSupply
		saltSupplyWarning hardnessUnit operatingHours totalWater softWater serviceAddress
		waterMaxDuration waterMaxFlow waterMaxAmount)],
	soft_safe => [qw(deviceNumber version commissioningDate desiredWaterHardness saltSupply
		saltSupplyWarning hardnessUnit operatingHours totalWater softWater serviceAddress
		waterMaxDuration waterMaxFlow waterMaxAmount)],
	soft_pro => [qw(deviceNumber version commissioningDate desiredWaterHardness saltSupply
		saltSupplyWarning hardnessUnit operatingHours totalWater softWater serviceAddress
		waterMaxDuration waterMaxAmount waterMaxFlow)],
	softwell => [qw(deviceNumber version commissioningDate operatingHours softWater)],
	zewa => [qw(deviceNumber version commissioningDate totalWater absenceLimits sleepDuration
		learningStatus microLeakage datetime)],
	idos => [qw(deviceNumber version commissioningDate totalWater datetime status dosage)],
	ifill => [qw(deviceNumber version commissioningDate totalWater limits)],
);
my %expected_poll = (
	soft_basic => [qw(totalWater softWater saltSupply)],
	soft_safe => [qw(totalWater softWater saltSupply)],
	soft_pro => [qw(totalWater softWater saltSupply)],
	softwell => [qw(softWater)],
	zewa => [qw(totalWater)],
	idos => [qw(totalWater status)],
	ifill => [qw(totalWater)],
);

my $model_data = models();
my %actual_models = map {
	$_ => join('|', $model_data->{$_}{name}, $model_data->{$_}{family})
} keys %$model_data;
is(\%actual_models, \%expected_models, 'jede Modellnummer bleibt der dokumentierten Familie zugeordnet');

my $profile_data = profiles();
is([sort keys %$profile_data], [sort keys %expected_get], 'der Profilvertrag umfasst genau alle Familien');

# Der Vergleich jeder Familie erkennt sowohl fehlende Funktionen als auch eine
# Verschiebung auf eine andere, syntaktisch weiterhin gueltige REST-Adresse.
for my $family (sort keys %expected_get) {
	is(get_contract($profile_data->{$family}), $expected_get{$family},
		"$family verknuepft jede Lesefunktion mit Adresse und Decoder");
	is(set_contract($profile_data->{$family}), $expected_set{$family},
		"$family verknuepft jede Schreibfunktion mit Adresse und Encoder");
	is($profile_data->{$family}{init}, $expected_init{$family},
		"$family initialisiert genau die vereinbarten Werte");
	is($profile_data->{$family}{poll}, $expected_poll{$family},
		"$family pollt genau die vereinbarten Werte");
}

done_testing;
