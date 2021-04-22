package CGI::Tiny;

use strict;
use warnings;
use Carp ();
use IO::Handle ();
use Exporter 'import';

our $VERSION = '0.004';

our @EXPORT = 'cgi';

# List from HTTP::Status 6.29
# Unmarked codes are from RFC 7231 (2017-12-20)
my %HTTP_STATUS = (
    100 => 'Continue',
    101 => 'Switching Protocols',
    102 => 'Processing',                      # RFC 2518: WebDAV
    103 => 'Early Hints',                     # RFC 8297: Indicating Hints
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    203 => 'Non-Authoritative Information',
    204 => 'No Content',
    205 => 'Reset Content',
    206 => 'Partial Content',                 # RFC 7233: Range Requests
    207 => 'Multi-Status',                    # RFC 4918: WebDAV
    208 => 'Already Reported',                # RFC 5842: WebDAV bindings
    226 => 'IM Used',                         # RFC 3229: Delta encoding
    300 => 'Multiple Choices',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',                    # RFC 7232: Conditional Request
    305 => 'Use Proxy',
    307 => 'Temporary Redirect',
    308 => 'Permanent Redirect',              # RFC 7528: Permanent Redirect
    400 => 'Bad Request',
    401 => 'Unauthorized',                    # RFC 7235: Authentication
    402 => 'Payment Required',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    407 => 'Proxy Authentication Required',   # RFC 7235: Authentication
    408 => 'Request Timeout',
    409 => 'Conflict',
    410 => 'Gone',
    411 => 'Length Required',
    412 => 'Precondition Failed',             # RFC 7232: Conditional Request
    413 => 'Payload Too Large',
    414 => 'URI Too Long',
    415 => 'Unsupported Media Type',
    416 => 'Range Not Satisfiable',           # RFC 7233: Range Requests
    417 => 'Expectation Failed',
    418 => 'I\'m a teapot',                   # RFC 2324: HTCPC/1.0  1-april
    421 => 'Misdirected Request',             # RFC 7540: HTTP/2
    422 => 'Unprocessable Entity',            # RFC 4918: WebDAV
    423 => 'Locked',                          # RFC 4918: WebDAV
    424 => 'Failed Dependency',               # RFC 4918: WebDAV
    425 => 'Too Early',                       # RFC 8470: Using Early Data in HTTP
    426 => 'Upgrade Required',
    428 => 'Precondition Required',           # RFC 6585: Additional Codes
    429 => 'Too Many Requests',               # RFC 6585: Additional Codes
    431 => 'Request Header Fields Too Large', # RFC 6585: Additional Codes
    451 => 'Unavailable For Legal Reasons',   # RFC 7725: Legal Obstacles
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout',
    505 => 'HTTP Version Not Supported',
    506 => 'Variant Also Negotiates',         # RFC 2295: Transparant Ngttn
    507 => 'Insufficient Storage',            # RFC 4918: WebDAV
    508 => 'Loop Detected',                   # RFC 5842: WebDAV bindings
    509 => 'Bandwidth Limit Exceeded',        #           Apache / cPanel
    510 => 'Not Extended',                    # RFC 2774: Extension Framework
    511 => 'Network Authentication Required', # RFC 6585: Additional Codes
);

my @DAYS_OF_WEEK = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH_NAMES = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %MONTH_NUMS;
@MONTH_NUMS{@MONTH_NAMES} = 0..11;

sub epoch_to_date {
  my ($sec,$min,$hour,$mday,$mon,$year,$wday) = gmtime $_[0];
  return sprintf '%s, %02d %s %04d %02d:%02d:%02d GMT',
    $DAYS_OF_WEEK[$wday], $mday, $MONTH_NAMES[$mon], $year + 1900, $hour, $min, $sec;
}

sub date_to_epoch {
  # RFC 1123 (Sun, 06 Nov 1994 08:49:37 GMT)
  my ($mday,$mon,$year,$hour,$min,$sec) = $_[0] =~ m/^ (?:Sun|Mon|Tue|Wed|Thu|Fri|Sat),
    [ ] ([0-9]{2}) [ ] (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ ] ([0-9]{4})
    [ ] ([0-9]{2}) : ([0-9]{2}) : ([0-9]{2}) [ ] GMT $/x;

  # RFC 850 (Sunday, 06-Nov-94 08:49:37 GMT)
  ($mday,$mon,$year,$hour,$min,$sec) = $_[0] =~ m/^ (?:Sun|Mon|Tues|Wednes|Thurs|Fri|Satur)day,
    [ ] ([0-9]{2}) - (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) - ([0-9]{2})
    [ ] ([0-9]{2}) : ([0-9]{2}) : ([0-9]{2}) [ ] GMT $/x unless defined $mday;

  # asctime (Sun Nov  6 08:49:37 1994)
  ($mon,$mday,$hour,$min,$sec,$year) = $_[0] =~ m/^ (?:Sun|Mon|Tue|Wed|Thu|Fri|Sat)
    [ ] (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ ]{1,2} ([0-9]{1,2})
    [ ] ([0-9]{2}) : ([0-9]{2}) : ([0-9]{2}) [ ] ([0-9]{4}) $/x unless defined $mday;

  return undef unless defined $mday;

  require Time::Local;
  # 4 digit years interpreted literally, but may have leading zeroes
  # 2 digit years interpreted with best effort heuristic
  return scalar Time::Local::timegm($sec, $min, $hour, $mday, $MONTH_NUMS{$mon},
    (length($year) == 4 && $year < 1900) ? $year - 1900 : $year);
}

