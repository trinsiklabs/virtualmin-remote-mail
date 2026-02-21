# virtual_feature.pl
# Virtualmin feature hooks for the Remote Mail Server plugin.
# This file is loaded by Virtualmin to register the plugin as a domain feature.

use strict;
use warnings;
our (%text, %config);
our $module_name;
our $module_config_directory;
our $domains_dir;

require 'virtualmin-remote-mail-lib.pl';
my $input_name = $module_name;
$input_name =~ s/[^A-Za-z0-9]/_/g;

# feature_name()
# Returns a short name for this feature
sub feature_name
{
return $text{'feat_name'};
}

# feature_losing(&domain)
# Returns a description of what will be deleted when this feature is removed
sub feature_losing
{
return $text{'feat_losing'};
}

# feature_label(in-edit-form)
# Returns the label for domain creation and editing forms
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

# feature_hlink(in-edit-form)
# Returns the help page linked by the feature label
sub feature_hlink
{
return 'feat';
}

# feature_check()
# Returns undef if all needed programs/configs are present, or an error message
sub feature_check
{
# Verify at least one remote mail server is configured
my @servers = &list_remote_mail_servers();
if (!@servers) {
	return $text{'feat_enoserver'};
	}
return undef;
}

# feature_depends(&domain, [&olddomain])
# Returns undef if all dependencies are met, or an error message.
# Requires DNS feature to be enabled (we manage MX/SPF/DKIM records).
sub feature_depends
{
my ($d, $oldd) = @_;
return $text{'feat_edns'} if (!$d->{'dns'});
return undef;
}

# feature_clash(&domain, [field])
# Returns undef if no clash, or an error message.
# Clashes with the local mail feature — can't have both.
sub feature_clash
{
my ($d, $field) = @_;
return undef if ($field && $field ne 'dom');
if ($d->{'mail'}) {
	return $text{'feat_eclash_mail'};
	}
return undef;
}

# feature_suitable([&parentdom], [&aliasdom], [&subdom])
# Returns 1 if this feature can be used with the given domain type.
# Only for top-level domains, not aliases or subs.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return !$aliasdom && !$subdom;
}

# feature_setup(&domain)
# Called when this feature is enabled for a domain.
# Provisions DNS records on vh1 and mail services on the remote server.
sub feature_setup
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $server = &get_remote_mail_server($server_id);
if (!$server) {
	&$virtual_server::first_print($text{'setup_start'});
	&$virtual_server::second_print($text{'setup_enoserver'});
	return 0;
	}

&obtain_lock_remote_mail($d);

my %state = ( 'server_id' => $server_id,
              'setup_time' => time() );
my $ok = 1;

# Step 1: Validate remote server connectivity
&$virtual_server::first_print($text{'setup_test'});
my $err = &test_remote_mail_server($server_id);
if ($err) {
	&$virtual_server::second_print(&text('setup_etest', $err));
	&release_lock_remote_mail();
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});

# Step 2: DNS records (MX, SPF, A records for mail hosts)
&$virtual_server::first_print($text{'setup_dns'});
$err = &setup_remote_mail_dns($d, $server);
if ($err) {
	&$virtual_server::second_print(&text('setup_edns', $err));
	$ok = 0;
	}
else {
	$state{'dns_configured'} = 1;
	&$virtual_server::second_print($virtual_server::text{'setup_done'});
	}

