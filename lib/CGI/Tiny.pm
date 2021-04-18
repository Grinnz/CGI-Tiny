package CGI::Tiny;

use strict;
use warnings;
use Carp ();
use Encode ();
use Exporter 'import';

our $VERSION = '0.001';

our @EXPORT = qw(cgi cgi_on_error cgi_request_body_limit);

# List from HTTP::Status
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

my %ON_ERROR;
my %BODY_LIMIT;

sub cgi (&) {
  my ($handler) = @_;
  my $cgi = bless {}, __PACKAGE__;
  my ($error, $errored);
  {
    local $@;
    eval { $handler->($cgi); die "No response rendered by cgi\n" unless $cgi->{headers_rendered}; 1 }
      or do { $error = $@; $errored = 1 };
  }
  if ($errored) {
    my $caller = caller;
    $cgi->set_status(500) unless $cgi->{headers_rendered} or defined $cgi->{response_status};
    if (exists $ON_ERROR{$caller}) {
      my ($error_error, $error_errored);
      {
        local $@;
        eval { $ON_ERROR{$caller}->($cgi, $error); 1 } or do { $error_error = $@; $error_errored = 1 };
      }
      if ($error_errored) {
        warn "Exception in cgi_on_error: $error_error";
        warn "Original error: $error";
      }
    } else {
      warn $error;
    }
    $cgi->render(text => 'Internal Server Error') unless $cgi->{headers_rendered};
  }
  1;
}

sub cgi_on_error (&) { $ON_ERROR{scalar caller} = $_[0] }
sub cgi_request_body_limit { $BODY_LIMIT{scalar caller} = $_[0] }

sub headers_rendered { $_[0]{headers_rendered} }

sub request_method  { $ENV{REQUEST_METHOD} }
*method = \&request_method;
sub server_protocol { $ENV{SERVER_PROTOCOL} }
sub server_port     { $ENV{SERVER_PORT} }
sub path_info       { $ENV{PATH_INFO} }
*path = \&path_info;
sub script_name     { $ENV{SCRIPT_NAME} }
sub query_string    { $ENV{QUERY_STRING} }
*query = \&query_string;
sub remote_addr     { $ENV{REMOTE_ADDR} }
sub content_type    { $ENV{CONTENT_TYPE} }
sub content_length  { $ENV{CONTENT_LENGTH} }

sub header { (my $name = $_[1]) =~ tr/-/_/; $ENV{"HTTP_\U$name"} }
sub header_names { [sort keys %{$_[0]->_headers}] }
sub headers { {%{$_[0]->_headers}} }

sub _headers {
  my ($self) = @_;
  unless (exists $self->{request_headers}) {
    my %headers;
    foreach my $key (sort keys %ENV) {
      my $name = $key;
      next unless $name =~ s/^HTTP_//;
      $name =~ tr/_/-/;
      $headers{lc $name} = $ENV{$key};
    }
    $self->{request_headers} = \%headers;
  }
  return $self->{request_headers};
}

sub query_pairs { [@{$_[0]->_query_params->{ordered}}] }
sub query_params {
  my ($self) = @_;
  my %params;
  my $keyed = $self->_query_params->{keyed};
  foreach my $key (%$keyed) {
    my @values = @{$keyed->{$key}};
    $params{$key} = @values > 1 ? \@values : $values[0];
  }
  return \%params;
}
sub query_param { my $p = $_[0]->_query_params->{keyed}; exists $p->{$_[1]} ? $p->{$_[1]}[-1] : undef }
sub every_query_param { my $p = $_[0]->_query_params->{keyed}; exists $p->{$_[1]} ? [@{$p->{$_[1]}}] : [] }

sub _query_params {
  my ($self) = @_;
  unless (exists $self->{query_params}) {
    my (@ordered, %keyed);
    foreach my $pair (split /[&;]/, $self->query) {
      my ($key, $value) = split /=/, $pair, 2;
      $value = '' unless defined $value;
      do { s/%([0-9a-fA-F]{2})/chr hex $1/ge; utf8::decode $_ } for $key, $value;
      push @ordered, [$key, $value];
      push @{$keyed{$key}}, $value;
    }
    $self->{query_params} = {ordered => \@ordered, keyed => \%keyed};
  }
  return $self->{query_params};
}

