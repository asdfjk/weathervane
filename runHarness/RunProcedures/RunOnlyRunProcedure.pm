# Copyright 2017-2019 VMware, Inc.
# SPDX-License-Identifier: BSD-2-Clause
package RunOnlyRunProcedure;

use Moose;
use MooseX::Storage;
use WeathervaneTypes;
use Parameters qw(getParamValue);
use POSIX;
use JSON;
use Log::Log4perl qw(get_logger);
use Utils qw(callMethodOnObjectsParamListParallel1 callMethodOnObjectsParallel callBooleanMethodOnObjectsParallel callBooleanMethodOnObjectsParallel1 callMethodsOnObjectParallel);

use strict;

use namespace::autoclean;

with Storage( 'format' => 'JSON', 'io' => 'File' );

extends 'RunProcedure';

has '+name' => ( default => 'Run-Only', );

override 'initialize' => sub {
	my ( $self, $paramHashRef ) = @_;

	super();
};

override 'run' => sub {
	my ($self) = @_;
	my $console_logger = get_logger("Console");
	my $debug_logger = get_logger("Weathervane::RunProcedures::RunOnlyRunProcedure");
	my $majorSequenceNumberFile = $self->getParamValue('sequenceNumberFile');
	my $outputDir = $self->getParamValue('outputDir');
	my $tmpDir    = $self->getParamValue('tmpDir');

	# Add appender to the console log to put a copy in the tmpLog directory
	my $layout   = Log::Log4perl::Layout::PatternLayout->new("%d: %m%n");
	my $appender = Log::Log4perl::Appender->new(
		"Log::Dispatch::File",
		name     => "tmpdirConsoleFile",
		filename => "$tmpDir/console.log",
		mode     => "append",
	);
	$appender->layout($layout);
	$console_logger->add_appender($appender);

	# Get the major sequence number
	my $majorSeqNum;
	if ( -e "$majorSequenceNumberFile" ) {
		open SEQFILE, "<$majorSequenceNumberFile";
		$majorSeqNum = <SEQFILE>;
		close SEQFILE;
		$majorSeqNum--; #already incremented in weathervane.pl
	} else {
		print "Major sequence number file is missing.\n";
		exit -1;
	}
	# Get the minor sequence number of the next run
	my $minorSequenceNumberFile = "$tmpDir/minorsequence.num";
	my $minorSeqNum;
	if ( -e "$minorSequenceNumberFile" ) {
		open SEQFILE, "<$minorSequenceNumberFile";
		$minorSeqNum = <SEQFILE>;
		close SEQFILE;
		open SEQFILE, ">$minorSequenceNumberFile";
		my $nextSeqNum = $minorSeqNum + 1;
		print SEQFILE $nextSeqNum;
		close SEQFILE;
	}
	else {
		$minorSeqNum = 0;
		open SEQFILE, ">$minorSequenceNumberFile";
		my $nextSeqNum = 1;
		print SEQFILE $nextSeqNum;
		close SEQFILE;
	}
	my $seqnum = $majorSeqNum . "-" . $minorSeqNum;
	$self->seqnum($seqnum);

	my $prevRunMajorSeqNum = $majorSeqNum - 1;
	my $prevRunDir = "$outputDir/$prevRunMajorSeqNum";
	my $prevRunPrepareOnlyNumFile = "$prevRunDir/prepareOnly.num";
	my $checkDir;
	if ( -e "$prevRunPrepareOnlyNumFile" ) {
		open SEQFILE, "<$prevRunPrepareOnlyNumFile";
		my $prepareOnlyMinorSeqNum = <SEQFILE>;
		close SEQFILE;
		$checkDir = "$prevRunDir/$prepareOnlyMinorSeqNum";
		if ( !(-e "$checkDir") ) {
			print "Could not find prepareOnly dir to check users at $checkDir.\n";
			exit -1;
		}
	} else {
		print "Previous run at $prevRunDir does not have a prepareOnly.num file.\n";
		exit -1;
	}

	# Now send all output to new subdir 	
	$tmpDir = "$tmpDir/$minorSeqNum";
	if ( !( -e $tmpDir ) ) {
		`mkdir $tmpDir`;
	}

	# Make sure that no previous Benchmark processes are still running
	$debug_logger->debug("killOldWorkloadDrivers");
	$self->killOldWorkloadDrivers("/tmp");

	# Make sure that the services know their external port numbers
	$self->setExternalPortNumbers();

	# configure the workload driver
	my $ok = callBooleanMethodOnObjectsParallel1( 'configureWorkloadDriver',
		$self->workloadsRef, $tmpDir );
	if ( !$ok ) {
		$self->cleanupAfterFailure(
			"Couldn't configure the workload driver properly.  Exiting.",
			$seqnum, $tmpDir );
		my $runResult = RunResult->new(
			'runNum'     => $seqnum,
			'isPassable' => 0,
		);

		return $runResult;
	}
	
	# Check that the users are the same as the number from the prepareOnly phase
	if (!$self->checkUsersTxt($checkDir)) {
		exit;	
	}
	
	$console_logger->info("Starting run number $seqnum");

	# initialize the workload drivers
	$ok = $self->initializeWorkloads( $seqnum, $tmpDir );
	if ( !$ok ) {
		$self->cleanupAfterFailure(
			"Workload driver did not initialize properly.  Exiting.",
			$seqnum, $tmpDir );
		my $runResult = RunResult->new(
			'runNum'     => $seqnum,
			'isPassable' => 0,
		);

		return $runResult;

	}

	$ok = $self->runWorkloads( $seqnum, $tmpDir );
	if ( !$ok ) {
		$self->cleanupAfterFailure(
			"Workload driver did not start properly.  Exiting.",
			$seqnum, $tmpDir );
		my $runResult = RunResult->new(
			'runNum'     => $seqnum,
			'isPassable' => 0,
		);

		return $runResult;

	}

	## get stats that require services to be up

	# directory for logs related to start/stop/etc
	my $cleanupLogDir = $tmpDir . "/cleanupLogs";
	if ( !( -e $cleanupLogDir ) ) {
		`mkdir -p $cleanupLogDir`;
	}

	$console_logger->info(
"Stopping all services and collecting log and statistics files (if requested)."
	);

	## get the config files
	$self->getConfigFiles($tmpDir);

	## get the stats logs
	$self->getStatsFiles($tmpDir);

	## get the logs
	$self->getLogFiles($tmpDir);

	# Stop the workload drivers from driving load
	$self->stopWorkloads( $seqnum, $tmpDir );

	my $sanityPassed = 1;
	if ( $self->getParamValue('stopServices') ) {

		## stop the services
		$self->stopDataManager($cleanupLogDir);
		
		$sanityPassed = $self->sanityCheckServices($cleanupLogDir);
		if ($sanityPassed) {
			$console_logger->info("All Sanity Checks Passed");
		}
		else {
			$console_logger->info("Sanity Checks Failed");
		}

		my @tiers = qw(frontend backend data infrastructure);
		callMethodOnObjectsParamListParallel1( "stopServices", [$self], \@tiers, $cleanupLogDir );

		# clean up old logs and stats
		$self->cleanup($cleanupLogDir);
	}

	# Put a file in the output/seqnum directory with the run name
	open RUNNAMEFILE, ">$tmpDir/description.txt"
	  or die "Can't open $tmpDir/description.txt: $!";
	print RUNNAMEFILE $self->getParamValue('description') . "\n";
	close RUNNAMEFILE;

	# record all of the parameter values used in a file
	# Save the original value of users, but include the right value for this run
	`mkdir -p $tmpDir/configuration/workloadDriver`;
	my $json = JSON->new;
	$json = $json->pretty(1);
	my $configText = $json->encode( $self->origParamHashRef );
	open CONFIGVALUESFILE, ">$tmpDir/configuration/weathervane.config.asRun"
	  or die
	  "Can't open $tmpDir/configuration/workloadDriver/weathervane.config.asRun: $!";
	print CONFIGVALUESFILE $configText;
	close CONFIGVALUESFILE;

	## for each service and the workload driver, parse stats
	# and gather up the headers and values for the results csv
	my $csvHashRef = $self->getStatsSummary($seqnum, $tmpDir);

	# Shut down the drivers
	$self->shutdownDrivers( $seqnum, $tmpDir );

	# Todo: Add parsing of logs for errors
	# my $isRunError = $self->parseLogs()
	my $isRunError = 0;

	my $isPassed = $self->isPassed($tmpDir) && $sanityPassed;
	
	my $runResult = RunResult->new(
		'runNum'                => $seqnum,
		'isPassable'            => 1,
		'isPassed'              => $isPassed,
		'runNum'                => $seqnum,
		'resultsSummaryHashRef' => $csvHashRef,

		#		'metricsHashRef'        => $self->workloadDriver->getResultMetrics(),
		'isRunError' => $isRunError,
	);

	return $runResult;

};

__PACKAGE__->meta->make_immutable;

1;