# Step 3: Postfix configuration on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_postfix'});
	$err = &setup_remote_postfix($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_epostfix', $err));
		$ok = 0;
		}
	else {
		$state{'postfix_configured'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 4: Dovecot user on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_dovecot'});
	$err = &setup_remote_dovecot($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_edovecot', $err));
		$ok = 0;
		}
	else {
		$state{'dovecot_configured'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 5: DKIM on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_dkim'});
	$err = &setup_remote_dkim($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_edkim', $err));
		# DKIM failure is non-fatal
		}
	else {
		$state{'dkim_configured'} = 1;
		$d->{'remote_mail_dkim_enabled'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 6: SSL certificate sync
if ($ok) {
	&$virtual_server::first_print($text{'setup_ssl'});
	$err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_essl', $err));
		# SSL failure is non-fatal
		}
	else {
		$state{'ssl_synced'} = 1;
		$d->{'remote_mail_ssl_synced'} = time();
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Save state
if ($ok) {
	$d->{'remote_mail_server'} = $server_id;
	&save_domain_state($d->{'dom'}, \%state);
	}
else {
	# Rollback completed steps
	&rollback_setup($d, $server_id, \%state);
	}

&release_lock_remote_mail();
return $ok;
}

# feature_delete(&domain)
# Called when this feature is disabled or the domain is being deleted.
# Tears down all remote mail configuration.
sub feature_delete
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $server = &get_remote_mail_server($server_id);

&obtain_lock_remote_mail($d);

# Remove DKIM on remote
if ($d->{'remote_mail_dkim_enabled'} && $server) {
	&$virtual_server::first_print($text{'delete_dkim'});
	my $err = &delete_remote_dkim($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_edkim', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove Dovecot user on remote
if ($server) {
	&$virtual_server::first_print($text{'delete_dovecot'});
	my $err = &delete_remote_dovecot($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_edovecot', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove Postfix config on remote
if ($server) {
	&$virtual_server::first_print($text{'delete_postfix'});
	my $err = &delete_remote_postfix($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_epostfix', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove DNS records
&$virtual_server::first_print($text{'delete_dns'});
my $err = &delete_remote_mail_dns($d, $server);
if ($err) {
	&$virtual_server::second_print(&text('delete_edns', $err));
	}
else {
	&$virtual_server::second_print(
		$virtual_server::text{'setup_done'});
	}

# Clean up state
&delete_domain_state($d->{'dom'});
delete $d->{'remote_mail_server'};
delete $d->{'remote_mail_ssl_synced'};
delete $d->{'remote_mail_dkim_enabled'};

&release_lock_remote_mail();
return 1;
}

# feature_modify(&domain, &olddomain)
# Called when a domain with this feature is modified (e.g., renamed)
sub feature_modify
{
my ($d, $oldd) = @_;
if ($d->{'dom'} ne $oldd->{'dom'}) {
	&$virtual_server::first_print($text{'modify_domain'});
	my $server_id = &get_domain_mail_server($d);
	my $server = &get_remote_mail_server($server_id);

	&obtain_lock_remote_mail($d);

	# Update DNS records
	my $err = &delete_remote_mail_dns($oldd, $server);
	if (!$err) {
		$err = &setup_remote_mail_dns($d, $server);
		}

	# Update Postfix transports
	if (!$err && $server) {
		$err = &modify_remote_postfix($d, $oldd, $server_id, $server);
		}

	# Update DKIM
	if (!$err && $server && $d->{'remote_mail_dkim_enabled'}) {
		&delete_remote_dkim($oldd, $server_id, $server);
		$err = &setup_remote_dkim($d, $server_id, $server);
		}

	# Move state file
	&delete_domain_state($oldd->{'dom'});
	my %state = ( 'server_id' => $server_id,
	              'setup_time' => time(),
	              'dns_configured' => 1,
	              'postfix_configured' => 1,
	              'dovecot_configured' => 1,
	              'dkim_configured' => $d->{'remote_mail_dkim_enabled'} || 0 );
	&save_domain_state($d->{'dom'}, \%state);

	&release_lock_remote_mail();

	if ($err) {
		&$virtual_server::second_print(&text('modify_err', $err));
		return 0;
		}
	&$virtual_server::second_print($virtual_server::text{'setup_done'});
	}
return 1;
}

# feature_disable(&domain)
# Called when the domain is being disabled (suspended)
sub feature_disable
{
my ($d) = @_;
&$virtual_server::first_print($text{'disable_mail'});
my $server_id = &get_domain_mail_server($d);

# Disable Postfix transport on remote (stops accepting mail)
my $err = &disable_remote_postfix($d, $server_id);
if ($err) {
	&$virtual_server::second_print(&text('disable_err', $err));
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_enable(&domain)
# Called when the domain is being re-enabled (unsuspended)
sub feature_enable
{
my ($d) = @_;
&$virtual_server::first_print($text{'enable_mail'});
my $server_id = &get_domain_mail_server($d);

# Re-enable Postfix transport on remote
my $err = &enable_remote_postfix($d, $server_id);
if ($err) {
	&$virtual_server::second_print(&text('enable_err', $err));
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_validate(&domain)
# Verify remote config matches expected state
sub feature_validate
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $state = &get_domain_state($d->{'dom'});
if (!$state || !$state->{'server_id'}) {
	return $text{'validate_enostate'};
	}
# Check that we have DNS records
if (!$state->{'dns_configured'}) {
	return $text{'validate_enodns'};
	}
# Check Postfix
if (!$state->{'postfix_configured'}) {
	return $text{'validate_enopostfix'};
	}
return undef;
}

# feature_links(&domain)
# Returns links to module pages for this domain
sub feature_links
{
my ($d) = @_;
return ( { 'mod' => $module_name,
           'desc' => $text{'links_link'},
           'page' => 'edit_domain.cgi?dom='.$d->{'dom'},
           'cat' => 'server',
         } );
}

# feature_inputs_show()
# Always show feature inputs
sub feature_inputs_show
{
return 1;
}

# feature_inputs([&domain])
# Returns form fields for choosing the remote mail server
sub feature_inputs
{
my ($d) = @_;
my @servers = &list_remote_mail_servers();
return '' if (!@servers);

my @opts;
foreach my $id (@servers) {
	my $s = &get_remote_mail_server($id);
	push(@opts, [ $id, $s->{'desc'} || $s->{'host'} ]);
	}
my $default = $d ? $d->{'remote_mail_server'} :
              &get_default_remote_mail_server();
return &ui_table_row($text{'feat_server'},
	&ui_select($input_name."_server", $default, \@opts));
}

# feature_inputs_parse(&domain, &in)
# Parse the server selection input
sub feature_inputs_parse
{
my ($d, $in) = @_;
if (defined($in->{$input_name."_server"})) {
	my $id = $in->{$input_name."_server"};
	my $s = &get_remote_mail_server($id);
	if (!$s) {
		return $text{'feat_eserver'};
		}
	$d->{'remote_mail_server'} = $id;
	}
return undef;
}

# feature_args(&domain)
# CLI argument definitions
sub feature_args
{
return ( { 'name' => $module_name."-server",
           'value' => 'server-id',
           'opt' => 1,
           'desc' => 'Remote mail server ID' },
       );
}

# feature_args_parse(&domain, &args)
# Parse CLI arguments
sub feature_args_parse
{
my ($d, $args) = @_;
if (defined($args->{$module_name."-server"})) {
	my $id = $args->{$module_name."-server"};
	my $s = &get_remote_mail_server($id);
	if (!$s) {
		return "Invalid remote mail server ID: $id";
		}
	$d->{'remote_mail_server'} = $id;
	}
return undef;
}

# feature_import(domain-name, user-name, db-name)
# Check if this feature is already enabled for an imported domain
sub feature_import
{
my ($dname, $user, $db) = @_;
my $state = &get_domain_state($dname);
return ($state && $state->{'server_id'}) ? 1 : 0;
}

# feature_webmin(&main-domain, &all-domains)
# Returns Webmin module ACLs for the domain owner
sub feature_webmin
{
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @{$_[1]};
if (@doms) {
	return ( [ $module_name,
	           { 'dom' => join(" ", @doms),
	             'noconfig' => 1 } ] );
	}
return ();
}

# feature_modules()
sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# feature_backup(&domain, file, &opts, &all-opts)
# Backup domain mail state
sub feature_backup
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'backup_conf'});
my $state = &get_domain_state($d->{'dom'});
if ($state) {
	&virtual_server::write_as_domain_user($d,
		sub { &write_file($file, $state) });
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_restore(&domain, file, &opts, &all-opts)
# Restore domain mail state
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_conf'});
&obtain_lock_remote_mail($d);
my %state;
&read_file($file, \%state);
&save_domain_state($d->{'dom'}, \%state);
&release_lock_remote_mail();
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_backup_name()
sub feature_backup_name
{
return $text{'backup_name'};
}

# template_input(&template)
# Template settings for default remote mail server
sub template_input
{
my ($tmpl) = @_;
my $v = $tmpl->{$module_name."server"};
$v = "none" if (!defined($v) && $tmpl->{'default'});

my @servers = &list_remote_mail_servers();
my @opts = ( [ 'none', $text{'tmpl_none'} ] );
foreach my $id (@servers) {
	my $s = &get_remote_mail_server($id);
	push(@opts, [ $id, $s->{'desc'} || $s->{'host'} ]);
	}

my $rv = &ui_table_row($text{'tmpl_server'},
	&ui_radio($input_name."_mode",
		$v eq "" ? 0 : $v eq "none" ? 1 : 2,
		[ $tmpl->{'default'} ? () : ( [ 0, $text{'default'} ] ),
		  [ 1, $text{'tmpl_none'} ],
		  [ 2, $text{'tmpl_server_sel'} ] ])."\n".
	&ui_select($input_name."_server", $v, \@opts));
return $rv;
}

# template_parse(&template, &in)
sub template_parse
{
my ($tmpl, $in) = @_;
if ($in->{$input_name.'_mode'} == 0) {
	$tmpl->{$module_name."server"} = "";
	}
elsif ($in->{$input_name.'_mode'} == 1) {
	$tmpl->{$module_name."server"} = "none";
	}
else {
	$tmpl->{$module_name."server"} = $in->{$input_name."_server"};
	}
}

# ---- Stub functions for later phases ----
# These will be implemented in phases 3-8.

# setup_remote_mail_dns(&domain, \%server)
# Creates DNS records: MX, A for mail hosts, SPF TXT, and autoconfig CNAME.
# Uses Virtualmin's DNS API.
sub setup_remote_mail_dns
{
my ($d, $server) = @_;
return "No DNS zone for domain" if (!$d->{'dns'});

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	if (!$file) {
		die "Could not get DNS zone file for $d->{'dom'}";
		}

	# Remove any existing MX records for the bare domain
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'MX' &&
		    ($r->{'name'} eq $d->{'dom'}.'.' ||
		     $r->{'name'} eq $d->{'dom'})) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	# Add MX and A records from builder
	my @mx_recs = &build_mx_records($d->{'dom'}, $server);
	foreach my $rec (@mx_recs) {
		my %dns = ( 'name'  => $rec->{'name'}.'.',
		            'type'  => $rec->{'type'},
		            'values' => [ $rec->{'value'} ] );
		if ($rec->{'type'} eq 'MX') {
			$dns{'values'} = [ $rec->{'priority'},
			                   $rec->{'value'}.'.' ];
			}
		&virtual_server::create_dns_record($recs, $file, \%dns);
		}

	# SPF record
	my @ip4 = ( $server->{'host'} );
	push(@ip4, $server->{'spam_gateway'}) if ($server->{'spam_gateway'});
	my $spf_value = &build_spf_record({
		ip4     => \@ip4,
		include => ['_spf.trinsiklabs.com'],
		all     => '~all',
		});

	# Remove existing SPF TXT records
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq $d->{'dom'}.'.' ||
		     $r->{'name'} eq $d->{'dom'}) &&
		    join(' ', @{$r->{'values'}}) =~ /v=spf1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => $d->{'dom'}.'.',
		  'type' => 'TXT',
		  'values' => [ "\"$spf_value\"" ] });

	# DMARC record
	my ($dmarc_name, $dmarc_value) = &build_dmarc_record($d->{'dom'}, {
		p => 'none',
		});

	# Remove existing DMARC
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq $dmarc_name.'.' ||
		     $r->{'name'} eq $dmarc_name) &&
		    join(' ', @{$r->{'values'}}) =~ /v=DMARC1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => $dmarc_name.'.',
		  'type' => 'TXT',
		  'values' => [ "\"$dmarc_value\"" ] });

	# Autoconfig/autodiscover CNAME for mail clients
	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => "autoconfig.$d->{'dom'}.",
		  'type' => 'CNAME',
		  'values' => [ "mail.$d->{'dom'}." ] });

	# Bump SOA serial and schedule BIND reload
	if (defined(&virtual_server::post_records_change)) {
		&virtual_server::post_records_change($d, $recs, $file);
		}
	else {
		&virtual_server::register_post_action(
			\&virtual_server::restart_bind);
		}

	if (defined(&virtual_server::release_lock_dns)) {
		&virtual_server::release_lock_dns($d, 1);
		}
	};

return $@ ? "$@" : undef;
}

# delete_remote_mail_dns(&domain, \%server)
# Removes all DNS records added by setup_remote_mail_dns
sub delete_remote_mail_dns
{
my ($d, $server) = @_;
return undef if (!$d->{'dns'});

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	return undef if (!$file);

	my $dom = $d->{'dom'};

	# Collect names we manage
	my @managed_a = ("mail.${dom}.", "autoconfig.${dom}.");
	if ($server && $server->{'spam_gateway_host'}) {
		push(@managed_a,
		     ($server->{'spam_gateway_host'} || 'mg').".${dom}.");
		}

	# Delete records in reverse to avoid index shifting
	for (my $i = $#$recs; $i >= 0; $i--) {
		my $r = $recs->[$i];

		# MX for bare domain
		if ($r->{'type'} eq 'MX' &&
		    ($r->{'name'} eq "${dom}." || $r->{'name'} eq $dom)) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# A records for mail hosts we created
		if ($r->{'type'} eq 'A' &&
		    grep { $r->{'name'} eq $_ } @managed_a) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# CNAME for autoconfig
		if ($r->{'type'} eq 'CNAME' &&
		    $r->{'name'} eq "autoconfig.${dom}.") {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# SPF TXT
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq "${dom}." || $r->{'name'} eq $dom) &&
		    join(' ', @{$r->{'values'}}) =~ /v=spf1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# DMARC TXT
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq "_dmarc.${dom}." ||
		     $r->{'name'} eq "_dmarc.${dom}") &&
		    join(' ', @{$r->{'values'}}) =~ /v=DMARC1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# DKIM TXT (selector._domainkey)
		if ($r->{'type'} eq 'TXT' &&
		    $r->{'name'} =~ /\._domainkey\.\Q${dom}\E\.?$/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}
		}

	if (defined(&virtual_server::post_records_change)) {
		&virtual_server::post_records_change($d, $recs, $file);
		}
	else {
		&virtual_server::register_post_action(
			\&virtual_server::restart_bind);
		}

	if (defined(&virtual_server::release_lock_dns)) {
		&virtual_server::release_lock_dns($d, 1);
		}
	};

return $@ ? "$@" : undef;
}

# modify_remote_mail_dns(&domain, &old_domain, \%server)
# Update DNS records when domain is renamed — delete old, create new
sub modify_remote_mail_dns
{
my ($d, $oldd, $server) = @_;
my $err = &delete_remote_mail_dns($oldd, $server);
return $err if ($err);
return &setup_remote_mail_dns($d, $server);
}

# ---- Phase 4: Remote Postfix Configuration ----

# setup_remote_postfix(&domain, $server_id, \%server)
# Configures Postfix on the remote server:
# - Adds domain to virtual_domains
# - Adds sender-dependent transport map entry for outgoing relay
# - Runs postmap and reloads Postfix
sub setup_remote_postfix
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	# Add to virtual_domains (hash map file)
	&remote_mail_ssh($server_id,
		"postconf -h virtual_mailbox_domains 2>/dev/null");

	# Add domain to virtual_mailbox_domains via hash file
	my $cmd = "grep -q '^\Q${dom}\E\\b' /etc/postfix/virtual_domains 2>/dev/null" .
	          " || echo '${dom} OK' >> /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add virtual domain: $out";
		}

	# Add sender-dependent transport map for outgoing relay
	if ($server->{'outgoing_relay'}) {
		my $relay = $server->{'outgoing_relay'};
		my $port = $server->{'outgoing_relay_port'} || 25;
		my $transport = "smtp:[${relay}]:${port}";
		$cmd = "grep -q '^\@\Q${dom}\E\\b' /etc/postfix/dependent 2>/dev/null" .
		       " || echo '\@${dom} ${transport}' >> /etc/postfix/dependent" .
		       " && postmap /etc/postfix/dependent";
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		if ($exit != 0) {
			die "Failed to add sender transport: $out";
			}
		}

	# Reload Postfix
	($out, $exit) = &remote_mail_ssh($server_id, "systemctl reload postfix");
	if ($exit != 0) {
		die "Failed to reload Postfix: $out";
		}
	};

