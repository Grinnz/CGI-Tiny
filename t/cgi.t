use strict;
use warnings;
use CGI::Tiny;
use Test::More;

my @env_keys = qw(
  AUTH_TYPE CONTENT_LENGTH CONTENT_TYPE GATEWAY_INTERFACE
  PATH_INFO PATH_TRANSLATED QUERY_STRING
  REMOTE_ADDR REMOTE_HOST REMOTE_IDENT REMOTE_USER
  REQUEST_METHOD SCRIPT_NAME
  SERVER_NAME SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE
);

sub _parse_response {
  my ($response) = @_;
  my ($headers_str, $body) = split /\r\n\r\n/, $response, 2;
  my %headers;
  foreach my $header (split /\r\n/, $headers_str) {
    my ($name, $value) = split /:\s*/, $header;
    $headers{lc $name} = $value;
  }
  return {headers => \%headers, body => $body};
}

subtest 'Empty response' => sub {
  local @ENV{@env_keys} = ('')x@env_keys;
  local $ENV{PATH_INFO} = '/';
  local $ENV{REQUEST_METHOD} = 'GET';
  local $ENV{SCRIPT_NAME} = '/';
  local $ENV{SERVER_PROTOCOL} = 'HTTP/1.0';
  open my $in_fh, '<', \(my $in_data = '') or die "failed to open handle for input: $!";
  open my $out_fh, '>', \my $out_data or die "failed to open handle for output: $!";
  cgi {
    my ($cgi) = @_;
    $cgi->set_input_handle($in_fh);
    $cgi->set_output_handle($out_fh);
    $cgi->render;
  };
  ok length($out_data), 'response rendered';
  my $response = _parse_response($out_data);
  ok defined($response->{headers}{'content-type'}), 'Content-Type set';
  is $response->{headers}{'content-type'}, 'application/octet-stream', 'right content type';
  ok !length($response->{body}), 'empty response body';
};

done_testing;