# for cleanup in END in case of premature exit
my %PENDING_CGI;

sub cgi (&) {
  my ($handler) = @_;
  my $cgi = bless {pid => $$}, __PACKAGE__;
  my $cgi_key = 0+$cgi;
  $PENDING_CGI{$cgi_key} = $cgi; # don't localize, so premature exit can clean up in END
  my ($error, $errored);
  {
    local $@;
    eval { local $_ = $cgi; $handler->(); 1 } or do { $error = $@; $errored = 1 };
  }
  if ($errored) {
    _handle_error($cgi, $error);
  } elsif (!$cgi->{headers_rendered}) {
    _handle_error($cgi, "cgi completed without rendering a response\n");
  }
  delete $PENDING_CGI{$cgi_key};
  1;
}

# cleanup of premature exit, more reliable than potentially doing this in global destruction
# ModPerl::Registry or CGI::Compile won't run END after each request,
# but they override exit to throw an exception which we handle already
END {
  foreach my $key (keys %PENDING_CGI) {
    my $cgi = delete $PENDING_CGI{$key};
    _handle_error($cgi, "cgi exited without rendering a response\n") unless $cgi->{headers_rendered};
  }
}

sub _handle_error {
  my ($cgi, $error) = @_;
  return unless $cgi->{pid} == $$; # in case of fork
  $cgi->{response_status} = "500 $HTTP_STATUS{500}" unless $cgi->{headers_rendered} or defined $cgi->{response_status};
  if (defined(my $handler = $cgi->{on_error})) {
    my ($error_error, $error_errored);
    {
      local $@;
      eval { $handler->($cgi, $error); 1 } or do { $error_error = $@; $error_errored = 1 };
    }
    return unless $cgi->{pid} == $$; # in case of fork in error handler
    if ($error_errored) {
      warn "Exception in error handler: $error_error";
      warn "Original error: $error";
    }
  } else {
    warn $error;
  }
  $cgi->render(text => 'Internal Server Error') unless $cgi->{headers_rendered};
}

sub set_error_handler      { $_[0]{on_error} = $_[1]; $_[0] }
sub set_request_body_limit { $_[0]{request_body_limit} = $_[1]; $_[0] }
sub set_input_handle       { $_[0]{input_handle} = $_[1]; $_[0] }
sub set_output_handle      { $_[0]{output_handle} = $_[1]; $_[0] }

sub auth_type         { defined $ENV{AUTH_TYPE} ? $ENV{AUTH_TYPE} : '' }
sub content_length    { defined $ENV{CONTENT_LENGTH} ? $ENV{CONTENT_LENGTH} : '' }
sub content_type      { defined $ENV{CONTENT_TYPE} ? $ENV{CONTENT_TYPE} : '' }
sub gateway_interface { defined $ENV{GATEWAY_INTERFACE} ? $ENV{GATEWAY_INTERFACE} : '' }
sub path_info         { defined $ENV{PATH_INFO} ? $ENV{PATH_INFO} : '' }
sub path_translated   { defined $ENV{PATH_TRANSLATED} ? $ENV{PATH_TRANSLATED} : '' }
sub query_string      { defined $ENV{QUERY_STRING} ? $ENV{QUERY_STRING} : '' }
sub remote_addr       { defined $ENV{REMOTE_ADDR} ? $ENV{REMOTE_ADDR} : '' }
sub remote_host       { defined $ENV{REMOTE_HOST} ? $ENV{REMOTE_HOST} : '' }
sub remote_ident      { defined $ENV{REMOTE_IDENT} ? $ENV{REMOTE_IDENT} : '' }
sub remote_user       { defined $ENV{REMOTE_USER} ? $ENV{REMOTE_USER} : '' }
sub request_method    { defined $ENV{REQUEST_METHOD} ? $ENV{REQUEST_METHOD} : '' }
sub script_name       { defined $ENV{SCRIPT_NAME} ? $ENV{SCRIPT_NAME} : '' }
sub server_name       { defined $ENV{SERVER_NAME} ? $ENV{SERVER_NAME} : '' }
sub server_port       { defined $ENV{SERVER_PORT} ? $ENV{SERVER_PORT} : '' }
sub server_protocol   { defined $ENV{SERVER_PROTOCOL} ? $ENV{SERVER_PROTOCOL} : '' }
sub server_software   { defined $ENV{SERVER_SOFTWARE} ? $ENV{SERVER_SOFTWARE} : '' }
*method = \&request_method;
*path = \&path_info;
*query = \&query_string;

sub query_pairs { [@{$_[0]->_query_params->{ordered}}] }
sub query_params {
  my ($self) = @_;
  my %params;
  my $keyed = $self->_query_params->{keyed};
  foreach my $key (keys %$keyed) {
    my @values = @{$keyed->{$key}};
    $params{$key} = @values > 1 ? \@values : $values[0];
  }
  return \%params;
}
sub query_param       { my $p = $_[0]->_query_params->{keyed}; exists $p->{$_[1]} ? $p->{$_[1]}[-1] : undef }
sub query_param_array { my $p = $_[0]->_query_params->{keyed}; exists $p->{$_[1]} ? [@{$p->{$_[1]}}] : [] }

