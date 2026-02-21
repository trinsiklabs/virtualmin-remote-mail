#!/usr/bin/perl
# 02-feature.t — Test feature hooks with mocked Webmin
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin
require "$FindBin::Bin/mock-webmin.pl";

# Load library and feature hooks
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# =========================================
# Test: Metadata hooks
# =========================================

subtest 'Feature metadata' => sub {
    plan tests => 5;

    my $name = feature_name();
    ok($name, 'feature_name returns a value');

    my $losing = feature_losing();
    ok($losing, 'feature_losing returns a value');

    my $label = feature_label(0);
    ok($label, 'feature_label returns for display');

    my $label2 = feature_label(1);
    ok($label2, 'feature_label returns for edit');

    my $hlink = feature_hlink();
    is($hlink, 'feat', 'feature_hlink returns feat');
};

# =========================================
# Test: feature_check
# =========================================

subtest 'feature_check' => sub {
    plan tests => 2;

    # No servers configured — should return error
    my $err = feature_check();
    ok($err, 'feature_check fails with no servers');

    # Add a server
    save_remote_mail_server('1', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        default     => 1,
    });
    $err = feature_check();
    is($err, undef, 'feature_check passes with a server configured');

    # Clean up
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_depends
# =========================================

subtest 'feature_depends' => sub {
    plan tests => 2;

    # Domain without DNS
    my $d = { 'dom' => 'test.com', 'dns' => 0 };
    my $err = feature_depends($d);
    ok($err, 'feature_depends fails without DNS');

    # Domain with DNS
    $d->{'dns'} = 1;
    $err = feature_depends($d);
    is($err, undef, 'feature_depends passes with DNS');
};

# =========================================
# Test: feature_clash
# =========================================

subtest 'feature_clash' => sub {
    plan tests => 2;

    # Domain with local mail
    my $d = { 'dom' => 'test.com', 'mail' => 1 };
    my $err = feature_clash($d);
    ok($err, 'feature_clash detects local mail conflict');

    # Domain without local mail
    $d->{'mail'} = 0;
    $err = feature_clash($d);
    is($err, undef, 'feature_clash passes without local mail');
};

# =========================================
# Test: feature_suitable
# =========================================

subtest 'feature_suitable' => sub {
    plan tests => 3;

    ok(feature_suitable(undef, undef, undef), 'Suitable for top-level domain');
    ok(!feature_suitable(undef, { 'dom' => 'alias' }, undef), 'Not suitable for alias');
    ok(!feature_suitable(undef, undef, { 'dom' => 'sub' }), 'Not suitable for subdomain');
};

# =========================================
# Test: feature_validate
# =========================================

subtest 'feature_validate' => sub {
    plan tests => 3;

    my $d = { 'dom' => 'test.com' };

    # No state file — should fail
    my $err = feature_validate($d);
    ok($err, 'validate fails with no state');

    # Partial state
    save_domain_state('test.com', { server_id => '1' });
    $err = feature_validate($d);
    ok($err, 'validate fails with incomplete state');

    # Complete state
    save_domain_state('test.com', {
        server_id => '1',
        dns_configured => 1,
        postfix_configured => 1,
    });
    $err = feature_validate($d);
    is($err, undef, 'validate passes with complete state');

    delete_domain_state('test.com');
};

# =========================================
# Test: feature_import
# =========================================

subtest 'feature_import' => sub {
    plan tests => 2;

    is(feature_import('nostate.com'), 0, 'Import returns 0 for unknown domain');

    save_domain_state('imported.com', { server_id => '1' });
    is(feature_import('imported.com'), 1, 'Import returns 1 for known domain');

    delete_domain_state('imported.com');
};

# =========================================
# Test: feature_backup and feature_restore
# =========================================

subtest 'Backup and restore' => sub {
    plan tests => 3;

    # Create state
    save_domain_state('backup.com', {
        server_id => '1',
        dns_configured => 1,
        postfix_configured => 1,
    });

    my $d = { 'dom' => 'backup.com' };
    my $backup_file = "$main::module_config_directory/test-backup";

    # Backup
    @main::_progress_messages = ();
    my $ok = feature_backup($d, $backup_file);
    is($ok, 1, 'Backup succeeds');

    # Delete state and restore
    delete_domain_state('backup.com');
    $ok = feature_restore($d, $backup_file);
    is($ok, 1, 'Restore succeeds');

    # Verify restored state
    my $state = get_domain_state('backup.com');
    is($state->{'server_id'}, '1', 'Restored state matches');

    delete_domain_state('backup.com');
    unlink($backup_file);
};

