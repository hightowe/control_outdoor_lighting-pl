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
use LWP::UserAgent;                       # libwww-perl
use IO::Socket::SSL;                      # libio-socket-ssl-perl
use HTTP::Request::Common;                # libhttp-message-perl
use JSON::XS;                             # libjson-xs-perl
use Cwd qw(realpath);                     # core
use Time::Piece;                          # core
use Time::Seconds;                        # core
use File::Basename qw(basename dirname);  # core
use File::Slurp qw(read_file write_file); # core
use Data::Dumper;                         # core
$Data::Dumper::Indent = 1;
#use Data::Printer; # libdata-printer-perl Nicer for Time::Piece object dumps
#sub PDumper { np @_, colored => 1 } # a Data::Printer PDumper() subroutine

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

# Calculate the needed lights on and off times
my $mins_from_sunset = get_mins_from_sunset($CONF->{location});
my $TIMES = {mins_from_sunset => $mins_from_sunset};
{
  my $now = Time::Piece->localtime; # Needed throughout this scope
  $TIMES->{now} = $now;
  my $sunset_time = get_sunset_time_with_cache($now, $CONF->{location});
  #my $sunset_time = '2025-03-27T10:25:06-04:00'; # For DEVELOPMENT only

  my $sst = convert_sunset_time_to_timepiece($now, $sunset_time);
  $TIMES->{sunset} = $sst;
  # Turn lights on relative to mins_prior_sunset config
  $TIMES->{time_on} = $sst - $CONF->{on_off}->{mins_prior_sunset}*60;
  # Turn lights off relative to mins_after_sunset config
  $TIMES->{time_off} = $sst + $CONF->{on_off}->{mins_after_sunset}*60;
  # Adjust time_off if always_off_by exists and is prior to mins_after_sunset
  if (exists($CONF->{on_off}->{always_off_by})) {
    my $always_off_time = $now->datetime;
    $always_off_time =~ s/\d\d:\d\d:\d\d$/$CONF->{on_off}->{always_off_by}:00/;
    my $always_off_by = $now->strptime($always_off_time,"%Y-%m-%dT%H:%M:%S");
    if ($always_off_by->epoch < $TIMES->{time_off}) {
      $TIMES->{time_off} = $always_off_by;
    }
  }
}
print "Calculated times: ".JDumper($TIMES)."\n";

