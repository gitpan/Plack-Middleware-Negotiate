package Plack::Middleware::Negotiate;
#ABSTRACT: Apply HTTP content negotiation as Plack middleware
our $VERSION = '0.07'; #VERSION

use strict;
use v5.10.1;
use parent 'Plack::Middleware';

use Plack::Util::Accessor qw(formats parameter extension);
use Plack::Request;
use HTTP::Negotiate qw(choose);
use Carp qw(croak);

use Log::Contextual::Easy::Default;

sub prepare_app {
    my $self = shift;

    croak __PACKAGE__ . ' requires formats'
        unless $self->formats and %{$self->formats};

    $self->formats->{_} //= { };

    unless ($self->formats->{_}->{type}) {
        foreach (grep { $_ ne '_' } keys %{$self->formats}) {
            croak __PACKAGE__ . " format requires type: $_"
                unless $self->formats->{$_}->{type};
        }
    }

    $self->app( sub {
        [ 406, ['Content-Type'=>'text/plain'], ['Not Acceptable']];
    } ) unless $self->app;
}

sub call {
    my ($self, $env) = @_;

    my $orig_path = $env->{PATH_INFO};

    my $format = $self->negotiate($env);
    $env->{'negotiate.format'} = $format;

    my $app;
    if ( $format and $self->formats->{$format} ) {
        $app = $self->formats->{$format}->{app};
    }
    $app //= $self->app;

    Plack::Util::response_cb( $app->($env), sub {
        my $res = shift;
        $self->add_headers( $res->[1], $env->{'negotiate.format'} );
        $env->{PATH_INFO} = $orig_path;
        $res;
    });
}

sub add_headers { # TODO: use Plack::Util or P:M:Headers
    my ($self, $headers, $name) = @_;

    my $format = $self->about($name) || return;
    my $fields = { @$headers };

    if (!$fields->{'Content-Type'}) {
        my $type = $format->{type};
        $type .= "; charset=". $format->{charset}
            if $format->{charset};
        push @$headers, 'Content-Type' => $type;
    }

    push @$headers, 'Content-Language' => $format->{language}
        if $format->{language} and !$fields->{'Content-Language'};
}

