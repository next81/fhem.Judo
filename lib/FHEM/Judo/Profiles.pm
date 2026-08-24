# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# Licensed under the GNU General Public License v2.0 only

package Judo::Profiles;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(models profiles);

# Die REST-API belegt identische Adressen je nach Produktfamilie mit
# unterschiedlichen Funktionen. Die Modellnummer entscheidet deshalb vor jedem
# weiteren Kommando, welches streng begrenzte Profil verwendet werden darf.
my %MODELS = (
	50  => { name => 'i-soft', family => 'soft_basic' },
	51  => { name => 'i-soft SAFE+', family => 'soft_safe' },
	52  => { name => 'SOFTwell P', family => 'softwell' },
	53  => { name => 'SOFTwell S', family => 'softwell' },
	54  => { name => 'SOFTwell K', family => 'softwell' },
	60  => { name => 'i-fill 60', family => 'ifill' },
	65  => { name => 'i-dos eco', family => 'idos' },
	66  => { name => 'i-soft K SAFE+', family => 'soft_safe' },
	67  => { name => 'i-soft K', family => 'soft_basic' },
	68  => { name => 'ZEWA i-SAFE / FILT / PROM-i-SAFE', family => 'zewa' },
	71  => { name => 'SOFTwell KP', family => 'softwell' },
	72  => { name => 'SOFTwell KS', family => 'softwell' },
	75  => { name => 'i-soft PRO', family => 'soft_pro' },
	76  => { name => 'i-soft PRO L', family => 'soft_pro' },
	83  => { name => 'i-soft', family => 'soft_basic' },
	84  => { name => 'i-soft K', family => 'soft_basic' },
	87  => { name => 'i-soft SAFE+', family => 'soft_safe' },
	88  => { name => 'i-soft PRO', family => 'soft_pro' },
	89  => { name => 'SOFTwell P', family => 'softwell' },
	90  => { name => 'SOFTwell K', family => 'softwell' },
	98  => { name => 'SOFTwell KP', family => 'softwell' },
	99  => { name => 'SOFTwell S', family => 'softwell' },
	100 => { name => 'SOFTwell KS', family => 'softwell' },
	103 => { name => 'i-soft K SAFE+', family => 'soft_safe' },
);

# Diese Lesekommandos sind laut Judo-Dokumentation in allen Familien identisch.
my %COMMON_GET = (
	model => {
		code => 'FF00', decoder => 'model', bytes => 1, args => 'none', list => 'noArg',
	},
	deviceNumber => {
		code => '0600', decoder => 'device_number', bytes => 4, args => 'none', list => 'noArg',
	},
	version => {
		code => '0100', decoder => 'version', bytes => 3, args => 'none', list => 'noArg',
	},
	commissioningDate => {
		code => '0E00', decoder => 'commissioning_date', bytes => 4, args => 'none', list => 'noArg',
	},
);

# Aeltere Familien liefern feste Vierbyte-Statistikbloecke.
my %FIXED_WATER_STATS = (
	waterDay => {
		code => 'FB00', decoder => 'stat_fixed', statistic => 'day', args => 'date',
	},
	waterWeek => {
		code => 'FC00', decoder => 'stat_fixed', statistic => 'week', args => 'week',
	},
	waterMonth => {
		code => 'FD00', decoder => 'stat_fixed', statistic => 'month', args => 'month',
	},
	waterYear => {
		code => 'FE00', decoder => 'stat_fixed', statistic => 'year', args => 'year',
	},
);

# i-soft PRO liefert nur vorhandene Werte als Index plus Dreibyte-Menge.
my %SPARSE_WATER_STATS = (
	waterDay => {
		code => 'FB00', decoder => 'stat_sparse', statistic => 'day', args => 'date',
	},
	waterWeek => {
		code => 'FC00', decoder => 'stat_sparse', statistic => 'week', args => 'week',
	},
	waterMonth => {
		code => 'FD00', decoder => 'stat_sparse', statistic => 'month', args => 'month',
	},
	waterYear => {
		code => 'FE00', decoder => 'stat_sparse', statistic => 'year', args => 'year',
	},
);

my %SPARSE_FLOW_STATS = (
	flowDay => {
		code => 'F700', decoder => 'stat_sparse', statistic => 'day', args => 'date',
	},
	flowWeek => {
		code => 'F800', decoder => 'stat_sparse', statistic => 'week', args => 'week',
	},
	flowMonth => {
		code => 'F900', decoder => 'stat_sparse', statistic => 'month', args => 'month',
	},
	flowYear => {
		code => 'FA00', decoder => 'stat_sparse', statistic => 'year', args => 'year',
	},
);

