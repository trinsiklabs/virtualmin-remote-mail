#!/usr/local/bin/perl
# save_domain.cgi — Handle per-domain mail actions (SSL sync, etc.)
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

if ($in{'action'} eq 'sync_ssl') {
	&ui_print_unbuffered_header(&virtual_server::domain_in($d),
	                            $text{'domain_title'}, "");

	&$virtual_server::first_print($text{'setup_ssl'});
	my $err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			"<font color=red>$err</font>");
		}
	else {
		$d->{'remote_mail_ssl_synced'} = time();
		&virtual_server::save_domain($d) if defined(&virtual_server::save_domain);
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}

	&webmin_log("ssl_sync", undef, $d->{'dom'});
	&ui_print_footer("edit_domain.cgi?dom=$in{'dom'}",
	                 $text{'domain_title'});
	}
else {
	&redirect("edit_domain.cgi?dom=$in{'dom'}");
	}
