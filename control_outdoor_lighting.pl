#!/usr/bin/perl

########################################################################
# A program to turn outdoor lights on/and off relative to the sunset
# time at that location.
#
# It is intended to run frequently from cron, using a script like this:
# 
# #!/bin/bash
#
# DIR="/path/to/the/program"
# EXE="$DIR/control_outdoor_lighting.pl"
# LOG="$DIR/control_outdoor_lighting.pl.log"
#
# (
#   /bin/date --iso-8601=seconds
#   /usr/bin/time --format "Runtime: %E\n" /bin/timeout --signal=TERM --kill-after=5 4m "$EXE"
# ) 1>>"$LOG" 2>&1
#
#----------------------------------------------------------------------
# - First written 03/20/2025 by Lester Hightower
# - First written to support a KAUF Smart Plug model PLF12 and
#   https://api.sunrise-sunset.org
########################################################################

use strict;
no warnings "experimental::signatures";
use feature qw(signatures);
use LWP::UserAgent;
use IO::Socket::SSL;
use HTTP::Request::Common;
use JSON::XS;
use Time::Piece;
use Time::Seconds;
use File::Basename qw(basename);
use File::Slurp qw(read_file write_file);
use Data::Dumper;
$Data::Dumper::Indent = 1;

my $CONF = load_conf_file(); # Load configuration

# Start of program
local $ENV{TZ} = $CONF->{timezone}; # Have the script work in CONF->{timezone}

# Make a LWP::UserAgent object to use
my $ua = LWP::UserAgent->new(
    #cookie_jar => $self->{cookie_jar},
    #agent => $rbGlobals->get('UserAgent'),
    ssl_opts => {
      verify_hostname => 0,
      SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
    },
  );

my $mins_from_sunset = get_mins_from_sunset($CONF->{location});
print "mins_from_sunset = ".$mins_from_sunset."\n";

# Figure out the needed state that we should be in
my $needed_state = undef;
if ($mins_from_sunset <= $CONF->{on_off}->{mins_prior_sunset} &&
	$mins_from_sunset > -1*$CONF->{on_off}->{mins_after_sunset}) {
  $needed_state = 1;
} elsif ($mins_from_sunset <= -1*$CONF->{on_off}->{mins_after_sunset}) {
  $needed_state = 0;
}
$needed_state = $CONF->{on_off}->{default_state} if (! defined($needed_state));

# We may need to override $needed_state=1 via always_off_by
if ($needed_state && exists($CONF->{on_off}->{always_off_by})) {
  #always_off_by => '22:00:00', # Always off by this time
  my $now = Time::Piece->localtime;
  # Put the always_off_by into the now time string and parse it
  my $always_off_time = $now->datetime;
  $always_off_time =~ s/\d\d:\d\d:\d\d$/$CONF->{on_off}->{always_off_by}:00/;
  my $always_off_by = $now->strptime($always_off_time,"%Y-%m-%dT%H:%M:%S");
  print Dumper({now => $now->datetime, off_by => $always_off_by->datetime});
  # If we've passed the always_off_by time, then needed_state=0
  if ($now->epoch > $always_off_by->epoch) {
    print "Overriding due to always_off_by=$CONF->{on_off}->{always_off_by}\n";
    print Dumper({now => $now->epoch, always_off_by => $always_off_by->epoch});
    $needed_state = 0;
  }
}

my $current_state = get_plug_state($CONF->{plug_hostname});
print Dumper({needed_state => $needed_state, current_state => $current_state})."\n";

# If the current state is not what we decided that we needed, we need to
# determine if it was overridden and, if so, respect the override_mins.
#
# TODO - do we need to keep track of the last state we see and its time...?
#
{
  my $state = get_state_data();
  if ($current_state != $needed_state && exists($state->{last_set_state_time})) {
    my $now = Time::Piece->localtime;
    my $set = $now->strptime($state->{last_set_state_time}, "%Y-%m-%dT%H:%M:%S");
    my $mins_since_set = int(($now->epoch - $set->epoch) / 60);
    my $override_mins = $CONF->{on_off}->{override_mins}->{$current_state};

    if (exists($state->{override_start_time})) {
      my $override_time = $now->strptime($state->{override_start_time}, "%Y-%m-%dT%H:%M:%S");
      my $mins_since_override = int(($now->epoch - $override_time->epoch) / 60);
      if ($mins_since_override >= 0 && $mins_since_override <= $override_mins) {
        print "$mins_since_override mins since we saw an override is within override_mins.\n";
        print "Not changing state...\n";
        $needed_state = $current_state;
      }
    } else {
      if ($mins_since_set >= 0 && $mins_since_set <= $override_mins) {
        print "$mins_since_set mins since our set is within override_mins.\n";
        print "Not changing state...\n";
        $needed_state = $current_state;
      }
      $state->{override_start_time} = $now->datetime; # When we first saw this override
      set_state_data($state);
    }
  } elsif (exists($state->{override_start_time})) {
    # If we stored an override_start_time and now current_state==needed_state
    # then we should remove that override_start_time
    print "Removing override_start_time of $state->{override_start_time}...\n";
    delete($state->{override_start_time});
    set_state_data($state);
  }
}

