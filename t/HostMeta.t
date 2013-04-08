#!/usr/bin/perl
use strict;
use warnings;
use lib ('lib', '../lib');

use Test::More;
use Test::Mojo;
use Mojo::JSON;
use Mojolicious::Lite;

my $hm_host = 'hostme.ta';

my $t = Test::Mojo->new;
my $app = $t->app;
$app->plugin('HostMeta');

my $c = Mojolicious::Controller->new;

# Set request information globally
$c->app($app);
$c->req->url->base->parse('http://' . $hm_host);

$app->hook(
  before_dispatch => sub {
    my $c = shift;
    my $base = $c->req->url->base;
    $base->parse('http://' . $hm_host . '/');
    $base->port('');
  });

my $h = $app->renderer->helpers;

# XRD
ok($h->{new_xrd}, 'render_xrd fine.');
ok($h->{render_xrd}, 'render_xrd fine.');

# Util::Endpoint
ok($h->{endpoint}, 'endpoint fine.');

# Hostmeta
ok($h->{hostmeta}, 'hostmeta fine.');

# Complementary check
ok(!exists $h->{foobar}, 'foobar not fine.');

$t->get_ok('/.well-known/host-meta')
    ->status_is(200)
    ->content_type_is('application/xrd+xml')
    ->element_exists('XRD')
    ->element_exists('XRD[xmlns]')
    ->element_exists('XRD[xsi]')
    ->element_exists_not('Link')
    ->element_exists_not('Property')
    ->element_exists('Host')->text_is(Host => $hm_host);

$app->hook(
  'before_serving_hostmeta' => sub {
    my ($c, $xrd) = @_;

    # Set property
    $xrd->property('foo' => 'bar');

    # Check endpoint
    is($c->endpoint('host-meta'),
       "http://$hm_host/.well-known/host-meta",
       'Correct endpoint');
  });

$t->get_ok('/.well-known/host-meta')
    ->status_is(200)
    ->content_type_is('application/xrd+xml')
    ->element_exists('XRD')
    ->element_exists('XRD[xmlns]')
    ->element_exists('XRD[xsi]')
    ->element_exists_not('Link')
    ->element_exists('Property')
    ->element_exists('Property[type="foo"]')
    ->text_is('Property[type="foo"]' => 'bar')
    ->element_exists('Host')->text_is(Host => $hm_host);

$app->callback(
  hostmeta_fetch => sub {
    my ($c, $host) = @_;

    if ($host eq 'example.org') {
      my $xrd = $c->new_xrd;
      $xrd->link(bar => 'foo');
      return $xrd;
    }
    return;
  });

my $xrd = $t->app->hostmeta('example.org');
ok(!$xrd->property, 'Property not found.');
ok(!$xrd->property('bar'), 'Property not found.');
is($xrd->at('Link')->attrs('rel'), 'bar', 'Correct link');
ok(!$xrd->link, 'Empty Link request');
is($xrd->link('bar')->attrs('href'), 'foo', 'Correct link');

my ($test1, $test2) = (1,1);
$app->hook(
  prepare_hostmeta => sub {
    my ($c, $xrd_ref) = @_;
    $xrd_ref->property('permanentcheck' => $test1++ );
  });

$app->hook(
  before_serving_hostmeta => sub {
    my ($c, $xrd_ref) = @_;
    $xrd_ref->property('check' => $test2++ );
  });

$xrd = $c->hostmeta;
is($xrd->property('permanentcheck')->text, 1, 'prepare_hostmeta 1');
is($xrd->property('check')->text, 1, 'before_serving_hostmeta 1');

$xrd = $c->hostmeta;
is($xrd->property('permanentcheck')->text, 1, 'prepare_hostmeta 2');
is($xrd->property('check')->text, 2, 'before_serving_hostmeta 2');

$xrd = $c->hostmeta;
is($xrd->property('permanentcheck')->text, 1, 'prepare_hostmeta 3');
is($xrd->property('check')->text, 3, 'before_serving_hostmeta 3');

$app->hook(
  before_serving_hostmeta => sub {
    my ($c, $xrd_ref) = @_;

    my $link = $xrd_ref->link(salmon => {
      href => 'http://www.sojolicio.us/'
    });
    $link->add('Title' => 'Salmon');
  });

