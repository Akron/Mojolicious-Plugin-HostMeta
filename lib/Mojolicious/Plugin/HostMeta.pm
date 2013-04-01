package Mojolicious::Plugin::HostMeta;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::UserAgent;
use Mojo::JSON;
use Mojo::Util qw/quote/;

# Todo: Support async callback
# Todo: Disallow insecure hops

our $VERSION = 0.01;

my $WK_PATH = '/.well-known/host-meta';
my $UA_NAME = __PACKAGE__ . ' v' . $VERSION;

# Register plugin
sub register {
  my ($plugin, $mojo, $param) = @_;

  my $helpers = $mojo->renderer->helpers;

  # Load Util-Endpoint if not already loaded
  unless (exists $helpers->{endpoint}) {
    $mojo->plugin('Util::Endpoint');
  };

  # Load Util-Endpoint if not already loaded
  unless (exists $helpers->{callback}) {
    $mojo->plugin('Util::Callback');
  };

  # Set callbacks on registration
  $mojo->callback(['hostmeta_fetch'] => $param);

  # Load XML if not already loaded
  unless (exists $helpers->{render_xrd}) {
    $mojo->plugin('XRD');
  };

  # Get seconds to expiration
  my $seconds = (60 * 60 * 24 * 10);
  if ($param->{expires} && $param->{expires} =~ /^\d+$/) {
    $seconds = delete $param->{expires};
  };

  my $hostmeta = $mojo->new_xrd;
  $hostmeta->extension('XML::Loy::HostMeta');

  # Get host information on first request
  $mojo->hook(
    prepare_hostmeta =>
      sub {
	my ($c, $xrd_ref) = @_;
	my $host = $c->req->url->to_abs->host;

	# Add host-information to host-meta
	$hostmeta->host($host) if $host;
      }
    );

  # Establish 'hostmeta' helper
  $mojo->helper(
    hostmeta => sub {
      my $c = shift;

      # Host name is provided
      unless ($_[0]) {

	# Return local hostmeta
	return _serve_hostmeta($c, $hostmeta);
      };

      # Return discovered hostmeta
      return _fetch_hostmeta($c, @_);
    });

  # Establish /.well-known/host-meta route
  my $route = $mojo->routes->route($WK_PATH);

  # Define endpoint
  $route->endpoint('host-meta');

  # Set route callback
  $route->to(
    cb => sub {
      my $c = shift;

      # resource parameter
      if (my $res = $c->param('resource')) {

	# LRDD if loaded
	if (exists $helpers->{lrdd}) {
	  my $xrd = $c->lrdd($res => 'localhost');
	  return $c->render_xrd($xrd) if $xrd;
	};

	# Resource not found
	return $c->render_xrd(undef, $res);
      };

      # Seconds given
      if ($seconds) {

	# Set cache control
	my $headers = $c->res->headers;
	$headers->cache_control(
	  "public, max-age=$seconds"
	);

	# Set expires element
	$hostmeta->expires(time + $seconds);

	# Set expires header
	$headers->expires($hostmeta->expires);
      };

      # Serve host-meta document
      return $c->render_xrd(
	_serve_hostmeta($c, $hostmeta)
      );
    });
};


