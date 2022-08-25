#!/usr/bin/perl

################################################################################
# report-parser - A Perl based tool to parse DMARC and TLS reports from an IMAP
# mailbox or from the filesystem, and insert the information into a database.
# ( Formerly known as imap-dmarcts )
#
# Copyright (C) 2016 TechSneeze.com and John Bieling
#
# Available at:
# https://github.com/techsneeze/dmarcts-report-parser
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of  MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
################################################################################

################################################################################
# The subroutines storeXMLInDatabase(), getDATAFromMessage(), storeJSONInDatabase()
# and getJSONFromMessage() are based on # John R. Levine's rddmarc
# (http://www.taugh.com/rddmarc/). The following special conditions apply to those
#  subroutines:
#
# Copyright 2012, Taughannock Networks. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or
# other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
################################################################################

# Always be safe
use strict;
use warnings;

# Use these modules
use Getopt::Long;
use IO::Compress::Gzip qw(gzip $GzipError);
#use Data::Dumper;
use Mail::IMAPClient;
use Mail::Mbox::MessageParser;
use MIME::Base64 qw(encode_base64);
use MIME::Words qw(decode_mimewords);
use MIME::Parser;
use MIME::Parser::Filer;
use XML::Simple;
use JSON;
use DBI;
use Socket;
use Socket6;
use PerlIO::gzip;
use File::Basename ();
use File::MimeInfo;
use IO::Socket::SSL;
#use IO::Socket::SSL 'debug3';



################################################################################
### usage ######################################################################
################################################################################

sub show_usage {
	print "\n";
	print " Usage: \n";
	print "    ./dmarcts-report-parser.pl [OPTIONS] [PATH] \n";
	print "\n";
	print " This script needs a configuration file called <dmarcts-report-parser.conf> in \n";
	print " the current working directory, which defines a database server with credentials \n";
	print " and (if used) an IMAP server with credentials. \n";
	print "\n";
	print " Additionaly, one of the following source options must be provided: \n";
	print "        -i : Read reports from messages on IMAP server as defined in the \n";
	print "             config file. \n";
	print "        -m : Read reports from mbox file(s) provided in PATH. \n";
	print "        -e : Read reports from MIME email file(s) provided in PATH. \n";
	print "        -x : Read reports from data file(s) provided in PATH. \n";
	print "        -z : Read reports from zip file(s) provided in PATH. \n";
	print "\n";
	print " The following optional options are allowed: \n";
	print "        -d : Print debug info. \n";
	print "        -r : Replace existing reports rather than skipping them. \n";
	print "  --delete : Delete processed message files (the raw data is stored in the \n";
	print "             database for later reference). \n";
	print "    --info : Print out number of data files or emails processed. \n";
	print "\n";
}





################################################################################
### main #######################################################################
################################################################################

# Define all possible configuration options.
our ($debug, $delete_reports, $delete_failed, $reports_replace, $maxsize_xml, $compress_xml, $raw_data_compress, $raw_data_max_size,
	$dbtype, $dbname, $dbuser, $dbpass, $dbhost, $dbport, $db_tx_support,
  $imapserver, $imapport, $imapuser, $imappass, $imapignoreerror, $imapssl, $imaptls, $imapmovefolder,
	$imapmovefoldererr, $imapreadfolder, $imapopt, $tlsverify, $processInfo);

# defaults
$maxsize_xml 	= 50000;
$dbtype = 'mysql';
$db_tx_support	= 1;

# used in messages
my $scriptname = $0;

# allowed values for the DB columns, also used to build the enum() in the
# CREATE TABLE statements in checkDatabase(), in order defined here
use constant ALLOWED_DISPOSITION => qw(
	none
	quarantine
	reject
	unknown
);
use constant ALLOWED_DKIM_ALIGN => qw(
	fail
	pass
	unknown
);
use constant ALLOWED_SPF_ALIGN => qw(
	fail
	pass
	unknown
);
use constant ALLOWED_DKIMRESULT => qw(
	none
	pass
	fail
	neutral
	policy
	temperror
	permerror
	unknown
);
use constant ALLOWED_SPFRESULT => qw(
	none
	neutral
	pass
	fail
	softfail
	temperror
	permerror
	unknown
);

# Load script configuration options from local config file. The file is expected
# to be in the current working directory.
my $conf_file = 'dmarcts-report-parser.conf';

# Get command line options.
my %options = ();
use constant { TS_IMAP => 0, TS_MESSAGE_FILE => 1, TS_XML_FILE => 2, TS_MBOX_FILE => 3, TS_ZIP_FILE => 4 };
GetOptions( \%options, 'd', 'r', 'x', 'm', 'e', 'i', 'z', 'delete', 'info', 'c' => \$conf_file );

# locate conf file or die
if ( -e $conf_file ) {
  #$conf_file = "./$conf_file";
} elsif( -e  (File::Basename::dirname($0) . "/$conf_file" ) ) {
	$conf_file = ( File::Basename::dirname($0) . "/$conf_file" );
} else {
	show_usage();
	die "$scriptname: Could not read config file '$conf_file' from current working directory or path (" . File::Basename::dirname($0) . ')'
}

# load conf file with error handling
if ( substr($conf_file, 0, 1) ne '/'  and substr($conf_file, 0, 1) ne '.') {
  $conf_file = "./$conf_file";
}
my $conf_return = do $conf_file;
die "$scriptname: couldn't parse $conf_file: $@" if $@;
die "$scriptname: couldn't do $conf_file: $!"    unless defined $conf_return;

# check config
if (!defined $imapreadfolder ) {
  die "$scriptname: \$imapreadfolder not defined. Check config file";
}
if (!defined $imapignoreerror ) {
  $imapignoreerror = 0;   # maintain compatibility to old version
}

# Evaluate command line options
my $source_options = 0;
our $reports_source;

if (exists $options{m}) {
	$source_options++;
	$reports_source = TS_MBOX_FILE;
}

if (exists $options{x}) {
	$source_options++;
	$reports_source = TS_XML_FILE;
}

if (exists $options{e}) {
	$source_options++;
	$reports_source = TS_MESSAGE_FILE;
}

if (exists $options{i}) {
	$source_options++;
	$reports_source = TS_IMAP;
}

if (exists $options{z}) {
	$source_options++;
	$reports_source = TS_ZIP_FILE;
}

if (exists $options{c}) {
	$source_options++;
}

if ($source_options > 1) {
	show_usage();
	die "$scriptname: Only one source option can be used (-i, -x, -m, -e or -z).\n";
} elsif ($source_options == 0) {
	show_usage();
	die "$scriptname: Please provide a source option (-i, -x, -m, -e or -z).\n";
}

