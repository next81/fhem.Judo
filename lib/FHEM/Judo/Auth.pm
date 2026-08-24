# Copyright (c) 2025-2026 Andreas Planer
# Repository: https://github.com/next81/fhem.Judo
# Licensed under the GNU General Public License v2.0 only

package Judo::Auth;

use strict;
use warnings;
use Encode qw(encode decode FB_CROAK);
use Exporter qw(import);

our @EXPORT_OK = qw(
	Judo_password_index Judo_password_key Judo_store_password
	Judo_read_password Judo_clear_password
);

# Meldet Passwortspeicherfehler ueber das zentrale Fehlerregister, ohne jemals
# Passwort- oder Schluesselmaterial in die Meldung aufzunehmen.
sub Judo_auth_record_issue($$$) {
	my ($hash, $message, $level) = @_;

	if (ref($hash->{helper}) eq 'HASH' && defined &main::Judo_record_issue) {
		main::Judo_record_issue($hash, 'passwordStorage', $message, undef, $level);
	} elsif (defined &main::Judo_log) {
		main::Judo_log($hash, $level, "password storage error: $message");
	}
	return;
}

# Entfernt einen zuvor gemeldeten Passwortspeicherfehler nach erfolgreichem
# Zugriff; ein fehlender Passwortwert selbst ist kein Speicherfehler.
sub Judo_auth_clear_issue($) {
	my ($hash) = @_;
	main::Judo_clear_issue($hash, 'passwordStorage')
		if ref($hash->{helper}) eq 'HASH' && defined &main::Judo_clear_issue;
	return;
}

# Liefert den instanzbezogenen Key-Value-Namen fuer das verschleierte Passwort.
sub Judo_password_index($) {
	my ($hash) = @_;
	return $hash->{TYPE} . '_' . $hash->{NAME} . '_passwd';
}

# Erzeugt den rotierenden XOR-Schluessel nach dem in FHEM-Modulen etablierten
# Key-Value-Muster. Dies ist Verschleierung, keine kryptographische Speicherung.
sub Judo_password_key($) {
	my ($hash) = @_;
	my $index = Judo_password_index($hash);
	my $key = main::getUniqueId() . $index;

	# Digest::MD5 ist in FHEM ueblich, bleibt aber fuer minimal installierte
	# Systeme optional.
	if (eval { require Digest::MD5; 1 }) {
		$key = Digest::MD5::md5_hex(unpack('H*', $key));
		$key .= Digest::MD5::md5_hex($key);
	}
	return $key;
}

# Speichert ein UTF-8-Passwort verschleiert im FHEM-Key-Value-Speicher.
sub Judo_store_password($$) {
	my ($hash, $password) = @_;
	my $key = Judo_password_key($hash);
	my $encoded = '';
	my $bytes = encode('UTF-8', $password);

	# Jedes Passwortbyte wird mit dem rotierenden instanzbezogenen Schluessel
	# verknuepft und als Hex gespeichert.
	for my $character (split //, $bytes) {
		my $mask = chop($key);
		$encoded .= sprintf('%.2x', ord($character) ^ ord($mask));
		$key = $mask . $key;
	}

	my $error = main::setKeyValue(Judo_password_index($hash), $encoded);

	# Schreibfehler sind kritisch, enthalten im Log aber niemals das Passwort.
	if (defined($error)) {
		Judo_auth_record_issue($hash, "Key-Value-Schreibfehler: $error", 1);
		return "Passwort konnte nicht gespeichert werden: $error";
	}
	Judo_auth_clear_issue($hash);
	return undef;
}

# Liest und entschleiert das Passwort ohne es zu protokollieren oder in einem
# sichtbaren Reading abzulegen.
sub Judo_read_password($) {
	my ($hash) = @_;
	my ($error, $encoded) = main::getKeyValue(Judo_password_index($hash));

	# Ein technischer Lesefehler wird von einem regulaer fehlenden Passwort
	# unterschieden und durch die Fehler-Deduplizierung nur einmal protokolliert.
	if (defined($error)) {
		Judo_auth_record_issue($hash, "Key-Value-Lesefehler: $error", 1);
		return undef;
	}
	if (!defined($encoded) || $encoded eq '') {
		Judo_auth_clear_issue($hash);
		return undef;
	}

	# Beschaedigte Speicherwerte werden ohne Ausgabe ihres Inhalts gemeldet.
	if ($encoded !~ /^(?:[0-9A-Fa-f]{2})+$/) {
		Judo_auth_record_issue($hash, 'Passwortspeicher enthaelt ungueltige Hexdaten', 1);
		return undef;
	}
	my $key = Judo_password_key($hash);
	my $bytes = '';

	# Die gespeicherten Hexbytes werden mit derselben Rotation zurueckgewandelt.
	for my $character (map { pack('C', hex($_)) } ($encoded =~ /(..)/g)) {
		my $mask = chop($key);
		$bytes .= chr(ord($character) ^ ord($mask));
		$key = $mask . $key;
	}
	my $password = eval { decode('UTF-8', $bytes, FB_CROAK) };

	# Nicht-UTF-8-Bestaende bleiben aus Kompatibilitaetsgruenden nutzbar, werden
	# aber als kontrollierte Warnung sichtbar gehalten.
	if (!defined($password)) {
		Judo_auth_record_issue(
			$hash, 'Passwortspeicher enthaelt keine gueltigen UTF-8-Daten; Kompatibilitaetsmodus aktiv', 2);
		return $bytes;
	}
	Judo_auth_clear_issue($hash);
	return $password;
}

# Entfernt den gespeicherten Passwortwert dieser Instanz.
sub Judo_clear_password($) {
	my ($hash) = @_;
	my $error = main::setKeyValue(Judo_password_index($hash), undef);

	# Loeschfehler bleiben sichtbar, ohne den bisherigen Speicherwert offenzulegen.
	if (defined($error)) {
		Judo_auth_record_issue($hash, "Key-Value-Loeschfehler: $error", 1);
		return "Passwort konnte nicht entfernt werden: $error";
	}
	Judo_auth_clear_issue($hash);
	return undef;
}

1;