# Get HostMeta document
sub _fetch_hostmeta {
  my $c = shift;

  my $host = lc shift;

  # Get host information
  $host =~ s!^\s*(?:http(s?)://)?([^/]+)/*\s*$!$2! or return;
  my $secure = 1 if $1;

  my $param = shift;
  my $mojo = $c->app;
  my ($res, $rel);

  # Check if security is forced
  $secure = $_[0] && $_[0] eq '-secure' ? 1 : 0;

  # Build resource parameter
  my $res_param = do {
    if ($param) {
      $rel = $param->{rel};
      $res = $param->{resource};
    };
    $res ? '?resource=' . $res : '';
  };

  my $hostmeta_xrd;

  # Resource requested
  if ($res) {
    if (exists $mojo->renderer->helpers->{lrdd}) {

      # Todo: Support lrdd
      return $c->lrdd($host => $res);
    }

    # No support
    else {
      $mojo->log->warn('No support for LRDD');
      return;
    };
  };

  # Callback for caching
  $hostmeta_xrd = $c->callback(
    hostmeta_fetch => $host
  );

  # HostMeta document was cached
  if ($hostmeta_xrd) {
    _filter_rel($hostmeta_xrd, $rel) if $rel;

    # Return cached hostmeta document
    return $hostmeta_xrd;
  };

  # Create host-meta path
  my $host_hm_path = $host . $WK_PATH;

  # Get secure user agent
  my $ua = Mojo::UserAgent->new(
    name => $UA_NAME,
    max_redirects => 0
  );

  # Fetch Host-Meta XRD
  # First try ssl
  my $tx = $ua->get('https://' . $host_hm_path . $res_param);
  my $host_hm;

  if ($host_hm = $tx->success) {
    unless ($host_hm->is_status_class(200)) {

      # if (index($host_hm->res->content_type, 'application') == 0) {
      #   return undef;
      # };

      # Only support secure retrieval
      return if $secure;

      # Update insecure max_redirects;
      $ua->max_redirects(3);

      # Then try insecure
      $tx = $ua->get("http://${host_hm_path}${res_param}");

      # Transaction was successful
      if ($host_hm = $tx->success) {

	# Retrieval was successful
	return unless $host_hm->is_status_class(200);
      }

      # Transaction was not successful
      else {
	return;
      };
    }
  }

  # Transaction was not successful
  else {
    return;
  };

  # Parse XRD
  $hostmeta_xrd = $c->new_xrd($host_hm->body) or return;
  $hostmeta_xrd->extension('XML::Loy::HostMeta');

  # Hook for caching
  $c->app->plugins->emit_hook(
    after_fetching_hostmeta => (
      $c, $host, $hostmeta_xrd, $host_hm->headers
    )
  );

  # Filter relations
  _filter_rel($hostmeta_xrd, $rel) if $rel;

  # Return XRD object
  return $hostmeta_xrd;
};


# Run hooks for preparation and serving of hostmeta
sub _serve_hostmeta {
  my ($c, $hostmeta) = @_;

  my $plugins = $c->app->plugins;
  my $phm = 'prepare_hostmeta';

  # prepare_hostmeta has subscribers
  if ($plugins->has_subscribers( $phm )) {

    # Emit hook for subscribers
    $plugins->emit_hook($phm => ( $c, $hostmeta ));

    # Unsubscribe all subscribers
    foreach (@{ $plugins->subscribers( $phm ) }) {
      $plugins->unsubscribe( $phm => $_ );
    };
  };

  # No further modifications wanted
  unless ($plugins->has_subscribers('before_serving_hostmeta')) {
    return $hostmeta;
  };

  # Clone hostmeta reference
  my $hostmeta_clone = $c->new_xrd($hostmeta->to_xml);

  # Emit 'before_serving_hostmeta' hook
  $plugins->emit_hook(
    before_serving_hostmeta => (
      $c, $hostmeta_clone
    ));

  # Return hostmeta clone
  return $hostmeta_clone;
};


# Filter link relations
sub _filter_rel {
  my ($xrd, $rel) = @_;
  my @rel = ref $rel ? @$rel : split(/\s+/, $rel);

  # Find unwanted link relations
  $rel = 'Link:' . join(':', map { 'not([rel=' . quote($_) . '])'} @rel);

  # Remove unwanted link relations
  $xrd->find($rel)->pluck('remove');
};


1;


__END__

=pod

=head1 NAME

Mojolicious::Plugin::HostMeta - Serve and Retrieve Host-Meta documents

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin('HostMeta');

  # Mojolicious::Lite
  plugin 'HostMeta';

  # In Controllers
  print $self->hostmeta('gmail.com')->link('lrrd');

  print $self->endpoint('host-meta');

=head1 DESCRIPTION

L<Mojolicious::Plugin::HostMeta> is a Mojolicious plugin to serve and
retrieve "well-known" L<Host-Meta|https://tools.ietf.org/html/rfc6415>
documents.


=head1 METHODS

=head2 C<register>

  # Mojolicious
  $app->plugin('HostMeta' => {
    expires => 100
  });

  # Mojolicious::Lite
  plugin 'HostMeta';

Called when registering the plugin.
Accepts one optional parameter C<expires>, which is the number
of seconds the served host-meta should be cached.
Defaults to 10 days.


=head1 HELPERS

=head2 C<hostmeta>

  # In Controller:
  my $xrd = $self->hostmeta;
  $xrd = $self->hostmeta('gmail.com');
  $xrd = $self->hostmeta('sojolicio.us' => {
    rel => 'hub'
  });
  $xrd = $self->hostmeta('gmail.com', -secure);

This helper returns host-meta documents
as L<XML::Loy::XRD> objects with the
L<XML::Loy::HostMeta> extension.

If no host is given, the local host-meta document is returned.
If a hostname is given, the corresponding host-meta document
is retrieved from the host and returned.
In that case an additional hash reference is accepted.
It may include a C<rel> parameter
(see the L<WebFinger|http://tools.ietf.org/html/draft-ietf-appsawg-webfinger>
specification for further explanation)
and may include a C<resource> parameter, which will be passed
to L<WebFinger|Mojolicious::Plugin::WebFinger> if this plugin
is installed.

An additional C<-secure> flag indicates, that discovery is allowed
only over C<https> without redirections.


=head1 ROUTES

The route C</.well-known/host-meta> is established and serves
the host's own host-meta document.
An L<endpoint|Mojolicious::Plugin::Util::Endpoint> called
C<host-meta> is established.


=head1 CALLBACKS

=head2 hostmeta_fetch

  # Establish a callback
  $mojo->callback(
    hostmeta_fetch => sub {
      my ($c, $host) = @_;

      my $doc = $c->chi->get('hostmeta-' . $host);
      return unless $doc;

      # Return document
      return $c->new_xrd($doc);
    }
  );

This callback is released before a host-meta document
is retrieved from a foreign server. The parameters passed to the
callback include the current controller object and the host's
name.

If a L<XML::Loy::XRD> document associated with the requested
host name is returned, the retrieval will stop.

The callback can be established with the
L<callback|Mojolicious::Plugin::Util::Callback/callback>
helper or on registration.

This can be used for caching.

=head1 HOOKS

=head2 prepare_hostmeta

  $mojo->hook(prepare_hostmeta => sub {
    my $c = shift;
    my $hostmeta = shift;
    $hostmeta->link(permanent => '/perma.html');
  };

This hook is run when the host's own host-meta document is
first prepared. The hook passes the current controller
object and the host-meta document as an L<XML::Loy::XRD> object.
This hook is only emitted once for each subscriber.


=head2 before_serving_hostmeta

  $mojo->hook('before_serving_hostmeta' => sub {
    my $c = shift;
    my $hostmeta = shift;
    $hostmeta->link(lrdd => './well-known/host-meta');
  };

This hook is run before the host's own host-meta document is
served. The hook passes the current controller object and
the host-meta document as an L<XML::Loy::XRD> object.


=head2 after_fetching_hostmeta

  $mojo->hook(
    after_fetching_hostmeta => sub {
      my ($c, $host, $xrd, $headers) = @_;

      # Store in cache
      $c->chi->set('hostmeta-' . $host => $xrd->to_xml);
    }
  );

This hook is run after a foreign host-meta document is newly fetched.
The parameters passed to the hook are the current controller object,
the host name, the XRD document as an L<XML::Loy::XRD> object
and the L<headers|Mojo::Headers> object of the response.

This hook is not released after a successful LRDD resource request.

This can be used for caching.


=head1 EXAMPLE

The C<examples/> folder contains a full working example application with serving
and discovery.
The example has an additional dependency of L<CHI>.

It can be started using the daemon, morbo or hypnotoad.

  $ perl examples/hostmetaapp daemon

This example may be a good starting point for your own implementation.


=head1 DEPENDENCIES

L<Mojolicious> (best with SSL support),
L<Mojolicious::Plugin::Util::Endpoint>,
L<Mojolicious::Plugin::Util::Callback>,
L<Mojolicious::Plugin::XRD>.


=head1 AVAILABILITY

  https://github.com/Akron/Mojolicious-Plugin-HostMeta


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011-2013, L<Nils Diewald|http://nils-diewald.de/>.

This program is free software, you can redistribute it
and/or modify it under the same terms as Perl.

=cut
