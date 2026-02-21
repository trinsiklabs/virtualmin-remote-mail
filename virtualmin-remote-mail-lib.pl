# virtualmin-remote-mail-lib.pl
# Core library for the Virtualmin Remote Mail Server plugin.
# Handles server config CRUD, RPC/SSH wrappers, DNS builders, and state.

use strict;
use warnings;
our (%text, %config, %module_info);
our $module_name;
our $module_config_directory;

BEGIN { push(@INC, ".."); };
eval "use WebminCore;";
&init_config();
&foreign_require('virtual-server', 'virtual-server-lib.pl');
our %access = &get_module_acl();

# Directory for per-domain state files
our $domains_dir = "$module_config_directory/domains";

# Lock tracking
our $got_lock_remote_mail = 0;
our @got_lock_remote_mail_files;

# ---- Server Config CRUD ----

# list_remote_mail_servers()
# Returns a list of configured remote mail server IDs
sub list_remote_mail_servers
{
my @servers;
foreach my $k (keys %config) {
	if ($k =~ /^server_([a-zA-Z0-9]+)_host$/) {
		push(@servers, $1);
		}
	}
return sort @servers;
}

# get_remote_mail_server($id)
# Returns a hash ref with all config fields for the given server ID
sub get_remote_mail_server
{
my ($id) = @_;
return undef if (!defined $config{"server_${id}_host"});
my %server;
foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_(.+)$/) {
		$server{$1} = $config{$k};
		}
	}
$server{'id'} = $id;
return \%server;
}

# save_remote_mail_server($id, \%server)
# Saves server config fields. Removes old keys for this ID first, then
# writes new ones. Persists to the module config file.
sub save_remote_mail_server
{
my ($id, $server) = @_;

# Remove old keys for this server
foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_/) {
		delete $config{$k};
		}
	}

# Write new keys
foreach my $k (keys %$server) {
	next if ($k eq 'id');
	$config{"server_${id}_${k}"} = $server->{$k};
	}

&lock_file("$module_config_directory/config");
&save_module_config();
&unlock_file("$module_config_directory/config");
}

# delete_remote_mail_server($id)
# Removes all config keys for a server
sub delete_remote_mail_server
{
my ($id) = @_;

foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_/) {
		delete $config{$k};
		}
	}

&lock_file("$module_config_directory/config");
&save_module_config();
&unlock_file("$module_config_directory/config");
}

# get_default_remote_mail_server()
# Returns the ID of the default server, or the first one found
sub get_default_remote_mail_server
{
foreach my $id (&list_remote_mail_servers()) {
	my $s = &get_remote_mail_server($id);
	return $id if ($s->{'default'});
	}
# Fall back to first server
my @servers = &list_remote_mail_servers();
return $servers[0] if (@servers);
return undef;
}

# ---- RPC and SSH Wrappers ----

# remote_mail_call($server_id, $module, $func, @args)
# Wrapper around remote_foreign_call to the mail server's Webmin
sub remote_mail_call
{
my ($server_id, $module, $func, @args) = @_;
my $server = &get_remote_mail_server($server_id);
return undef if (!$server);

my $serv = { 'host' => $server->{'webmin_host'} || $server->{'host'},
             'port' => $server->{'webmin_port'} || 10000,
             'ssl'  => $server->{'webmin_ssl'},
             'user' => $server->{'webmin_user'},
             'pass' => $server->{'webmin_pass'} };

return &remote_foreign_call($serv, $module, $func, @args);
}