if ($ARGV[0]) {
	if ($reports_source == TS_IMAP) {
		show_usage();
		die "$scriptname: The IMAP source option (-i) may not be used together with a PATH.\n";
	}
} else {
	if ($reports_source != TS_IMAP && $source_options == 1) {
		show_usage();
		die "$scriptname: The provided source option requires a PATH.\n";
	}
}

# Override config options by command line options.
if (exists $options{r}) {$reports_replace = 1;}
if (exists $options{d}) {$debug = 1;}
if (exists $options{delete}) {$delete_reports = 1;}
if (exists $options{info}) {$processInfo = 1;}

# Setup connection to database server.
our %dbx;
my $dbx_file = File::Basename::dirname($0) . "/dbx_$dbtype.pl";
my $dbx_return = do $dbx_file;
die "$scriptname: couldn't load DB definition for type $dbtype: $@" if $@;
die "$scriptname: couldn't load DB definition for type $dbtype: $!" unless defined $dbx_return;

my $dbh = DBI->connect("DBI:$dbtype:database=$dbname;host=$dbhost;port=$dbport",
	$dbuser, $dbpass)
or die "$scriptname: Cannot connect to database\n";
if ($db_tx_support) {
	$dbh->{AutoCommit} = 0;
}
checkDatabase($dbh);


# Process messages based on $reports_source.
if ($reports_source == TS_IMAP) {
	my $socketargs = '';
	my $processedReport = 0;

	# Disable verify mode for TLS support.
	if ($imaptls == 1) {
		if ( $tlsverify == 0 ) {
			print "use tls without verify servercert.\n" if $debug;
			$imapopt = [ SSL_verify_mode => SSL_VERIFY_NONE ];
		} else {
			print "use tls with verify servercert.\n" if $debug;
			$imapopt = [ SSL_verify_mode => SSL_VERIFY_PEER ];
		}
	# The whole point of setting this socket arg is so that we don't get the nasty warning
	} else {
		print "using ssl without verify servercert.\n" if $debug;
		$socketargs = [ SSL_verify_mode => SSL_VERIFY_NONE ];
	}

	print "connection to $imapserver with Ssl => $imapssl, User => $imapuser, Ignoresizeerrors => $imapignoreerror\n" if $debug;

	# Setup connection to IMAP server.
	my $imap = Mail::IMAPClient->new(
	  Server     => $imapserver,
	  Port       => $imapport,
	  Ssl        => $imapssl,
	  Starttls   => $imapopt,
	  Debug      => $debug,
	  Socketargs => $socketargs
	)
	# module uses eval, so we use $@ instead of $!
	or die "$scriptname: IMAP Failure: $@";

	# This connection is finished this way because of the tradgedy of exchange...
	$imap->User($imapuser);
	$imap->Password($imappass);
	$imap->connect();

	# Ignore Size Errors if we're using Exchange
	$imap->Ignoresizeerrors($imapignoreerror);

	# Set $imap to UID mode, which will force imap functions to use/return
	# UIDs, instead of message sequence numbers. UIDs are not allowed to
	# change during a session and are not allowed to be used twice. Looping
	# over message sequence numbers and deleting a msg in between could have
	# unwanted side effects.
	$imap->Uid(1);

	# How many msgs are we going to process?
	print "Processing ". $imap->message_count($imapreadfolder)." messages in folder <$imapreadfolder>.\n" if $debug;

	# Only select and search $imapreadfolder, if we actually
	# have something to do.
	if ($imap->message_count($imapreadfolder)) {
		# Select the mailbox to get messages from.
		$imap->select($imapreadfolder)
			or die "$scriptname: IMAP Select Error: $!";

		# Store each message as an array element.
		my @msgs = $imap->search('ALL')
			or die "$scriptname: Couldn't get all messages\n";

		# Loop through IMAP messages.
		foreach my $msg (@msgs) {
			my $filecontent;
			my $data_type;

			($filecontent, $data_type) = &getDATAFromMessage($imap->message_string($msg));
			my $processResult = processDATA(TS_MESSAGE_FILE, $filecontent, $msg, "IMAP message with UID #");
			$processedReport++;
			if ($processResult & 4) {
				# processDATA returns a value with database error bit enabled, do nothing at all!
				if ($imapmovefoldererr) {
					# if we can, move to error folder
					moveToImapFolder($imap, $msg, $imapmovefoldererr);
				} else {
					# do nothing at all
					next;
				}
			} elsif ($processResult & 2) {
				# processDATAprocessDATA returns a value with delete bit enabled.
				$imap->delete_message($msg)
				or warn "$scriptname: Could not delete IMAP message. [$@]\n";
			} elsif ($imapmovefolder) {
				if ($processResult & 1 || !$imapmovefoldererr) {
					# processDATA processed the XML OK, or it failed and there is no error imap folder
					moveToImapFolder($imap, $msg, $imapmovefolder);
				} elsif ($imapmovefoldererr) {
					# processDATA failed and error folder set
					moveToImapFolder($imap, $msg, $imapmovefoldererr);
				}
			} elsif ($imapmovefoldererr && !($processResult & 1)) {
				# processDATA failed, error imap folder set, but imapmovefolder unset. An unlikely setup, but still...
				moveToImapFolder($imap, $msg, $imapmovefoldererr);
			}
		}

		# Expunge and close the folder.
		$imap->expunge($imapreadfolder);
		$imap->close($imapreadfolder);
	}

	# We're all done with IMAP here.
	$imap->logout();
	if ( $debug || $processInfo ) { print "$scriptname: Processed $processedReport emails.\n"; }

} else { # TS_MBOX_FILE, TS_ZIP_FILE, TS_MESSAGE_FILE or TS_XML_FILE

	my $counts = 0;
# mimetypes test routine
# 	foreach my $a (@ARGV) {
# 		my @file_list = glob($a);
# 		foreach my $f (@file_list) {
# 			my $mtype = mimetype($f);
# 			print "File: $f MType: $mtype\n";
# 		}
# }

	foreach my $a (@ARGV) {
		# Linux bash supports wildcard expansion BEFORE the script is
		# called, so here we only see a list of files. Other OS behave
		# different, so we should not depend on that feature: Use glob
		# on each argument to manually expand the argument, if possible.
		my @file_list = glob($a);

		foreach my $f (@file_list) {
			my $filecontent;
			my $data_type = "";

			if ($reports_source == TS_MBOX_FILE) {
				my $parser = Mail::Mbox::MessageParser->new({"file_name" => $f, "debug" => $debug, "enable_cache" => 0});
				my $num = 0;
				do {
					$num++;
					$filecontent = $parser->read_next_email();
					if (defined($filecontent)) {
						($filecontent, $data_type) = &getDATAFromMessage($filecontent);
						if (processDATA(TS_MESSAGE_FILE, $filecontent, $f, "message #$num of mbox file <$f>") & 2) {
							# processDATAprocessDATA returns a value with delete bit enabled
							warn "$scriptname: Removing message #$num from mbox file <$f> is not yet supported.\n";
						}
						$counts++;
					}
				} while(defined($filecontent));

			} elsif ($reports_source == TS_ZIP_FILE) {
				# filecontent is zip file
				($filecontent, $data_type) = &getDATAFromZip($f);
				if (processDATA(TS_ZIP_FILE, $filecontent, $f, "$data_type file ") & 2) {
					# processDATAprocessDATA returns a value with delete bit enabled
					unlink($f);
				}
				$counts++;
			} elsif (open(FILE, "<", $f)) {

				if ($reports_source == TS_MESSAGE_FILE) {
					# filecontent is a mime message with zip or xml part
					$filecontent = join("", <FILE>);
					($filecontent, $data_type) = &getDATAFromMessage($filecontent);
					if (processDATA(TS_MESSAGE_FILE, $filecontent, $f, "$data_type file ") & 2) {
						# processDATAprocessDATA returns a value with delete bit enabled
						unlink($f);
					}
					$counts++;
				} elsif ($reports_source == TS_XML_FILE) {
					# filecontent is xml file
					($filecontent, $data_type) = &getDATAFromFile($f);
					if (processDATA(TS_XML_FILE, $filecontent, $f, "$data_type file ") & 2) {
						# processDATAprocessDATA returns a value with delete bit enabled
						unlink($f);
					}
					$counts++;
				} else {
					warn "$scriptname: Unknown reports_source <$reports_source> for file <$f>. Skipped.\n";
				}
				close FILE;

			} else {
				warn "$scriptname: Could not open file <$f>: $!. Skipped.\n";
				# Could not retrieve filecontent, the skipped message
				# will be processed every time the script is run even if
				# delete_reports and delete_failed is given. The user
				# has to look at the actual file.
			}
		}
	}
	if ($debug || $processInfo) { print "$scriptname: Processed $counts messages(s).\n"; }
}