my %SPARSE_SALT_STATS = (
	saltUsageDay => {
		code => 'F300', decoder => 'stat_sparse', statistic => 'day', args => 'date',
	},
	saltUsageWeek => {
		code => 'F400', decoder => 'stat_sparse', statistic => 'week', args => 'week',
	},
	saltUsageMonth => {
		code => 'F500', decoder => 'stat_sparse', statistic => 'month', args => 'month',
	},
	saltUsageYear => {
		code => 'F600', decoder => 'stat_sparse', statistic => 'year', args => 'year',
	},
);

# Die wiederverwendeten Enthaerter-Kommandos bleiben deklarativ, damit Profile
# einzelne Adressen, Grenzen oder Einheiten gezielt ueberschreiben koennen.
my %SOFTENER_GET = (
	desiredWaterHardness => {
		code => '5100', decoder => 'uint_le', bytes => 2, unit => "\xC2\xB0dH", args => 'none', list => 'noArg',
	},
	saltSupply => {
		code => '5600', decoder => 'salt_supply', bytes => 4, args => 'none', list => 'noArg',
	},
	saltSupplyWarning => {
		code => '5700', decoder => 'uint_le', bytes => 1, unit => 'days', args => 'none', list => 'noArg',
	},
	hardnessUnit => {
		code => '2300', decoder => 'hardness_unit', bytes => 1, args => 'none', list => 'noArg',
	},
	operatingHours => {
		code => '2500', decoder => 'operating_hours', bytes => 4, args => 'none', list => 'noArg',
	},
	totalWater => {
		code => '2800', decoder => 'uint_le', min_bytes => 4, take_bytes => 4, unit => 'l', args => 'none', list => 'noArg',
	},
	softWater => {
		code => '2900', decoder => 'uint_le', bytes => 4, unit => 'l', args => 'none', list => 'noArg',
	},
	serviceAddress => {
		code => '5800', decoder => 'ascii', min_bytes => 1, max_bytes => 16,
		args => 'none', list => 'noArg',
	},
	waterMaxDuration => {
		code => '3E00', decoder => 'limit', min_bytes => 1, max_bytes => 2,
		unit => 'min', args => 'none', list => 'noArg',
	},
);

my %SOFTENER_SET = (
	desiredWaterHardness => {
		code => '3000', encoder => 'number', bytes => 1, min => 0, max => 20,
		list => 'slider,0,1,20', refresh => 'desiredWaterHardness',
	},
	regeneration => {
		code => '3500', encoder => 'constant', data => '00', list => 'noArg',
	},
	saltSupply => {
		code => '5600', encoder => 'number_le', bytes => 2, min => 0, max => 65535,
		refresh => 'saltSupply',
	},
	saltSupplyWarning => {
		code => '5700', encoder => 'number', bytes => 1, min => 0, max => 255,
		refresh => 'saltSupplyWarning',
	},
	serviceAddress => {
		code => '5800', encoder => 'ascii_fixed', bytes => 16, refresh => 'serviceAddress',
	},
	waterMaxDuration => {
		code => '3E00', encoder => 'number', bytes => 1, min => 0, max => 255,
		refresh => 'waterMaxDuration',
	},
);