sub _query_params {
  my ($self) = @_;
  unless (exists $self->{query_params}) {
    my (@ordered, %keyed);
    foreach my $pair (split /[&;]/, $self->query) {
      my ($key, $value) = split /=/, $pair, 2;
      $value = '' unless defined $value;
      do { tr/+/ /; s/%([0-9a-fA-F]{2})/chr hex $1/ge; utf8::decode $_ } for $key, $value;
      push @ordered, [$key, $value];
      push @{$keyed{$key}}, $value;
    }
    $self->{query_params} = {ordered => \@ordered, keyed => \%keyed};
  }
  return $self->{query_params};
}

sub headers { +{%{$_[0]->_headers}} }
sub header { (my $name = $_[1]) =~ tr/-/_/; $ENV{"HTTP_\U$name"} }

sub _headers {
  my ($self) = @_;
  unless (exists $self->{request_headers}) {
    my %headers;
    foreach my $key (keys %ENV) {
      my $name = $key;
      next unless $name =~ s/^HTTP_//;
      $name =~ tr/_/-/;
      $headers{lc $name} = $ENV{$key};
    }
    $self->{request_headers} = \%headers;
  }
  return $self->{request_headers};
}

sub cookies { +{%{$_[0]->_cookies}} }
sub cookie { $_[0]->_cookies->{$_[1]} }

sub _cookies {
  my ($self) = @_;
  unless (exists $self->{request_cookies}) {
    $self->{request_cookies} = {};
    if (defined $ENV{HTTP_COOKIE}) {
      foreach my $pair (split /\s*;\s*/, $ENV{HTTP_COOKIE}) {
        next unless length $pair;
        my ($name, $value) = split /=/, $pair, 2;
        $self->{request_cookies}{$name} = $value if defined $value;
      }
    }
  }
  return $self->{request_cookies};
}

sub body {
  my ($self) = @_;
  unless (exists $self->{content}) {
    my $limit = $self->{request_body_limit};
    $limit = $ENV{CGI_TINY_REQUEST_BODY_LIMIT} unless defined $limit;
    $limit = 16777216 unless defined $limit;
    my $length = $ENV{CONTENT_LENGTH} || 0;
    if ($limit and $length > $limit) {
      $self->{response_status} = "413 $HTTP_STATUS{413}" unless $self->{headers_rendered};
      die "Request body limit exceeded\n";
    }
    $_[0]{content} = '';
    my $offset = 0;
    my $in_fh = defined $self->{input_handle} ? $self->{input_handle} : *STDIN;
    binmode $in_fh;
    while ($length > 0) {
      my $chunk = 131072;
      $chunk = $length if $length and $length < $chunk;
      last unless my $read = read $in_fh, $_[0]{content}, $chunk, $offset;
      $offset += $read;
      $length -= $read;
    }
  }
  return $self->{content};
}

sub body_pairs { [@{$_[0]->_body_params->{ordered}}] }
sub body_params {
  my ($self) = @_;
  my %params;
  my $keyed = $self->_body_params->{keyed};
  foreach my $key (keys %$keyed) {
    my @values = @{$keyed->{$key}};
    $params{$key} = @values > 1 ? \@values : $values[0];
  }
  return \%params;
}
sub body_param       { my $p = $_[0]->_body_params->{keyed}; exists $p->{$_[1]} ? $p->{$_[1]}[-1] : undef }
sub body_param_array { my $p = $_[0]->_body_params->{keyed}; exists $p->{$_[1]} ? [@{$p->{$_[1]}}] : [] }

sub _body_params {
  my ($self) = @_;
  unless (exists $self->{body_params}) {
    my (@ordered, %keyed);
    if ($ENV{CONTENT_TYPE} and $ENV{CONTENT_TYPE} =~ m/^application\/x-www-form-urlencoded/i) {
      foreach my $pair (split /&/, $self->body) {
        my ($key, $value) = split /=/, $pair, 2;
        $value = '' unless defined $value;
        do { tr/+/ /; s/%([0-9a-fA-F]{2})/chr hex $1/ge; utf8::decode $_ } for $key, $value;
        push @ordered, [$key, $value];
        push @{$keyed{$key}}, $value;
      }
    }
    $self->{body_params} = {ordered => \@ordered, keyed => \%keyed};
  }
  return $self->{body_params};
}

sub body_json {
  my ($self) = @_;
  unless (exists $self->{body_json}) {
    if ($ENV{CONTENT_TYPE} and $ENV{CONTENT_TYPE} =~ m/^application\/json/i) {
      $self->{body_json} = $self->_json->decode($self->body);
    }
  }
  return $self->{body_json};
}

sub add_response_header {
  my ($self, $name, $value) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to add HTTP response header '$name' but headers have already been rendered";
  } else {
    push @{$self->{response_headers}}, [$name, $value];
  }
  return $self;
}

my %COOKIE_ATTR_VALUE = (expires => 1, domain => 1, path => 1, secure => 0, httponly => 0, samesite => 1, 'max-age' => 1);
sub add_response_cookie {
  my ($self, $name, $value, @attrs) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to add HTTP response cookie '$name' but headers have already been rendered";
  } else {
    my $cookie_str = "$name=$value";
    my $i = 0;
    while ($i <= $#attrs) {
      my ($key, $val) = @attrs[$i, $i+1];
      my $has_value = $COOKIE_ATTR_VALUE{lc $key};
      if (!defined $has_value) {
        Carp::carp "Attempted to set unknown cookie attribute '$key'";
      } elsif ($has_value) {
        $cookie_str .= "; $key=$val" if defined $val;
      } else {
        $cookie_str .= "; $key" if $val;
      }
    } continue {
      $i += 2;
    }
    push @{$self->{response_headers}}, ['Set-Cookie', $cookie_str];
  }
  return $self;
}

