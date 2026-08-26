# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'tests/lib';
use JudoTestEnv qw(reset_env);
no warnings qw(once);

BEGIN { $INC{'HttpUtils.pm'} = 1; }

my $loaded = do './FHEM/50_Judo.pm';
die $@ if $@;
die $! if !defined $loaded;

reset_env();
my $module = {};
main::Judo_Initialize($module);
is($module->{DefFn}, 'Judo_Define', 'DefFn registriert');
is($module->{GetFn}, 'Judo_Get', 'GetFn registriert');
is($module->{SetFn}, 'Judo_Set', 'SetFn registriert');
is($module->{AttrFn}, 'Judo_Attr', 'AttrFn registriert');
is($module->{NotifyFn}, 'Judo_Notify', 'NotifyFn registriert');
like($module->{AttrList}, qr/(?:^| )interval(?: |$)/, 'Heartbeatintervall registriert');
like($module->{AttrList}, qr/(?:^| )maxFailures(?: |$)/, 'Fehlerschwelle registriert');
is($main::Judo_VERSION, '1.1.0', 'Modulversion gesetzt');
ok(-f 'lib/FHEM/Judo/Auth.pm', 'Authentifizierungsbibliothek wird ausgeliefert');
ok(-f 'lib/FHEM/Judo/Connection.pm', 'Verbindungsbibliothek wird ausgeliefert');
ok(-f 'lib/FHEM/Judo/Profiles.pm', 'Profilbibliothek wird ausgeliefert');
ok(-f 'lib/FHEM/Judo/Protocol.pm', 'Protokollbibliothek wird ausgeliefert');
ok(-f 'lib/FHEM/Judo/Runtime.pm', 'Laufzeitbibliothek wird ausgeliefert');

open my $module_file, '<:encoding(UTF-8)', 'FHEM/50_Judo.pm'
	or die "Moduldatei kann nicht gelesen werden: $!";
my $source = do { local $/; <$module_file> };
close $module_file;
unlike($source, qr/checkAddresses/i, 'unsicherer Adressscan ist vollstaendig entfernt');
unlike($source, qr/Crypt::OpenSSL/, 'ungenutzte OpenSSL-Abhaengigkeit ist entfernt');
unlike($source, qr{://[^\s]+:[^\s]+\@}, 'Quellcode baut keine Credential-URLs');
unlike($source, qr/^sub Judo_(?:schedule_reconnect|reconnect_timer|clear_requests|start|
	schedule_heartbeat|heartbeat_timer|queue_get|enqueue_request|dispatch_next|
	Callback|parse_response|mark_failure)\b/mx,
	'Verbindungsfunktionen sind aus dem Hauptmodul ausgelagert');
unlike($source, qr/^sub Judo_(?:profile|get_descriptor|handle_success|apply_model)\b/m,
	'Laufzeitfunktionen sind aus dem Hauptmodul ausgelagert');
like($source, qr/id="Judo-heartbeat"/, 'Heartbeat ist in der Commandref dokumentiert');

my ($english_help) = $source =~ /=begin html\r?\n(.*?)\r?\n=end html\r?\n/s;
my ($german_help) = $source =~ /=begin html_DE\r?\n(.*?)\r?\n=end html_DE\r?\n/s;
ok(defined($english_help), 'englischer HTML-Hilfeblock ist vorhanden');
ok(defined($german_help), 'deutscher HTML-Hilfeblock ist vorhanden');
$english_help //= '';
$german_help //= '';

my %help_entries = (
	set => { map { $_ => 1 } qw(clearPassword password reconnect) },
	get => { map { $_ => 1 } qw(heartbeat model profile) },
	attr => { map { $_ => 1 } qw(interval timeout maxFailures username ssl disable) },
);
my $profiles = Judo::Profiles::profiles();

# Alle profilabhaengigen Befehle muessen dieselben kontextsensitiven Hilfeziele
# wie die immer verfuegbaren Verwaltungsbefehle erhalten.
for my $profile (values %$profiles) {

	# Set- und Get-Deskriptoren bleiben die verbindliche Quelle der FHEMWEB-Auswahl.
	for my $section (qw(set get)) {

		for my $command (keys %{ $profile->{$section} }) {
			$help_entries{$section}{$command} = 1;
		}

	}

}

# Beide Sprachvarianten muessen dieselben allgemeinen und spezifischen Anker
# fuer set, get und attr anbieten.
for my $language (
	[ 'EN', $english_help ],
	[ 'DE', $german_help ],
) {
	my ($label, $help) = @$language;

	# Jeder Hilfebereich benoetigt den allgemeinen FHEMWEB-Sprunganker.
	for my $section (qw(set get attr)) {
		like(
			$help,
			qr{<a id="Judo-\Q$section\E"></a>},
			"$label enthaelt den allgemeinen $section-Hilfeanker",
		);

		# Jeder auswaehlbare Wert muss direkt auf seinen Listeneintrag zeigen.
		for my $entry (sort keys %{ $help_entries{$section} }) {
			my $anchor = "Judo-$section-$entry";
			like(
				$help,
				qr{<a id="\Q$anchor\E"></a>\s*<li>},
				"$label enthaelt die kontextsensitive Hilfe fuer $section $entry",
			);
		}

	}

}

done_testing;