################################################################################
### subroutines ################################################################
################################################################################

sub moveToImapFolder {
	my $imap = $_[0];
	my $msg = $_[1];
	my $imapfolder = $_[2];

	print "Moving (copy and delete) IMAP message file to IMAP folder: $imapfolder\n" if $debug;

	# Try to create $imapfolder, if it does not exist.
	if (!$imap->exists($imapfolder)) {
		$imap->create($imapfolder)
		or warn "$scriptname: Could not create IMAP folder: $imapfolder.\n";
	}

	# Try to move the message to $imapfolder.
	my $newid = $imap->copy($imapfolder, [ $msg ]);
	if (!$newid) {
		warn "$scriptname: Error on moving (copy and delete) processed IMAP message: Could not COPY message to IMAP folder: <$imapfolder>!\n";
		warn "$scriptname: Messsage will not be moved/deleted. [$@]\n";
	} else {
		$imap->delete_message($msg)
		or do {
			warn "$scriptname: Error on moving (copy and delete) processed IMAP message: Could not DELETE message\n";
			warn "$scriptname: after copying it to <$imapfolder>. [$@]\n";
		}
	}
}

sub processDATA {
	my ($type, $filecontent, $f, $data_type) = (@_);

	if ($debug) {
		print "\n";
		print "----------------------------------------------------------------\n";
		print "Processing $data_type $f \n";
		print "----------------------------------------------------------------\n";
		print "Type: $type\n";
		print "FileContent: $filecontent\n";
		print "MSG: $f\n";
		print "----------------------------------------------------------------\n";
	}

	# my $data; #TS_XML_FILE or TS_MESSAGE_FILE
	# if ($type == TS_MESSAGE_FILE) {
	# 	# ($data, $data_type) = &getDATAFromMessage($filecontent);
	# 	$data = $filecontent;
	# } elsif ($type == TS_ZIP_FILE) {
	# 	$data = $filecontent;
	# } else { #TS_
	# 	$data = $filecontent;
	# }

	# If !$filecontent, the file/mail is probably not a DMARC report.
	# So do not storeXMLInDatabase.
	if ($filecontent && storeDATAInDatabase($filecontent) <= 0) {
		# If storeXMLInDatabase returns false, there was some sort
		# of database storage failure and we MUST NOT delete the
		# file, because it has not been pushed into the database.
		# The user must investigate this issue.
		warn "$scriptname: Skipping $f due to database errors.\n";
		return 5; #xml ok(1), but database error(4), thus no delete (!2)
	}

	# Delete processed message, if the --delete option
	# is given. Failed reports are only deleted, if delete_failed is given.
	if ($delete_reports && ($filecontent || $delete_failed)) {
		if ($filecontent) {
			print "Removing after report has been processed.\n" if $debug;
			return 3; #xml ok (1), delete file (2)
		} else {
			# A mail which does not look like a DMARC report
			# has been processed and should now be deleted.
			# Print its content so it gets send as cron
			# message, so the user can still investigate.
			warn "$scriptname: The $f does not seem to contain a valid DMARC report. Skipped and Removed. Content:\n";
			warn $filecontent."\n";
			return 2; #xml not ok (!1), delete file (2)
		}
	}

	if ($filecontent) {
		return 1;
	} else {
		warn "$scriptname: The $f does not seem to contain a valid DMARC report. Skipped.\n";
		return 0;
	}
}


################################################################################