# Jedes Profil enthaelt ausschliesslich die fuer seine Familie dokumentierten
# Kommandos. Unbekannte Adressen gelangen dadurch nicht bis zur REST-API.
my %PROFILES = (
	soft_safe => {
		name => 'i-soft SAFE/i-soft',
		get => {
			%COMMON_GET, %SOFTENER_GET, %FIXED_WATER_STATS,
			waterMaxFlow => {
				code => '3F00', decoder => 'limit', bytes => 2, unit => 'l/h', args => 'none', list => 'noArg',
			},
			waterMaxAmount => {
				code => '4000', decoder => 'limit', bytes => 2, unit => 'l', args => 'none', list => 'noArg',
			},
		},
		set => {
			%SOFTENER_SET,
			hardnessUnit => {
				code => '2400', encoder => 'choice',
				choices => { dH => 0, eH => 1, fH => 2, gpg => 3, ppm => 4, mmol => 5, mval => 6 },
				list => 'dH,eH,fH,gpg,ppm,mmol,mval', refresh => 'hardnessUnit',
			},
			waterMaxFlow => {
				code => '3F00', encoder => 'number_le', bytes => 2, min => 0, max => 65535,
				refresh => 'waterMaxFlow',
			},
			waterMaxAmount => {
				code => '4000', encoder => 'number_le', bytes => 2, min => 0, max => 65535,
				refresh => 'waterMaxAmount',
			},
			leakageProtection => {
				encoder => 'choice_code', choices => { close => '3C00', open => '3D00' }, list => 'close,open',
			},
			holidayMode => {
				code => '4100', encoder => 'number', bytes => 1, min => 0, max => 255,
			},
		},
		init => [qw(deviceNumber version commissioningDate desiredWaterHardness saltSupply
			saltSupplyWarning hardnessUnit operatingHours totalWater softWater serviceAddress
			waterMaxDuration waterMaxFlow waterMaxAmount)],
		poll => [qw(totalWater softWater saltSupply)],
	},
	soft_basic => {
		name => 'i-soft/i-soft K', get => {}, set => {}, init => [], poll => [],
	},
	soft_pro => {
		name => 'i-soft PRO',
		get => {
			%COMMON_GET, %SOFTENER_GET, %SPARSE_WATER_STATS,
			%SPARSE_FLOW_STATS, %SPARSE_SALT_STATS,
			waterMaxAmount => {
				code => '3F00', decoder => 'limit', bytes => 2, unit => 'l', args => 'none', list => 'noArg',
			},
			waterMaxFlow => {
				code => '4000', decoder => 'limit', bytes => 2, unit => 'l/h', args => 'none', list => 'noArg',
			},
			sceneConfiguration => {
				code => '3700', decoder => 'raw', args => 'byte', arg_min => 0, arg_max => 10,
			},
		},
		set => {
			%SOFTENER_SET,
			hardnessUnit => {
				code => '2400', encoder => 'choice', choices => { dH => 0, fH => 2 },
				list => 'dH,fH', refresh => 'hardnessUnit',
			},
			waterMaxAmount => {
				code => '3F00', encoder => 'number_le', bytes => 2, min => 0, max => 3000,
				refresh => 'waterMaxAmount',
			},
			waterMaxFlow => {
				code => '4000', encoder => 'number_le', bytes => 2, min => 0, max => 5000,
				refresh => 'waterMaxFlow',
			},
			leakageProtection => {
				encoder => 'choice_code', choices => { close => '3C00', open => '3D00' }, list => 'close,open',
			},
			holidayMode => { code => '4100', encoder => 'holiday_pro' },
			scene => { code => '3600', encoder => 'scene' },
			sceneConfigurationRaw => {
				code => '3700', encoder => 'raw_hex', min_bytes => 2, max_bytes => 32,
			},
			sceneReset => {
				code => '3800', encoder => 'number', bytes => 1, min => 0, max => 10,
			},
		},
		init => [qw(deviceNumber version commissioningDate desiredWaterHardness saltSupply
			saltSupplyWarning hardnessUnit operatingHours totalWater softWater serviceAddress
			waterMaxDuration waterMaxAmount waterMaxFlow)],
		poll => [qw(totalWater softWater saltSupply)],
	},
	softwell => {
		name => 'SOFTwell',
		get => {
			%COMMON_GET, %FIXED_WATER_STATS,
			operatingHours => {
				code => '2500', decoder => 'operating_hours', bytes => 4, args => 'none', list => 'noArg',
			},
			softWater => {
				code => '2900', decoder => 'uint_le', bytes => 4, unit => 'l', args => 'none', list => 'noArg',
			},
		},
		set => {},
		init => [qw(deviceNumber version commissioningDate operatingHours softWater)],
		poll => [qw(softWater)],
	},
	zewa => {
		name => 'ZEWA i-SAFE',
		get => {
			%COMMON_GET, %FIXED_WATER_STATS,
			totalWater => {
				code => '2800', decoder => 'uint_le', min_bytes => 4, take_bytes => 4, unit => 'l', args => 'none', list => 'noArg',
			},
			absenceLimits => {
				code => '5E00', decoder => 'zewa_limits', bytes => 6, args => 'none', list => 'noArg',
			},
			sleepDuration => {
				code => '6600', decoder => 'uint_le', bytes => 1, unit => 'h', args => 'none', list => 'noArg',
			},
			learningStatus => {
				code => '6400', decoder => 'learning_status', bytes => 3, args => 'none', list => 'noArg',
			},
			microLeakage => {
				code => '6500', decoder => 'micro_leakage', bytes => 1, args => 'none', list => 'noArg',
			},
			datetime => {
				code => '5900', decoder => 'datetime', bytes => 6, args => 'none', list => 'noArg',
			},
			absenceSchedule => {
				code => '6000', decoder => 'absence_schedule', bytes => 6,
				args => 'byte', arg_min => 0, arg_max => 6,
			},
		},
		set => {
			resetMessage => { code => '6300', encoder => 'constant', data => '', list => 'noArg' },
			leakageProtection => {
				encoder => 'choice_code', choices => { close => '5100', open => '5200' }, list => 'close,open',
			},
			sleepMode => {
				encoder => 'choice_code', choices => { start => '5400', stop => '5500' }, list => 'start,stop',
			},
			holidayMode => {
				encoder => 'choice_code', choices => { start => '5700', stop => '5800' }, list => 'start,stop',
			},
			microLeakageTest => { code => '5C00', encoder => 'constant', data => '', list => 'noArg' },
			learningMode => { code => '5D00', encoder => 'constant', data => '', list => 'noArg' },
			leakageSettings => { code => '5000', encoder => 'zewa_leakage_settings' },
			sleepDuration => {
				code => '5300', encoder => 'number', bytes => 1, min => 1, max => 10,
				refresh => 'sleepDuration',
			},
			holidayType => {
				code => '5600', encoder => 'number', bytes => 1, min => 0, max => 3,
			},
			microLeakage => {
				code => '5B00', encoder => 'number', bytes => 1, min => 0, max => 2,
				refresh => 'microLeakage',
			},
			absenceLimits => {
				code => '5F00', encoder => 'three_le_numbers', bytes => 2, min => 0, max => 65535,
				refresh => 'absenceLimits',
			},
			datetime => { code => '5A00', encoder => 'datetime', refresh => 'datetime' },
			absenceSchedule => { code => '6100', encoder => 'absence_schedule' },
			absenceScheduleDelete => {
				code => '6200', encoder => 'number', bytes => 1, min => 0, max => 6,
			},
		},
		init => [qw(deviceNumber version commissioningDate totalWater absenceLimits sleepDuration
			learningStatus microLeakage datetime)],
		poll => [qw(totalWater)],
	},
	idos => {
		name => 'i-dos eco',
		get => {
			%COMMON_GET, %FIXED_WATER_STATS,
			datetime => {
				code => '6100', decoder => 'datetime', bytes => 6, args => 'none', list => 'noArg',
			},
			status => {
				code => '4300', decoder => 'idos_status', bytes => 29, args => 'none', list => 'noArg',
			},
			dosage => {
				code => '6300', decoder => 'idos_dosage', min_bytes => 2, max_bytes => 6,
				take_bytes => 2, args => 'none', list => 'noArg',
			},
			totalWater => {
				code => '2800', decoder => 'uint_le', min_bytes => 4, take_bytes => 4, unit => 'l', args => 'none', list => 'noArg',
			},
		},
		set => {
			datetime => { code => '7100', encoder => 'datetime', refresh => 'datetime' },
			dosageConcentration => {
				code => '5200', encoder => 'idos_concentration',
				list => 'minimum,normal,maximum', refresh => 'status',
			},
			pumpMode => { code => '5300', encoder => 'idos_pump' },
		},
		init => [qw(deviceNumber version commissioningDate totalWater datetime status dosage)],
		poll => [qw(totalWater status)],
	},
	ifill => {
		name => 'i-fill 60',
		get => {
			%COMMON_GET, %FIXED_WATER_STATS,
			limits => {
				code => '4200', decoder => 'ifill_limits', min_bytes => 22, max_bytes => 24,
				args => 'none', list => 'noArg',
			},
			totalWater => {
				code => '2800', decoder => 'uint_le', min_bytes => 4, take_bytes => 4, unit => 'l', args => 'none', list => 'noArg',
			},
		},
		set => {
			limits => { code => '5000', encoder => 'ifill_limits', refresh => 'limits' },
			fillValve => {
				code => '5300', encoder => 'choice', choices => { auto => 0, open => 1, close => 2 },
				list => 'auto,open,close',
			},
			leakageProtection => {
				encoder => 'choice_code', choices => { close => '5100', open => '5200' }, list => 'close,open',
			},
			alarmRelay => {
				code => '5400', encoder => 'choice',
				choices => { auto => 0, manualOff => 128, manualOn => 129 },
				list => 'auto,manualOff,manualOn',
			},
		},
		init => [qw(deviceNumber version commissioningDate totalWater limits)],
		poll => [qw(totalWater)],
	},
);

# i-soft und i-soft SAFE teilen dieselben dokumentierten Kommandos. Eigenstaendige
# Container verhindern, dass spaetere Erweiterungen beide Profile versehentlich koppeln.
$PROFILES{soft_basic}{get} = { %{ $PROFILES{soft_safe}{get} } };
$PROFILES{soft_basic}{set} = { %{ $PROFILES{soft_safe}{set} } };
$PROFILES{soft_basic}{init} = [ @{ $PROFILES{soft_safe}{init} } ];
$PROFILES{soft_basic}{poll} = [ @{ $PROFILES{soft_safe}{poll} } ];

# Liefert die gekapselte Modellzuordnung fuer die sichere Profilauswahl.
sub models() {
	return \%MODELS;
}

# Liefert die gekapselten REST-Profile fuer ausschliesslich lesenden Zugriff.
sub profiles() {
	return \%PROFILES;
}

1;