sub negotiate {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    if (defined $self->parameter) {
        my $param = $self->parameter;
        if ($env->{QUERY_STRING} =~ /(^|&)$param=([^&]+)/) {
            my $format = $2;
            if ( ($format // '_') ne '_' and $self->known($format) ) {
                log_trace { "format $format chosen based on query parameter" };
                unless ( $env->{QUERY_STRING} =~ s/&$param=([^&]+)//) {
                    $env->{QUERY_STRING} =~ s/^$param=([^&]+)&?//;
                }
                return $format;
            }
        }
    }

    if ($self->extension and $req->path =~ /\.([^.]+)$/ and $self->known($1)) {
        my $format = $1;
        $env->{PATH_INFO} =~ s/\.$format$//
            if $self->extension eq 'strip';
        log_trace { "format $format chosen based on extension" };
        return $format;
    }

    my $format = choose($self->variants, $req->headers);
    log_trace { "format $format chosen based on HTTP content negotiation" };

    return $format;
}

sub known {
    my ($self, $name) = @_;
    return exists $self->formats->{$name};
}

sub about {
    my ($self, $name) = @_;

    return unless defined $name and $name ne '_';

    my $default = $self->formats->{_};
    my $format  = $self->formats->{$name} || return;

    return {
        quality  => $format->{quality} // $default->{quality} // 1,
        type     => $format->{type} // $default->{type},
        encoding => $format->{encoding} // $default->{encoding},
        charset  => $format->{charset} // $default->{charset},
        language => $format->{language} // $default->{language},
    };
}

sub variants {
    my $self = shift;
    return [ 
        sort { $a->[0] cmp $b->[0] }
        map { 
            my $format = $self->about($_);
            [ 
                $_, 
                $format->{quality},
                $format->{type}, 
                $format->{encoding},
                $format->{charset},
                $format->{language},
                0 
        ] } 
        grep { $_ ne '_' } keys %{$self->formats}
    ];
}

1;

__END__

=pod

=head1 NAME

Plack::Middleware::Negotiate - Apply HTTP content negotiation as Plack middleware

=head1 VERSION

version 0.07

=head1 SYNOPSIS

    builder {
        enable 'Negotiate',
            formats => {
                xml  => { 
                    type    => 'application/xml',
                    charset => 'utf-8',
                },
                html => { type => 'text/html', language => 'en' },
                _    => { size => 0 }  # default values for all formats           
            },
            parameter => 'format', # e.g. http://example.org/foo?format=xml
            extension => 'strip';  # e.g. http://example.org/foo.xml
        $app; # neither html nor xml requested
    };

=head1 DESCRIPTION

Plack::Middleware::Negotiate applies HTTP content negotiation to a L<PSGI>
request. The PSGI environment key C<negotiate.format> is set to the chosen
format name. In addition to normal content negotiation one may enable explicit
format selection with a path extension or query parameter. The middleware takes
care for rewriting and restoring PATH_INFO if it is configured to detect and
strip a format extension. The PSGI response is enriched with corresponding HTTP
headers Content-Type and Content-Language unless these headers already exist.

If used as pure application, this middleware returns a HTTP status code 406 if
no format could be negotiated.

=head1 METHODS

=head2 new( formats => { ... } [ %argument ] )

Creates a new negotiation middleware with a given set of formats.

Each format can be defined with C<type>, C<quality> (defaults to 1),
C<encoding>, C<charset>, and C<language>. The special format name C<_>
(underscore) is reserved to define default values for all formats.

Formats can also be used to directly route the request to a PSGI application:

    my $app = Plack::Middleware::Negotiate->new(
        formats => {
            json => { 
                type => 'application/json',
                app  => $json_app,
            },
            html => {
                type => 'text/html',
                app  => $html_app,
            }
        }
    );

=head2 negotiate( $env )

Chooses a format based on a PSGI request. The request is first checked for
explicit format selection via C<parameter> and C<extension> (if configured) and
then passed to L<HTTP::Negotiate>. Returns the format name. May modify the PSGI
request environment keys PATH_INFO and SCRIPT_NAME if format was selected by
extension set to C<strip>, and strips the C<format> query parameter from
QUERY_STRING if C<parameter> is set to a known format.

=head2 about( $format )

If the format was specified, this method returns a hash with C<quality>,
C<type>, C<encoding>, C<charset>, and C<language>. Missing values are set to
the default.

=head2 known( $format )

Tells whether a format name is known. By default this is the case if the format
name exists in the list of formats.

=head2 variants

Returns a list of content variants to be used in L<HTTP::Negotiate>. The return
value is an array reference of array references, each with seven elements:
format name, source quality, type, encoding, charset, language, and size. The
size is always zero.

=head2 add_headers( \@headers, $format )

Add apropriate HTTP response headers for a format unless the headers are
already given.

=encoding utf8

=head1 METHODS

=head1 CONFIGURATION

=over

=item formats

A list of formats to choose among.

=item parameter

Enables explicit format selection with a query paramater, for instance
'C<format>'.

=item extension

Enables explicit format selection with a virtual file extension. The value
'C<strip>' strips a known format name from the request path. The value
'C<keep>' keeps the format name extension after format selection.

=back

=head1 LOGGING AND DEBUGGUNG

Plack::Middleware::Negotiate uses C<Log::Contextual> to emit a logging message
during content negotiation on logging level <trace>. Just set:

    $ENV{PLACK_MIDDLEWARE_NEGOTIATE_TRACE} = 1;

=head1 LIMITATIONS

The Content-Encoding HTTP response header is not automatically set on a
response and content negotiation based on size is not supported. Feel free to
comment on whether and how this middleware should support both.

=head1 SEE ALSO

Content negotiation in this module is based on L<HTTP::Negotiate>. See 
L<HTTP::Headers::ActionPack::ContentNegotiation> for an alternative approach.
This module has some overlap with L<Plack::Middleware::SetAccept>.

=head1 AUTHOR

Jakob Voß <voss@gbv.de>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Jakob Voß.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