return $@ ? "$@" : undef;
}

# delete_remote_postfix(&domain, $server_id, \%server)
# Removes Postfix configuration for a domain from the remote server
sub delete_remote_postfix
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	# Remove from virtual_domains
	my $cmd = "sed -i '/^\Q${dom}\E\\b/d' /etc/postfix/virtual_domains 2>/dev/null" .
	          " && postmap /etc/postfix/virtual_domains";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove from sender-dependent transport
	$cmd = "sed -i '/^\@\Q${dom}\E\\b/d' /etc/postfix/dependent 2>/dev/null" .
	       " && postmap /etc/postfix/dependent";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove any virtual_mailbox entries for the domain
	$cmd = "sed -i '/\@\Q${dom}\E\\b/d' /etc/postfix/virtual_mailbox 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_mailbox 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove virtual alias entries
	$cmd = "sed -i '/\@\Q${dom}\E\\b/d' /etc/postfix/virtual_alias 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_alias 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Reload
	($out, $exit) = &remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# modify_remote_postfix(&domain, &old_domain, $server_id, \%server)
# Updates Postfix config when domain is renamed
sub modify_remote_postfix
{
my ($d, $oldd, $server_id, $server) = @_;
my $err = &delete_remote_postfix($oldd, $server_id, $server);
return $err if ($err);
return &setup_remote_postfix($d, $server_id, $server);
}

