#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use CGI::Tiny;
use Text::Xslate;
use Data::Section::Simple 'get_data_section';

use constant TEMPLATES_FROM_DIR => $ENV{MYCGI_TEMPLATES_FROM_DIR};

cgi {
  my $cgi = $_;
  my $foo = $cgi->query_param('foo');
  my $tx = Text::Xslate->new(path => ['templates'], cache => 0);

  if (TEMPLATES_FROM_DIR) {
    # from templates/
    $cgi->render(html => $tx->render('index.tx', {foo => $foo}));
  } else {
    # or from __DATA__
    my $template = get_data_section 'index.tx';
    $cgi->render(html => $tx->render_string($template, {foo => $foo}));
  }
};

__DATA__
@@ index.tx
<html><body><h1><: $foo :></h1></body></html>
