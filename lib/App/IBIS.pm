package App::IBIS;

use 5.012;
use strict;
use warnings FATAL => 'all';

use Moose;
use namespace::autoclean;

use Catalyst::Runtime 5.80;

# Set flags and add plugins for the application.
#
# Note that ORDERING IS IMPORTANT here as plugins are initialized in order,
# therefore you almost certainly want to keep ConfigLoader at the head of the
# list if you're using it.
#
#         -Debug: activates the debug mode for very useful log messages
#   ConfigLoader: will load the configuration from a Config::General file in the
#                 application's home directory
# Static::Simple: will serve static files from the application's root
#                 directory

# XXX NOTE THAT THIS STRUCTURE IS ****EXTREMELY**** SENSITIVE TO
# THE SEQUENCE IT SHOWS UP IN THE CODE. DO NOT FUCK AROUND WITH IT.
BEGIN {
    # this should always go first otherwise it loads up blank
    my @INIT_ARGS = qw/ConfigLoader/;

    # and now the debug modules
    if ($ENV{CATALYST_DEBUG}) {
        # not sure why it doesn't flip these on by default anyway
        push @INIT_ARGS, qw/-Debug StackTrace/;
        push @INIT_ARGS, '+CatalystX::Profile' if int($ENV{CATALYST_DEBUG}) > 1;
    }

    # use this for other init modules
    # push @INIT_ARGS, $whatever;

    # NOTE `perldoc -f use`: this is what `use` is shorthand for
    require Catalyst;
    Catalyst->import(@INIT_ARGS);
}

use CatalystX::RoleApplicator;

# use Catalyst qw/ConfigLoader -Debug StackTrace/;

use Convert::Color   ();
use HTTP::Negotiate  ();
use Unicode::Collate ();
use RDF::Trine       ();

our $VERSION = '0.12';

extends 'Catalyst';

# XXX this thing is dumb; no need to be a role, it's just data
with 'App::IBIS::Role::Schema';
with 'Role::Markup::XML';

__PACKAGE__->apply_request_class_roles(qw/
    Catalyst::TraitFor::Request::ProxyBase
/);

my (@LABELS, @ALT_LAB);

# XXX maybe rig this up so we can configure it via the config file?
has collator => (
    is      => 'ro',
    isa     => 'Unicode::Collate',
    default => sub { Unicode::Collate->new(level => 3, identical => 1) },
);

after setup_finalize => sub {
    my $app = shift;

    # TODO prepare palette
    my $p = $app->config->{palette};
    for my $t (sort keys %{$p->{class}}) {
        if ($t =~ /:/) {
            chomp (my $hex = $p->{class}{$t});

            # correct shorthand hex values and coerce to Convert::Color
            $hex =~ /^#?([0-9A-Fa-f]{3})|([0-9A-Fa-f]{6})$/;
            if ($1 ne '') {
                $hex = 'rgb8:' . join '', map { ($_) x 2 } split //, $1;
            }
             elsif ($2 ne '') {
                $hex = "rgb8:$2";
            }
            else {
                # XXX not sure what to do here
                next;
            }

            my $co = Convert::Color->new($hex);

            $app->log->debug(sprintf "%s\tH:%03.2f\tS:%03.2f\tL:%03.2f",
                             $t, $co->convert_to('husl')->hsl);
        }
    }

    # populate labels

    my $m  = $app->model('RDF');
    my $ns = $m->ns;

    $app->log->debug('Statements: ' . $m->size);
    $app->log->debug('Contexts: '   . join ', ', $m->get_contexts);

    @LABELS  = grep { defined $_ } map { $ns->uri($_) }
        qw(skos:prefLabel rdfs:label foaf:name dct:title
         dc:title dct:identifier dc:identifier rdf:value);
    @ALT_LAB = grep { defined $_ } map { $ns->uri($_) }
        qw(skos:altLabel bibo:shortTitle dct:alternative);

};

# Configure the application.
#
# Note that settings in app_ibis.conf (or other external
# configuration file that you set up manually) take precedence
# over this when using ConfigLoader. Thus configuration
# details given here can function as a default configuration,
# with an external configuration file acting as an override for
# local deployment.

__PACKAGE__->config(
    name => 'App::IBIS',
    # Disable deprecated behavior needed by old applications
    disable_component_resolution_regex_fallback => 1,
    enable_catalyst_header => 0, # Send X-Catalyst header
);

# Start the application
__PACKAGE__->setup;


=head1 NAME

App::IBIS - Catalyst based application

=head1 SYNOPSIS

    script/app_ibis_server.pl

=head1 DESCRIPTION

[enter your description here]

=head1 METHODS

=head2 label_for $SUBJECT

Ghetto-rig a definitive label

=cut

sub label_for {
    my ($c, $s, $alt) = @_;
    return unless $s->is_resource or $s->is_blank;

    my $m  = $c->model('RDF');
    my $g  = $c->graph;
    my $ns = $m->ns;

    # get the sequence of candidates
    my @candidates = $alt ? (@ALT_LAB, @LABELS) : (@LABELS, @ALT_LAB);

    # pull them all out
    my %out;
    for my $p (@candidates) {
        my @coll = grep { $_->is_literal and $_->literal_value !~ /^\s*$/ }
            $m->objects($s, $p, $g);

        $out{$p->uri_value} = \@coll if @coll;
    }

    # now do content negotiation to them
    my (@variants, $qs);
    for my $i (1..@candidates) {
        my $p = $candidates[$i-1];
        $qs = 1/$i;
        for my $o (@{$out{$p->uri_value}}) {
            my $lang = $o->literal_value_language;
            my $size = length $o->literal_value;
            $size = 1/$size unless $alt; # choose the longest one
            push @variants, [[$o, $p], $qs, undef, undef, undef, $lang, $size];
        }
    }

    if (my @out = HTTP::Negotiate::choose(\@variants, $c->req->headers)) {
        my ($o, $p) = @{$out[0][0]};

        return wantarray ? ($o, $p) : $o;
    }
    else {
        return $s;
    }
}

