#!/usr/bin/env perl

# ical-to-gcal
# A quick script to fetch and parse an iCal/vcal feed, and update a named Google Calendar.
#
# See the README in the repo for more details on why and how to use it:
# https://github.com/yvangodard/ical-to-google-calendar
#
# Original script by David Precious <davidp@preshweb.co.uk>
# https://github.com/bigpresh/ical-to-google-calendar

use strict;
use Net::Google::Calendar;
use Net::Netrc;
use iCal::Parser;
use LWP::Simple;
use Getopt::Long;

my ($calendar, $ical_url, $configmachine);
Getopt::Long::GetOptions(
    "calendar|c=s"      => \$calendar,
    "ical_url|ical|i=s" => \$ical_url,
    "configmachine|i=s" => \$configmachine,
) or die "Failed to parse options";

if (!$ical_url) {
    die "An iCal URL must be provided (--ical_url=....)";
}
if (!$calendar) {
    die "You must specify the calendar name (--calendar=...)";
}
if (!$configmachine) {
    die "You must specify the configmachine to use in  ~/.netrc (--configmachine=...)";
}

my $ical_data = LWP::Simple::get($ical_url)
    or die "Failed to fetch $ical_url";

my $ic = iCal::Parser->new;

my $ical = $ic->parse_strings($ical_data)
    or die "Failed to parse iCal data";

# We get events keyed by year, month, day - we just want a flat list of events
# to walk through.  Do this keyed by the event ID, so that multiple-day events
# are handled appropriately.  We'll want this hash anyway to do a pass through
# all events on the Google Calendar, removing any that are no longer in the
# iCal feed.

my %ical_events;
for my $year (keys %{ $ical->{events} }) {
    for my $month (keys %{ $ical->{events}{$year} }) {
        for my $day (keys %{ $ical->{events}{$year}{$month} }) {
            for my $event_uid (keys %{ $ical->{events}{$year}{$month}{$day} }) {
                $ical_events{ $event_uid }
                    = $ical->{events}{$year}{$month}{$day}{$event_uid};
            }
        }
    }
}

# Right, we can now walk through each event in $events
for my $event_uid (keys %ical_events) {
    my $event = $ical_events{$event_uid};
    printf "$event_uid (%s at %s)\n",
        @$event{ qw (SUMMARY LOCATION) };
}


# Get our login details, and find the Google calendar in question:
my $mach = Net::Netrc->lookup($configmachine)
    or die "No login details for $configmachine in ~/.netrc";
my ($user, $pass) = $mach->lpa;


my $gcal = Net::Google::Calendar->new;
$gcal->login($user, $pass)
    or die "Google Calendar login failed";

my ($desired_calendar) = grep { $_->title eq $calendar } $gcal->get_calendars;

if (!$desired_calendar) {
    die "No calendar named $calendar found!";
}
$gcal->set_calendar($desired_calendar);

# Fetch all events from this calendar, parse out the ical feed's UID and whack
# them in a hash keyed by the UID; if that UID no longer appears in the ical
# feed, it's one to delete.

my %gcal_events;

gcal_event:
for my $event ($gcal->get_events ('max-results' => 99999)) {
    my ($ical_uid) = $event->content->body =~ m{\[ical_imported_uid:(.+)\]};

    # If there's no ical uid, we presumably didn't create this, so leave it
    # alone
    if (!$ical_uid) {
        warn sprintf "Event %s (%s) ignored as it has no "
            . "ical_imported_uid property",
            $event->id,
            $event->title;
        next gcal_event;
    }

    # OK, if this event didn't appear in the iCal feed, it has been deleted at
    # the other end, so we should delete it from our Google calendar:
    if (!$ical_events{$ical_uid}) {
        printf "Deleting event %s (%s) (no longer found in iCal feed)\n",
            $event->id, $event->title;
        $gcal->delete_entry($event)
            or warn "Failed to delete an event from Google Calendar";
    }

    # Now check for any differences, and update if required

    # Remember that we found this event, so we can refer to it when looking for
    # events we need to create
    $gcal_events{$ical_uid} = $event;
}


# Now, walk through the ical events we found, and create/update Google Calendar
# events
for my $ical_uid (keys %ical_events) {
    
    my ($method, $gcal_event);

    if (exists $gcal_events{$ical_uid}) {
        $gcal_event = $gcal_events{$ical_uid};
        $method = 'update_entry';
        print "Need to update ical event $ical_uid in gcal\n";
    } else {
        $gcal_event = Net::Google::Calendar::Entry->new;
        $method = 'add_entry';
        print "Need to create new gcal event for $ical_uid\n";
    }

    my $ical_event = $ical_events{$ical_uid};
    $gcal_event->title(    $ical_event->{SUMMARY}  );
    $gcal_event->location( $ical_event->{LOCATION} );
    $gcal_event->when( $ical_event->{DTSTART}, $ical_event->{DTEND} );

    if ($method eq 'add_entry') {
        $gcal_event->content("[ical_imported_uid:$ical_uid]");
    }

    $gcal->$method($gcal_event)
        or warn "Failed to $method for $ical_uid";
}