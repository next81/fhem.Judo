# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'tests/lib';
use JudoTestEnv qw(reset_env);

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

my %models = (
	soft_basic => 50,
	soft_safe => 51,
	softwell => 52,
	ifill => 60,
	idos => 65,
	zewa => 68,
	soft_pro => 88,
);
my %decoders = map { $_ => 1 } qw(model device_number version commissioning_date
	uint_le limit operating_hours salt_supply hardness_unit ascii datetime zewa_limits
	learning_status micro_leakage absence_schedule idos_dosage idos_status ifill_limits
	stat_sparse stat_fixed raw);
my %encoders = map { $_ => 1 } qw(constant number number_le choice choice_code ascii_fixed
	raw_hex datetime three_le_numbers holiday_pro scene zewa_leakage_settings
	absence_schedule idos_concentration idos_pump ifill_limits);

for my $family (sort keys %models) {
	reset_env();
	my $hash = { NAME => $family, TYPE => 'Judo', READINGS => {}, helper => {
		queue => [], issues => {}, generation => 1, request_id => 0,
	} };
	$main::defs{$family} = $hash;
	main::Judo_apply_model($hash, $models{$family});
	my $profile = main::Judo_profile($hash);
	ok($profile, "$family besitzt ein Profil");

	# Jeder Get-Deskriptor muss eine feste Zweibyteadresse und einen implementierten Decoder besitzen.
	for my $command (sort keys %{ $profile->{get} }) {
		my $descriptor = $profile->{get}{$command};
		like($descriptor->{code}, qr/^[0-9A-F]{4}$/, "$family get $command hat eine Zweibyteadresse");
		ok($decoders{ $descriptor->{decoder} }, "$family get $command verwendet einen bekannten Decoder");
	}

	# Set-Deskriptoren verwenden entweder eine feste Adresse oder ausschliesslich
	# explizit erlaubte Vollcodes einer Auswahl.
	for my $command (sort keys %{ $profile->{set} }) {
		my $descriptor = $profile->{set}{$command};
		ok($encoders{ $descriptor->{encoder} }, "$family set $command verwendet einen bekannten Encoder");

		if ($descriptor->{encoder} eq 'choice_code') {
			like($_, qr/^[0-9A-F]{4}$/, "$family set $command Auswahlcode ist gueltig")
				for values %{ $descriptor->{choices} };
		} else {
			like($descriptor->{code}, qr/^[0-9A-F]{4}$/, "$family set $command hat eine Zweibyteadresse");
		}

	}

	# Automatische Requests duerfen nur argumentlose Lesekommandos des Profils referenzieren.
	for my $kind (qw(init poll)) {

		for my $command (@{ $profile->{$kind} }) {
			ok($profile->{get}{$command}, "$family $kind referenziert vorhandenes Get $command");
			is($profile->{get}{$command}{args} || 'none', 'none',
				"$family $kind $command benoetigt keine Benutzereingabe");
		}

	}
}

done_testing;
