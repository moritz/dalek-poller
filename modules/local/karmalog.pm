package modules::local::karmalog;
use strict;
use warnings;

my $url = 'https://github.com/parrot/parrot/raw/master/CREDITS';

=head1 NAME

    modules::local::karmalog

=head1 DESCRIPTION

This is a base class which knows how to emit karma messages to an IRC channel.

This plugin scrapes the CREDITS file from the Parrot svn repository, and builds
up a hash mapping aliases to usernames.  This is so it can consolidate karma
onto a user's IRC nick, even though their commit bits in various places may be
under different names.

It looks for N: and A: lines in the CREDITS file.  The A: line is something we
just made up, and it stands for "alias" or "AKA".  For the following entry:

    N: Will "Coke" Coleda
    U: coke
    A: wcoleda
    E: will@coleda.com
    D: Tcl language (partcl), APL, website, various languages/ upkeep, misc.

It should understand that commits under the username "wcoleda" are aliased to
"coke", and the irc message should say coke++, not wcoleda++.

=head1 METHODS

=head2 fetch_metadata

Called by the core. Grab the CREDITS file, call parse_credits() with the result.

=cut

sub fetch_metadata {
    my $package = shift;
    my $credits = common::fetch_url($url);
    $package->parse_credits($credits) if defined $credits;
}


=head2 parse_credits

    $self->parse_credits($creditsfile);

Given the contents of the CREDITS file, parse it to an array of hashes, then
extract aliases from that.  The resulting aliases are stored in %aliases.

It expects to find user entries between the leading "----------" and the
trailing "=cut".

This function is separate from scrape_credits so that the testsuite can call
it directly.

=cut

our %aliases;

sub parse_credits {
    my ($package, $credits) = @_;
    my @content = split(/\n/, $credits);
    my $line = '';
    $line = shift(@content) until $line =~ /----------/;
    my $this = {};
    my @entries = $this;

    # parse the file into field structures
    while(@content) {
        # simple state machine.
        $line = shift(@content);
        if($line =~ /^([A-Z]):\s+(.+)/) {
            my ($type, $value) = ($1, $2);
            $$this{$type} = $value;
        }
        if(!length($line)) {
            # a new user entry is starting
            $this = {};
            push(@entries, $this);
        }
    }

    # find aliases
    my %newaliases;
    foreach my $entry (@entries) {
        next unless exists $$entry{U};
        my $username = $$entry{U};
        $newaliases{$$entry{N}} = $username if exists $$entry{N};
        if(exists($$entry{A})) {
            my @aliases = split(/,\s*/,$$entry{A});
            foreach my $alias (@aliases) {
                $alias =~ s/^"?(.+?)"?$/$1/; # strip leading and trailing quotes
                $newaliases{$alias} = $$entry{U};
            }
        }
    }
    common::lprint("karmalog: aliases file parsed, " . scalar(keys %newaliases) . " aliases total");
    %aliases = %newaliases;
}


=head2 emit_karma_message

    $self->emit_karma_message(
        feed    => $feedname,
        rev     => $rev,
        user    => $username,
        log     => \@log,
        link    => $link,
        prefix  => $prefix,
        targets => $targets,
    );

Emit a log message about a commit to the target channels.  This is the method
the subclasses care about.  Username aliases are handled internally.

The message looks like:

feedname: rev | username++ | prefix
feedname: One or more lines of commit log message
feedname: review: http://link/to/googlecode/diff/page

=cut

sub emit_karma_message {
    my ($self, %args) = @_;
    common::put($args{targets}, @{ $self->format_karma_message(%args) });
}

sub karmaize {
    my ($self, $user) = @_;
    return "unknown" unless defined $user;
    $user = $aliases{$user} if exists $aliases{$user};
    $user = "($user)" if $user =~ / /;
    return "$user++";
}

sub format_karma_message {
    my ($self, %args) = @_;
    my $user = $args{user};
    my $feed = $args{feed};
    my $rev  = $args{rev};
    my $end  = $args{prefix};
    my $karma = $self->karmaize($user);
    $end  = "/" unless defined $end;
    $end .= ':' if(defined($args{log}) || defined($args{link}));
    my $link = $args{link};
    if (defined $link && $link =~ m|github.*commit/[0-9a-f]{40}$|) {
        $link = substr($link, 0, length($link)-30);
    }
    my @put;
    push @put, "$rev | $karma | $end";
    push @put, @{ $args{log} // [] };
    push @put, "review: " . $link if defined $link;
    return [ map { "$feed: $_" } @put ];
}


=head2 emit_ticket_karma

    $self->emit_ticket_karma(
        prefix  => 'TT #',
        ticket  => $ticket,
        user    => $username,
        summary => $summary,
        action  => 'closed',
    );

Emit a short log message about a ticket change to the target channels.  Username
aliases are handled internally.

The message looks like:

TT #699 closed by jkeenan++: manifest_tests Makefile target does not work in release tarball

=cut

sub emit_ticket_karma {
    my ($self, %args) = @_;
    common::put($args{targets}, @{ $self->format_ticket_karma(%args) });
}

sub format_ticket_karma {
    my ($self, %args) = @_;
    my $prefix  = $args{prefix};
    my $ticket  = $args{ticket};
    my $user    = $args{user};
    my $summary = $args{summary};
    my $action  = $args{action};
    my $url     = $args{url};
    $user       = "unknown"  unless defined $user;
    $summary    = ""         unless defined $summary;
    $prefix     = "Ticket #" unless defined $prefix;
    $user       = $aliases{$user} if exists $aliases{$user};
    return ["$prefix$ticket $action by $user++: $summary",
           (defined($url) ? "$prefix$ticket: $url" : ())];
}

1;