# disable_remote_postfix(&domain, $server_id)
# Temporarily disables mail delivery by commenting out virtual_domains entry
sub disable_remote_postfix
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
eval {
	my $cmd = "sed -i 's/^\Q${dom}\E\\b/#DISABLED# ${dom}/' /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains" .
	          " && systemctl reload postfix";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to disable domain in Postfix: $out";
		}
	};
return $@ ? "$@" : undef;
}

# enable_remote_postfix(&domain, $server_id)
# Re-enables mail delivery by uncommenting virtual_domains entry
sub enable_remote_postfix
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
eval {
	my $cmd = "sed -i 's/^#DISABLED# \Q${dom}\E/${dom} OK/' /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains" .
	          " && systemctl reload postfix";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to enable domain in Postfix: $out";
		}
	};
return $@ ? "$@" : undef;
}

# ---- Phase 5: Remote Dovecot / User Management ----

# setup_remote_dovecot(&domain, $server_id, \%server)
# Creates the domain's home directory and initial Maildir on the remote server
sub setup_remote_dovecot
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};
my $maildir = $server->{'maildir_format'} || '.maildir';

eval {
	# Create domain home and maildir
	my $home = "/home/${dom}";
	my $cmd = "mkdir -p ${home}/${maildir}/{cur,new,tmp}" .
	          " && chmod -R 700 ${home}/${maildir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to create maildir: $out";
		}
	};

