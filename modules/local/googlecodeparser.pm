package modules::local::googlecodeparser;
use strict;
use warnings;

use XML::Atom::Client;
use HTML::Entities;

use base 'modules::local::karmalog';

=head1 NAME

    modules::local::googlecodeparser

=head1 DESCRIPTION

This module is responsible for parsing ATOM feeds generated by code.google.com.
It is also knowledgeable enough about google code's URL schemes to be able to
recognise repository URLs, extract the project name and generate ATOM feed URLs.

This is very similar to, and heavily based on, modules::local::githubparser.

=cut

our %feeds;

=head1 METHODS

=head2 fetch_feed

This is a pseudomethod called as a timer callback.  It fetches the feed, parses
it into an XML::Atom::Feed object and passes that to process_feed().

This is the main entry point to this module.  Botnix does not use full class
instances, instead it just calls by package name.  This function maps from the
function name to a real $self object (stored in %objects_by_package).

=cut

sub fetch_feed {
    my $self = shift;
    for my $project (sort keys %feeds) {
        my $link = "http://code.google.com/feeds/p/$project/svnchanges/basic";
        my $atom = XML::Atom::Client->new();
        my $feed = $atom->getFeed($link);
        $self->process_feed($project, $feed);
        ::mark_feed_started(__PACKAGE__, $project);
    }
}


=head2 process_feed

    $self->process_feed($feed);

Enumerates the commits in the feed, emitting any events which are newer than
the previously saved "lastval" (which is stashed in the $self object).
output_item() is called for any objects it determines to be new.  It judges
this by the datestamp, which is in a format that allows asciibetical inequality
comparisons.  After enumerating the list, lastval is updated to the newest item
in the feed.

The first time through, nothing is emitted.  This is because we assume the bot
was just restarted ungracefully and the users have already seen all the old
events.

=cut

sub process_feed {
    my ($self, $project, $feed) = @_;
    my @items = $feed->entries;
    @items = sort { $a->updated cmp $b->updated } @items; # ascending order
    my $newest = $items[-1];
    my $latest = $newest->updated;

    foreach my $item (@items) {
        my ($rev)   = $item->link->href =~ m|\?r=([0-9]+)|;
        ::try_item($self, $project, $feeds{$project}, $rev, $item);
    }
}

=head2 try_link

    modules::local::googlecode->try_link($url, ['network', '#channel']);

This is called by autofeed.pm.  Given a google code URL, try to determine the
project name and canonical path.  Then configure a feed reader for it if one
doesn't already exist.

The array reference containing network and channel are optional.  If not
specified, magnet/#parrot is assumed.  If the feed already exists but didn't
have the specified target, the existing feed is extended.

Currently supports 2 URL formats:

    http://code.google.com/p/pynie/
    http://partcl.googlecode.com/

This covers all of the links on the Languages page at time of writing.

=cut

sub try_link {
    my ($pkg, $url, $target) = @_;
    $target = ['magnet', '#parrot'] unless defined $target;
    my $projectname;
    if($url =~ m|http://code.google.com/p/([^/]+)/?$|) {
        $projectname = $1;
    } elsif($url =~ m|http://([^.]+).googlecode.com/$|) {
        $projectname = $1;
    } else {
        # whatever it is, we can't handle it.  Log and return.
        main::lprint("googlecode try_link(): I can't handle $url");
        return;
    }

    my $array = ($feeds{$projectname} //= []);
    foreach my $this (@$array) {
        return if($$target[0] eq $$this[0] && $$target[1] eq $$this[1]);
    }
    push @$array, $target;

    main::lprint("$projectname google code ATOM parser autoloaded.");
}

sub init {
    main::create_timer("googlecode_fetch_feed_timer", __PACKAGE__,
        "fetch_feed", 260);
}

=head2 output_item

    $self->output_item($item);

Takes an XML::Atom::Entry object, extracts the useful bits from it and calls
put() to emit the karma message.

The karma message is typically as follows:

feedname: $revision | username++ | $commonprefix:
feedname: One or more lines of commit log message
feedname: review: http://link/to/googlecode/diff/page

=cut

sub format_item {
    my ($self, $feedid, $rev, $item) = @_;
    my $prefix  = 'unknown';
    my $creator = $item->author->name;
    my $link    = $item->link->href;
    my $desc    = $item->content->body;

    $creator = "($creator)" if($creator =~ /\s/);

    my $log;
    decode_entities($desc);
    $desc =~ s/^\s+//s;   # leading whitespace
    $desc =~ s/\s+$//s;   # trailing whitespace
    $desc =~ s/<br\/>//g; # encapsulated newlines
    my @lines = split("\n", $desc);
    shift(@lines) if $lines[0] eq 'Changed Paths:';
    my @files;
    while(defined($lines[0]) && $lines[0] =~ /[^ ]/) {
        my $line = shift @lines;
        if($line =~ m[\xa0\xa0\xa0\xa0(?:Modify|Add|Delete)\xa0\xa0\xa0\xa0/(.+)]) {
            push(@files, $1);
        } elsif($line =~ m[^ \(from /]) {
            # skip this line and the one after it.
            shift(@lines);
        } else {
            unshift(@lines, $line);
            last;
        }
        while(defined($lines[0]) && $lines[0] eq ' ') {
            $line = shift @lines;
        }
    }
    pop(@lines) while scalar(@lines) && $lines[-1] eq '';
    $log = join("\n", @lines);
    $log =~ s/^\s+//;

    $prefix =  ::longest_common_prefix(@files);
    $prefix =~ s|^/||;      # cut off the leading slash
    if(scalar @files > 1) {
        $prefix .= " (" . scalar(@files) . " files)";
    }

    $log =~ s|<br */>||g;
    decode_entities($log);
    my @log_lines = split(/[\r\n]+/, $log);

    main::lprint("$feedid: output_item: output rev $rev");
    $self->format_karma_message(
        feed    => $feedid,
        rev     => "r$rev",
        user    => $creator,
        log     => \@log_lines,
        link    => $link,
        prefix  => $prefix,
    );
}

1;
