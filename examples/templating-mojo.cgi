#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use CGI::Tiny;
use Mojo::Template;
use Mojo::File 'curfile';
use Mojo::Loader 'data_section';

use constant TEMPLATES_FROM_DIR => $ENV{MYCGI_TEMPLATES_FROM_DIR};

cgi {
  my $cgi = $_;
  my $foo = $cgi->query_param('foo');
  my $mt = Mojo::Template->new(auto_escape => 1, vars => 1);

  if (TEMPLATES_FROM_DIR) {
    # from templates/
    my $template_path = curfile->sibling('templates', 'index.html.ep');
    $cgi->render(html => $mt->render_file($template_path, {foo => $foo}));
  } else {
    # or from __DATA__
    my $template = data_section __PACKAGE__, 'index.html.ep';
    $cgi->render(html => $mt->render($template, {foo => $foo}));
  }
};

__DATA__
@@ index.html.ep
<html><body><h1><%= $foo %></h1></body></html>
