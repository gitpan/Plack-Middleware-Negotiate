use strict;
use warnings;
use v5.10.1;
use Test::More;
use Plack::Builder;
use Plack::Test;
use HTTP::Request::Common;

my $app = sub { [200,[],[shift->{'negotiate.format'}]] };

my $stack = builder {
	enable 'Negotiate',
		formats => {
			utf8 => { charset => 'utf-8' },
			iso => { charset => 'iso-8859-1' },
			_ 	=> { type => 'text/html' },
		};
	$app;	
};

test_psgi $stack => sub {
	my $cb = shift;

	my $res = $cb->(GET '/', 'Accept-Charset' => 'utf-8' );
	is $res->content, 'utf8', 'selected utf8';
	is $res->header('Content-Type'), 'text/html; charset=utf-8', 'set content-type';
	
	$res = $cb->(GET '/', 'Accept-Charset' => 'iso-8859-1' );
	is $res->content, 'iso', 'selected iso';
	is $res->header('Content-Type'), 'text/html; charset=iso-8859-1', 'set content-type';

	$res = $cb->(GET '/', 'Accept-Charset' => 'iso-8859-1', Accept => 'text/html; charset=utf8' );
	is $res->content, 'iso', 'selected iso (Accept-Charset has priority)';
	is $res->header('Content-Type'), 'text/html; charset=iso-8859-1', 'set content-type';
};

done_testing;