=head2 rdf_cache [ $RESET ]

Retrieve an in-memory cache of everything in C<< $c->graph >>,
optionally resetting it.

=cut

sub rdf_cache {
    my ($c, $reset) = @_;

    my $g = $c->graph;

    my $cache = $c->stash->{graph} ||= {};
    my $model = $cache->{$g->value};

    if ($model) {
        return $model unless $reset;
        # make sure we empty this thing before overwriting it in case
        # there are cyclical references
        $model->_store->nuke;
    }

    $model = $cache->{$g->value} = RDF::Trine::Model->new
        (RDF::Trine::Store::Hexastore->new);

    # run this for side effects
    $c->global_mtime;

    $model->add_iterator
        ($c->model('RDF')->get_statements(undef, undef, undef, $g));

    $model;
}

=head2 global_mtime

this will of course be a per-process mtime of the rdf cache but better than nothing

=cut

sub global_mtime {
    my $c = shift;

    my $g = $c->graph;

    my $mtimes = $c->stash->{mtime} ||= {};

    $mtimes->{$g->value} ||= DateTime->now;
}

=head2 graph

Return the context graph of the instance. The graph defaults to
C<< $c->req->base >> unless it is overridden directly in the
configuration, or otherwise mapped to a different URI.

(We can come back and lock the context down to the user or something
later.)

=cut

sub graph {
    my $c = shift;

    return $c->stash->{context_graph} if $c->stash->{context_graph};

    my $g = $c->req->base;
    $c->log->debug("Using base $g as context");

    if (my $cfg = $c->config->{graph}) {
        my $x = 0;
        if (ref $cfg eq 'HASH') {
            $x = 1;
            $g = $cfg->{$g} || $g;
        }
        elsif (!ref $cfg and $cfg) {
            $x = 1;
            $g = $cfg;
        }

        $c->log->debug("Using context graph $g from config") if $x;
    }

    # i suppose this could theoretically (?)
    $c->stash->{context_graph} = RDF::Trine::iri("$g");
}

=head2 stub %PARAMS

Generate a stub document with all the trimmings.

=cut

sub stub {
    my ($c, %p) = @_;

    #my %ns = (%{$self->uns}, %{$p{ns} || {}});

    # optionally multiple css files
    my $css = $c->config->{css} ||
        ['/asset/font-awesome.css', '/asset/main.css'];
    $css = [$css] unless ref $css;
    my @css = map {
        { rel => 'stylesheet', type => 'text/css',
              href => $c->uri_for($_) }
    } @$css;

    my @link = (
        @css,
        { rel => 'alternate', type => 'application/atom+xml',
          href => $c->uri_for('feed') },
        { rel => 'alternate', type => 'text/turtle',
          href => $c->uri_for('dump') },
        { rel => 'contents index top', href => $c->uri_for('/') },
    );

    if (my $me = $c->whoami) {
        # $c->log->debug("whoami: $me");
        push @link, { rel => 'pav:retrievedBy', href => $me->value };
    }
    # else {
    #     $c->log->debug("no whoami :(");
    # }

    my ($body, $doc) = $c->_XHTML(
        link  => \@link,
        head  => [
            map +{ -name => 'script', type => 'text/javascript',
                   src => $c->uri_for($_) },
            qw(asset/jquery.js asset/rdf asset/d3 asset/rdf-viz
               asset/complex asset/hierarchical asset/main.js) ],
        ns    => $c->uns,
        vocab => $c->uns->xhv->uri,
        %p,
    );

    wantarray ? ($body, $doc) : $doc;
}

=head2 whoami

Attempt to return the C<foaf:Agent> associated with C<REMOTE_USER> if
there is one, otherwise return C<REMOTE_USER> as an
L<RDF::Trine::Node::Resource>, or C<undef> if it is not present.

=cut

sub whoami {
    my $c = shift;
    my $m = $c->rdf_cache;
    my $n = $c->ns;
    my $u = $c->req->remote_user // $c->req->env->{REMOTE_USER} // '';

    # trim the username in case there's spaces etc
    $u =~ s/\A\s*(.*?)\s*\Z/$1/;

    if ($u eq '') {
        $c->log->debug("REMOTE_USER field empty");
    }
    else {
        return $c->stash->{resolved_user} if $c->stash->{resolved_user};

        # if there is no uri scheme then we add one
        unless ($u =~ /^[A-Za-z][0-9A-Za-z+.-]:/) {
            # this is either something email-like or is not
            $u = ($u =~ /@/) ? lc("mailto:$u") : "urn:x-user:$u";
        }

        $c->log->debug("user: $u");

        $u = RDF::Trine::iri($u);
        my %uniq = map { $_->sse => $_ }
            ($m->objects($u, $n->sioc->account_of, undef, type => 'resource'),
             $m->subjects($n->foaf->account, $u));

        # there should only be one of thse
        my @out = sort values %uniq;

        return $c->stash->{resolved_user} = @out ? $out[0] : $u;
    }

    return;
}

=head1 SEE ALSO

L<App::IBIS::Controller::Root>, L<Catalyst>

=head1 AUTHOR

dorian,,,

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