# =========================================
# Test: feature_setup full lifecycle with mocks
# =========================================

subtest 'feature_setup lifecycle' => sub {
    plan tests => 5;

    # Configure a server
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

    my $d = {
        'dom' => 'lifecycle.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    @main::_commands_run = ();
    @main::_progress_messages = ();

    my $ok = feature_setup($d);
    is($ok, 1, 'feature_setup returns success');

    # Check that state was saved
    my $state = get_domain_state('lifecycle.com');
    ok($state->{'server_id'}, 'State file has server_id');
    ok($state->{'dns_configured'}, 'State records DNS configured');
    ok($state->{'postfix_configured'}, 'State records Postfix configured');

    # Verify progress messages were emitted
    ok(scalar @main::_progress_messages > 0, 'Progress messages were output');

    # Clean up: run feature_delete
    feature_delete($d);
    my $empty_state = get_domain_state('lifecycle.com');
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_delete cleans up
# =========================================

subtest 'feature_delete cleanup' => sub {
    plan tests => 4;

    save_remote_mail_server('1', {
        host         => 'vh2.trinsik.io',
        ssh_host     => 'vh2.trinsik.io',
        ssh_user     => 'root',
        dkim_selector => '202307',
        maildir_format => '.maildir',
        default      => 1,
    });

    # Create state as if setup ran
    save_domain_state('delete-test.com', {
        server_id => '1',
        dns_configured => 1,
        postfix_configured => 1,
        dovecot_configured => 1,
        dkim_configured => 1,
    });

    my $d = {
        'dom' => 'delete-test.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_dkim_enabled' => 1,
    };

    @main::_commands_run = ();
    my $ok = feature_delete($d);
    is($ok, 1, 'feature_delete returns success');

    # Verify state was removed
    my $state = get_domain_state('delete-test.com');
    ok(!$state->{'server_id'}, 'State file removed after delete');

    # Verify domain hash fields cleaned up
    ok(!$d->{'remote_mail_server'}, 'Domain server field cleared');
    ok(!$d->{'remote_mail_dkim_enabled'}, 'Domain DKIM field cleared');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_modify (domain rename)
# =========================================

subtest 'feature_modify domain rename' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'vh2.trinsik.io',
        ssh_host     => 'vh2.trinsik.io',
        ssh_user     => 'root',
        dkim_selector => '202307',
        default      => 1,
    });

    save_domain_state('old-name.com', {
        server_id => '1',
        dns_configured => 1,
        postfix_configured => 1,
    });

    my $oldd = {
        'dom' => 'old-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };
    my $newd = {
        'dom' => 'new-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    @main::_commands_run = ();
    my $ok = feature_modify($newd, $oldd);
    is($ok, 1, 'feature_modify succeeds');

    # Should have state for new domain, not old
    my $new_state = get_domain_state('new-name.com');
    ok($new_state->{'server_id'}, 'State exists for renamed domain');

    delete_domain_state('new-name.com');
    delete_remote_mail_server('1');
};

# =========================================
# Test: rollback_setup cleans up partial state
# =========================================

subtest 'rollback_setup' => sub {
    plan tests => 1;

    save_remote_mail_server('1', {
        host    => 'vh2.trinsik.io',
        ssh_host => 'vh2.trinsik.io',
        ssh_user => 'root',
        dkim_selector => '202307',
        default => 1,
    });

    save_domain_state('rollback.com', {
        server_id => '1',
        dns_configured => 1,
        postfix_configured => 1,
    });

    my $d = { 'dom' => 'rollback.com', 'dns' => 1 };
    my %state = (
        dns_configured => 1,
        postfix_configured => 1,
    );

    @main::_commands_run = ();
    rollback_setup($d, '1', \%state);

    my $cleaned = get_domain_state('rollback.com');
    ok(!$cleaned->{'server_id'}, 'State removed after rollback');

    delete_remote_mail_server('1');
};

done_testing();
