# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# Licensed under the GNU General Public License v2.0 only

package Judo::Runtime;

use strict;
use warnings;
use Exporter qw(import);
use Judo::Profiles qw(models profiles);
use Judo::Protocol qw(Judo_decode_model_id Judo_decode_data);

our @EXPORT_OK = qw(
	Judo_profile Judo_get_descriptor Judo_handle_success Judo_apply_model
);

# Die fachlichen Tabellen werden nur lesend verwendet und bleiben vollstaendig
# in Judo::Profiles definiert.
my %Judo_MODELS = %{ models() };
my %Judo_PROFILES = %{ profiles() };
my %Judo_COMMON_GET = (
	model => $Judo_PROFILES{soft_safe}{get}{model},
);

# Liefert das bereits erkannte Profil oder undef vor der Modellantwort.
sub Judo_profile($) {
	my ($hash) = @_;
	my $family = $hash->{helper}{family};
	return defined($family) ? $Judo_PROFILES{$family} : undef;
}

# Liefert einen Get-Deskriptor; FF00 bleibt als einziges Kommando auch ohne
# erkanntes Profil verfuegbar.
sub Judo_get_descriptor($$) {
	my ($hash, $command) = @_;
	return $Judo_COMMON_GET{model} if $command eq 'model';
	my $profile = Judo_profile($hash);
	return $profile ? $profile->{get}{$command} : undef;
}

# Markiert einen validen Request als Lebenszeichen und verarbeitet danach
# Modell, Decoder oder den erfolgreichen Set-Auftrag.
sub Judo_handle_success($$$) {
	my ($hash, $request, $data) = @_;
	my $previous_state = $hash->{READINGS}{state}{VAL} || '';
	main::Judo_clear_issue($hash, $request->{command});
	$hash->{helper}{last_success_epoch} = time;
	$hash->{helper}{heartbeat_failures} = 0;
	main::Judo_readings($hash, {
		availability => 'online', heartbeatFailures => 0,
		state => 'online',
	});
	main::Judo_log($hash, 2,
		"state $previous_state -> online command=$request->{command}")
		if $previous_state ne 'online';

	# FF00 bestimmt beim ersten Erfolg das Profil und dient spaeter als sicherer
	# Heartbeat samt Plausibilitaetspruefung der Modellnummer.
	if ($request->{command} eq 'model') {
		my ($model_id, $model_error) = Judo_decode_model_id($data);

		if ($model_error) {
			main::Judo_record_issue($hash, 'model', $model_error);
			main::Judo_reading($hash, 'state', 'error');
			return;
		}

		# Aendert sich die Modellnummer, werden noch wartende Kommandos des alten
		# Profils verworfen, bevor das neue Profil seine Initialwerte plant.
		if (!$hash->{helper}{family} || $hash->{helper}{model_id} != $model_id) {
			$hash->{helper}{queue} = [];
			Judo_apply_model($hash, $model_id);
		}

		if (($request->{reason} || '') eq 'heartbeat') {
			$hash->{helper}{heartbeat_count} =
				($hash->{helper}{heartbeat_count} || 0) + 1;
			main::Judo_readings($hash, {
				heartbeat => main::Judo_now_text(),
				heartbeatCount => $hash->{helper}{heartbeat_count},
			});
			main::Judo_log($hash, 4,
				"heartbeat completed count=$hash->{helper}{heartbeat_count}");
		}
		return;
	}

	# Lesekommandos duerfen Readings erst nach Laengen- und Formatpruefung setzen.
	if ($request->{mode} eq 'get') {
		my ($updates, $decode_error) = Judo_decode_data($hash, $request, $data);

		if ($decode_error) {
			main::Judo_record_issue($hash, $request->{command}, $decode_error);
			main::Judo_reading($hash, 'state', 'error');
			return;
		}
		main::Judo_readings($hash, $updates);
		main::Judo_log($hash, 5,
			"decoded command=$request->{command} readings="
				. join(',', sort keys %$updates));
		main::Judo_update_deltas($hash, $updates);
		return;
	}
	my $action = $request->{command};
	$action .= ' ' . $request->{display}
		if defined($request->{display}) && $request->{display} ne '';
	main::Judo_readings($hash, {
		lastAction => $action, lastActionTime => main::Judo_now_text(),
	});
	main::Judo_log($hash, 3, "set completed command=$request->{command}");
	my $refresh = $request->{descriptor}{refresh};

	# Ein gezielter Refresh wird als Folgeauftrag sichtbar, ohne Nutzdaten zu loggen.
	if (defined($refresh) && $refresh ne '') {
		main::Judo_log($hash, 4,
			"refresh scheduled source=$request->{command} command=$refresh");
		main::Judo_queue_get($hash, $refresh, 'refresh');
	}
	return;
}

# Ordnet eine Modellnummer einem Profil zu und startet danach nur dessen sichere
# initiale Lesekommandos.
sub Judo_apply_model($$) {
	my ($hash, $model_id) = @_;
	my $model = $Judo_MODELS{$model_id};
	$hash->{helper}{model_id} = $model_id;

	# Unbekannte Modelle bleiben per FF00 erreichbar, erhalten aber keinerlei
	# potentiell kollidierende Familienkommandos.
	if (!$model) {
		delete $hash->{helper}{family};
		main::Judo_readings($hash, {
			family => 'unsupported', model => "unknown ($model_id)", modelID => $model_id,
			state => 'unsupported',
		});
		main::Judo_record_issue(
			$hash, 'model', "Nicht unterstuetzter Judo-Geraetetyp $model_id");
		return;
	}
	$hash->{helper}{family} = $model->{family};
	main::Judo_clear_issue($hash, 'model');
	main::Judo_readings($hash, {
		family => $model->{family}, model => $model->{name}, modelID => $model_id,
	});
	my $profile = $Judo_PROFILES{ $model->{family} };
	main::Judo_log($hash, 2,
		"model=$model->{name} id=$model_id family=$model->{family} version=$main::Judo_VERSION");
	main::Judo_log($hash, 4,
		"initial requests family=$model->{family} count=" . scalar(@{ $profile->{init} }));

	# Die Initialwerte werden seriell und erst nach der Modellantwort abgefragt.
	for my $command (@{ $profile->{init} }) {
		main::Judo_queue_get($hash, $command, 'init');
	}

	return;
}

1;
