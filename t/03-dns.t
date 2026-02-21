#!/usr/bin/perl
# 03-dns.t — Test DNS record generation in isolation
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin and library
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");

# =========================================
# Test: SPF record generation
# =========================================

subtest 'SPF generation — trinsik production config' => sub {
    plan tests => 2;

    my $spf = build_spf_record({
        ip4     => ['167.172.136.27', '216.55.103.236'],
        include => ['_spf.trinsiklabs.com'],
        all     => '~all',
    });

    like($spf, qr/^v=spf1 /, 'Starts with v=spf1');
    is($spf,
       'v=spf1 ip4:167.172.136.27 ip4:216.55.103.236 include:_spf.trinsiklabs.com ~all',
       'Full SPF record matches expected format');
};

subtest 'SPF edge cases' => sub {
    plan tests => 3;

    # Empty (no mechanisms)
    my $spf = build_spf_record({});
    is($spf, 'v=spf1 ~all', 'Empty SPF has just version and all');

    # Strict -all
    $spf = build_spf_record({ ip4 => ['1.2.3.4'], all => '-all' });
    like($spf, qr/-all$/, 'Strict -all honored');

    # Only includes
    $spf = build_spf_record({
        include => ['_spf.google.com'],
        all     => '~all',
    });
    is($spf, 'v=spf1 include:_spf.google.com ~all', 'Include-only SPF');
};

# =========================================
# Test: DKIM record generation
# =========================================

subtest 'DKIM record generation' => sub {
    plan tests => 4;

    my ($name, $value) = build_dkim_record(
        'guidelineroofing.com', '202307',
        'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC7ZoX'
    );

    is($name, '202307._domainkey.guidelineroofing.com', 'DKIM name for production domain');
    like($value, qr/^v=DKIM1/, 'DKIM value starts with version');
    like($value, qr/k=rsa/, 'DKIM specifies RSA key type');
    like($value, qr/p=MIGfMA0GCSqGSIb3/, 'DKIM contains public key');
};

# =========================================
# Test: DMARC record generation
# =========================================

subtest 'DMARC record generation' => sub {
    plan tests => 5;

    my ($name, $value) = build_dmarc_record('example.com', {
        p   => 'quarantine',
        rua => 'mailto:dmarc-reports@example.com',
        pct => 100,
    });

    is($name, '_dmarc.example.com', 'DMARC record name');
    like($value, qr/v=DMARC1/, 'Contains version');
    like($value, qr/p=quarantine/, 'Contains policy');
    like($value, qr/rua=mailto:dmarc-reports\@example\.com/, 'Contains rua');
    like($value, qr/pct=100/, 'Contains pct');
};

subtest 'DMARC defaults' => sub {
    plan tests => 2;

    my ($name, $value) = build_dmarc_record('example.com', {});
    like($value, qr/p=none/, 'Default policy is none');

    ($name, $value) = build_dmarc_record('example.com', { p => 'reject' });
    like($value, qr/p=reject/, 'Reject policy');
};

# =========================================
# Test: MX record generation
# =========================================

subtest 'MX records — with spam gateway' => sub {
    plan tests => 8;

    my @recs = build_mx_records('guidelineroofing.com', {
        host              => '167.172.136.27',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
    });

    is(scalar @recs, 3, 'Three records with spam gateway');

    # MX record
    is($recs[0]->{'type'}, 'MX', 'Record 1 is MX');
    is($recs[0]->{'name'}, 'guidelineroofing.com', 'MX for domain');
    is($recs[0]->{'value'}, 'mg.guidelineroofing.com', 'MX points to spam gateway host');
    is($recs[0]->{'priority'}, 5, 'MX priority is 5');

    # A record for spam gateway
    is($recs[1]->{'type'}, 'A', 'Record 2 is A');
    is($recs[1]->{'value'}, '216.55.103.236', 'A record for spam gateway IP');

    # A record for mail server
    is($recs[2]->{'value'}, '167.172.136.27', 'A record for mail server IP');
};

subtest 'MX records — direct (no spam gateway)' => sub {
    plan tests => 4;

    my @recs = build_mx_records('example.com', {
        host => '10.0.0.5',
    });

    is(scalar @recs, 2, 'Two records without spam gateway');
    is($recs[0]->{'type'}, 'MX', 'MX record');
    is($recs[0]->{'value'}, 'mail.example.com', 'MX points to mail.domain');
    is($recs[1]->{'value'}, '10.0.0.5', 'A record for mail server');
};

subtest 'MX records — custom spam gateway prefix' => sub {
    plan tests => 1;

    my @recs = build_mx_records('example.com', {
        host              => '10.0.0.2',
        spam_gateway      => '10.0.0.3',
        spam_gateway_host => 'spamfilter',
    });

    is($recs[0]->{'value'}, 'spamfilter.example.com', 'Custom prefix used');
};

# =========================================
# Test: MX/SPF with overridden effective config
# =========================================

subtest 'MX records — with overridden spam gateway via effective config' => sub {
    plan tests => 4;

    # Simulate what get_effective_mail_config would return: domain override
    my $eff = {
        host              => '167.172.136.27',
        spam_gateway      => '10.0.0.99',         # overridden from domain
        spam_gateway_host => 'spamgw',             # overridden from domain
    };

    my @recs = build_mx_records('override.com', $eff);
    is(scalar @recs, 3, 'Three records with overridden spam gateway');
    is($recs[0]->{'value'}, 'spamgw.override.com', 'MX points to overridden spam gateway host');
    is($recs[1]->{'value'}, '10.0.0.99', 'A record uses overridden spam gateway IP');
    is($recs[2]->{'value'}, '167.172.136.27', 'mail.domain A record unchanged');
};

subtest 'SPF record — with overridden spam gateway IP' => sub {
    plan tests => 2;

    # Server default would be 216.55.103.236, but domain overrides to 10.0.0.99
    my $eff = {
        host         => '167.172.136.27',
        spam_gateway => '10.0.0.99',
    };

    my @ip4 = ( $eff->{'host'} );
    push(@ip4, $eff->{'spam_gateway'}) if ($eff->{'spam_gateway'});
    my $spf = build_spf_record({
        ip4     => \@ip4,
        include => ['_spf.trinsiklabs.com'],
        all     => '~all',
    });

    like($spf, qr/ip4:10\.0\.0\.99/, 'SPF contains overridden spam gateway IP');
    unlike($spf, qr/216\.55\.103\.236/, 'SPF does NOT contain server default spam gateway');
};

done_testing();
