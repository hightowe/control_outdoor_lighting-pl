#!/usr/bin/perl

########################################################################
# A program to extract the daily power usage from the logs that my
# control_outdoor_lighting.pl program produces. It is needed because
# the PLF12 cannot reset its total_daily_energy on the daily without
# being connected to a Home Assistant server, which I don't want. And
# so, my total_daily_energy is actually total_accumulated_energy. This
# program parses that data out and does the daily math of usage.
#
#----------------------------------------------------------------------
# - First written 04/04/2025 by Lester Hightower
########################################################################

use strict;
no warnings "experimental::signatures";
use feature qw(signatures);
use JSON::XS;                             # libjson-xs-perl
use Time::Piece;                          # core
use Time::Seconds;                        # core
use File::Basename qw(basename dirname);  # core
use File::Slurp qw(read_file write_file); # core
use Data::Dumper;                         # core
$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;

my $LOG_FILE="./control_outdoor_lighting.pl.log";
$LOG_FILE = $ARGV[0] if (defined($ARGV[0]));
my $log_lines = read_file($LOG_FILE, array_ref => 1) || die "Failed to read $LOG_FILE";
my %logs = ();

my $this_log_tm = undef;
LOG_LINE: foreach my $line (@{$log_lines}) {
 chomp $line;
  # Start of new log: 2025-03-21T11:30:01-04:00
  if ($line =~ m/^\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\d/) {
    $this_log_tm = $line;
    next LOG_LINE;
  }
  push(@{$logs{$this_log_tm}}, $line) if defined($this_log_tm);
}
#print Dumper(\%logs)."\n";

my $SVs = extract_sensor_values(\%logs);
#print Dumper($SVs)."\n";

# Extract the beg/end total_daily_energy and then calc the use
my $TDEs = {};
foreach my $this_log_tm (sort keys %{$SVs}) {
  my ($day) = $this_log_tm =~ m/^(\d\d\d\d-\d\d-\d\d)T/;
  if (! exists($TDEs->{$day})) {
    $TDEs->{$day}->{beg} = $SVs->{$this_log_tm}->{total_daily_energy}->{value};
  } else {
    $TDEs->{$day}->{end} = $SVs->{$this_log_tm}->{total_daily_energy}->{value};
  }
}
foreach my $day (sort keys %{$TDEs}) {
  if (exists($TDEs->{$day}->{beg}) && exists($TDEs->{$day}->{end})) {
    $TDEs->{$day}->{use} = $TDEs->{$day}->{end} - $TDEs->{$day}->{beg};
  }
}
print Dumper($TDEs)."\n";

exit;

#########################################################################
#########################################################################
#########################################################################

#    'Sensor values: {',
#    '   "current" : {',
#    '      "state" : "-0.00 A",',
#    '      "value" : -7.354117e-16',
#    '   },',
#    '   "power" : {',
#    '      "state" : "0.0 W",',
#    '      "value" : 0',
#    '   },',
#    '   "total_daily_energy" : {',
#    '      "state" : "5.865 kWh",',
#    '      "value" : 5.864526',
#    '   },',
#    '   "uptime" : {',
#    '      "state" : "103195 s",',
#    '      "value" : 103194.6',
#    '   },',
#    '   "voltage" : {',
#    '      "state" : "118.5 V",',
#    '      "value" : 118.4582',
#    '   }',
#    '}',
sub extract_sensor_values($logs) {
  my $SVs = {};
  foreach my $this_log_tm (sort keys %{$logs}) {
    my @SVs=();
    LOG_LINE: foreach my $line (@{$logs->{$this_log_tm}}) {
      if (scalar(@SVs) < 1 && $line !~ m/^\s*Sensor values: /i) {
        next LOG_LINE
      }
      if (scalar(@SVs) < 1) {
        push(@SVs, '{');
        next LOG_LINE
      }
      push @SVs, $line;
      last LOG_LINE if ($SVs[$#SVs] eq '}');
    }
    my $json = join("\n", @SVs);
    my $data = undef;
    my $rc = eval { $data = decode_json($json); 1; };
    if ( $rc == 1 && ref($data) eq 'HASH' ) {
      #print "decode_json() worked for $this_log_tm\n";
      $SVs->{$this_log_tm} = $data;
    } else {
      warn "decode_json() failed for $this_log_tm\n";
    }
  }
  return $SVs;
}