sub set_response_status {
  my ($self, $status) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set HTTP response status but headers have already been rendered";
  } else {
    if ($status =~ m/^[0-9]+\s/) {
      $self->{response_status} = $status;
    } else {
      Carp::croak "Attempted to set unknown HTTP response status $status" unless exists $HTTP_STATUS{$status};
      $self->{response_status} = "$status $HTTP_STATUS{$status}";
    }
  }
  return $self;
}

sub set_response_content_type {
  my ($self, $content_type) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set HTTP response content type but headers have already been rendered";
  } else {
    $self->{response_content_type} = $content_type;
  }
  return $self;
}

sub set_response_charset { $_[0]{response_charset} = $_[1]; $_[0] }

sub set_nph {
  my ($self, $value) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set NPH response mode but headers have already been rendered";
  } else {
    $self->{nph} = $value;
  }
  return $self;
}

sub headers_rendered { $_[0]{headers_rendered} }

my %known_types = (json => 1, html => 1, xml => 1, text => 1, data => 1, redirect => 1);

sub render {
  my ($self, $type, $data) = @_;
  $type = '' unless defined $type;
  Carp::croak "Don't know how to render '$type'" if length $type and !exists $known_types{$type};
  my $charset = $self->{response_charset};
  $charset = 'UTF-8' unless defined $charset;
  my $out_fh = defined $self->{output_handle} ? $self->{output_handle} : *STDOUT;
  if (!$self->{headers_rendered}) {
    my @headers = @{$self->{response_headers} || []};
    my $headers_str = '';
    my %headers_set;
    foreach my $header (@headers) {
      my ($name, $value) = @$header;
      $headers_str .= "$name: $value\r\n";
      $headers_set{lc $name} = 1;
    }
    if (!$headers_set{location} and $type eq 'redirect') {
      $headers_str = "Location: $data\r\n$headers_str";
    }
    if (!$headers_set{'content-type'} and $type ne 'redirect') {
      my $content_type = $self->{response_content_type};
      $content_type =
          $type eq 'json' ? 'application/json;charset=UTF-8'
        : $type eq 'html' ? "text/html;charset=$charset"
        : $type eq 'xml'  ? "application/xml;charset=$charset"
        : $type eq 'text' ? "text/plain;charset=$charset"
        : 'application/octet-stream'
        unless defined $content_type;
      $headers_str = "Content-Type: $content_type\r\n$headers_str";
    }
    if (!$headers_set{date}) {
      my $date_str = epoch_to_date(time);
      $headers_str = "Date: $date_str\r\n$headers_str";
    }
    my $status = $self->{response_status};
    $status = "302 $HTTP_STATUS{302}" if !defined $status and $type eq 'redirect';
    if ($self->{nph}) {
      $status = "200 $HTTP_STATUS{200}" unless defined $status;
      my $protocol = $ENV{SERVER_PROTOCOL};
      $protocol = 'HTTP/1.0' unless defined $protocol and length $protocol;
      $headers_str = "$protocol $status\r\n$headers_str";
      my $server = $ENV{SERVER_SOFTWARE};
      $headers_str .= "Server: $server\r\n" if defined $server and length $server;
    } elsif (!$headers_set{status} and defined $status) {
      $headers_str = "Status: $status\r\n$headers_str";
    }
    binmode $out_fh;
    $out_fh->printflush("$headers_str\r\n");
    $self->{headers_rendered} = 1;
  } elsif ($type eq 'redirect') {
    Carp::carp "Attempted to render a redirect but headers have already been rendered";
  }
  if ($type eq 'json') {
    $out_fh->printflush($self->_json->encode($data));
  } elsif ($type eq 'html' or $type eq 'xml' or $type eq 'text') {
    require Encode;
    $out_fh->printflush(Encode::encode($charset, "$data"));
  } elsif ($type eq 'data') {
    $out_fh->printflush($data);
  }
}

sub _json {
  my ($self) = @_;
  unless (exists $self->{json}) {
    local $@;
    if (eval { require Cpanel::JSON::XS; Cpanel::JSON::XS->VERSION('4.09'); 1 }) {
      $self->{json} = Cpanel::JSON::XS->new->allow_dupkeys->stringify_infnan;
    } else {
      require JSON::PP;
      $self->{json} = JSON::PP->new;
    }
    $self->{json}->utf8->canonical->allow_nonref->allow_unknown->allow_blessed->convert_blessed->escape_slash;
  }
  return $self->{json};
}

1;

=head1 NAME

CGI::Tiny - Common Gateway Interface, with no frills

=head1 SYNOPSIS

  #!/usr/bin/perl
  use strict;
  use warnings;
  use CGI::Tiny;

  cgi {
    my $cgi = $_;
    $cgi->set_error_handler(sub {
      my ($cgi, $error) = @_;
      warn $error;
      $cgi->render(json => {error => 'Internal Error'}) unless $cgi->headers_rendered;
    });
    my $method = $cgi->method;
    my $fribble;
    if ($method eq 'GET') {
      $fribble = $cgi->query_param('fribble');
    } elsif ($method eq 'POST') {
      $fribble = $cgi->body_param('fribble');
    } else {
      $cgi->set_response_status(405);
      $cgi->render;
      exit;
    }
    die "Invalid fribble parameter" unless length $fribble;
    $cgi->render(json => {fribble => $fribble});
  };

=head1 DESCRIPTION

