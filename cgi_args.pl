use strict;
use warnings;
our $module_name;

do 'virtualmin-remote-mail-lib.pl';

sub cgi_args
{
my ($cgi) = @_;
if ($cgi eq 'edit_domain.cgi') {
	my ($d) = grep { &virtual_server::can_edit_domain($_) &&
	                 $_->{$module_name} } &virtual_server::list_domains();
	return $d ? 'dom='.&urlize($d->{'dom'}) : 'none';
	}
elsif ($cgi eq 'edit_servers.cgi') {
	my @servers = &list_remote_mail_servers();
	return @servers ? 'id='.$servers[0] : '';
	}
return undef;
}
