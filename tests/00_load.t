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

done_testing;