CGI::Tiny provides a modern interface to write
L<CGI|https://en.wikipedia.org/wiki/Common_Gateway_Interface> scripts to
dynamically respond to HTTP requests. It is intended to be:

=over

=item * Minimal

CGI::Tiny contains a small amount of code and (on modern Perls) no non-core
requirements. No framework needed.

=item * Simple

CGI::Tiny is straightforward to use, avoids anything magical or surprising, and
provides easy access to the most commonly needed features.

=item * Robust

CGI::Tiny's interface is designed to help the developer avoid common pitfalls
and vulnerabilities by default.

=item * Lazy

CGI::Tiny only loads code or processes information once it is needed, so simple
requests can be handled without unnecessary overhead.

=item * Restrained

CGI::Tiny is designed for the CGI protocol which executes the program again for
every request. It is not suitable for persistent protocols like FastCGI or
PSGI.

=item * Flexible

CGI::Tiny can be used with other modules to handle tasks like routing and
templating, and doesn't impose unnecessary constraints to reading input or
rendering output.

=back

Most applications are better written in a L<PSGI>-compatible framework (e.g.
L<Dancer2> or L<Mojolicious>) and deployed in a persistent application server
so that the application does not have to start up again every time it receives
a request. CGI::Tiny, and the CGI protocol in general, is only suited for
restricted deployment environments that can only run CGI scripts, or
applications that don't need to scale.

See L</"COMPARISON TO CGI.PM">.

This module's interface is currently I<EXPERIMENTAL> and may be changed
incompatibly if needed.

=head1 USAGE

=for Pod::Coverage cgi

CGI::Tiny's interface is a regular function called C<cgi> exported by default.

  cgi {
    my $cgi = $_;
    # set up error handling on $cgi
    # inspect request data via $cgi
    # set response headers if needed via $cgi
    # render response data with $cgi->render
  };

The code block is immediately run with C<$_> set to a CGI::Tiny object, which
L</"METHODS"> can be called on to read request information and render a
response.

If an exception is thrown within the code block, or the code block does not
render a response, it will run the handler set by L</"set_error_handler"> if
any, or by default emit the error as a warning and (if nothing has been
rendered yet) render a 500 Internal Server Error.

Note that the C<cgi> block's current implementation as a regular exported
subroutine is an implementation detail, and future implementations reserve the
right to provide it as an XSUB or keyword for performance reasons. You should
not rely on C<@_> to be set, and you should not use C<return> to exit the
block; use C<exit> to end a CGI script early after rendering a response.

=head1 EXTENDING

CGI::Tiny is a minimal interface to the CGI protocol, but can be extended with
the use of other CPAN modules.

=head2 Fatpacking

L<App::FatPacker> can be used to pack CGI::Tiny, as well as any other pure-perl
dependencies, into a CGI script so that it can be deployed to other systems
without having to install the dependencies there. As a bonus, this means the
script doesn't have to load those modules separately from disk on every
execution.

  $ fatpack pack script.source.cgi > script.cgi

=head2 JSON

CGI::Tiny has built in support for parsing and rendering JSON content with
L<JSON::PP>. CGI scripts that deal with JSON content will greatly benefit from
installing L<Cpanel::JSON::XS> version C<4.09> or newer for efficient encoding
and decoding, which will be used automatically if available.

=head2 Templating

HTML and XML responses are most easily managed with templating. A number of
CPAN modules provide this capability.

L<Text::Xslate> is an efficient template engine designed for HTML/XML.

  #!/usr/bin/perl
  use strict;
  use warnings;
  use utf8;
  use CGI::Tiny;
  use Text::Xslate;
  use Data::Section::Simple 'get_data_section';

  cgi {
    my $cgi = $_;
    my $foo = $cgi->query_param('foo');
    my $tx = Text::Xslate->new(path => ['templates'], cache => 0);

    # from templates/
    $cgi->render(html => $tx->render('index.tx', {foo => $foo}));

    # from __DATA__
    my $template = get_data_section 'index.tx';
    $cgi->render(html => $tx->render_string($template, {foo => $foo}));
  };

  __DATA__
  @@ index.tx
  <html><body><h1><: $foo :></h1></body></html>

L<Mojo::Template> is a lightweight HTML/XML template engine in the L<Mojo>
toolkit.

  #!/usr/bin/perl
  use strict;
  use warnings;
  use utf8;
  use CGI::Tiny;
  use Mojo::Template;
  use Mojo::File 'curfile';
  use Mojo::Loader 'data_section';

  cgi {
    my $cgi = $_;
    my $foo = $cgi->query_param('foo');
    my $mt = Mojo::Template->new(auto_escape => 1, vars => 1);

    # from templates/
    my $template_path = curfile->sibling('templates', 'index.html.ep');
    $cgi->render(html => $mt->render_file($template_path, {foo => $foo}));

    # from __DATA__
    my $template = data_section __PACKAGE__, 'index.html.ep';
    $cgi->render(html => $mt->render($template, {foo => $foo}));
  };

  __DATA__
  @@ index.html.ep
  <html><body><h1><%= $foo %></h1></body></html>

=head2 Routing

