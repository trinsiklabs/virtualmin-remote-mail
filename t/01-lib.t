#!/usr/bin/perl
# 01-lib.t — Test core library functions with mocked Webmin
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

# Load mock Webmin before the library
require "$FindBin::Bin/mock-webmin.pl";

# Load the library under test
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");

# Point domains_dir at temp directory
$main::domains_dir = "$main::module_config_directory/domains";

# =========================================
# Test: Server Config CRUD
# =========================================

subtest 'Server config CRUD' => sub {
    plan tests => 12;

    # Initially no servers
    my @servers = list_remote_mail_servers();
    is(scalar @servers, 0, 'No servers initially');

    # Save a server
    my %server1 = (
        host         => 'vh2.trinsik.io',
        desc         => 'Primary Mail Server',
        webmin_host  => 'vh2.trinsik.io',
        webmin_port  => 10000,
        webmin_ssl   => 1,
        webmin_user  => 'root',
        webmin_pass  => 'secret',
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
    );
    save_remote_mail_server('1', \%server1);

    # List should now have one
    @servers = list_remote_mail_servers();
    is(scalar @servers, 1, 'One server after save');
    is($servers[0], '1', 'Server ID is 1');

    # Get server
    my $s = get_remote_mail_server('1');
    ok($s, 'Got server config');
    is($s->{'host'}, 'vh2.trinsik.io', 'Host matches');
    is($s->{'desc'}, 'Primary Mail Server', 'Description matches');
    is($s->{'webmin_port'}, 10000, 'Webmin port matches');
    is($s->{'default'}, 1, 'Default flag matches');
    is($s->{'id'}, '1', 'ID field added');

    # Get default server
    my $default_id = get_default_remote_mail_server();
    is($default_id, '1', 'Default server is server_1');

    # Get nonexistent server
    my $none = get_remote_mail_server('99');
    is($none, undef, 'Nonexistent server returns undef');

    # Delete server
    delete_remote_mail_server('1');
    @servers = list_remote_mail_servers();
    is(scalar @servers, 0, 'No servers after delete');
};

# =========================================
# Test: SPF Record Builder
# =========================================

subtest 'SPF record builder' => sub {
    plan tests => 4;

    # Basic SPF
    my $spf = build_spf_record({
        ip4 => ['1.2.3.4'],
        all => '~all',
    });
    is($spf, 'v=spf1 ip4:1.2.3.4 ~all', 'Basic SPF record');

    # Multiple IPs and includes
    $spf = build_spf_record({
        ip4     => ['1.2.3.4', '5.6.7.8'],
        include => ['_spf.google.com', '_spf.trinsiklabs.com'],
        all     => '-all',
    });
    is($spf,
       'v=spf1 ip4:1.2.3.4 ip4:5.6.7.8 include:_spf.google.com include:_spf.trinsiklabs.com -all',
       'Multi-IP SPF with includes');

    # IPv6
    $spf = build_spf_record({
        ip4 => ['1.2.3.4'],
        ip6 => ['2001:db8::1'],
        all => '~all',
    });
    is($spf, 'v=spf1 ip4:1.2.3.4 ip6:2001:db8::1 ~all', 'SPF with IPv6');

    # Default ~all
    $spf = build_spf_record({ ip4 => ['1.2.3.4'] });
    like($spf, qr/~all$/, 'Default ~all when not specified');
};

# =========================================
# Test: DKIM Record Builder
# =========================================

subtest 'DKIM record builder' => sub {
    plan tests => 3;

    my ($name, $value) = build_dkim_record('example.com', '202307', 'MIIBpubkey==');
    is($name, '202307._domainkey.example.com', 'DKIM record name');
    like($value, qr/^v=DKIM1; k=rsa; p=MIIBpubkey==$/, 'DKIM record value');

    # Different selector
    ($name, $value) = build_dkim_record('test.io', 'default', 'ABCDkey');
    is($name, 'default._domainkey.test.io', 'DKIM with different selector');
};

# =========================================
# Test: DMARC Record Builder
# =========================================

subtest 'DMARC record builder' => sub {
    plan tests => 3;

    my ($name, $value) = build_dmarc_record('example.com', {
        p   => 'none',
        rua => 'mailto:dmarc@example.com',
    });
    is($name, '_dmarc.example.com', 'DMARC record name');
    like($value, qr/v=DMARC1/, 'DMARC contains version');
    like($value, qr/rua=mailto:dmarc\@example.com/, 'DMARC contains rua');
};

# =========================================
# Test: MX Record Builder
# =========================================

subtest 'MX record builder' => sub {
    plan tests => 6;

    # With spam gateway
    my @records = build_mx_records('example.com', {
        host              => '10.0.0.2',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
    });
    is(scalar @records, 3, 'Three records with spam gateway (MX + 2 A)');
    is($records[0]->{'type'}, 'MX', 'First record is MX');
    is($records[0]->{'value'}, 'mg.example.com', 'MX points to spam gateway host');
    is($records[1]->{'value'}, '216.55.103.236', 'A record for spam gateway');

    # Without spam gateway (direct)
    @records = build_mx_records('example.com', {
        host => '10.0.0.2',
    });
    is(scalar @records, 2, 'Two records without spam gateway (MX + A)');
    is($records[0]->{'value'}, 'mail.example.com', 'MX points to mail.domain');
};

# =========================================
# Test: Domain State Management
# =========================================

