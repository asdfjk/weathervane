# Copyright 2017-2019 VMware, Inc.
# SPDX-License-Identifier: BSD-2-Clause
package PostgresqlDockerService;

use Moose;
use MooseX::Storage;
use Parameters qw(getParamValue);
use POSIX;
use Log::Log4perl qw(get_logger);

use Services::Service;

use namespace::autoclean;

with Storage( 'format' => 'JSON', 'io' => 'File' );

extends 'Service';

has 'clearBeforeStart' => (
	is      => 'rw',
	isa     => 'Bool',
	default => 0,
);

override 'initialize' => sub {
	my ($self) = @_;

	super();
};

sub stopInstance {
	my ( $self, $logPath ) = @_;

	my $hostname         = $self->host->name;
	my $name             = $self->name;
	my $time     = `date +%H:%M`;
	chomp($time);
	my $logName          = "$logPath/StopPostgresqlDocker-$hostname-$name-$time.log";
	my $logger = get_logger("Weathervane::Services::PostgresqlDockerService");
	$logger->debug("stop PostgresqlDockerService");

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	$self->host->dockerStop( $applog, $name );

	close $applog;
}

override 'create' => sub {
	my ( $self, $logPath ) = @_;

	my $name             = $self->name;
	my $hostname         = $self->host->name;
	my $host         = $self->host;
	my $impl             = $self->getImpl();
	my $logger = get_logger("Weathervane::Services::PostgresqlService");

	my $time     = `date +%H:%M`;
	chomp($time);
	my $logName = "$logPath/Create" . ucfirst($impl) . "Docker-$hostname-$name-$time.log";
	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	# Map the log and data volumes to the appropriate host directories
	my %volumeMap;
	if ($self->getParamValue('postgresqlUseNamedVolumes') || $host->getParamValue('vicHost')) {
		$volumeMap{"/mnt"} = $self->getParamValue('postgresqlVolume');
	}

	my %envVarMap;
	$envVarMap{"POSTGRES_USER"}     = "auction";
	$envVarMap{"POSTGRES_PASSWORD"} = "auction";
	
	$envVarMap{"POSTGRESPORT"} = $self->internalPortMap->{$impl};

	if (   ( exists $self->dockerConfigHashRef->{'memory'} )
		&&  $self->dockerConfigHashRef->{'memory'}  )
	{
		my $memString = $self->dockerConfigHashRef->{'memory'};
		$logger->debug("docker memory is set to $memString, using this to tune postgres.");
		$memString =~ /(\d+)\s*(\w)/;
		$envVarMap{"POSTGRESTOTALMEM"} = $1;
		$envVarMap{"POSTGRESTOTALMEMUNIT"} = $2;
	} else {
		$envVarMap{"POSTGRESTOTALMEM"} = 0;
		$envVarMap{"POSTGRESTOTALMEMUNIT"} = 0;		
	}
	$envVarMap{"POSTGRESSHAREDBUFFERS"} = $self->getParamValue('postgresqlSharedBuffers');		
	$envVarMap{"POSTGRESSHAREDBUFFERSPCT"} = $self->getParamValue('postgresqlSharedBuffersPct');		
 	$envVarMap{"POSTGRESEFFECTIVECACHESIZE"} = $self->getParamValue('postgresqlEffectiveCacheSize');
 	$envVarMap{"POSTGRESEFFECTIVECACHESIZEPCT"} = $self->getParamValue('postgresqlEffectiveCacheSizePct');
 	$envVarMap{"POSTGRESMAXCONNECTIONS"} = $self->getParamValue('postgresqlMaxConnections');
 	
	# Create the container
	my %portMap;
	my $directMap = 0;

	my $cmd        = "";
	my $entryPoint = "";

	foreach my $key ( keys %{ $self->internalPortMap } ) {
		my $port = $self->internalPortMap->{$key};
		$portMap{$port} = $port;
	}
	$self->host->dockerRun( $applog, $name, $impl, $directMap, \%portMap, \%volumeMap, \%envVarMap,
		$self->dockerConfigHashRef, $entryPoint, $cmd, $self->needsTty );

	close $applog;
};

sub startInstance {
	my ( $self, $logPath ) = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");
	my $hostname         = $self->host->name;
	my $name             = $self->name;
	my $time     = `date +%H:%M`;
	chomp($time);
	my $logName          = "$logPath/StartPostgresqlDocker-$hostname-$name-$time.log";

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	my $portMapRef = $self->host->dockerPort($name);

	if ( $self->host->dockerNetIsHostOrExternal($self->getParamValue('dockerNet') )) {

		# For docker host networking, external ports are same as internal ports
		$self->portMap->{ $self->getImpl() } = $self->internalPortMap->{ $self->getImpl() };
	}
	else {

		# For bridged networking, ports get assigned at start time
		$self->portMap->{ $self->getImpl() } = $portMapRef->{ $self->internalPortMap->{ $self->getImpl() } };
	}
	
	close $applog;
}