return $@ ? "$@" : undef;
}

# delete_remote_dovecot(&domain, $server_id, \%server)
# Removes the domain's mail home from the remote server.
# Note: Does NOT delete data by default — renames to .deleted for safety.
sub delete_remote_dovecot
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	my $home = "/home/${dom}";
	my $ts = time();
	my $cmd = "[ -d ${home} ] && mv ${home} ${home}.deleted.${ts} || true";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to archive mail home: $out";
		}
	};

return $@ ? "$@" : undef;
}

# create_remote_mail_user(&domain, $server_id, $user, $password, \%opts)
# Creates a mailbox user on the remote server:
# - Adds virtual_mailbox entry
# - Creates Maildir
# - Sets password in Dovecot passwd file
sub create_remote_mail_user
{
my ($d, $server_id, $user, $password, $opts) = @_;
my $dom = $d->{'dom'};
my $email = "${user}\@${dom}";
my $server = &get_remote_mail_server($server_id);
my $maildir = $server->{'maildir_format'} || '.maildir';
my $home = "/home/${dom}";
my $userdir = "${home}/${maildir}/${user}";

eval {
	# Create user maildir
	my $cmd = "mkdir -p ${userdir}/{cur,new,tmp} && chmod -R 700 ${userdir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to create user maildir: $out";
		}

	# Add virtual_mailbox entry
	$cmd = "grep -q '^\Q${email}\E\\b' /etc/postfix/virtual_mailbox 2>/dev/null" .
	       " || echo '${email} ${dom}/${maildir}/${user}/' >> /etc/postfix/virtual_mailbox" .
	       " && postmap /etc/postfix/virtual_mailbox";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add virtual mailbox: $out";
		}

	# Generate password hash and add to Dovecot passwd file
	if ($password) {
		$cmd = "doveadm pw -s SSHA512 -p " . quotemeta($password);
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		chomp($out);
		if ($exit != 0) {
			die "Failed to generate password hash: $out";
			}
		my $hash = $out;

		# Append to passwd file (or update existing)
		$cmd = "grep -q '^\Q${email}\E:' /etc/dovecot/users 2>/dev/null" .
		       " && sed -i 's|^\Q${email}\E:.*|${email}:${hash}::::${userdir}|' /etc/dovecot/users" .
		       " || echo '${email}:${hash}::::${userdir}' >> /etc/dovecot/users";
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		if ($exit != 0) {
			die "Failed to set user password: $out";
			}
		}

	# Reload Postfix to pick up virtual_mailbox changes
	&remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# delete_remote_mail_user(&domain, $server_id, $user)