# remote_mail_ssh($server_id, $command)
# Executes a command on the remote server via SSH.
# Returns ($output, $exit_code).
sub remote_mail_ssh
{
my ($server_id, $command) = @_;
my $server = &get_remote_mail_server($server_id);
return (undef, -1) if (!$server);

my $ssh_host = $server->{'ssh_host'} || $server->{'host'};
my $ssh_user = $server->{'ssh_user'} || 'root';
my $ssh_key  = $server->{'ssh_key'};

my @cmd = ('ssh');
push(@cmd, '-i', $ssh_key) if ($ssh_key);
push(@cmd, '-o', 'StrictHostKeyChecking=no');
push(@cmd, '-o', 'BatchMode=yes');
push(@cmd, '-o', 'ConnectTimeout=10');
push(@cmd, "${ssh_user}\@${ssh_host}");
push(@cmd, $command);

my $out = &backquote_command(join(' ', map { quotemeta($_) } @cmd)." 2>&1");
my $exit = $?;
return ($out, $exit >> 8);
}

# test_remote_mail_server($id)
# Tests both Webmin RPC and SSH connectivity. Returns undef on success,
# or an error message on failure.
sub test_remote_mail_server
{
my ($id) = @_;
my $server = &get_remote_mail_server($id);
return "Server $id not found" if (!$server);

# Test Webmin RPC
eval {
	my $ver = &remote_mail_call($id, 'webmin', 'get_webmin_version');
	if (!$ver) {
		die "No response from Webmin RPC";
		}
	};
if ($@) {
	return &text('test_erpc', $@);
	}

# Test SSH
my ($out, $exit) = &remote_mail_ssh($id, 'echo ok');
if ($exit != 0 || $out !~ /ok/) {
	return &text('test_essh', $out || "Connection failed");
	}

return undef;
}

# ---- DNS Record Builders ----
# Pure functions that generate record values — no I/O, easy to test.

# build_spf_record(\%params)
# Params: ip4 => [list], ip6 => [list], include => [list], all => '~all'
# Returns the SPF TXT record value string.
sub build_spf_record
{
my ($params) = @_;
my @parts = ('v=spf1');

if ($params->{'ip4'}) {
	foreach my $ip (@{$params->{'ip4'}}) {
		push(@parts, "ip4:$ip");
		}
	}
if ($params->{'ip6'}) {
	foreach my $ip (@{$params->{'ip6'}}) {
		push(@parts, "ip6:$ip");
		}
	}
if ($params->{'include'}) {
	foreach my $inc (@{$params->{'include'}}) {
		push(@parts, "include:$inc");
		}
	}
push(@parts, $params->{'all'} || '~all');
return join(' ', @parts);
}

# build_dkim_record($domain, $selector, $pubkey)
# Returns ($name, $value) for the DKIM TXT record.
# $pubkey should be the base64 public key without headers/footers.
sub build_dkim_record
{
my ($domain, $selector, $pubkey) = @_;
my $name = "${selector}._domainkey.${domain}";
my $value = "v=DKIM1; k=rsa; p=${pubkey}";
return ($name, $value);
}

# build_dmarc_record($domain, \%params)
# Params: p => 'none'|'quarantine'|'reject', rua => 'mailto:...', pct => 100
# Returns ($name, $value) for the DMARC TXT record.
sub build_dmarc_record
{
my ($domain, $params) = @_;
my $name = "_dmarc.${domain}";
my @parts = ('v=DMARC1');
push(@parts, 'p='.($params->{'p'} || 'none'));
push(@parts, 'rua='.$params->{'rua'}) if ($params->{'rua'});
push(@parts, 'pct='.$params->{'pct'}) if (defined $params->{'pct'});
my $value = join('; ', @parts);
return ($name, $value);
}

