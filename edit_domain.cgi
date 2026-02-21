#!/usr/local/bin/perl
# edit_domain.cgi — Per-domain remote mail configuration
use strict;
use warnings;
our (%text, %in, %config);
our $module_name;

require 'virtualmin-remote-mail-lib.pl';
&ReadParse();

&can_edit_domain($in{'dom'}) || &error($text{'edit_ecannot'} || "Access denied");

my $d = &virtual_server::get_domain_by("dom", $in{'dom'});
$d || &error($text{'edit_edomain'} || "Domain not found");

my $server_id = &get_domain_mail_server($d);
my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
my $state = &get_domain_state($d->{'dom'});

&ui_print_header(&virtual_server::domain_in($d), $text{'domain_title'}, "");

print &ui_table_start($text{'domain_header'}, undef, 2);

# Mail server
print &ui_table_row($text{'domain_server'},
	$server ? &html_escape($server->{'desc'} || $server->{'host'})
	        : "<i>$text{'domain_not_configured'}</i>");

# Status for each component
my @components = (
	['dns_configured',     $text{'domain_dns'}],
	['postfix_configured', $text{'domain_postfix'}],
	['dovecot_configured', $text{'domain_dovecot'}],
	['dkim_configured',    $text{'domain_dkim'}],
	['ssl_synced',         $text{'domain_ssl'}],
);

foreach my $c (@components) {
	my ($key, $label) = @$c;
	my $status = $state->{$key}
		? "<font color=green>$text{'domain_configured'}</font>"
		: "<font color=grey>$text{'domain_not_configured'}</font>";
	print &ui_table_row($label, $status);
	}

# Last SSL sync time
if ($d->{'remote_mail_ssl_synced'}) {
	print &ui_table_row($text{'domain_last_ssl'},
		scalar localtime($d->{'remote_mail_ssl_synced'}));
	}

print &ui_table_end();

# SSL sync button
if ($server_id && $state->{'ssl_synced'}) {
	print &ui_form_start("save_domain.cgi", "post");
	print &ui_hidden("dom", $d->{'dom'});
	print &ui_hidden("action", "sync_ssl");
	print &ui_form_end([ [ undef, $text{'domain_sync_ssl'} ] ]);
	}

&ui_print_footer(&virtual_server::domain_in($d),
                 $text{'index_return'});
