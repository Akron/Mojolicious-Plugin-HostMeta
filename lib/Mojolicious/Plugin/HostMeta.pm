package Mojolicious::Plugin::HostMeta;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::UserAgent;
use Mojo::JSON;
use Mojo::Util qw/quote/;
use Mojo::IOLoop;
use Scalar::Util 'weaken';

# Todo:
# - Add Acceptance for XRD and JRD and JSON as a header

our $VERSION = 0.03;


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

      # Undefined host name
      shift if !defined $_[0];

      # Host name is provided
      if (!$_[0] || ref $_[0]) {

	# Return local hostmeta
	return _serve_hostmeta($c, $hostmeta, @_);
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

  # Check if security is forced
  my $secure = $_[-1] && $_[-1] eq '-secure' ? pop : 0;

  # Get callback
  my $cb = pop if ref($_[-1]) && ref($_[-1]) eq 'CODE';

  # Get host information
  unless ($host =~ s!^\s*(?:http(s?)://)?([^/]+)/*\s*$!$2!) {
    return;
  };
  $secure = 1 if $1;

  # Build relations parameter
  my $rel;
  $rel = shift if $_[0] && ref $_[0] eq 'ARRAY';

  # Callback for caching
  my $hostmeta_xrd = $c->callback(
    hostmeta_fetch => $host
  );

  # HostMeta document was cached
  if ($hostmeta_xrd) {
    _filter_rel($hostmeta_xrd, $rel) if $rel;

    # Return cached hostmeta document
    return $cb->($hostmeta_xrd) if $cb;
    return $hostmeta_xrd;
  };

  # Create host-meta path
  my $host_hm_path = $host . $WK_PATH;

  # Get secure user agent
  my $ua = Mojo::UserAgent->new(
    name => $UA_NAME,
    max_redirects => ($secure ? 0 : 3)
  );

  # Is blocking
  unless ($cb) {

    # Fetch Host-Meta XRD - first try ssl
    my $tx = $ua->get('https://' . $host_hm_path);
    my $host_hm;

    # Transaction was not successful
    return unless $host_hm = $tx->success;

    unless ($host_hm->is_status_class(200)) {

      # Only support secure retrieval
      return if $secure;

      # Update insecure max_redirects;
      $ua->max_redirects(3);

      # Then try insecure
      $tx = $ua->get('http://' . $host_hm_path);

      # Transaction was not successful
      return unless $host_hm = $tx->success;

      # Retrieval was successful
      return unless $host_hm->is_status_class(200);
    };

    # Parse hostmeta document
    return _parse_hostmeta($c, $host, $host_hm, $rel);
  };

  # Non-blocking
  # Create delay for https with or without redirection
  my $delay = Mojo::IOLoop->delay(
    sub {
      my $delay = shift;

      # Get with https - possibly without redirects
      $ua->get('https://' . $host_hm_path => $delay->begin);
    },
    sub {
      my $delay = shift;
      my $tx = shift;

      # Get response
      if (my $host_hm = $tx->success) {

	# Fine
	if ($host_hm->is_status_class(200)) {

	  # Parse hostmeta document
	  return $cb->(
	    _parse_hostmeta($c, $host, $host_hm, $rel)
	  );
	};

	# Only support secure retrieval
	return $cb->(undef) if $secure;
      }

      # Fail
      else {
	return $cb->(undef);
      };

      # Try http with redirects
      $delay->steps(
	sub {
	  my $delay = shift;

	  # Get with http and redirects
	  $ua->max_redirects(3)
	    ->get(
	      'http://' . $host_hm_path =>
		$delay->begin
	      );
	},
	sub {
	  my $delay = shift;

	  # Transaction was successful
	  if (my $host_hm = pop->success) {

	    # Retrieval was not successful
	    if ($host_hm->is_status_class(200)) {

	      # Parse hostmeta document
	      return $cb->(
		_parse_hostmeta($c, $host, $host_hm, $rel)
	      );
	    }
	  };

	  # Fail
	  return $cb->(undef);
	});
    }
  );

  # Wait if IOLoop is not running
  $delay->wait unless Mojo::IOLoop->is_running;
  return;
};


# Run hooks for preparation and serving of hostmeta
sub _serve_hostmeta {
  my $c = shift;
  my $hostmeta = shift;

  # Ignore security flag
  pop if $_[-1] && $_[-1] eq '-secure';

  # Get callback
  my $cb = pop if ref($_[-1]) && ref($_[-1]) eq 'CODE';

  my $rel = shift;

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
    return $cb->($hostmeta) if $cb;
    return $hostmeta;
  };

  # Clone hostmeta reference
  my $hostmeta_clone = $c->new_xrd($hostmeta->to_xml);

  # Emit 'before_serving_hostmeta' hook
  $plugins->emit_hook(
    before_serving_hostmeta => (
      $c, $hostmeta_clone
    ));

  # Filter relations
  _filter_rel($hostmeta_clone, $rel) if $rel;

  # Return hostmeta clone
  return $cb->($hostmeta_clone) if $cb;
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


# Parse hostmeta body
sub _parse_hostmeta {
  my ($c, $host, $host_hm, $rel) = @_;

  # Parse XRD
  my $hostmeta_xrd = $c->new_xrd($host_hm->body) or return;
  $hostmeta_xrd->extension('XML::Loy::HostMeta');

  # Hook for caching
  $c->app->plugins->emit_hook(
    after_fetching_hostmeta => (
      $c, $host, $hostmeta_xrd, $host_hm->headers->clone
    )
  );

  # Filter relations
  _filter_rel($hostmeta_xrd, $rel) if $rel;

  # Return XRD object
  return $hostmeta_xrd;
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

  # Serves XRD or JRD from /.well-known/host-meta

  # Blocking requests
  print $self->hostmeta('gmail.com')->link('lrrd');

  # Non-blocking requests
  $self->hostmeta('gmail.com' => sub {
    print shift->link('lrrd');
  });

=head1 DESCRIPTION

L<Mojolicious::Plugin::HostMeta> is a Mojolicious plugin to serve and
request "well-known" L<Host-Meta|https://tools.ietf.org/html/rfc6415>
documents.


=head1 METHODS

=head2 C<register>

  # Mojolicious
  $app->plugin(HostMeta => {
    expires => 100
  });

  # Mojolicious::Lite
  plugin 'HostMeta';

Called when registering the plugin.
Accepts one optional parameter C<expires>, which is the number
of seconds the served host-meta should be cached by the fetching client.
Defaults to 10 days.


=head1 HELPERS

=head2 C<hostmeta>

  # In Controller:
  my $xrd = $self->hostmeta;
  $xrd = $self->hostmeta('gmail.com');
  $xrd = $self->hostmeta('sojolicio.us' => ['hub']);
  $xrd = $self->hostmeta('gmail.com', -secure);

  # Non blocking
  $self->hostmeta('gmail.com', ['hub'] => sub {
    my $xrd = shift;
    # ...
  }, -secure);

This helper returns host-meta documents
as L<XML::Loy::XRD> objects with the
L<XML::Loy::HostMeta> extension.

If no host name is given, the local host-meta document is returned.
If a host name is given, the corresponding host-meta document
is retrieved from the host and returned.

An additional array reference may limit the relations to be retrieved
(see the L<WebFinger|http://tools.ietf.org/html/draft-ietf-appsawg-webfinger>
specification for further explanation).
A final C<-secure> flag indicates, that discovery is allowed
only over C<https> without redirections.

This method can be used in a blocking or non-blocking way.
For non-blocking retrievel, pass a callback function as the
last argument before the optional C<-secure> flag to the method.


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
This should be used for dynamical changes of the document
for each request.


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

This can be used for caching.


=head1 ROUTES

The route C</.well-known/host-meta> is established and serves
the host's own host-meta document.
An L<endpoint|Mojolicious::Plugin::Util::Endpoint> called
C<host-meta> is established.


=head1 EXAMPLE

The C<examples/> folder contains a full working example application
with serving and discovery.
The example has an additional dependency of L<CHI>.

It can be started using the daemon, morbo or hypnotoad.

  $ perl examples/hostmetaapp daemon

This example may be a good starting point for your own implementation.

A less advanced application using non-blocking requests without caching
is also available in the C<examples/> folder. It can be started using
the daemon, morbo or hypnotoad as well.

  $ perl examples/hostmetaapp-async daemon


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