ok($xrd = $c->hostmeta, 'Get local hostmeta');

ok($xrd->expires, 'Expires exists');
ok($xrd->at('Expires')->remove, 'Removed Expires');

is_deeply(
  Mojo::JSON->new->decode($xrd->to_json),
  {"links" => [
    {"rel" => "salmon",
     "titles" => {
       "default" => "Salmon"
     },
     "href" => 'http://www.sojolicio.us/'
   }
  ],
   "properties" => {
     "permanentcheck" => "1",
     "check" => "4",
     "foo" => "bar"
   }
 }, 'json Export');

$t->get_ok('/.well-known/host-meta.json')
    ->status_is(200)
    ->content_type_is('application/json');

# rel parameter
$t->get_ok('/.well-known/host-meta?rel=author')
  ->status_is(200)
  ->element_exists_not('Link[rel="salmon"]');

ok($xrd = $c->hostmeta, 'Get local HostMeta');

is($xrd->property('permanentcheck')->text, 1, 'Property 1');
is($xrd->property('foo')->text, 'bar', 'Property 2');
is($xrd->property('check')->text, 7, 'Property 3');
is($xrd->link('salmon')->attrs('href'), 'http://www.sojolicio.us/', 'Link 1');
ok(!$xrd->link('author'), 'Link 2');

ok($xrd = $c->hostmeta(['author']), 'Get local HostMeta');

is($xrd->property('permanentcheck')->text, 1, 'Property 4');
is($xrd->property('foo')->text, 'bar', 'Property 5');
is($xrd->property('check')->text, 8, 'Property 6');
ok(!$xrd->link('salmon'), 'Link 3');
ok(!$xrd->link('author'), 'Link 4');

$c->hostmeta(
  sub {
    my $xrd = shift;
    is($xrd->property('permanentcheck')->text, 1, 'Property 7');
    is($xrd->property('check')->text, 9, 'Property 8');
    is($xrd->link('salmon')->attrs('href'),
       'http://www.sojolicio.us/', 'Link 5');
});

$c->hostmeta(
  ['author'] => sub {
    my $xrd = shift;
    is($xrd->property('permanentcheck')->text, 1, 'Property 9');
    is($xrd->property('check')->text, 10, 'Property 10');
    ok(!$xrd->link('salmon'), 'Link 6');
});

$c->hostmeta(
  undef, ['author'] => sub {
    my $xrd = shift;
    is($xrd->property('permanentcheck')->text, 1, 'Property 11');
    is($xrd->property('check')->text, 11, 'Property 12');
    ok(!$xrd->link('salmon'), 'Link 7');
});

pass('No life tests');

done_testing;
exit;

is($c->hostmeta('mozilla.com')->link('lrdd')->attrs('template'),
'http://webfinger.mozillalabs.com/webfinger.php?q={uri}',
   'Found mozilla.org');

$c->hostmeta(
  'undef', ['author'] => sub {
    my $xrd = shift;
    ok(!$xrd, 'Not found');
});


is($c->hostmeta('yahoo.com')->subject, 'yahoo.com', 'Title');
ok(!$c->hostmeta('yahoo.com', -secure), 'Not found for secure');

$c->hostmeta(
  'yahoo.com' => sub {
    ok(!$_[0], 'Insecure');
  } => -secure);

$c->hostmeta(
  'yahoo.com' => sub {
    my $xrd = shift;
    is($xrd->link('hub')->attrs('href'),
       'http://yhub.yahoo.com',
       'Correct template');
    is($xrd->subject, 'yahoo.com', 'Title');
  });

$c->hostmeta(
  'e14n.com' => sub {
    my $xrd = shift;
    is($xrd->link('lrdd')->attrs('template'),
       'https://e14n.com/api/lrdd?resource={uri}',
       'Correct template');

    is($xrd->link('registration_endpoint')->attrs('href'),
       'https://e14n.com/api/client/register',
       'Correct template');
});

$c->hostmeta(
  'e14n.com' => ['lrdd'] => sub {
    my $xrd = shift;

    is($xrd->link('lrdd')->attrs('template'),
       'https://e14n.com/api/lrdd?resource={uri}',
       'Correct template');
    ok(!$xrd->link('registration_endpoint'),
       'no registration endpoint');
});

done_testing;
exit;


__END__