# Removes a mailbox user from the remote server
sub delete_remote_mail_user
{
my ($d, $server_id, $user) = @_;
my $dom = $d->{'dom'};
my $email = "${user}\@${dom}";

eval {
	# Remove from virtual_mailbox
	my $cmd = "sed -i '/^\Q${email}\E\\b/d' /etc/postfix/virtual_mailbox 2>/dev/null" .
	          " && postmap /etc/postfix/virtual_mailbox";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove from Dovecot passwd
	$cmd = "sed -i '/^\Q${email}\E:/d' /etc/dovecot/users 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove virtual alias entries for this user
	$cmd = "sed -i '/^\Q${email}\E\\b/d' /etc/postfix/virtual_alias 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_alias 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	&remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# list_remote_mail_users(&domain, $server_id)
# Returns a list of mail users for the domain from the remote server
sub list_remote_mail_users
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my @users;

my ($out, $exit) = &remote_mail_ssh($server_id,
	"grep '\@\Q${dom}\E:' /etc/dovecot/users 2>/dev/null");
if ($exit == 0 && $out) {
	foreach my $line (split(/\n/, $out)) {
		if ($line =~ /^([^@]+)\@\Q${dom}\E:/) {
			push(@users, $1);
			}
		}
	}

return @users;
}

# ---- Phase 6: DKIM Integration ----

# setup_remote_dkim(&domain, $server_id, \%server)
# Configures OpenDKIM on the remote server for this domain:
# - Generates key pair if needed
# - Adds signing table and key table entries
# - Reloads OpenDKIM
sub setup_remote_dkim
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};
my $selector = $server->{'dkim_selector'} || '202307';