Web applications use routing to serve multiple types of requests from one
application. L<Routes::Tiny> can be used to organize this with CGI::Tiny, using
C<REQUEST_METHOD> and C<PATH_INFO> (which is the URL path after the CGI script
name).

  #!/usr/bin/perl
  use strict;
  use warnings;
  use CGI::Tiny;
  use Routes::Tiny;

  my %dispatch = (
    foos => sub {
      my ($cgi) = @_;
      my $method = $cgi->method;
      ...
    },
    get_foo => sub {
      my ($cgi, $captures) = @_;
      my $id = $captures->{id};
      ...
    },
    put_foo => sub {
      my ($cgi, $captures) = @_;
      my $id = $captures->{id};
      ...
    },
  );

  cgi {
    my $cgi = $_;

    my $routes = Routes::Tiny->new;
    # /script.cgi/foo
    $routes->add_route('/foo', name => 'foos');
    # /script.cgi/foo/42
    $routes->add_route('/foo/:id', method => 'GET', name => 'get_foo');
    $routes->add_route('/foo/:id', method => 'PUT', name => 'put_foo');

    if (defined(my $match = $routes->match($cgi->path, method => $cgi->method))) {
      $dispatch{$match->name}->($cgi, $match->captures);
    } else {
      $cgi->set_response_status(404);
      $cgi->render(text => 'Not Found');
    }
  };

=head1 METHODS

The following methods can be called on the CGI::Tiny object provided to the
C<cgi> code block.

=head2 Setup

=head3 set_error_handler

  $cgi = $cgi->set_error_handler(sub {
    my ($cgi, $error) = @_;
    ...
  });

Sets an error handler to run in the event of an exception. If the response
status has not been set by L</"set_response_status"> or rendering headers, it
will default to 500 when this handler is called.

The error value can be any exception thrown by Perl or user code. It should
generally not be included in any response rendered to the client, but instead
warned or logged.

Exceptions may occur before or after response headers have been rendered, so
error handlers should render some response if L</"headers_rendered"> is
false.

If the error handler itself throws an exception, that error and the original
error will be emitted as a warning. If no response has been rendered after the
error handler completes or dies, the default 500 Internal Server Error response
will be rendered.

=head3 set_request_body_limit

  $cgi = $cgi->set_request_body_limit(16*1024*1024);

Sets the limit in bytes for parsing a request body into memory. If not set,
defaults to the value of the C<CGI_TINY_REQUEST_BODY_LIMIT> environment
variable or 16777216 (16 MiB). Since the request body is not parsed until
needed, methods that parse the whole request body into memory like L</"body">
will set the response status to C<413 Payload Too Large> and throw an exception
if the content length is over the limit. A value of 0 will remove the limit
(not recommended unless you have other safeguards on memory usage).

=head3 set_input_handle

  $cgi = $cgi->set_input_handle($fh);

Sets the input handle to read the request body from. If not set, reads from
C<STDIN>. The handle will have C<binmode> applied before reading to remove any
translation layers.

=head3 set_output_handle

  $cgi = $cgi->set_output_handle($fh);

Sets the output handle to print the response to. If not set, prints to
C<STDOUT>. The handle will have C<binmode> applied before printing to remove
any translation layers.

=head2 Request

=head3 auth_type

=head3 content_length

=head3 content_type

=head3 gateway_interface

=head3 path_info

=head3 path_translated

=head3 query_string

=head3 remote_addr

=head3 remote_host

=head3 remote_ident

=head3 remote_user

=head3 request_method

=head3 script_name

=head3 server_name

=head3 server_port

=head3 server_protocol

=head3 server_software

  my $type   = $cgi->content_type;   # CONTENT_TYPE
  my $method = $cgi->request_method; # REQUEST_METHOD
  my $port   = $cgi->server_port;    # SERVER_PORT

Access to L<request meta-variables|https://tools.ietf.org/html/rfc3875#section-4.1>
of the equivalent uppercase names. Since CGI does not distinguish between
missing and empty values, missing values will be normalized to an empty string.

=head3 method

=head3 path

=head3 query

  my $method = $cgi->method; # REQUEST_METHOD
  my $path   = $cgi->path;   # PATH_INFO
  my $query  = $cgi->query;  # QUERY_STRING

Short aliases for a few request meta-variables.

=head3 query_pairs

  my $pairs = $cgi->query_pairs;

Retrieve URL query string parameters as an array reference of two-element array
references.

=head3 query_params

  my $params = $cgi->query_params;

Retrieve URL query string parameters as a hash reference. If a parameter name
is passed multiple times, its value will be an array reference.

=head3 query_param

  my $value = $cgi->query_param('foo');

Retrieve value of a named URL query string parameter. If the parameter name is
passed multiple times, returns the last value. Use L</"query_param_array"> to
get multiple values of a parameter.

=head3 query_param_array

  my $arrayref = $cgi->query_param_array('foo');

Retrieve values of a named URL query string parameter as an array reference.

=head3 headers

  my $hashref = $cgi->headers;

Hash reference of available request header names and values. Header names are
represented in lowercase.

=head3 header

  my $value = $cgi->header('Accept');

Retrieve the value of a request header by name (case insensitive). CGI request
headers can only contain a single value, which may be combined from multiple
values.

=head3 cookies

  my $hashref = $cgi->cookies;

Hash reference of request cookie names and values.

=head3 cookie

  my $value = $cgi->cookie('foo');

Retrieve the value of a request cookie by name.

=head3 body

  my $bytes = $cgi->body;

Retrieve the request body as bytes.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head3 body_pairs

  my $pairs = $cgi->body_pairs;

Retrieve C<x-www-form-urlencoded> body parameters as an array reference of
two-element array references.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head3 body_params

  my $params = $cgi->body_params;

Retrieve C<x-www-form-urlencoded> body parameters as a hash reference. If a
parameter name is passed multiple times, its value will be an array reference.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head3 body_param

  my $value = $cgi->body_param('foo');

