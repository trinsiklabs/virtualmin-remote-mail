#!/usr/bin/perl
# 04-user.t — Test remote user management and Postfix/Dovecot operations
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin and library + feature hooks
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# Helper: join all captured commands and strip backslash escaping
# for easier regex matching
sub captured_cmds {
    my $raw = join("\n", @main::_commands_run);
    $raw =~ s/\\(.)/$1/g;   # remove backslash escapes
    return $raw;
}

# Set up a test server
save_remote_mail_server('1', {
    host         => 'vh2.trinsik.io',
    webmin_host  => 'vh2.trinsik.io',
    ssh_host     => 'vh2.trinsik.io',
    ssh_user     => 'root',
    ssh_key      => '/root/.ssh/id_rsa',
    spam_gateway => '216.55.103.236',
    spam_gateway_host => 'mg',
    outgoing_relay => 'smtp-out.trinsiklabs.com',
    outgoing_relay_port => 25,
    dkim_selector => '202307',
    maildir_format => '.maildir',
    default      => 1,
});

my $d = { 'dom' => 'testdomain.com', 'dns' => 1 };

# =========================================
# Test: setup_remote_postfix
# =========================================

subtest 'setup_remote_postfix' => sub {
    plan tests => 4;

    @main::_commands_run = ();
    my $server = get_remote_mail_server('1');
    my $err = setup_remote_postfix($d, '1', $server);
    is($err, undef, 'setup_remote_postfix succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtual_domains/, 'Adds to virtual_domains');
    like($cmds, qr/dependent/, 'Adds sender-dependent transport');
    like($cmds, qr/reload postfix/, 'Reloads Postfix');
};

# =========================================
# Test: delete_remote_postfix
# =========================================

subtest 'delete_remote_postfix' => sub {
    plan tests => 3;

    @main::_commands_run = ();
    my $server = get_remote_mail_server('1');
    my $err = delete_remote_postfix($d, '1', $server);
    is($err, undef, 'delete_remote_postfix succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtual_domains/, 'Removes from virtual_domains');
    like($cmds, qr/dependent/, 'Removes sender-dependent transport');
};

# =========================================
# Test: disable/enable Postfix
# =========================================

subtest 'disable_remote_postfix' => sub {
    plan tests => 2;

    @main::_commands_run = ();
    my $err = disable_remote_postfix($d, '1');
    is($err, undef, 'disable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/DISABLED/, 'Marks domain as disabled');
};

subtest 'enable_remote_postfix' => sub {
    plan tests => 2;

    @main::_commands_run = ();
    my $err = enable_remote_postfix($d, '1');
    is($err, undef, 'enable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/DISABLED/, 'Restores disabled domain');
};

# =========================================
# Test: setup_remote_dovecot
# =========================================

subtest 'setup_remote_dovecot' => sub {
    plan tests => 3;

    @main::_commands_run = ();
    my $server = get_remote_mail_server('1');
    my $err = setup_remote_dovecot($d, '1', $server);
    is($err, undef, 'setup_remote_dovecot succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/mkdir.*testdomain\.com/, 'Creates domain home directory');
    like($cmds, qr/\.maildir/, 'Uses configured maildir format');
};

# =========================================
# Test: delete_remote_dovecot (safe rename)
# =========================================

subtest 'delete_remote_dovecot' => sub {
    plan tests => 2;

    @main::_commands_run = ();
    my $server = get_remote_mail_server('1');
    my $err = delete_remote_dovecot($d, '1', $server);
    is($err, undef, 'delete_remote_dovecot succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/\.deleted\.\d+/, 'Renames to .deleted.timestamp (safe)');
};

# =========================================
# Test: create_remote_mail_user
# =========================================

subtest 'create_remote_mail_user' => sub {
    plan tests => 4;

    @main::_commands_run = ();
    my $err = create_remote_mail_user($d, '1', 'info', 'password123', {});
    is($err, undef, 'create_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/mkdir.*info/, 'Creates user maildir');
    like($cmds, qr/virtual_mailbox/, 'Adds virtual_mailbox entry');
    like($cmds, qr/doveadm/, 'Sets password via doveadm');
};

# =========================================
# Test: delete_remote_mail_user
# =========================================

subtest 'delete_remote_mail_user' => sub {
    plan tests => 3;

    @main::_commands_run = ();
    my $err = delete_remote_mail_user($d, '1', 'info');
    is($err, undef, 'delete_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtual_mailbox/, 'Removes virtual_mailbox entry');
    like($cmds, qr/dovecot\/users|dovecot.users/, 'Removes from Dovecot passwd');
};

# =========================================
# Test: list_remote_mail_users (mock returns empty)
# =========================================

subtest 'list_remote_mail_users' => sub {
    plan tests => 1;

    my @users = list_remote_mail_users($d, '1');
    is(scalar @users, 0, 'Empty user list from mock');
};

# =========================================
# Test: setup_remote_postfix with overridden relay
# =========================================

subtest 'setup_remote_postfix — overridden outgoing relay' => sub {
    plan tests => 3;

    @main::_commands_run = ();

    # Build an effective config with overridden relay (simulating what
    # get_effective_mail_config would return for a domain with overrides)
    my $eff_server = {
        host              => 'vh2.trinsik.io',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'relay.override.com',   # domain override
        outgoing_relay_port => 2525,                    # domain override
    };

    my $d_ovr = { 'dom' => 'overridetest.com', 'dns' => 1 };
    my $err = setup_remote_postfix($d_ovr, '1', $eff_server);
    is($err, undef, 'setup_remote_postfix with overridden relay succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/relay\.override\.com/, 'Transport uses overridden relay host');
    like($cmds, qr/2525/, 'Transport uses overridden relay port');
};

# Clean up
delete_remote_mail_server('1');

done_testing();