eval {
	my $keydir = "/etc/opendkim/keys/${dom}";

	# Create key directory and generate key if not exists
	my $cmd = "mkdir -p ${keydir}" .
	          " && [ -f ${keydir}/${selector}.private ] ||" .
	          " opendkim-genkey -s ${selector} -d ${dom} -D ${keydir}" .
	          " && chown -R opendkim:opendkim ${keydir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to generate DKIM key: $out";
		}

	# Add signing table entry
	$cmd = "grep -q '\Q${dom}\E' /etc/opendkim/signing.table 2>/dev/null" .
	       " || echo '*\@${dom} ${selector}._domainkey.${dom}'" .
	       " >> /etc/opendkim/signing.table";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add signing table entry: $out";
		}

	# Add key table entry
	$cmd = "grep -q '\Q${dom}\E' /etc/opendkim/key.table 2>/dev/null" .
	       " || echo '${selector}._domainkey.${dom} ${dom}:${selector}:${keydir}/${selector}.private'" .
	       " >> /etc/opendkim/key.table";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add key table entry: $out";
		}

	# Reload OpenDKIM
	($out, $exit) = &remote_mail_ssh($server_id,
		"systemctl reload opendkim 2>/dev/null || systemctl restart opendkim");
	if ($exit != 0) {
		die "Failed to reload OpenDKIM: $out";
		}
	};

return $@ ? "$@" : undef;
}

