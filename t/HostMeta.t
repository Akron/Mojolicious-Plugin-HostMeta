#!/usr/bin/perl
use strict;
use warnings;

$|++;

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

done_testing;
exit;

__END__
