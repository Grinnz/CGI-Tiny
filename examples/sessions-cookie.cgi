#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use CGI::Tiny;

cgi {
  my $cgi = $_;

  my ($authed_user, $session_id);
  if ($cgi->path eq '/login') {
    if ($cgi->method eq 'GET' or $cgi->method eq 'HEAD') {
      $cgi->render(html => login_form_template(login_failed => 0));
      exit;
    } elsif ($cgi->method eq 'POST') {
      my $user = $cgi->body_param('login_user');
      my $pass = $cgi->body_param('login_pass');
      if (verify_password($user, $pass)) {
        $session_id = store_new_session($user);
        $authed_user = $user;
      } else {
        $cgi->render(html => login_form_template(login_failed => 1));
        exit;
      }
    }
  } elsif (defined($session_id = $cgi->cookie('myapp_session'))) {
    if ($cgi->path eq '/logout') {
      invalidate_session($session_id);
      # expire session cookie
      $cgi->add_response_cookie(myapp_session => $session_id, 'Max-Age' => 0, Path => '/', HttpOnly => 1);
      $cgi->render(redirect => $cgi->script_name . '/login');
      exit;
    } else {
      $authed_user = get_session_user($session_id);
    }
  }

  unless (defined $authed_user) {
    $cgi->render(redirect => $cgi->script_name . '/login');
    exit;
  }

  # set/refresh session cookie
  $cgi->add_response_cookie(myapp_session => $session_id, 'Max-Age' => 3600, Path => '/', HttpOnly => 1);

  $cgi->render(text => "Welcome, $authed_user!");
};
