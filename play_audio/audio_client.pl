#!/usr/bin/perl
# (C) 2019 Pali

use 5.010;
use strict;
use warnings;

use Net::DBus qw(:typing);
use Net::DBus::Error;
use Net::DBus::Reactor;
use Net::DBus::RemoteService;
use Net::DBus::Service;

$| = 1;
$SIG{PIPE} = 'IGNORE';

open my $audio_file, 'demo.s16' or die print "Failed to open demo file";
print "Opened audio file: $audio_file\n";

my %sockets;

my $reactor = Net::DBus::Reactor->main();
my $bus = Net::DBus->system();
my $bus_object = $bus->get_bus_object();
main::Agent->new(main::Application->new(main::Service->new($bus), '/org/hsphfpd/application'), '/audio/pcm_agent');
my $hsphfpd_service = Net::DBus::RemoteService->new($bus, '', 'org.hsphfpd');
my $hsphfpd_manager = $hsphfpd_service->get_object('/', 'org.hsphfpd.ApplicationManager');
$bus_object->connect_to_signal('NameOwnerChanged', \&bus_name_owner_changed);
bus_name_owner_changed('org.hsphfpd', '', 'org.hsphfpd');
$reactor->run();
exit 0;

sub bus_name_owner_changed {
	my ($name, $old, $new) = @_;
	return unless $name eq 'org.hsphfpd';
	if ($old ne '') {
		shutdown $_, 2 foreach values %sockets;
		%sockets = ();
	}
	if ($new ne '') {
		eval { $hsphfpd_manager->RegisterApplication(dbus_object_path('/org/hsphfpd/application')); 1 } or print "Registering application failed: $@";
	}
}


package main::Service;
use parent 'Net::DBus::Service';
sub new { bless { bus => $_[1], service_name => $_[1]->get_unique_name(), objects => {} }, $_[0] }


package main::Application;
use parent 'Net::DBus::Object';
use Net::DBus::Exporter 'org.freedesktop.DBus.ObjectManager';
BEGIN {
	dbus_method('GetManagedObjects', [], [ [ 'dict', 'objectpath', [ 'dict', 'string', [ 'dict', 'string', [ 'variant' ] ] ] ] ], { strict_exceptions => 1, return_names => [ 'object_paths_interfaces_and_properties' ] });
	dbus_signal('InterfacesAdded', [ 'objectpath', [ 'dict', 'string', [ 'dict', 'string', [ 'variant' ] ] ] ], { param_names => [ 'object_path', 'interfaces_and_properties' ] });
	dbus_signal('InterfacesRemoved', [ 'objectpath', [ 'array', 'string' ] ], { param_names => [ 'object_path', 'interfaces' ] });
}
sub GetManagedObjects { { '/org/hsphfpd/application/audio/pcm_agent' => { 'org.hsphfpd.AudioAgent' => { AgentCodec => 'PCM_s16le_8kHz' } } } }


package main::Agent;
use parent 'Net::DBus::Object';
use Net::DBus::Exporter 'org.hsphfpd.AudioAgent';
BEGIN {
	dbus_method('NewConnection', [ 'caller', 'objectpath', 'unixfd', [ 'dict', 'string', [ 'variant' ] ] ], [], { strict_exceptions => 1, param_names => [ 'audio_transport', 'sco', 'properties' ] });
	dbus_property('AgentCodec', 'string', 'read', { strict_exceptions => 1 });
}
sub AgentCodec { 'PCM_s16le_8kHz' }
sub NewConnection {
	my ($self, $caller, $path, $fd, $properties) = @_;
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Canceled', message => qq(Cannot open supplied file descriptor "$fd": Bad file descriptor)) unless $fd =~ /^[0-9]+$/;
	# After successful open() call, $socket owns $fd and close($socket) would close also $fd
	open my $socket, '+<&=', $fd or die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Canceled', message => qq(Cannot open supplied file descriptor "$fd": $!));
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Rejected', message => qq(Caller "$caller" does not own "org.hsphfpd" service)) if ($bus->get_service_owner('org.hsphfpd') // '') ne $caller;
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Rejected', message => qq(Invalid object path)) unless defined $path and $path =~ m{^/};
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Rejected', message => qq(Invalid properties structure)) unless ref $properties eq 'HASH';
	my $mtu = $properties->{MTU};
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Rejected', message => qq(Invalid MTU value)) unless defined $mtu and $mtu =~ /^[1-9][0-9]*$/ and $mtu != 0;
	my $air_codec = $properties->{AirCodec};
	die Net::DBus::Error->new(name => 'org.hsphfpd.Error.Rejected', message => qq(Invalid AirCodec value)) unless defined $air_codec and $air_codec ne '';
	print "New connection: caller=$caller path=$path fd=$fd mtu=$mtu air_codec=$air_codec\n";

	my $close_connection = sub {
		print "Closing connection: path=$path\n";
		$reactor->remove_read(fileno $socket);
		$reactor->remove_exception(fileno $socket);
		shutdown $socket, 2;
		delete $sockets{$socket};
		close $socket;
		close $audio_file;
	};
	$reactor->add_write(fileno $socket, sub {
		my $ret;
		my $audio_samples;
		my $read_audio = sysread $audio_file, $audio_samples, $mtu;
		if (not $read_audio) {
			print "Reading data from Audio file " . (fileno $audio_file) . " failed: " . (defined $read_audio ? "End of file" : $!) . "\n";
			return $close_connection->();
		}
		$ret = syswrite $socket, $audio_samples;
		if (not defined $ret or $ret != length $audio_samples) {
			print "Writing data to SCO socket " . (fileno $socket) . " failed: " . (defined $ret ? "Written only $ret bytes of " . (length $audio_samples) . " bytes" : $!) . "\n";
			return $close_connection->();
		}
	});
	$reactor->add_read(fileno $socket, sub {
	    my $ret;
		my $soc_samples;
		my $read_soc = sysread $socket, $soc_samples, $mtu;
	});
	$reactor->add_exception(fileno $socket, $close_connection);
	$reactor->add_exception(fileno $audio_file, $close_connection);
	$sockets{$socket} = $socket;
}