Retrieve value of a named C<x-www-form-urlencoded> body parameter. If the
parameter name is passed multiple times, returns the last value. Use
L</"body_param_array"> to get multiple values of a parameter.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head3 body_param_array

  my $arrayref = $cgi->body_param_array('foo');

Retrieve values of a named C<x-www-form-urlencoded> body parameter as an array
reference.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head3 body_json

  my $data = $cgi->body_json;

Decode an C<application/json> request body from UTF-8-encoded JSON.

Note that this will read the whole request body into memory, so make sure the
L</"set_request_body_limit"> can fit well within the available memory.

=head2 Response

=head3 add_response_header

  $cgi = $cgi->add_response_header('Content-Disposition' => 'attachment');

Adds a response header. No effect after response headers have been rendered.

Note that header names are case insensitive and CGI::Tiny does not attempt to
deduplicate or munge headers that have been added manually. Headers are printed
in the response in the same order added, and adding the same header multiple
times will result in multiple instances of that response header.

=head3 add_response_cookie

  $cgi = $cgi->add_response_cookie($name => $value,
    Expires   => 'Sun, 06 Nov 1994 08:49:37 GMT',
    HttpOnly  => 1,
    'Max-Age' => 3600,
    Path      => '/foo',
    SameSite  => 'Strict',
    Secure    => 1,
  );

Adds a response cookie. No effect after response headers have been rendered.

Note that cookie values should only consist of ASCII characters and may not
contain any control characters, space characters, or the characters C<",;\>.
More complex values can be encoded to UTF-8 and L<base64|MIME::Base64> for
transport.

  use Encode 'encode';
  use MIME::Base64 'encode_base64';
  $cgi->add_response_cookie(foo => encode_base64(encode('UTF-8', $value), ''));

  use Encode 'decode';
  use MIME::Base64 'decode_base64';
  my $value = decode 'UTF-8', decode_base64 $cgi->cookie('foo');

Structures can be encoded to JSON and base64 for transport.

  use Cpanel::JSON::XS 'encode_json';
  use MIME::Base64 'encode_base64';
  $cgi->add_response_cookie(foo => encode_base64(encode_json(\%hash), ''));

  use Cpanel::JSON::XS 'decode_json';
  use MIME::Base64 'decode_base64';
  my $hashref = decode_json decode_base64 $cgi->cookie('foo');

Optional cookie attributes are specified in key-value pairs after the cookie
name and value. Cookie attribute names are case-insensitive.

=over

=item Domain

Domain for which cookie is valid.

=item Expires

Expiration date string for cookie. L</"epoch_to_date"> can be used to generate
the appropriate date string format.

=item HttpOnly

If set to a true value, the cookie will be restricted from client-side scripts.

=item Max-Age

Max age of cookie before it expires, in seconds, as an alternative to
specifying C<Expires>.

=item Path

URL path for which cookie is valid.

=item SameSite

C<Strict> to restrict the cookie to requests from the same site, C<Lax> to
allow it additionally in certain cross-site requests. This attribute is
currently part of a draft specification so its handling may change, but it is
supported by most browsers.

=item Secure

If set to a true value, the cookie will be restricted to HTTPS requests.

=back

=head3 set_response_status

  $cgi = $cgi->set_response_status(404);
  $cgi = $cgi->set_response_status('500 Internal Server Error');

Sets the response HTTP status code. No effect after response headers have been
rendered.

A full status string including a human-readable message will be used as-is. A
bare status code must be a known
L<HTTP status code|https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml>
and will have the standard human-readable message appended.

The CGI protocol assumes a status of C<200 OK> if no response status is set.

=head3 set_response_content_type

  $cgi = $cgi->set_response_content_type('application/xml');

Sets the response Content-Type header, to override autodetection. No effect
after response headers have been rendered.

=head3 set_response_charset

  $cgi = $cgi->set_response_charset('UTF-8');

Set charset to use when rendering C<text>, C<html>, or C<xml> response data,
defaults to C<UTF-8>.

=head3 set_nph

  $cgi = $cgi->set_nph(1);

If set to a true value before rendering response headers, CGI::Tiny will act as
a L<NPH (Non-Parsed Header)|https://tools.ietf.org/html/rfc3875#section-5>
script and render full HTTP response headers. This may be required for some CGI
servers, or enable unbuffered responses or HTTP extensions not supported by the
CGI server.

No effect after response headers have been rendered.

=head3 headers_rendered

  my $bool = $cgi->headers_rendered;

Returns true if response headers have been rendered, such as by the first call
to L</"render">.

=head3 render

  $cgi->render;
  $cgi->render(html => $html);
  $cgi->render(xml  => $xml);
  $cgi->render(text => $text);
  $cgi->render(data => $bytes);
  $cgi->render(json => $ref);
  $cgi->render(redirect => $url);

Renders response data of a type indicated by the first parameter, if any. The
first time it is called will render response headers and set
L</"headers_rendered">, and it may be called additional times with more
response data.

The C<Content-Type> response header will be set according to
L</"set_response_content_type">, or autodetected depending on the data type
passed in the first call to C<render>, or to C<application/octet-stream> if
there is no more appropriate value.

C<html>, C<xml>, or C<text> data is expected to be decoded characters, and will
be encoded according to L</"set_response_charset"> (UTF-8 by default). C<json>
data will be encoded to UTF-8.

C<redirect> will set a C<Location> header if response headers have not yet been
rendered, and will set a response status of 302 if none has been set by
L</"set_response_status">. It will not set a C<Content-Type> response header.
If response headers have already been rendered a warning will be emitted.