# get_remote_dkim_public_key($server_id, $domain, $selector)
# Fetches the DKIM public key from the remote server
sub get_remote_dkim_public_key
{
my ($server_id, $domain, $selector) = @_;
$selector ||= '202307';
my $keyfile = "/etc/opendkim/keys/${domain}/${selector}.txt";

my ($out, $exit) = &remote_mail_ssh($server_id, "cat ${keyfile} 2>/dev/null");
if ($exit != 0 || !$out) {
	return undef;
	}

# Extract the public key from the TXT record file
# Format: selector._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=MIIBi..." )
my $pubkey = '';
if ($out =~ /p=([A-Za-z0-9+\/=\s"]+)/) {
	$pubkey = $1;
	$pubkey =~ s/[")\s]//g;
	}
return $pubkey;
}

# delete_remote_dkim(&domain, $server_id, \%server)
# Removes OpenDKIM configuration for a domain
sub delete_remote_dkim
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	# Remove signing table entry
	my $cmd = "sed -i '/\Q${dom}\E/d' /etc/opendkim/signing.table 2>/dev/null";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove key table entry
	$cmd = "sed -i '/\Q${dom}\E/d' /etc/opendkim/key.table 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Note: we keep the key files for potential reuse

	# Reload OpenDKIM
	($out, $exit) = &remote_mail_ssh($server_id,
		"systemctl reload opendkim 2>/dev/null || systemctl restart opendkim");
	};

return $@ ? "$@" : undef;
}

# ---- Phase 7: SSL Certificate Sync ----

# sync_remote_mail_ssl(&domain, $server_id)
# Syncs SSL certificates from vh1 to the remote mail server via SCP.
# Reloads Dovecot and Postfix on the remote server.
sub sync_remote_mail_ssl
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $server = &get_remote_mail_server($server_id);
return "Server not found" if (!$server);

eval {
	# Determine cert paths on vh1 (Virtualmin stores these in domain hash)
	my $cert = $d->{'ssl_cert'} || "/home/${dom}/ssl.cert";
	my $key  = $d->{'ssl_key'}  || "/home/${dom}/ssl.key";
	my $ca   = $d->{'ssl_chain'} || $d->{'ssl_ca'};

	# Verify cert exists locally
	if (! -r $cert) {
		die "SSL certificate not found at $cert";
		}

	my $ssh_host = $server->{'ssh_host'} || $server->{'host'};
	my $ssh_user = $server->{'ssh_user'} || 'root';
	my $ssh_key  = $server->{'ssh_key'};

	my @scp_opts = ('-o', 'StrictHostKeyChecking=no',
	                '-o', 'BatchMode=yes',
	                '-o', 'ConnectTimeout=10');
	push(@scp_opts, '-i', $ssh_key) if ($ssh_key);

	my $remote_dir = "/etc/ssl/mail/${dom}";
	my $dest = "${ssh_user}\@${ssh_host}";

	# Create remote directory
	my ($out, $exit) = &remote_mail_ssh($server_id,
		"mkdir -p ${remote_dir} && chmod 700 ${remote_dir}");
	if ($exit != 0) {
		die "Failed to create remote SSL directory: $out";
		}

	# SCP cert and key
	my $scp_base = "scp " . join(' ', map { quotemeta($_) } @scp_opts);
	$out = &backquote_command(
		"${scp_base} " . quotemeta($cert) .
		" ${dest}:${remote_dir}/fullchain.pem 2>&1");
	if ($?) {
		die "Failed to copy certificate: $out";
		}

	$out = &backquote_command(
		"${scp_base} " . quotemeta($key) .
		" ${dest}:${remote_dir}/privkey.pem 2>&1");
	if ($?) {
		die "Failed to copy private key: $out";
		}

	# Copy CA chain if available
	if ($ca && -r $ca) {
		$out = &backquote_command(
			"${scp_base} " . quotemeta($ca) .
			" ${dest}:${remote_dir}/chain.pem 2>&1");
		}

	# Set permissions on remote
	&remote_mail_ssh($server_id,
		"chmod 600 ${remote_dir}/*.pem");

	# Reload Dovecot and Postfix to pick up new certs
	($out, $exit) = &remote_mail_ssh($server_id,
		"systemctl reload dovecot 2>/dev/null; systemctl reload postfix 2>/dev/null");
	};

return $@ ? "$@" : undef;
}

# ---- Phase 8: Disk Usage ----

# get_remote_disk_usage(&domain, $server_id)
# Returns disk usage in bytes for the domain's mail directory on the remote server.
# Results are cached for the configured TTL.
sub get_remote_disk_usage
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $cache_file = "$domains_dir/${dom}.du";
my $cache_ttl = $config{'disk_usage_cache'} || 3600;

# Check cache
if (-r $cache_file) {
	my @stat = stat($cache_file);
	if (time() - $stat[9] < $cache_ttl) {
		open(my $fh, '<', $cache_file);
		my $bytes = <$fh>;
		close($fh);
		chomp($bytes);
		return $bytes if ($bytes =~ /^\d+$/);
		}
	}

# Fetch from remote
my ($out, $exit) = &remote_mail_ssh($server_id,
	"du -sb /home/${dom} 2>/dev/null | cut -f1");
my $bytes = 0;
if ($exit == 0 && $out =~ /^(\d+)/) {
	$bytes = $1;
	}

# Cache result
if (! -d $domains_dir) {
	&make_dir($domains_dir, 0700);
	}
open(my $fh, '>', $cache_file);
print $fh "$bytes\n";
close($fh);

return $bytes;
}

# ---- Rollback ----

# rollback_setup(&domain, $server_id, \%state)
# Rolls back partially completed setup steps
sub rollback_setup
{
my ($d, $server_id, $state) = @_;
my $server = &get_remote_mail_server($server_id);

if ($state->{'dkim_configured'} && $server) {
	eval { &delete_remote_dkim($d, $server_id, $server) };
	}
if ($state->{'dovecot_configured'} && $server) {
	eval { &delete_remote_dovecot($d, $server_id, $server) };
	}
if ($state->{'postfix_configured'} && $server) {
	eval { &delete_remote_postfix($d, $server_id, $server) };
	}
if ($state->{'dns_configured'}) {
	eval { &delete_remote_mail_dns($d, $server) };
	}
&delete_domain_state($d->{'dom'});
}

1;