# Walk through a mime message and return a reference to the data containing
# the fields of the first ZIPed file embedded into the message. The data
# itself is not checked to be a valid DMARC report.
sub getDATAFromMessage {
	my ($message) = (@_);

	# fixup type in trustwave SEG mails
        $message =~ s/ContentType:/Content-Type:/;

	my $parser = new MIME::Parser;
	$parser->output_dir("/tmp");
	$parser->filer->ignore_filename(1);
	my $ent = $parser->parse_data($message);

	my $body = $ent->bodyhandle;
	my $mtype = $ent->mime_type;
	my $subj = decode_mimewords($ent->get('subject'));
	chomp($subj); # Subject always contains a \n.

	if ($debug) {
		print "Subject: $subj\n";
		print "MimeType: $mtype\n";
	}

	my $location;
	my $isgzip = 0;

	if(lc $mtype eq "application/zip") {
		if ($debug) {
			print "This is a ZIP file \n";
		}

		$location = $body->path;

		} elsif (lc $mtype eq "application/gzip" or lc $mtype eq "application/x-gzip" or lc $mtype eq "application/tlsrpt+gzip") {
		if ($debug) {
			print "This is a GZIP file \n";
		}

		$location = $body->path;
		$isgzip = 1;

	} elsif (lc $mtype eq "multipart/mixed" or lc $mtype eq "multipart/report") {
		# At the moment, nease.net messages are multi-part, so we need
		# to breakdown the attachments and find the zip.
		if ($debug) {
			print "This is a multipart attachment \n";
		}
		#print Dumper($ent->parts);

		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
			my $part = $ent->parts($i);

			# Find a zip file to work on...
			if(lc $part->mime_type eq "application/gzip" or lc $part->mime_type eq "application/x-gzip" or lc $part->mime_type eq "application/tlsrpt+gzip") {
				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				$isgzip = 1;
				print "$location\n" if $debug;
				last; # of parts
			} elsif(lc $part->mime_type eq "application/x-zip-compressed"
				or $part->mime_type eq "application/zip") {

				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				print "$location\n" if $debug;
			} elsif(lc $part->mime_type eq "application/octet-stream") {
				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				$isgzip = 1 if $location =~ /\.gz$/;
				print "$location\n" if $debug;
			} else {
				# Skip the attachment otherwise.
				if ($debug) {
					print "Skipped an unknown attachment (".lc $part->mime_type.")\n";
				}
				next; # of parts
			}
		}
	} else {
		## Clean up dangling mime parts in /tmp of messages without ZIP.
		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
			if ($debug) {
				if ($ent->parts($i)->{ME_Bodyhandle} && $ent->parts($i)->{ME_Bodyhandle}->{MB_Path}) {
					print $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				} else {
					print "undef";
				}
				print "\n";
			}
			if($ent->parts($i)->{ME_Bodyhandle}) {$ent->parts($i)->{ME_Bodyhandle}->purge;}
		}
	}

	# Set up a default return value, in case something goes wrong
	my @ret_arr = ("", "");

	# If a ZIP has been found, extract data and parse it.
	if(defined($location)) {
		if ($debug) {
			print "body is in " . $location . "\n";
		}

		# Open the zip file and process the data contained inside.
		my $unzip = "";
		if($isgzip) {
			open(DATA, "<:gzip", $location)
			or $unzip = "ungzip";
		} else {
			open(DATA, "-|", "unzip", "-p", $location)
			or $unzip = "unzip"; # Will never happen.

			# Sadly unzip -p never failes, but we can check if the
			# filehandle points to an empty file and pretend it did
			# not open/failed.
			if (eof DATA) {
				$unzip = "unzip";
			}
		}

		# Read data if possible (if open)
		if ($unzip eq "") {
			my $report_data = "";
			my $raw_data = join("", <DATA>);
			close DATA;
			$report_data = getXMLFromXMLString($raw_data);
			if ($report_data) {
				@ret_arr = ($report_data, "xml");
			} else {
				if ($debug) {
					warn "$scriptname: Subject: $subj\n:";
					warn "$scriptname: The data found in ZIP file (temp. location: <$location>) does not seem to be valid XML! Let's try JSON...\n";
				}

				$report_data = getJSONFromJSONString($raw_data);
				if ($report_data) {
					if ($debug) {
						warn "$scriptname: The data found in ZIP file seems to be valid JSON!\n";
					}
					@ret_arr = ($report_data, "json");
				} elsif ($debug) {
					warn "$scriptname: The data found in ZIP file (temp. location: <$location>) does not seem to be valid JSON either! \n";
				}
			}
		} else {
			warn "$scriptname: Subject: $subj\n:";
			warn "$scriptname: Failed to $unzip ZIP file (temp. location: <$location>)! \n";
			close DATA;
		}
	} else {
		warn "$scriptname: Subject: $subj\n:";
		warn "$scriptname: Could not find an embedded ZIP! \n";
	}

	if($body) {$body->purge;}
	if($ent) {$ent->purge;}

	return @ret_arr;
}

################################################################################

sub getDATAFromZip {
	my $filename = $_[0];
	my $mtype = mimetype($filename);

	if ($debug) {
		print "Filename: $filename, MimeType: $mtype\n";
	}

	my $isgzip = 0;

	if(lc $mtype eq "application/zip") {
		if ($debug) {
			print "This is a ZIP file \n";
		}
	} elsif (lc $mtype eq "application/gzip" or lc $mtype eq "application/x-gzip") {
		if ($debug) {
			print "This is a GZIP file \n";
		}

		$isgzip = 1;
	} else {
		if ($debug) {
			print "This is not an archive file \n";
		}
	}

	# Set up a default return value, in case something goes wrong
	my @ret_arr = ("", "");

	# If a ZIP has been found, extract DATA and parse it.
	if(defined($filename)) {
		# Open the zip file and process the DATA contained inside.
		my $unzip = "";
		if($isgzip) {
			open(DATA, "<:gzip", $filename)
			or $unzip = "ungzip";
		} else {
			open(DATA, "-|", "unzip", "-p", $filename)
			or $unzip = "unzip"; # Will never happen.

			# Sadly unzip -p never fails, but we can check if the
			# filehandle points to an empty file and pretend it did
			# not open/failed.
			if (eof DATA) {
				$unzip = "unzip";
			}
		}

		# Read DATA if possible (if open)
		if ($unzip eq "") {
			my $report_data = "";
			my $raw_data = join("", <DATA>);
			close DATA;
			$report_data = getXMLFromXMLString($raw_data);
			if ($report_data) {
				@ret_arr = ($report_data, "xml");
			} else {
				if ($debug) {
					warn "$scriptname: The data found in ZIP file does not seem to be valid XML! Let's try JSON... \n";
				}

				$report_data = getJSONFromJSONString($raw_data);
				if ($report_data) {
					if ($debug) {
						warn "$scriptname: The data found in ZIP file seems to be valid JSON!\n";
					}
					@ret_arr = ($report_data, "json");
				} elsif ($debug) {
					warn "$scriptname: The data found in ZIP file does not seem to be valid JSON, either! \n";
				}
			}
		} else {
			warn "$scriptname: Failed to $unzip ZIP file (<$filename>)! \n";
			close DATA;
		}
	} else {
		warn "$scriptname: Could not find an <$filename>! \n";
	}

	return @ret_arr;
}

################################################################################

