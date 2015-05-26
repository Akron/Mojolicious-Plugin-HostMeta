#!/usr/bin/env perl
use 5.010001;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::HostMeta',
  AUTHOR       => 'Nils Diewald',
  ABSTRACT     => 'Serve and Retrieve Host-Meta Documents',
  VERSION_FROM => 'lib/Mojolicious/Plugin/HostMeta.pm',
  BUILD_REQUIRES => {
    'Test::More' => 0
  },
  PREREQ_PM => {
    'Mojolicious' => 6.08,
    'XML::Loy' => 0.40,
    'Mojolicious::Plugin::XML::Loy' => 0.13,
    'Mojolicious::Plugin::XRD' => 0.16,
    'Mojolicious::Plugin::Util::Endpoint' => 0.13,
    'Mojolicious::Plugin::Util::Callback' => 0.02
  },
  LICENSE      => 'artistic_2',
  META_MERGE   => {
    requires  => { perl => '5.010001' },
    resources => {
      license     => 'http://www.opensource.org/licenses/artistic-license-2.0',
      repository  => 'https://github.com/Akron/Mojolicious-Plugin-HostMeta'
    }
  },
  MIN_PERL_VERSION => '5.010001',
  test => {TESTS => 't/*.t'}
);