The C<Date> response header will be set to the current time as an HTTP date
string if not set manually.

=head1 FUNCTIONS

The following convenience functions are provided but not exported.

=head2 epoch_to_date

  my $date = CGI::Tiny::epoch_to_date $epoch;

Convert a Unix epoch timestamp, such as returned by C<time>, to a RFC 1123 HTTP
date string suitable for use in HTTP headers such as C<Date> and C<Expires>.

=head2 date_to_epoch

  my $epoch = CGI::Tiny::date_to_epoch $date;

Parse a RFC 1123 HTTP date string to a Unix epoch timestamp. For compatibility
as required by L<RFC 7231|https://tools.ietf.org/html/rfc7231#section-7.1.1.1>,
legacy RFC 850 and ANSI C asctime date formats are also recognized. Returns
C<undef> if the string does not parse as any of these formats.

  # RFC 1123
  my $epoch = CGI::Tiny::date_to_epoch 'Sun, 06 Nov 1994 08:49:37 GMT';

  # RFC 850
  my $epoch = CGI::Tiny::date_to_epoch 'Sunday, 06-Nov-94 08:49:37 GMT';

  # asctime
  my $epoch = CGI::Tiny::date_to_epoch 'Sun Nov  6 08:49:37 1994';

=head1 ENVIRONMENT

CGI::Tiny recognizes the following environment variables, in addition to the
standard CGI environment variables.

=head2 CGI_TINY_REQUEST_BODY_LIMIT

Default value for L</"set_request_body_limit">.

=head1 COMPARISON TO CGI.PM

Traditionally, the L<CGI> module (referred to as CGI.pm to differentiate it
from the CGI protocol) has been used to write Perl CGI scripts. This module
fills a similar need but has a number of interface differences to be aware of.

=over

=item *

There is no global CGI::Tiny object; the object is constructed for the scope of
the C<cgi> block, only reads request data from the environment once it is
accessed, and once the block completes (normally or abnormally), it ensures
that a valid response is rendered to avoid gateway errors.

=item *

Instead of global variables like C<$CGI::POST_MAX>, global behavior settings
are applied to the CGI::Tiny object inside the C<cgi> block.

=item *

Exceptions within the C<cgi> block are handled by default by rendering a server
error response and emitting the error as a warning. This can be customized with
L</"set_error_handler">.

=item *

Request query and body parameter accessors in CGI::Tiny are not context
sensitive. L</"query_param"> and L</"body_param"> always return a single value,
and L</"query_param_array"> and L</"body_param_array"> must be used to retrieve
multi-value parameters. CGI::Tiny also does not have a method-sensitive
C<param> accessor; query or body parameters must be accessed specifically.

=item *

CGI::Tiny decodes request query and body parameters from UTF-8 to Unicode
characters by default, and L</"render"> provides methods to encode response
data from Unicode characters to UTF-8 or other charsets automatically.

=item *

In CGI.pm, response headers must be printed manually before any response data
is printed to avoid malformed responses. In CGI::Tiny, the L</"render"> method
is used to print response data, and automatically prints response headers the
first time it is called. C<redirect> responses are also handled by
L</"render">.

=item *

In CGI::Tiny, a custom response status is set by calling
L</"set_response_status"> before the first L</"render">, which only requires
the status code and will add the appropriate human-readable status message
itself.

=item *

Response setters are distinct methods from request accessors in CGI::Tiny.
L</"content_type">, L</"header">, and L</"cookie"> are used to access request
data, and L</"set_response_content_type">, L</"add_response_header">, and
L</"add_response_cookie"> are used to set response headers for the pending
response before the first call to L</"render">.

=item *

CGI::Tiny does not provide any HTML generation helpers, as this functionality
is much better implemented by other robust implementations on CPAN; see
L</"Templating">.

=item *

CGI::Tiny does not do any implicit encoding of cookie values or the C<Expires>
header or cookie attribute. The L</"epoch_to_date"> convenience function is
provided to render appropriate C<Expires> date values.

=back

There are a number of alternatives to CGI.pm but they do not sufficiently
address the design issues; primarily, none of them gracefully handle
exceptions or failure to render a response, and several of them have no
features for rendering responses.

=over

=item *

L<CGI::Simple> shares all of the interface design problems of CGI.pm, though it
does not reimplement the HTML generation helpers.

=item *

L<CGI::Thin> is ancient and only implements parsing of request query or body
parameters.

=item *

L<CGI::Minimal> has context-sensitive parameter accessors, and only implements
parsing of request query/body parameters and uploads.

=item *

L<CGI::Lite> has context-sensitive parameter accessors, and only implements
parsing of request query/body parameters, uploads, and cookies.

=item *

L<CGI::Easy> has a robust interface, but pre-parses all request information.

=back

=head1 CAVEATS

CGI is an extremely simplistic protocol and relies particularly on the global
state of environment variables and the C<STDIN> and C<STDOUT> standard
filehandles. CGI::Tiny does not prevent you from messing with these interfaces
directly, but it may result in confusion.

CGI::Tiny eschews certain sanity checking for performance reasons. For example,
Content-Type and other header values set for the response should only contain
ASCII text with no control characters, but CGI::Tiny does not verify this.

=head1 TODO

=over

=item * Uploads/multipart request

=item * Debugging tools

=back

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book <dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2021 by Dan Book.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<CGI::Alternatives>, L<Mojolicious>, L<Dancer2>