sub getDATAFromFile {
	my $filename = $_[0];
	my $mtype = mimetype($filename);

	if ($debug) {
		print "Filename: $filename, MimeType: $mtype\n";
	}

	# my $isgzip = 0;

	if(lc $mtype eq "application/xml") {
		if ($debug) {
			print "This is an XML file \n";
		}
	} elsif (lc $mtype eq "application/json") {
		if ($debug) {
			print "This is a JSON file \n";
		}
		# $isgzip = 1;
	} else {
		if ($debug) {
			print "This is not an archive file \n";
		}
	}

	# Set up a default return value, in case something goes wrong
	my @ret_arr = ("", "");

	# If a XML or JSON has been found, extract DATA and parse it.
	if(defined($filename)) {
		# Read DATA if possible (if open)
		open(DATA, "<", $filename);
		my $report_data = "";
		my $raw_data = join("", <DATA>);
		close DATA;
		$report_data = getXMLFromXMLString($raw_data);
		if ($report_data) {
			@ret_arr = ($report_data, "xml");
		} else {
			if ($debug) {
				warn "$scriptname: The data found in ZIP file does not seem to be valid XML! Let's try JSON... \n";
			}

			$report_data = getJSONFromJSONString($raw_data);
			if ($report_data) {
				if ($debug) {
					warn "$scriptname: The data found in ZIP file seems to be valid JSON!\n";
				}
				@ret_arr = ($report_data, "json");
			} elsif ($debug) {
					warn "$scriptname: The data found in ZIP file does not seem to be valid JSON, either! \n";
			}
		}
	} else {
		warn "$scriptname: Could not find an <$filename>! \n";
	}

	return @ret_arr;
}

################################################################################

sub getXMLFromXMLString {
	my $raw_xml = $_[0];

	eval {
		my $xs = XML::Simple->new();
		my $ref = $xs->XMLin($raw_xml, SuppressEmpty => '');
		$ref->{'raw_xml'} = $raw_xml;

		return $ref;
	} or do {
		return undef;
	}
}


################################################################################

sub getJSONFromJSONString {
	my $raw_json = $_[0];

	eval {
		my $ref = decode_json($raw_json);
		$ref->{'raw_json'} = $raw_json;

		return $ref;
	} or do {
		return undef;
	}
}


################################################################################

sub storeDATAInDatabase {
	my $raw_data = $_[0];

	my $database_return_value = 0;

	if ( $raw_data->{'report_metadata'}->{'org_name'} ) {
		$database_return_value = storeXMLInDatabase($raw_data);
	} else {
		$database_return_value = storeJSONInDatabase($raw_data);
	}
	return $database_return_value;
}


################################################################################