# Figure out the needed state that we should be in and apply it
{
  my $now = Time::Piece->localtime; # Needed throughout this scope

  # Grab when and what this script last set the outlet state to
  my $state = get_state_data(); # Our last known state
  my $last_set_state = $state->{last_set_state} // undef;
  my $last_set_state_time = $state->{last_set_state_time} // undef;
  if (defined($last_set_state_time)) {
    $last_set_state_time = $now->strptime($last_set_state_time, "%Y-%m-%dT%H:%M:%S");
  }

  # Determine the state things should be in now
  my $needed_state = undef;
  if ($now >= $TIMES->{time_on} && $now < $TIMES->{time_off}) {
    $needed_state = 1;
  } else {
    $needed_state = 0;
  }

  my $current_state = get_plug_state($CONF->{plug_hostname});
  print JDumper({needed_state => $needed_state, current_state => $current_state})."\n";

  # If we are out of correspondence, analyze the details
  my $are_we_in_an_override = 0;
  if ($current_state != $needed_state) {
    if (! defined($last_set_state_time)) {
      #print "We have no last_set_state_time and so need to toggle the state\n";
    } elsif (
      # If we last set state to on and after the start of the $TIMES->{time_on}
      # period but it is off now, or if we last set state to off before the
      # start of the $TIMES->{time_on} or after the start of $TIMES->{time_off}
      # but it is on now, assume that a user overrode us.
	($needed_state == 1 && $last_set_state == 1 &&
			$last_set_state_time->epoch >= $TIMES->{time_on}->epoch)
	|| ($needed_state == 0 && $last_set_state == 0 &&
			$last_set_state_time->epoch < $TIMES->{time_on}->epoch)
	|| ($needed_state == 0 && $last_set_state == 0 &&
			$last_set_state_time->epoch >= $TIMES->{time_off}->epoch)
	) {
      # If we haven't yet recorded an override_start_time, do that now
      if (! exists($state->{override_start_time})) {
        $state->{override_start_time} = $now->datetime; # When we first saw this override
        $state->{override_state} = $current_state; # What state the override is in
        set_state_data($state);
      }
      $are_we_in_an_override = 1;
      #print "We are in an override period and require further analysis\n";
    } else {
      #print "We are not in an override and need to toggle the state\n";
    }
  } else {
    print "We are in correspondence so there is nothing to do.\n";
    # If we are in correspondence we need to remove any override state info
    if (exists($state->{override_start_time})) {
      print "Removing override_start_time of $state->{override_start_time}...\n";
      delete($state->{override_start_time});
      delete($state->{override_state});
      set_state_data($state);
    }
  }

  # Do further analysis if we are in an override situation
  if ($current_state != $needed_state && $are_we_in_an_override) {
    print "In override=$state->{override_state} that began at: $state->{override_start_time}\n";
    my $mins_since_set = int(($now->epoch - $last_set_state_time->epoch) / 60);
    my $override_mins = $CONF->{on_off}->{override_mins}->{$current_state};
    my $override_time = $now->strptime($state->{override_start_time}, "%Y-%m-%dT%H:%M:%S");
    my $mins_since_override = int(($now->epoch - $override_time->epoch) / 60);
    if ($mins_since_override >= 0 && $mins_since_override <= $override_mins) {
      print "$mins_since_override mins since the override is within override_mins=$override_mins.\n";
      print "Not changing state...\n";
      $needed_state = $current_state; # Prevent a state change
    } else {
      print "$mins_since_override mins since the override exceeds override_mins=$override_mins.\n";
      print "Allowing the state to change...\n";
    }
  }

  # If $current_state is still != $needed_state, then we need to toggle it.
  if ($current_state != $needed_state) {
    print "Change needed: current_state=$current_state to needed_state=$needed_state\n";
    set_plug_state($CONF->{plug_hostname}, $needed_state);
    my $new_state = get_plug_state($CONF->{plug_hostname});
    if ($new_state != $needed_state) {
      warn "get_plug_state() failed to set the net state!\n";
    } else {
      save_plug_state($new_state);
      $state = get_state_data(); # Repull the state after toggling the plug
      # Remove an override if there is one
      if (exists($state->{override_start_time})) {
        print "Removing override state after we changed the plug state...\n";
        delete($state->{override_start_time});
        delete($state->{override_state});
        set_state_data($state);
      }
    }
  } elsif (! exists($state->{last_set_state})) {
    # If we are in coorespondence but missing a last_set_state, we want to
    # set it here so that we can better handle overrides.
    print "Missing last_set_state so setting it to now...\n";
    save_plug_state($current_state);
  }
}

# Collect and print some sensor values
{
  my $sensor_values = {};
  my $plug_hn = $CONF->{plug_hostname};
  foreach my $sensor (qw(voltage power current total_daily_energy uptime)) {
    $sensor_values->{$sensor} = get_plug_sensor_value($plug_hn, $sensor);
    # Scrub the "id" keys since they are just noise to us
    delete($sensor_values->{$sensor}->{id});
  }
  print "Sensor values: ".JDumper($sensor_values)."\n";
}

exit 0;

##################################

sub load_conf_file() {
  my $cf = realpath(dirname($0).'/'.basename($0).'.conf');
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
  my $json = JSON::XS->new->utf8(1)->canonical(1)->pretty(1)->encode($data);
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

sub convert_sunset_time_to_timepiece($now, $sunset_time) {
  die "Wrong type for \$now in convert_sunset_time_to_timepiece()" if (ref($now) ne 'Time::Piece');
  #print "sunset_time = $sunset_time\n";
  # 2025-03-20T19:39:47-04:00
  my $sunset_time_tmp = $sunset_time;
  $sunset_time_tmp =~ s/[-+]\d\d:\d\d$//; # Remove TZ offset
  my $sst = $now->strptime($sunset_time_tmp, "%Y-%m-%dT%H:%M:%S");
  #print "sst = " . $sst->datetime .$sst->tzoffset. "\n";
  return $sst;
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
  my $json = JSON::XS->new->utf8(1)->canonical(1)->pretty(1)->encode($data);
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
  my $sst = convert_sunset_time_to_timepiece($now, $sunset_time);
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

# During development, I used Data::Printer/PDumper to dump Time::Piece values
# in human-readable form, but did not like the added, non-core dependency.
sub JDumper {
  sub Time::Piece::TO_JSON {
    return $_[0]->datetime;
  }
  my @t = ();
  foreach my $to_dump (@_) {
    push @t, JSON::XS->new->utf8(1)->pretty(1)->canonical(1)->convert_blessed(1)->encode($to_dump);
  }
  my $t = join("\n", @t);
  chomp $t;
  return($t);
}