sub body {
  my ($self) = @_;
  unless (exists $self->{content}) {
    my $limit = $BODY_LIMIT{scalar caller};
    $limit = $ENV{CGI_TINY_REQUEST_BODY_LIMIT} unless defined $limit;
    $limit = 16777216 unless defined $limit;
    my $length = $ENV{CONTENT_LENGTH} || 0;
    if ($limit and $length > $limit) {
      $self->set_status(413);
      die "Request body limit exceeded\n";
    }
    $_[0]{content} = '';
    my $offset = 0;
    binmode *STDIN;
    while ($length > 0) {
      my $chunk = 131072;
      $chunk = $length if $length and $length < $chunk;
      last unless my $read = read *STDIN, $_[0]{content}, $chunk, $offset;
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
  foreach my $key (%$keyed) {
    my @values = @{$keyed->{$key}};
    $params{$key} = @values > 1 ? \@values : $values[0];
  }
  return \%params;
}
sub body_param { my $p = $_[0]->_body_params->{keyed}; exists $p->{$_[1]} ? $p->{$_[1]}[-1] : undef }
sub every_body_param { my $p = $_[0]->_body_params->{keyed}; exists $p->{$_[1]} ? [@{$p->{$_[1]}}] : [] }

sub _body_params {
  my ($self) = @_;
  unless (exists $self->{body_params}) {
    my (@ordered, %keyed);
    my $content_type = $self->content_type;
    if (defined $content_type and $content_type =~ m/^application\/x-www-form-urlencoded/) {
      foreach my $pair (split /&/, $self->body) {
        my ($key, $value) = split /=/, $pair, 2;
        $value = '' unless defined $value;
        do { s/%([0-9a-fA-F]{2})/chr hex $1/ge; utf8::decode $_ } for $key, $value;
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
    my $content_type = $self->content_type;
    if (defined $content_type and $content_type =~ m/^application\/json/) {
      $self->{body_json} = $self->_json->decode($self->body);
    }
  }
  return $self->{body_json};
}

sub set_status {
  my ($self, $status) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set HTTP response status but headers have already been rendered";
  } else {
    Carp::croak "Attempted to set unknown HTTP response status $status" unless exists $HTTP_STATUS{$status};
    $self->{response_status} = "$status $HTTP_STATUS{$status}";
  }
  return $self;
}

sub set_content_type {
  my ($self, $content_type) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set HTTP response content type but headers have already been rendered";
  } else {
    $self->{response_content_type} = $content_type;
  }
  return $self;
}

sub set_header {
  my ($self, $name, $value) = @_;
  if ($self->{headers_rendered}) {
    Carp::carp "Attempted to set HTTP response header '$name' but headers have already been rendered";
  } else {
    $self->{response_headers}{$name} = $value;
  }
  return $self;
}

sub set_charset { $_[0]{response_charset} = $_[1]; $_[0] }

sub render {
  my ($self, %args) = @_;
  my $charset = $self->{response_charset} || 'UTF-8';
  unless ($self->{headers_rendered}) {
    my %headers = %{$self->{response_headers} || {}};
    my $headers_str = '';
    my %headers_set;
    foreach my $name (sort keys %headers) {
      my @values = ref $headers{$name} eq 'ARRAY' ? @{$headers{$name}} : $headers{$name};
      $headers_str .= "$name: $_\r\n" for grep { defined } @values;
      $headers_set{lc $name} = 1;
    }
    if (!$headers_set{'content-type'}) {
      my $content_type = $self->{response_content_type};
      $content_type =
          exists $args{json} ? 'application/json;charset=UTF-8'
        : exists $args{html} ? "text/html;charset=$charset"
        : exists $args{text} ? "text/plain;charset=$charset"
        : 'application/octet-stream'
        unless defined $content_type;
      $headers_str = "Content-Type: $content_type\r\n$headers_str";
    }
    if (!$headers_set{status} and defined(my $status = $self->{response_status})) {
      $headers_str = "Status: $status\r\n$headers_str";
    }
    $headers_str .= "\r\n";
    binmode *STDOUT;
    print {*STDOUT} $headers_str;
    $self->{headers_rendered} = 1;
  }
  if (exists $args{json}) {
    my $json = $self->_json->encode($args{json});
    print {*STDOUT} $self->_json->encode($args{json});
  } elsif (exists $args{html}) {
    print {*STDOUT} Encode::encode $charset, "$args{html}";
  } elsif (exists $args{text}) {
    print {*STDOUT} Encode::encode $charset, "$args{text}";
  } elsif (exists $args{data}) {
    print {*STDOUT} $args{data};
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

  use strict;
  use warnings;
  use CGI::Tiny;

  cgi_on_error {
    my ($cgi, $error) = @_;
    warn $error;
    $cgi->render(json => {error => 'Internal Error'}) unless $cgi->headers_rendered;
  };

  cgi {
    my ($cgi) = @_;
    my $method = $cgi->method;
    my $fribble;
    if ($method eq 'GET') {
      $fribble = $cgi->query_param('fribble');
    } elsif ($method eq 'POST') {
      $fribble = $cgi->body_param('fribble');
    } else {
      $cgi->set_status(405);
      return $cgi->render;
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

=head1 FUNCTIONS

CGI::Tiny's DSL is a set of regular functions exported by default.

=head2 cgi

  cgi {
    my ($cgi) = @_;
    ...
  };

The primary interface to CGI::Tiny. The code block is immediately run and
passed a CGI::Tiny object which L</"METHODS"> can be called on.

If an exception is thrown within the code block, or the code block does not
render a response, it will run the handler set by L</"cgi_on_error"> if any, or
by default warn the error to STDERR and (if nothing has been rendered yet)
render a 500 Internal Server Error.

Affected by L</"cgi_on_error"> and L</"cgi_request_body_limit"> called from the
same package.

=head2 cgi_on_error

  cgi_on_error {
    my ($cgi, $error) = @_;
    ...
  };

Sets an error handler to run in the event of an exception. Must be set up
before calling L</"cgi">. The response status defaults to 500 when this handler
is called but can be overridden by the handler.

The error value can be any exception thrown by Perl or user code. It should
generally not be included in any response rendered to the client, but instead
warned or logged.

Exceptions may occur before or after response headers have been rendered, so
error handlers should render some response if L</"headers_rendered"> is
false. If no response has been rendered after the error handler completes, the
default 500 Internal Server Error response will be rendered.

=head2 cgi_request_body_limit

  cgi_request_body_limit 16*1024*1024;

Sets the limit in bytes for parsing a request body, defaults to the value of
the C<CGI_TINY_REQUEST_BODY_LIMIT> environment variable or 16777216 (16 MiB).
Since the request body is not read until needed, reaching the limit while
parsing the request body will throw an exception. A value of 0 will remove the
limit (not recommended unless you have other safeguards on memory usage).

=head1 METHODS

The following methods can be called on the CGI::Tiny object provided to the DSL
functions.

=head2 headers_rendered

  my $bool = $cgi->headers_rendered;

Returns true if response headers have been rendered, such as by the first call
to L</"render">.

=head2 request_method

=head2 server_protocol

=head2 server_port

=head2 path_info

=head2 script_name

=head2 query_string

=head2 remote_addr

=head2 content_type

=head2 content_length

  my $method = $cgi->request_method; # REQUEST_METHOD
  my $port   = $cgi->server_port;    # SERVER_PORT
  my $type   = $cgi->content_type;   # CONTENT_TYPE

Access to L<request meta-variables|https://tools.ietf.org/html/rfc3875#section-4.1>
of the equivalent uppercase names.

=head2 method

=head2 path

=head2 query

  my $method = $cgi->method; # REQUEST_METHOD
  my $path   = $cgi->path;   # PATH_INFO
  my $query  = $cgi->query;  # QUERY_STRING

Short aliases for a few request meta-variables.

=head2 header

  my $value = $cgi->header('Accept');

Retrieve the value of a request header by name (case insensitive). CGI request
headers can only contain a single value, which may be combined from multiple
values.

=head2 header_names

  my $arrayref = $cgi->header_names;

Array reference of available request header names, in lowercase.

=head2 headers

  my $hashref = $cgi->headers;

Hash reference of available request header names and values. Header names are
represented in lowercase.

=head2 query_pairs

  my $pairs = $cgi->query_pairs;

Retrieve URL query string parameters as an array reference of two-element array
references.

=head2 query_params

  my $params = $cgi->query_params;

Retrieve URL query string parameters as a hash reference. If a parameter name
is passed multiple times, its value will be an array reference.

=head2 query_param

  my $value = $cgi->query_param('foo');

Retrieve value of a named URL query string parameter. If the parameter name is
passed multiple times, returns the last value. Use L</"every_query_param"> to
get multiple values of a parameter.

=head2 every_query_param

  my $arrayref = $cgi->every_query_param('foo');

Retrieve values of a named URL query string parameter as an array reference.

=head2 body

  my $bytes = $cgi->body;

Retrieve the request body as bytes.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 body_pairs

  my $pairs = $cgi->body_pairs;

Retrieve C<x-www-form-urlencoded> body parameters as an array reference of
two-element array references.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 body_params

  my $params = $cgi->body_params;

Retrieve C<x-www-form-urlencoded> body parameters as a hash reference. If a
parameter name is passed multiple times, its value will be an array reference.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 body_param

  my $value = $cgi->body_param('foo');

Retrieve value of a named C<x-www-form-urlencoded> body parameter. If the
parameter name is passed multiple times, returns the last value. Use
L</"every_body_param"> to get multiple values of a parameter.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 every_body_param

  my $arrayref = $cgi->every_body_param('foo');

Retrieve values of a named C<x-www-form-urlencoded> body parameter as an array
reference.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 body_json

  my $data = $cgi->body_json;

Decode a C<application/json> request body from JSON.

Note that this will read the whole request body into memory, so make sure the
L</"cgi_request_body_limit"> can fit well within the available memory.

=head2 set_status

  $cgi = $cgi->set_status(404);

Sets the response HTTP status code. No effect after response headers have been
rendered. The CGI protocol assumes a status of C<200 OK> if no response status
is set.

=head2 set_content_type

  $cgi = $cgi->set_content_type('application/xml');

Sets the response Content-Type header. No effect after response headers have
been rendered.

=head2 set_header

  $cgi = $cgi->set_header('Content-Disposition' => 'attachment');

Sets a response header. No effect after response headers have been rendered. An
array reference value will set the header once for each value. Note that header
names are case insensitive and CGI::Tiny does not attempt to deduplicate or
munge headers that have been set manually.

=head2 set_charset

  $cgi = $cgi->set_charset('UTF-8');

Sets the charset to use when rendering C<text> or C<html> response data.

=head2 render

  $cgi->render(html => $html);
  $cgi->render(text => $text);
  $cgi->render(data => $bytes);
  $cgi->render(json => $ref);

Renders response data. The first time it is called will render response
headers, and it may be called additional times with more response data.

The C<Content-Type> response header will be set according to
L</"set_content_type"> or the type of data passed with the first call to
C<render>, or to C<application/octet-stream> if there is no more appropriate
value. C<html> or C<text> data is expected to be decoded characters, and will
be encoded according to L</"set_charset">. C<json> data will be encoded to
UTF-8.

=head1 CAVEATS

CGI is an extremely simplistic protocol and relies particularly on environment
variables and the C<STDIN> and C<STDOUT> standard filehandles. CGI::Tiny does
not prevent you from messing with these interfaces directly, but it may result
in confusion.

Most applications are better written in a L<PSGI>-compatible framework (e.g.
L<Dancer2> or L<Mojolicious>) and deployed in a persistent application server
so that the application does not have to start up every time it receives a
request.

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