# Extract fields from the XML report data hash and store them into the database.
# return 1 when ok, 0, for serious error and -1 for minor errors
sub storeXMLInDatabase {
	my $xml = $_[0]; # $xml is a reference to the xml data

	my $from = $xml->{'report_metadata'}->{'date_range'}->{'begin'};
	my $to = $xml->{'report_metadata'}->{'date_range'}->{'end'};
	my $org = $xml->{'report_metadata'}->{'org_name'};
	my $id = $xml->{'report_metadata'}->{'report_id'};
	my $email = $xml->{'report_metadata'}->{'email'};
	my $extra = $xml->{'report_metadata'}->{'extra_contact_info'};
        my $domain  = undef;
        my $policy_adkim = undef;
        my $policy_aspf = undef;
        my $policy_p = undef;
        my $policy_sp = undef;
        my $policy_pct = undef;

        if (ref $xml->{'policy_published'} eq "HASH") {
                $domain =  $xml->{'policy_published'}->{'domain'};
                $policy_adkim = $xml->{'policy_published'}->{'adkim'};
                $policy_aspf = $xml->{'policy_published'}->{'aspf'};
                $policy_p = $xml->{'policy_published'}->{'p'};
                $policy_sp = $xml->{'policy_published'}->{'sp'};
                $policy_pct = $xml->{'policy_published'}->{'pct'};
         } else {
                $domain =  $xml->{'policy_published'}[0]->{'domain'};
                $policy_adkim = $xml->{'policy_published'}[0]->{'adkim'};
                $policy_aspf = $xml->{'policy_published'}[0]->{'aspf'};
                $policy_p = $xml->{'policy_published'}[0]->{'p'};
                $policy_sp = $xml->{'policy_published'}[0]->{'sp'};
                $policy_pct = $xml->{'policy_published'}[0]->{'pct'};
        }

	my $record = $xml->{'record'};
	if ( ! defined($record) ) {
		warn "$scriptname: $org: $id: No records in report. Skipped.\n";
		return 0;
	}

	# see if already stored
	my $sth = $dbh->prepare(qq{SELECT org, serial FROM report WHERE reportid=?});
	$sth->execute($id);
	while ( my ($xorg,$sid) = $sth->fetchrow_array() )
	{
		if ($reports_replace) {
			# $sid is the serial of a report with reportid=$id
			# Remove this $sid from rptrecord and report table, but
			# try to continue on failure rather than skipping.
			print "$scriptname: $org: $id: Replacing data.\n";
			$dbh->do(qq{DELETE from rptrecord WHERE serial=?}, undef, $sid);
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot remove report data from database. Try to continue.\n";
			}
			$dbh->do(qq{DELETE from report WHERE serial=?}, undef, $sid);
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot remove report from database. Try to continue.\n";
			}
		} else {
			print "$scriptname: $org: $id: Already have report, skipped\n";
			# Do not store in DB, but return true, so the message can
			# be moved out of the way, if configured to do so.
			return 1;
		}
	}

	my $sql = qq{
		INSERT INTO report
		(
			mindate,
			maxdate,
			domain,
			org,
			reportid,
			email,
			extra_contact_info,
			policy_adkim,
			policy_aspf,
			policy_p,
			policy_sp,
			policy_pct,
			raw_xml
		)
		VALUES
		(
			$dbx{epoch_to_timestamp_fn}(?),
			$dbx{epoch_to_timestamp_fn}(?),
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?
		)
	};

	my $storexml = $xml->{'raw_xml'};
	if ($raw_data_compress) {
		my $gzipdata;
		if(!gzip(\$storexml => \$gzipdata)) {
			warn "$scriptname: $org: $id: Cannot add gzip XML to database ($GzipError). Skipped.\n";
			rollback($dbh);
			return 0;
			$storexml = "";
		} else {
			$storexml = encode_base64($gzipdata, "");
		}
	}
	if (length($storexml) > $raw_data_max_size) {
		warn "$scriptname: $org: $id: Skipping storage of large XML (".length($storexml)." bytes) as defined in config file.\n";
		$storexml = "";
	}
	$dbh->do($sql, undef, $from, $to, $domain, $org, $id, $email, $extra, $policy_adkim, $policy_aspf, $policy_p, $policy_sp, $policy_pct, $storexml);
	if ($dbh->errstr) {
		warn "$scriptname: $org: $id: Cannot add report to database. Skipped.\n";
		rollback($dbh);
		return 0;
	}

	my $serial = $dbh->last_insert_id(undef, undef, 'report', undef);
	if ($debug){
		print " serial $serial \n";
	}

	################################################################################
	sub do_xml_row($$$$) {
		my ($serial,$recp,$org,$id) = @_;
		my %r = %$recp;

		my $ip = $r{'row'}->{'source_ip'};
		if ( $ip eq '' ) {
			warn "$scriptname: $org: $id: source_ip is empty. Skipped.\n";
			rollback($dbh);
			return 0;
		}
		my $count = $r{'row'}->{'count'};
		my $disp = $r{'row'}->{'policy_evaluated'}->{'disposition'};
		if ( ! grep { $_ eq $disp } ALLOWED_DISPOSITION ) {
			$disp = 'unknown';
		};
		 # some reports don't have dkim/spf, "unknown" is default for these
		my $dkim_align = $r{'row'}->{'policy_evaluated'}->{'dkim'};
		if ( ! grep { $_ eq $dkim_align } ALLOWED_DKIM_ALIGN ) {
			$dkim_align = 'unknown';
		};
		my $spf_align = $r{'row'}->{'policy_evaluated'}->{'spf'};
		if ( ! grep { $_ eq $spf_align } ALLOWED_SPF_ALIGN ) {
			$spf_align = 'unknown';
		};

		my $identifier_hfrom = $r{'identifiers'}->{'header_from'};

		my ($dkim, $dkimresult, $spf, $spfresult, $reason);
		if(ref $r{'auth_results'} ne "HASH"){
			warn "$scriptname: $org: $id: Report has no auth_results data. Skipped.\n";
			rollback($dbh);
			return 0;
		}
		my $rp = $r{'auth_results'}->{'dkim'};
		if(ref $rp eq "HASH") {
			$dkim = $rp->{'domain'};
			$dkim = undef if ref $dkim eq "HASH";
			$dkimresult = $rp->{'result'};
		} else { # array, i.e. multiple dkim results (usually from multiple domains)
			# glom sigs together
			$dkim = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"?"": $d } @$rp;
			# report results
			my $rp_len = scalar(@$rp);
			for ( my $i=0; $i < $rp_len; $i++ ) {
				if ( $rp->[$i]->{'result'} eq "pass" ) {
					# If any one dkim result is a "pass", this should yield an overall "pass" and immediately exit the for loop, ignoring any remaing results
					# See
					# RFC 6376, DomainKeys Identified Mail (DKIM) Signatures
					# 	Section 4.2: https://tools.ietf.org/html/rfc6376#section-4.2 and
					# 	Section 6.1: https://tools.ietf.org/html/rfc6376#section-6.1
					# And the GitHub issues at
					#	https://github.com/techsneeze/dmarcts-report-viewer/issues/47
					#	https://github.com/techsneeze/dmarcts-report-parser/pull/78
					$dkimresult = "pass";
					last;
				} else {
					for ( my $j=$i+1; $j < $rp_len; $j++ ) {
						if ( $rp->[$i]->{'result'} eq $rp->[$j]->{'result'} ) {
						# Compare each dkim result to the next one to see if all of the dkim results are the same.
						# If all of the dkim results are the same, that will be the overall result.
						# If any of them are different, and don't contain a "pass" result, then $dkimresult will be empty
							$dkimresult = $rp->[0]->{'result'};
						} else {
							$dkimresult = 'unknown';
						}
					}
				}
			}
		}
		if ( ! defined($dkimresult) || ! grep { $_ eq $dkimresult } ALLOWED_DKIMRESULT ) {
			$dkimresult = 'unknown';
		};

		$rp = $r{'auth_results'}->{'spf'};
		if(ref $rp eq "HASH") {
			$spf = $rp->{'domain'};
			$spf = undef if ref $spf eq "HASH";
			$spfresult = $rp->{'result'};
		} else { # array, i.e. multiple dkim results (usually from multiple domains)
			# glom sigs together
			$spf = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"?"": $d } @$rp;
			# report results
			my $rp_len = scalar(@$rp);
			for ( my $i=0; $i < $rp_len; $i++ ) {
				if ( $rp->[$i]->{'result'} eq "pass" ) {
					# If any one spf result is a "pass", this should yield an overall "pass" and immediately exit the for loop, ignoring any remaing results
					$spfresult = "pass";
					last;
				} else {
					for ( my $j=$i+1; $j < $rp_len; $j++ ) {
						if ( $rp->[$i]->{'result'} eq $rp->[$j]->{'result'} ) {
						# Compare each spf result to the next one to see if all of the spf results are the same.
						# If all of the spf results are the same, that will be the overall result.
						# If any of them are different, and don't contain a "pass" result, then $spfresult will be empty
							$spfresult = $rp->[0]->{'result'};
						} else {
							$spfresult = 'unknown';
						}
					}
				}
			}
		}
		if ( ! defined($spfresult) || ! grep { $_ eq $spfresult } ALLOWED_SPFRESULT ) {
			$spfresult = 'unknown';
		};

		$rp = $r{'row'}->{'policy_evaluated'}->{'reason'};
		if(ref $rp eq "HASH") {
			$reason = $rp->{'type'};
		} else {
			$reason = join '/',map { $_->{'type'} } @$rp;
		}
		#print "ip=$ip, count=$count, disp=$disp, r=$reason,";
		#print "dkim=$dkim/$dkimresult, spf=$spf/$spfresult\n";

		# What type of IP address?
		my ($nip, $iptype, $ipval);
		if ($debug) {
			print "ip=$ip\n";
		}
		if($nip = inet_pton(AF_INET, $ip)) {
			$ipval = unpack "N", $nip;
			$iptype = "ip";
		} elsif($nip = inet_pton(AF_INET6, $ip)) {
			$ipval = $dbx{to_hex_string}($nip);
			$iptype = "ip6";
		} else {
			warn "$scriptname: $org: $id: ??? mystery ip $ip\n";
			rollback($dbh);
			return 0;
		}

		$dbh->do(qq{
			INSERT INTO rptrecord
			(
				serial,
				$iptype,
				rcount,
				disposition,
				spf_align,
				dkim_align,
				reason,
				dkimdomain,
				dkimresult,
				spfdomain,
				spfresult,
				identifier_hfrom)
			VALUES(?,$ipval,?,?,?,?,?,?,?,?,?,?)},
				undef,
				$serial,
				$count,
				$disp,
				$spf_align,
				$dkim_align,
				$reason,
				$dkim,
				$dkimresult,
				$spf,
				$spfresult,
				$identifier_hfrom);
		if ($dbh->errstr) {
			warn "$scriptname: $org: $id: Cannot add report data to database. Skipped.\n";
			rollback($dbh);
			return 0;
		}
		return 1;
	}
	# End do_xml_row()
	################################################################################

	my $res = 1;
	if(ref $record eq "HASH") {
		if ($debug){
			print "single record\n";
		}
		$res = -1 if !do_xml_row($serial,$record,$org,$id);
	} elsif(ref $record eq "ARRAY") {
		if ($debug){
			print "multi record\n";
		}
		foreach my $row (@$record) {
			$res = -1 if !do_xml_row($serial,$row,$org,$id);
		}
	} else {
		warn "$scriptname: $org: $id: mystery type " . ref($record) . "\n";
	}

	if ($debug && $res <= 0) {
		print "Result $res XML: $xml->{raw_xml}\n";
	}

	if ($res <= 0) {
		if ($db_tx_support) {
			warn "$scriptname: $org: $id: Cannot add records to rptrecord. Rolling back DB transaction.\n";
			rollback($dbh);
		} else {
			warn "$scriptname: $org: $id: errors while adding to rptrecord, serial $serial records likely obsolete.\n";
		}
	} else {
		if ($db_tx_support) {
			$dbh->commit;
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot commit transaction.\n";
			}
		}
	}
	return $res;
}