# If we need to change the state of the plug, do that here.
if ($current_state != $needed_state) {
  print "Change needed current_state=$current_state to needed_state=$needed_state\n";
  set_plug_state($CONF->{plug_hostname}, $needed_state);
  my $new_state = get_plug_state($CONF->{plug_hostname});
  if ($new_state != $needed_state) {
    warn "get_plug_state() failed to set the net state!\n";
  } else {
    save_plug_state($new_state);
  }
}

# Collect and print some sensor values
my $sensor_values = {};
{
  my $plug_hn = $CONF->{plug_hostname};
  foreach my $sensor (qw(voltage power current total_daily_energy uptime)) {
    $sensor_values->{$sensor} = get_plug_sensor_value($plug_hn, $sensor);
    # Scrub the "id" keys since they are just noise to us
    delete($sensor_values->{$sensor}->{id});
  }
}
print "Sensor values: ".Dumper($sensor_values)."\n";

exit 0;

##################################

sub load_conf_file() {
  my $cf = basename($0).'.conf';
  die "Do not see a conf files at: $cf\n" if (! -r $cf);
  my $conf = eval(read_file($cf));
  return $conf;
}

sub save_plug_state($state) {
  # Load current state first so that we only overwrite
  # the parts that we're responsible for.
  my $data = get_state_data();
  my $now = Time::Piece->localtime;
  $data->{last_set_state_time} = $now->datetime;
  $data->{last_set_state} = $state;
  delete($data->{override_start_time}); # Remove any override we may have seen
  set_state_data($data);
}

sub get_state_data {
  my $data = {};
  if (-f -r $CONF->{state_store_file}) {
    $data = decode_json(read_file($CONF->{state_store_file}));
  }
  return($data);
}

sub set_state_data($data) {
  my $json = JSON::XS->new->utf8(1)->pretty(1)->encode($data);
  write_file($CONF->{state_store_file}, $json);
}

sub set_plug_state($plug_hostname, $state) {
  # POST true -> http://10.10.10.39/switch/kauf_plug/turn_off
  # POST true -> http://10.10.10.39/switch/kauf_plug/turn_on
  my $state_url_paths = {
	0 => '/switch/kauf_plug/turn_off',
	1 => '/switch/kauf_plug/turn_on',
	};
  if (! exists($state_url_paths->{$state})) {
    die "Invalid state '$state' in set_plug_state()\n";
  }
  my $url="http://$plug_hostname$state_url_paths->{$state}";
  my $req = HTTP::Request::Common::POST($url, {value => 'true'});
  my $response = $ua->request($req);
  if (! $response->is_success) {
    # TODO - likely should not die here
    die "Failed to set_plug_state(): " . $response->error_as_HTML;
  }
  return 1;
}

sub get_plug_url_data($url) {
  my $req = HTTP::Request::Common::GET($url);
  my $response = $ua->request($req);
  if (! $response->is_success) {
    # TODO - likely should not die here
    die "Failed to get_plug_url_data('$url'): " . $response->error_as_HTML;
  }
  my $json_data = $response->decoded_content;
  my $data = decode_json($json_data);
  #print Dumper( $data ) . "\n";
  return $data;
}

# $ curl 'http://10.10.10.39/switch/kauf_plug'   
# {"id":"switch-kauf_plug","value":true,"state":"ON"}
sub get_plug_state($plug_hostname) {
  my $url="http://$plug_hostname/switch/kauf_plug";
  my $data = get_plug_url_data($url);
  return(undef) if (! exists($data->{state}));
  return(1) if (lc($data->{state}) eq 'on');
  return(0) if (lc($data->{state}) eq 'off');
  return undef;
}