subtest 'Domain state management' => sub {
    plan tests => 6;

    # Save state
    my %state = (
        server_id          => '1',
        setup_time         => 1700000000,
        dns_configured     => 1,
        postfix_configured => 1,
        dovecot_configured => 1,
    );
    save_domain_state('example.com', \%state);

    # Read state
    my $loaded = get_domain_state('example.com');
    is($loaded->{'server_id'}, '1', 'State server_id');
    is($loaded->{'dns_configured'}, '1', 'State dns flag');
    is($loaded->{'postfix_configured'}, '1', 'State postfix flag');

    # Nonexistent domain
    my $empty = get_domain_state('nonexistent.com');
    ok(!$empty->{'server_id'}, 'Nonexistent domain has no state');

    # Delete state
    delete_domain_state('example.com');
    $loaded = get_domain_state('example.com');
    ok(!$loaded->{'server_id'}, 'State deleted');

    # Domain mail server selection
    my $d = { 'dom' => 'test.com' };
    # No server set on domain, no default configured
    my $sid = get_domain_mail_server($d);
    ok(!$sid, 'No server when none configured');
};

# =========================================
# Test: get_effective_mail_config
# =========================================

subtest 'get_effective_mail_config — server defaults when no overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    my $d = { 'dom' => 'example.com' };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '216.55.103.236', 'Server default spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Server default spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Server default outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 25, 'Server default outgoing_relay_port');
};

subtest 'get_effective_mail_config — full domain overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    my $d = {
        'dom' => 'override.com',
        'remote_mail_spam_gateway'      => '10.0.0.99',
        'remote_mail_spam_gateway_host' => 'spam',
        'remote_mail_outgoing_relay'      => 'relay.other.com',
        'remote_mail_outgoing_relay_port' => 587,
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '10.0.0.99', 'Domain override spam_gateway');
    is($eff->{'spam_gateway_host'}, 'spam', 'Domain override spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'relay.other.com', 'Domain override outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 587, 'Domain override outgoing_relay_port');
};

subtest 'get_effective_mail_config — partial overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    # Domain overrides only spam_gateway, rest should fall through to server
    my $d = {
        'dom' => 'partial.com',
        'remote_mail_spam_gateway' => '10.0.0.50',
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '10.0.0.50', 'Domain override spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Server default spam_gateway_host (no override)');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Server default outgoing_relay (no override)');
    is($eff->{'outgoing_relay_port'}, 25, 'Server default outgoing_relay_port (no override)');
};

# =========================================
# Test: get_effective_mail_config — empty-string override
# =========================================

subtest 'get_effective_mail_config — empty string overrides use server default' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    # Domain has all overrides set to empty string (cleared)
    my $d = {
        'dom' => 'cleared.com',
        'remote_mail_spam_gateway'      => '',
        'remote_mail_spam_gateway_host' => '',
        'remote_mail_outgoing_relay'      => '',
        'remote_mail_outgoing_relay_port' => '',
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '216.55.103.236', 'Empty string falls back to server spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Empty string falls back to server spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Empty string falls back to server outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 25, 'Empty string falls back to server outgoing_relay_port');
};

# =========================================
# Test: validate_mail_override
# =========================================

subtest 'validate_mail_override — valid inputs' => sub {
    plan tests => 5;

    is(validate_mail_override('spam_gateway', '10.0.0.1'), undef, 'Valid IP accepted');
    is(validate_mail_override('spam_gateway', ''), undef, 'Empty value accepted (clears override)');
    is(validate_mail_override('spam_gateway_host', 'mg'), undef, 'Valid hostname prefix accepted');
    is(validate_mail_override('outgoing_relay', 'smtp-out.trinsiklabs.com'), undef, 'Valid relay hostname accepted');
    is(validate_mail_override('outgoing_relay_port', '587'), undef, 'Valid port accepted');
};

subtest 'validate_mail_override — invalid inputs' => sub {
    plan tests => 10;

    # Bad IPs
    like(validate_mail_override('spam_gateway', '999.1.1.1'),
        qr/Invalid IP/, 'Rejects octet > 255');
    like(validate_mail_override('spam_gateway', 'not-an-ip'),
        qr/Invalid IP/, 'Rejects non-IP string');
    like(validate_mail_override('spam_gateway', "1.2.3.4'; rm -rf /"),
        qr/Invalid IP/, 'Rejects shell injection in IP');

    # Bad hostname prefix
    like(validate_mail_override('spam_gateway_host', '-leading'),
        qr/Invalid hostname prefix/, 'Rejects leading hyphen');
    like(validate_mail_override('spam_gateway_host', 'has spaces'),
        qr/Invalid hostname prefix/, 'Rejects spaces in hostname');
    like(validate_mail_override('spam_gateway_host', 'has.dots'),
        qr/Invalid hostname prefix/, 'Rejects dots in hostname prefix');

    # Bad relay
    like(validate_mail_override('outgoing_relay', 'relay..host.com'),
        qr/Invalid relay hostname/, 'Rejects consecutive dots');
    like(validate_mail_override('outgoing_relay', "host; rm -rf /"),
        qr/Invalid relay hostname/, 'Rejects shell injection in relay');

    # Bad ports
    like(validate_mail_override('outgoing_relay_port', '0'),
        qr/Invalid port/, 'Rejects port 0');
    like(validate_mail_override('outgoing_relay_port', '99999'),
        qr/Invalid port/, 'Rejects port > 65535');
};

# =========================================
# Test: ACL
# =========================================

subtest 'ACL checks' => sub {
    plan tests => 1;

    # With wildcard access
    ok(can_edit_domain('anything.com'), 'Wildcard ACL allows all');
};

done_testing();