override 'remove' => sub {
	my ( $self, $logPath ) = @_;

	my $name     = $self->name;
	my $hostname = $self->host->name;
	my $time     = `date +%H:%M`;
	chomp($time);
	my $logName  = "$logPath/RemovePostgresqlDocker-$hostname-$name-$time.log";

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	$self->host->dockerStopAndRemove( $applog, $name );

	close $applog;
};

sub clearDataBeforeStart {
	my ( $self, $logPath ) = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");
	my $name        = $self->name;
	$logger->debug("clearDataBeforeStart for $name");
	$self->clearBeforeStart(1);
}

sub clearDataAfterStart {
	my ( $self, $logPath ) = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");
	my $hostname    = $self->host->name;
	my $name        = $self->name;

	$logger->debug("clearDataAfterStart for $name");

	my $time     = `date +%H:%M`;
	chomp($time);
	my $logName = "$logPath/ClearDataPostgresql-$hostname-$name-$time.log";

	my $applog;
	open( $applog, ">$logName" ) or die "Error opening $logName:$!";
	print $applog "Clearing Data From PortgreSQL\n";

	my ($cmdFailed, $out) = $self->host->dockerExec($applog, $name, "/clearAfterStart.sh");
	if ($cmdFailed) {
		$logger->error("Error clearing old data as part of the data loading process.  Error = $cmdFailed");	
	}

	close $applog;

}

sub isUp {
	my ( $self, $fileout ) = @_;
	return $self->isRunning($fileout);

}

sub isRunning {
	my ( $self, $fileout ) = @_;
	my $name = $self->name;

	return $self->host->dockerIsRunning( $fileout, $name );

}

sub isStopped {
	my ( $self, $fileout ) = @_;
	my $name = $self->name;

	return !$self->host->dockerExists( $fileout, $name );
}

sub setPortNumbers {
	my ($self) = @_;

	my $serviceType    = $self->getParamValue('serviceType');
	my $impl           = $self->getParamValue( $serviceType . "Impl" );
	my $hostname = $self->host->name;
	my $portMultiplier = $self->appInstance->getNextPortMultiplierByHostnameAndServiceType($hostname,$serviceType);
	my $portOffset     = $self->getParamValue( $serviceType . 'PortStep' ) * $portMultiplier;
	$self->internalPortMap->{$impl} = $self->getParamValue('postgresqlPort') + $portOffset;
}

sub setExternalPortNumbers {
	my ($self) = @_;
	
	my $name = $self->name;
	my $portMapRef = $self->host->dockerPort($name);

	if ( $self->host->dockerNetIsHostOrExternal($self->getParamValue('dockerNet') )) {

		# For docker host networking, external ports are same as internal ports
		$self->portMap->{ $self->getImpl() } = $self->internalPortMap->{ $self->getImpl() };
	}
	else {

		# For bridged networking, ports get assigned at start time
		$self->portMap->{ $self->getImpl() } = $portMapRef->{ $self->internalPortMap->{ $self->getImpl() } };
	}
}

sub configure {
	my ( $self, $logPath, $users, $suffix ) = @_;

}

sub cleanData {
	my ($self, $users, $logHandle)   = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");
	my $name = $self->name;
	$logger->debug("cleanData");
	my ($cmdFailed, $out) = $self->host->dockerExec($logHandle, $name, "/cleanup.sh");
	if ($cmdFailed) {
		$logger->warn("Cleanup on PostgreSQL nodes failed: $cmdFailed");
		return 0;
	}
	return 1;
}

sub stopStatsCollection {
	my ($self)      = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");

	my $hostname    = $self->host->name;
	my $name        = $self->name;
	my $serviceType = $self->getParamValue('serviceType');
	my $impl        = $self->getParamValue( $serviceType . "Impl" );
	my $port        = $self->internalPortMap->{$impl};

	my $logName = "/tmp/PostgresqlStatsEndOfSteadyState-$hostname-$name.log";

	my $applog;
	open( $applog, ">$logName" ) or die "Error opening $logName:$!";
	print $applog "Getting end of steady-state stats from PortgreSQL\n";
	my ($cmdFailed, $out) = $self->host->dockerExec($applog, $name, "perl /dumpStats.pl");
	if ($cmdFailed) {
		$logger->error("Error collecting PostgreSQL stats.  Error = $cmdFailed");	
	}

	close $applog;

}