# build_mx_records($domain, \%server_config)
# Returns a list of hash refs with: name, type, priority, value.
# Generates MX + A records for mail/spam-gateway hosts.
sub build_mx_records
{
my ($domain, $server) = @_;
my @records;

if ($server->{'spam_gateway'}) {
	# MX points to spam gateway hostname
	my $mg_host = ($server->{'spam_gateway_host'} || 'mg') . ".${domain}";
	push(@records,
		{ 'name' => $domain, 'type' => 'MX',
		  'priority' => 5, 'value' => $mg_host },
		{ 'name' => $mg_host, 'type' => 'A',
		  'value' => $server->{'spam_gateway'} },
		);

	# Also add mail.domain pointing to the actual mail server
	push(@records,
		{ 'name' => "mail.${domain}", 'type' => 'A',
		  'value' => $server->{'host'} },
		);
	}
else {
	# Direct MX to the mail server
	push(@records,
		{ 'name' => $domain, 'type' => 'MX',
		  'priority' => 5, 'value' => "mail.${domain}" },
		{ 'name' => "mail.${domain}", 'type' => 'A',
		  'value' => $server->{'host'} },
		);
	}

return @records;
}

# ---- Domain State Management ----

# get_domain_state($domain_name)
# Reads the per-domain state file. Returns a hash ref.
sub get_domain_state
{
my ($domain) = @_;
my $file = "$domains_dir/${domain}.conf";
my %state;
if (-r $file) {
	&read_file($file, \%state);
	}
return \%state;
}

# save_domain_state($domain_name, \%state)
# Writes the per-domain state file.
sub save_domain_state
{
my ($domain, $state) = @_;
if (! -d $domains_dir) {
	&make_dir($domains_dir, 0700);
	}
my $file = "$domains_dir/${domain}.conf";
&lock_file($file);
&write_file($file, $state);
&unlock_file($file);
}

# delete_domain_state($domain_name)
# Removes the per-domain state file.
sub delete_domain_state
{
my ($domain) = @_;
my $file = "$domains_dir/${domain}.conf";
&unlink_file($file) if (-f $file);
}

# ---- Effective Mail Config (domain overrides + server defaults) ----

# get_effective_mail_config(&domain, \%server)
# Merges per-domain overrides (stored in $d->{'remote_mail_*'}) with
# server defaults. Returns a new hash ref — never mutates the inputs.
sub get_effective_mail_config
{
my ($d, $server) = @_;
my %eff = %$server;
for my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
	my $dk = "remote_mail_${key}";
	if (defined $d->{$dk} && $d->{$dk} ne '') {
		$eff{$key} = $d->{$dk};
		}
	}
return \%eff;
}

# ---- Server Selection for Domain ----

# get_domain_mail_server($d)
# Returns the mail server ID for a domain, falling back to default
sub get_domain_mail_server
{
my ($d) = @_;
return $d->{'remote_mail_server'} || &get_default_remote_mail_server();
}

# ---- Locking ----

# obtain_lock_remote_mail([$d])
# Acquires locks for remote mail operations
sub obtain_lock_remote_mail
{
my ($d) = @_;
if (defined(&virtual_server::obtain_lock_anything)) {
	&virtual_server::obtain_lock_anything();
	}
if ($got_lock_remote_mail == 0) {
	@got_lock_remote_mail_files = ();
	push(@got_lock_remote_mail_files,
	     "$module_config_directory/config");
	if ($d) {
		push(@got_lock_remote_mail_files,
		     "$domains_dir/".$d->{'dom'}.".conf");
		}
	foreach my $f (@got_lock_remote_mail_files) {
		&lock_file($f);
		}
	}
$got_lock_remote_mail++;
}

# release_lock_remote_mail()
# Releases locks for remote mail operations
sub release_lock_remote_mail
{
if ($got_lock_remote_mail == 1) {
	foreach my $f (@got_lock_remote_mail_files) {
		&unlock_file($f);
		}
	}
$got_lock_remote_mail-- if ($got_lock_remote_mail);
if (defined(&virtual_server::release_lock_anything)) {
	&virtual_server::release_lock_anything();
	}
}

# ---- ACL ----

# can_edit_domain($dname)
# Check if current user can edit mail for this domain
sub can_edit_domain
{
my ($dname) = @_;
if ($access{'dom'} eq '*') {
	return 1;
	}
return &indexof($dname, split(/\s+/, $access{'dom'})) >= 0;
}

1;