################################################################################

# Tries to roll back the transaction (if enabled).
# If an error happens, warn the user, but continue execution.
sub rollback {
	my $dbh = $_[0];

	if ($db_tx_support) {
		$dbh->rollback;
		if ($dbh->errstr) {
			warn "$scriptname: Cannot rollback transaction.\n";
		}
	}
}

################################################################################

# Extract fields from the JSON report data hash and store them into the database.
# return 1 when ok, 0, for serious error and -1 for minor errors
sub storeJSONInDatabase {
	my $json = $_[0]; # $json is a reference to the json data

	my $from = $json->{'date-range'}->{'start-datetime'};
	my $to = $json->{'date-range'}->{'end-datetime'};
	my $org = $json->{'organization-name'};
	my $id = $json->{'report-id'};
	my $contact = $json->{'contact-info'};
	my $domain =  $json->{'policies'}[0]->{'policy'}->{'policy-domain'};
	my $policy_type =  $json->{'policies'}[0]->{'policy'}->{'policy-type'};
	my $policy_string = "";
	if($json->{'policies'}[0]->{'policy'}->{'policy-string'}) {
		$policy_string = join("\n",@{$json->{'policies'}[0]->{'policy'}->{'policy-string'}});
	}
	my $summary_failure = $json->{'policies'}[0]->{'summary'}->{'total-failure-session-count'};
	my $summary_successful = $json->{'policies'}[0]->{'summary'}->{'total-successful-session-count'};

	#Delete "Z" at the end of timestamp
	$from =~ tr/Z//d;
	$to =~ tr/Z//d;

	# see if already stored
	my $sth = $dbh->prepare(qq{SELECT org, serial FROM tls_report WHERE reportid=?});
	$sth->execute($id);
	while ( my ($xorg,$sid) = $sth->fetchrow_array() )
	{
		if ($reports_replace) {
			# $sid is the serial of a tls report with reportid=$id
			# Remove this $sid from tls_report table, but
			# try to continue on failure rather than skipping.
			print "Replacing $xorg $id.\n";
			$dbh->do(qq{DELETE from tls_report WHERE serial=?}, undef, $sid);
			if ($dbh->errstr) {
				print "Cannot remove report from database (". $dbh->errstr ."). Try to continue.\n";
			}
		} else {
			print "Already have $xorg $id, skipped\n";
			# Do not store in DB, but return true, so the message can
			# be moved out of the way, if configured to do so.
			return 1;
		}
	}

	my $sql = qq{
		INSERT INTO tls_report
		(
			mindate,
			maxdate,
			org,
			reportid,
			contact,
			domain,
			policy_type,
			policy_string,
			summary_failure,
			summary_successful,
			raw_json
		)
		VALUES
		(
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?,
			?
		)
	};

	my $storejson = $json->{'raw_json'};
	if ($raw_data_compress) {
		my $gzipdata;
		if(!gzip(\$storejson => \$gzipdata)) {
			print "Cannot add gzip JSON to database ($GzipError). Skipped.\n";
			return 0;
			$storejson = "";
		} else {
			$storejson = encode_base64($gzipdata, "");
		}
	}
	if (length($storejson) > $raw_data_max_size) {
		print "Skipping storage of large JSON (".length($storejson)." bytes) as defined in config file.\n";
		$storejson = "";
	}
	$dbh->do($sql, undef, $from, $to, $org, $id, $contact, $domain, $policy_type, $policy_string, $summary_failure, $summary_successful, $storejson);
	if ($dbh->errstr) {
		print "Cannot add report to database (". $dbh->errstr ."). Skipped.\n";
		return 0;
	}

	my $serial = $dbh->last_insert_id(undef, undef, 'tls_report', undef);
	if ($debug){
		print " serial $serial ";
	}

	################################################################################
	sub do_json_row($$$$) {
		my ($serial,$recp,$org,$id) = @_;
		my %r = %$recp;

		my $result_type = $r{'result-type'};
		my $receiving_mx_hostname = $r{'receiving-mx-hostname'};
		my $receiving_mx_helo = $r{'receiving-mx-helo'};
		my $failed_session_count = $r{'failed-session-count'};
		my $additional_information = $r{'additional-info-uri'};
		my $failure_reason_code = $r{'failure-reason-code'};

		# What type of IP address?
		# This should be turned into a function
		my ($nip, $iptype, $ipval);

		my $sending_mta_ip = $r{'sending-mta-ip'};
		my $sending_mta_ipval = 0;
		my $sending_mta_iptype = "ip";
		if (length $sending_mta_ip){
			if ($debug) {
				print "ip=$sending_mta_ip\n";
			}
			if($nip = inet_pton(AF_INET, $sending_mta_ip)) {
				$sending_mta_ipval = unpack "N", $nip;
				$sending_mta_iptype = "ip";
			} elsif($nip = inet_pton(AF_INET6, $sending_mta_ip)) {
				$sending_mta_ipval = $dbx{to_hex_string}($nip);
				$sending_mta_iptype = "ip6";
			} else {
				warn "$scriptname: $org: $id: ??? mystery ip $sending_mta_ip\n";
				rollback($dbh);
				return 0;
			}
		}

		# What type of IP address?
		# This should be turned into a function
		my $receiving_ip = $r{'receiving-ip'};
		my $receiving_ipval = 0;
		my $receiving_iptype = "ip";
		if (length $receiving_ip){
			if ($debug) {
				print "ip=$receiving_ip\n";
			}
			if($nip = inet_pton(AF_INET, $receiving_ip)) {
				$receiving_ipval = unpack "N", $nip;
				$receiving_iptype = "ip";
			} elsif($nip = inet_pton(AF_INET6, $receiving_ip)) {
				$receiving_ipval = $dbx{to_hex_string}($nip);
				$receiving_iptype = "ip6";
			} else {
				warn "$scriptname: $org: $id: ??? mystery ip $receiving_ip\n";
				rollback($dbh);
				return 0;
			}
		}

		$dbh->do(qq{
			INSERT INTO tls_rptrecord
			(
				serial,
				sending_mta_$sending_mta_iptype,
				receiving_$receiving_iptype,
				result_type,
				receiving_mx_hostname,
				receiving_mx_helo,
				failed_session_count,
				additional_information,
				failure_reason_code
			)
			VALUES(?,$sending_mta_ipval,$receiving_ipval,?,?,?,?,?,?)},
			undef,
			$serial,
			$result_type,
			$receiving_mx_hostname,
			$receiving_mx_helo,
			$failed_session_count,
			$additional_information,
			$failure_reason_code);
		if ($dbh->errstr) {
			warn "$scriptname: $org: $id: Cannot add report data to database. Skipped.\n";
			rollback($dbh);
			return 0;
		}
		return 1;

	}
	# End do_json_row()
	################################################################################

	my $failure_details = $json->{'policies'}[0]->{'failure-details'};
	my $res = 1;
	if ( ! defined($failure_details) ) {
		if ($debug) {
			warn "$scriptname: $org: $id: No failure details in report.\n";
		}
		# return 0;
	} elsif (ref $failure_details eq "HASH") {
		if ($debug){
			print "single record\n";
		}
		$res = -1 if !do_json_row($serial,$failure_details,$org,$id);
	} elsif(ref $failure_details eq "ARRAY") {
		if ($debug){
			print "multi record\n";
		}
		foreach my $row (@$failure_details) {
			$res = -1 if !do_json_row($serial,$row,$org,$id);
		}
	} else {
		warn "$scriptname: $org: $id: mystery type " . ref($failure_details) . "\n";
	}

	if ($debug && $res <= 0) {
		print "Raw JSON: $json->{raw_json}\n";
	}

	if ($res <= 0) {
		if ($db_tx_support) {
			warn "$scriptname: $org: $id: Cannot add records to tls_rptrecord. Rolling back DB transaction.\n";
			rollback($dbh);
		} else {
			warn "$scriptname: $org: $id: errors while adding to rptrecord, serial $serial records likely obsolete.\n";
		}
	} else {
		if ($db_tx_support) {
			$dbh->commit;
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot commit transaction.\n";
			}
		}
	}
	return $res;
}


