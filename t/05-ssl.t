#!/usr/bin/perl
# 05-ssl.t — Test SSL sync, DKIM, and disk usage operations
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

# Load mock Webmin and library + feature hooks
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# Helper: join all captured commands and strip backslash escaping
sub captured_cmds {
    my $raw = join("\n", @main::_commands_run);
    $raw =~ s/\\(.)/$1/g;
    return $raw;
}

# Set up a test server
save_remote_mail_server('1', {
    host         => 'vh2.trinsik.io',
    webmin_host  => 'vh2.trinsik.io',
    ssh_host     => 'vh2.trinsik.io',
    ssh_user     => 'root',
    ssh_key      => '/root/.ssh/id_rsa',
    dkim_selector => '202307',
    maildir_format => '.maildir',
    default      => 1,
});

# =========================================
# Test: DKIM setup
# =========================================

subtest 'setup_remote_dkim' => sub {
    plan tests => 5;

    @main::_commands_run = ();
    my $d = { 'dom' => 'testdomain.com', 'dns' => 1 };
    my $server = get_remote_mail_server('1');
    my $err = setup_remote_dkim($d, '1', $server);
    is($err, undef, 'setup_remote_dkim succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/opendkim-genkey/, 'Generates DKIM key');
    like($cmds, qr/signing\.table/, 'Adds signing table entry');
    like($cmds, qr/key\.table/, 'Adds key table entry');
    like($cmds, qr/reload opendkim|restart opendkim/, 'Reloads OpenDKIM');
};

# =========================================
# Test: delete_remote_dkim
# =========================================

subtest 'delete_remote_dkim' => sub {
    plan tests => 3;

    @main::_commands_run = ();
    my $d = { 'dom' => 'testdomain.com' };
    my $server = get_remote_mail_server('1');
    my $err = delete_remote_dkim($d, '1', $server);
    is($err, undef, 'delete_remote_dkim succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/signing\.table/, 'Removes signing table entry');
    like($cmds, qr/key\.table/, 'Removes key table entry');
};

# =========================================
# Test: get_remote_dkim_public_key
# =========================================

subtest 'get_remote_dkim_public_key' => sub {
    plan tests => 1;

    my $key = get_remote_dkim_public_key('1', 'testdomain.com', '202307');
    # Mock SSH returns "ok\n", which has no DKIM key format — returns empty string
    ok(!$key, 'Returns falsy when key file not in expected format');
};

# =========================================
# Test: sync_remote_mail_ssl
# =========================================

subtest 'sync_remote_mail_ssl' => sub {
    plan tests => 2;

    # Create temp cert files
    my $tmpdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmpdir/ssl.cert") or die;
    print $fh "CERT DATA\n";
    close($fh);
    open($fh, '>', "$tmpdir/ssl.key") or die;
    print $fh "KEY DATA\n";
    close($fh);

    @main::_commands_run = ();
    my $d = {
        'dom'       => 'testdomain.com',
        'ssl_cert'  => "$tmpdir/ssl.cert",
        'ssl_key'   => "$tmpdir/ssl.key",
    };
    my $err = sync_remote_mail_ssl($d, '1');
    is($err, undef, 'sync_remote_mail_ssl succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/ssl.*mail|mkdir/, 'Creates remote SSL directory');
};

# =========================================
# Test: sync_remote_mail_ssl with missing cert
# =========================================

subtest 'sync_remote_mail_ssl - missing cert' => sub {
    plan tests => 1;

    my $d = {
        'dom'      => 'testdomain.com',
        'ssl_cert' => '/nonexistent/path/ssl.cert',
        'ssl_key'  => '/nonexistent/path/ssl.key',
    };
    my $err = sync_remote_mail_ssl($d, '1');
    like($err, qr/not found/, 'Reports error for missing certificate');
};

# =========================================
# Test: get_remote_disk_usage
# =========================================

subtest 'get_remote_disk_usage' => sub {
    plan tests => 2;

    my $d = { 'dom' => 'testdomain.com' };
    my $bytes = get_remote_disk_usage($d, '1');
    # Mock SSH returns "ok\n" which won't parse as digits, so 0
    is($bytes, 0, 'Returns 0 when du output is not numeric');

    # Verify caching — file should exist
    ok(-f "$main::module_config_directory/domains/testdomain.com.du",
       'Cache file created');
};

# Clean up
delete_remote_mail_server('1');

done_testing();