# $ curl 'http://10.10.10.39/sensor/kauf_plug_power'
# {"id":"sensor-kauf_plug_power","value":0,"state":"0.0 W"}
# $ curl 'http://10.10.10.39/sensor/kauf_plug_current'
# {"id":"sensor-kauf_plug_current","value":-7.354117e-16,"state":"-0.00 A"}
# $ curl 'http://10.10.10.39/sensor/kauf_plug_voltage'
# {"id":"sensor-kauf_plug_voltage","value":119.4794,"state":"119.5 V"}
sub get_plug_sensor_value($plug_hostname, $sensor) {
  my $url="http://$plug_hostname/sensor/kauf_plug_$sensor";
  my $data = get_plug_url_data($url);
  return(undef) if (! exists($data->{value}));
  return $data;
}

# We cache the results and so we only hit the sunset API once per day.
sub get_sunset_time_with_cache($now, $loc) {
  # If our cache exists and matches now's sunset_ymd, then return that
  my $data = get_state_data();
  if (exists($data->{sunset_ymd}) && $data->{sunset_ymd} eq $now->ymd) {
    #warn "LHHD: sunset_time came from cache\n";
    return($data->{sunset_time}) if (exists($data->{sunset_time}));
  }

  # If we get this far then we need to retrive sunset_time for now
  # and cache it in the CONF->{state_store_file}.
  my $sunset_time = get_sunset_time($loc);
  $data->{sunset_ymd} = $now->ymd;
  $data->{sunset_time} = $sunset_time;
  my $json = JSON::XS->new->utf8(1)->pretty(1)->encode($data);
  write_file($CONF->{state_store_file}, $json);

  return $sunset_time;
}

# Returns the minutes until sunset (positive prior, negative after)
sub get_mins_from_sunset($loc) {
  # NOTE: Time::Piece has a quirk and cannot parse the "-04:00" with
  # %s and do I use this $now object below to parse the $sunset_time
  # with the TZ offset removed, and that applies the same timezone as
  # was already present in the $now object, and so the order of operations
  # here matters a lot...
  my $now = Time::Piece->localtime;
  #print "now = " . $now->datetime .$now->tzoffset. "\n";

  # Get the sunset_time
  my $sunset_time = get_sunset_time_with_cache($now, $loc);
  #print "sunset_time = $sunset_time\n";
  # 2025-03-20T19:39:47-04:00
  $sunset_time =~ s/[-+]\d\d:\d\d$//; # Remove TZ offset
  my $sst = $now->strptime($sunset_time, "%Y-%m-%dT%H:%M:%S");
  #print "sst = " . $sst->datetime .$sst->tzoffset. "\n";

  # Calculate the minutes from sunset (positive prior, negative after)
  my $mins_from_sunset = int(($sst->epoch - $now->epoch) / 60);
  #print "mins_from_sunset = ".$mins_from_sunset."\n";
  return($mins_from_sunset);
}

# Hits a web API to grab today's sunset time for a location
sub get_sunset_time($loc) {
  # https://api.sunrise-sunset.org/json?lat=30.171448241591328&lng=-81.7601464866356&tzid=America/New_York&formatted=0
  #$VAR1 = {
  #  'tzid' => 'America/New_York',
  #  'status' => 'OK',
  #  'results' => {
  #     'astronomical_twilight_begin' => '2025-03-20T06:10:13-04:00',
  #     'nautical_twilight_begin' => '2025-03-20T06:38:21-04:00',
  #     'nautical_twilight_end' => '2025-03-20T20:30:21-04:00',
  #     'sunrise' => '2025-03-20T07:28:55-04:00',
  #     'civil_twilight_end' => '2025-03-20T20:02:28-04:00',
  #     'civil_twilight_begin' => '2025-03-20T07:06:14-04:00',
  #     'day_length' => 43852,
  #     'solar_noon' => '2025-03-20T13:34:21-04:00',
  #     'astronomical_twilight_end' => '2025-03-20T20:58:29-04:00',
  #     'sunset' => '2025-03-20T19:39:47-04:00'
  #   }
  # };
  my $url="https://api.sunrise-sunset.org/json?" .
	"lat=$loc->{lat}&lng=$loc->{lng}&tzid=$loc->{tzid}&" .
	"formatted=0"; # Machine readable
  my $req = HTTP::Request::Common::GET($url);
  my $response = $ua->request($req);
  if (! $response->is_success) {
    # TODO - likely should not die here
    die "Failed to get_sunset_time(): " . $response->error_as_HTML;
  }
  my $json_data = $response->decoded_content;
  my $data = decode_json($json_data);
  #print Dumper( $data ) . "\n";
  return($data->{results}->{sunset}) if (exists($data->{results}->{sunset}));
  return undef;
}

