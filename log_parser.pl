do 'virtualmin-remote-mail-lib.pl';

sub parse_webmin_log
{
my ($user, $script, $action, $type, $object, $p) = @_;
if ($action eq 'save' && $type eq 'server') {
	return &text('log_save', "<tt>".&html_escape($object)."</tt>");
	}
elsif ($action eq 'setup') {
	return &text('log_setup', "<tt>".&html_escape($object)."</tt>");
	}
elsif ($action eq 'delete' && $type eq 'server') {
	return &text('log_delete', "<tt>".&html_escape($object)."</tt>");
	}
elsif ($action eq 'ssl_sync') {
	return "Synced SSL certificates for ".&html_escape($object);
	}
elsif ($action eq 'user_create') {
	return &text('log_user_create', "<tt>".&html_escape($object)."</tt>");
	}
elsif ($action eq 'user_delete') {
	return &text('log_user_delete', "<tt>".&html_escape($object)."</tt>");
	}
return undef;
}

1;