sub startStatsCollection {
	my ( $self, $intervalLengthSec, $numIntervals ) = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");

	my $hostname    = $self->host->name;
	my $name        = $self->name;
	my $serviceType = $self->getParamValue('serviceType');
	my $impl        = $self->getParamValue( $serviceType . "Impl" );
	my $port        = $self->internalPortMap->{$impl};

	my $logName = "/tmp/PostgresqlStartStatsCollection-$hostname-$name.log";

	my $applog;
	open( $applog, ">$logName" ) or die "Error opening $logName:$!";

	print $applog "Getting start of steady-state stats from PortgreSQL\n";
	my ($cmdFailed, $out) = $self->host->dockerExec($applog, $name, "perl /dumpStats.pl");
	if ($cmdFailed) {
		$logger->error("Error collecting PostgreSQL stats.  Error = $cmdFailed");	
	}

	close $applog;
}

sub getStatsFiles {
	my ( $self, $destinationPath ) = @_;
	my $hostname = $self->host->name;
	my $name     = $self->name;

	my $logName = "/tmp/PostgresqlStatsEndOfSteadyState-$hostname-$name.log";

	my $out = `cp $logName $destinationPath/. 2>&1`;

}

sub cleanStatsFiles {
	my ($self)   = @_;
	my $hostname = $self->host->name;
	my $name     = $self->name;

	my $logName = "/tmp/PostgresqlStatsEndOfSteadyState-$hostname-$name.log";

	my $out = `rm -f $logName 2>&1`;

}

sub getLogFiles {
	my ( $self, $destinationPath ) = @_;

	my $name     = $self->name;
	my $hostname = $self->host->name;

	my $logpath = "$destinationPath/$name";
	if ( !( -e $logpath ) ) {
		`mkdir -p $logpath`;
	}

	my $logName = "$logpath/PostgresqlDockerLogs-$hostname-$name.log";

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening $logName:$!";

	my $logContents = $self->host->dockerGetLogs( $applog, $name );

	print $applog $logContents;

	close $applog;

}

sub cleanLogFiles {
	my ($self)            = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlDockerService");
	$logger->debug("cleanLogFiles");

}

sub parseLogFiles {
	my ( $self, $host ) = @_;

}

sub getConfigFiles {
	my ( $self, $destinationPath ) = @_;

	my $name     = $self->name;
	my $hostname = $self->host->name;

	my $logpath = "$destinationPath/$name";
	if ( !( -e $logpath ) ) {
		`mkdir -p $logpath`;
	}

#	my $logName = "$logpath/GetConfigFilesPostgresqlDocker-$hostname-$name.log";

#	my $applog;
#	open( $applog, ">$logName" )
#	  || die "Error opening /$logName:$!";

#	$self->host->dockerCopyFrom( $applog, $name, "/mnt/dbData/postgresql/postgresql.conf", "$logpath/." );

#	close $applog;

}

sub getConfigSummary {
	my ($self) = @_;
	tie( my %csv, 'Tie::IxHash' );
	$csv{"postgresqlEffectiveCacheSize"} = $self->getParamValue('postgresqlEffectiveCacheSize');
	$csv{"postgresqlSharedBuffers"}      = $self->getParamValue('postgresqlSharedBuffers');
	$csv{"postgresqlMaxConnections"}     = $self->getParamValue('postgresqlMaxConnections');
	return \%csv;
}

sub getStatsSummary {
	my ( $self, $statsLogPath, $users ) = @_;
	tie( my %csv, 'Tie::IxHash' );
	%csv = ();
	return \%csv;
}

# Get the max number of users loaded in the database
sub getMaxLoadedUsers {
	my ($self) = @_;
	my $logger = get_logger("Weathervane::Services::PostgresqlService");

	my $logName          = "/dev/null";
	my $name        = $self->name;

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";
	
	my ($cmdFailed, $maxUsers) = $self->host->dockerExec($applog, $name, "psql -U auction  -t -q --command=\"select maxusers from dbbenchmarkinfo;\"");
	if ($cmdFailed) {
		$logger->error("Error Getting maxLoadedUsers from PostgreSQL.  Error = $cmdFailed");
	}
	chomp($maxUsers);
	$maxUsers += 0;
	
	close $applog;
	return $maxUsers;
}

__PACKAGE__->meta->make_immutable;

1;
