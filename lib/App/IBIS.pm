package App::IBIS;

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

use Catalyst qw/
    -Debug
    ConfigLoader
    Static::Simple
    StackTrace
/;
#    +CatalystX::Profile
#/;

extends 'Catalyst';

use Graphics::ColorObject;

our $VERSION = '0.03';

after setup_finalize => sub {
    my $app = shift;
    my $p = $app->config->{palette};
    for my $t (keys %{$p->{types}}) {
        if ($t =~ /:/) {
            my $hex = $p->{types}{$t};
            # expand 3x to 6x
            #$hex =~ s/^#?([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$/#$1$1$2$2$3$3/;
            #my $co = Graphics::ColorObject->new_RGBhex($hex);
            my $co = Graphics::ColorObject->new($hex);
            warn "$t: " . join ', ', @{$co->as_LCHab};
        }
    }
    #warn Data::Dumper::Dumper($app->config->{palette});
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
