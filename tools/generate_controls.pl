#!/usr/bin/env perl

use strict;
use warnings;
use File::Find qw(find);
use File::Spec ();
use POSIX qw(strftime);

my $output = 'controls_Judo.txt';
my @files = ('FHEM/50_Judo.pm');

# Das Controlfile muss neben dem FHEM-Einstiegspunkt alle ausgelagerten
# Produktionsbibliotheken enthalten. Tests und Werkzeuge werden nicht verteilt.
find(
	{
		no_chdir => 1,
		wanted => sub {
			return if !-f $File::Find::name || $File::Find::name !~ /\.pm\z/;
			push @files, File::Spec->abs2rel($File::Find::name, '.');
		},
	},
	'lib/FHEM/Judo',
);

my %seen;

# Ermittelt die auf GitHub ausgelieferte LF-Bytelaenge unabhaengig vom Checkout.
sub delivery_size($) {
	my ($file) = @_;
	open my $input, '<:raw', $file
		or die "Kann $file nicht lesen: $!\n";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $file nicht schliessen: $!\n";
	$content =~ s/\r\n/\n/g;
	return length($content);
}

# Sortierung und Deduplizierung halten die Ausgabe reproduzierbar.
@files = sort grep { !$seen{$_}++ } @files;

open my $controls, '>:raw', $output
	or die "Kann $output nicht schreiben: $!\n";

# Jede Produktionsdatei wird als portable FHEM-UPD-Zeile geschrieben.
for my $file (@files) {
	my @stat = stat($file);
	die "Kann $file nicht lesen: $!\n" if !@stat;
	my $path = $file;
	$path =~ s{\\}{/}g;
	my $timestamp = strftime('%Y-%m-%d_%H:%M:%S', localtime($stat[9]));
	my $size = delivery_size($file);
	print {$controls} "UPD $timestamp $size $path\n";
}

close $controls or die "Kann $output nicht schliessen: $!\n";
print "$output mit " . scalar(@files) . " Dateien erzeugt.\n";