################################################################################

# Check, if the database contains needed tables and columns. The idea is, that
# the user only has to create the database/database_user. All needed tables and
# columns are created automatically. Furthermore, if new columns are introduced,
# the user does not need to make any changes to the database himself.
sub checkDatabase {
	my $dbh = $_[0];

	my $tables = $dbx{tables};

	# Create missing tables and missing columns.
	for my $table ( keys %{$tables} ) {

		if (!db_tbl_exists($dbh, $table)) {

			# Table does not exist, build CREATE TABLE cmd from tables hash.
			print "$scriptname: Adding missing table <" . $table . "> to the database.\n";
			my $sql_create_table = "CREATE TABLE " . $table . " (\n";
			for (my $i=0; $i <= $#{$tables->{$table}{"column_definitions"}}; $i+=3) {
				my $col_name = $tables->{$table}{"column_definitions"}[$i];
				my $col_type = $tables->{$table}{"column_definitions"}[$i+1];
				my $col_opts = $tables->{$table}{"column_definitions"}[$i+2];
				# add comma if second or later entry
				if ($i != 0) {
					$sql_create_table .= ",\n";
				}
				$sql_create_table .= "$col_name $col_type $col_opts";
			}
			# Add additional_definitions, if defined.
			if ($tables->{$table}{"additional_definitions"} ne "") {
				$sql_create_table .= ",\n" . $tables->{$table}{"additional_definitions"};
			}
			# Add options.
			$sql_create_table .= ") " . $tables->{$table}{"table_options"} . ";";
			# Create table.
			print "$sql_create_table\n" if $debug;
			$dbh->do($sql_create_table);

			# Create indexes.
			foreach my $sql_idx (@{$tables->{$table}{indexes}}) {
				print "$sql_idx\n" if $debug;
				$dbh->do($sql_idx);
			}
		} else {

			#Table exists, get  current columns in this table from DB.
			my %db_col_exists = db_column_info($dbh, $table);

			# Check if all needed columns are present, if not add them at the desired position.
			my $insert_pos;
			for (my $i=0; $i <= $#{$tables->{$table}{"column_definitions"}}; $i+=3) {
				my $col_name = $tables->{$table}{"column_definitions"}[$i];
				my $col_type = $tables->{$table}{"column_definitions"}[$i+1];
				my $col_opts = $tables->{$table}{"column_definitions"}[$i+2];
				if (!$db_col_exists{$col_name}) {
					# add column
					my $sql_add_column = $dbx{add_column}($table, $col_name, $col_type, $col_opts, $insert_pos);
					print "$sql_add_column\n" if $debug;
					$dbh->do($sql_add_column);
				} elsif ($db_col_exists{$col_name} !~ /^\Q$col_type\E/) {
					# modify column
					my $sql_modify_column = $dbx{modify_column}($table, $col_name, $col_type, $col_opts);
					print "$sql_modify_column\n" if $debug;
					$dbh->do($sql_modify_column);
				}
				$insert_pos = $col_name;
			}
		}
	}

	$dbh->commit;
}

################################################################################

# Checks if the table exists in the database
sub db_tbl_exists {
	my ($dbh, $table) = @_;

	my @res = $dbh->tables(undef, undef, $table, undef);
	return scalar @res > 0;
}

################################################################################

# Gets columns and their data types in a given table
sub db_column_info {
	my ($dbh, $table) = @_;

	my $db_info = $dbh->column_info(undef, undef, $table, undef)->fetchall_hashref('COLUMN_NAME');
	my %columns;
	foreach my $column (keys(%$db_info)) {
		$columns{$column} = $db_info->{$column}{$dbx{column_info_type_col}};
	}
	return %columns;
}
