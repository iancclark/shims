#!/usr/bin/perl -w

use YAML;
use DBI;
use Net::LDAP;
use Data::Dumper;

use SOAP::Lite;
use HTTP::Cookies;

my $conf=YAML::LoadFile("/usr/local/etc/db2mm.yml");
my $jnl=DBI->connect("DBI:SQLite:dbname=/var/lib/db2mm.sqlite");
$jnl->do(<<_CREATE_
CREATE TABLE IF NOT EXISTS journal (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  list TEXT,
  mail TEXT,
  mode TEXT);
_CREATE_
);

my $dbh=DBI->connect($conf->{config}->{dsn},$conf->{config}->{dbu},$conf->{config}->{dbp});
if(!$dbh) {
	die "Database connection failed $!";
}

my $ldap=Net::LDAP->new($conf->{config}->{ldap_uri});
if(!$ldap) {
	die "LDAP connection failed $!"
}

my $msg=$ldap->bind($conf->{config}->{ldap_bind},password=>$conf->{config}->{ldap_pass});

if($msg->code){
	die "LDAP bind failed ".$msg->error;
}

my $cookies=HTTP::Cookies->new();
my $sympa=SOAP::Lite->proxy($conf->{config}->{soap_url},cookie_jar=>$cookies);
$sympa->default_ns('urn:sympasoap');
$msg=$sympa->login($conf->{config}->{soap_user},$conf->{config}->{soap_pass});
if($msg->fault) {
	die "Sympa/SOAP login failed: ".$msg->faultstring."\n";
}

foreach my $list (@{$conf->{lists}}) {
  print "$list->{name}\n";
  my $want_membs={};
  my $have_membs={};
  my @adds=();
  my @rems=();

  next if($list->{enabled} ne "yes");

  foreach my $q (@{$list->{queries}}) {
    print "$q->{type}> $q->{query}\n";
    if($q->{type} eq "sql") {
      my $sth=$dbh->prepare($q->{query});
      $sth->execute;
      while(my $r=$sth->fetchrow_hashref) {
	$want_membs->{lc($r->{mail})}=1;
      }
    } elsif($q->{type} eq "ldap") {
      my $attrlist;
      foreach my $a (@{$q->{attrs}}) {
	push(@$attrlist,$a->{attr});
      }
      my $search=$ldap->search(base=>$q->{base},filter=>$q->{query},attrs=>$attrlist);
      while(my $entry=$search->pop_entry) {
	foreach my $a (@{$q->{attrs}}) {
	  if($entry->get_value($a->{attr})) {
	    foreach my $v ($entry->get_value($a->{attr})) {
              chomp($a->{suffix});
	      $want_membs->{lc($v.$a->{suffix})}=1;
	    }
	    last;
          } 
        }
      }
    }
  }
  # Get current list membership
  if($list->{sympa}) {
    my $msg=$sympa->review($list->{name});
    if($msg->fault) {
      die "REVIEW of $list->{name} failed\n";
    }
    foreach my $m (@{$msg->result}) {
      if($m ne "no_subscribers") {
	$have_membs->{$m}=1;
      } 
    } 
  } else {
    open(LISTMEMB,"/usr/lib/mailman/bin/list_members ".$list->{name}." |");
    while(<LISTMEMB>) {
      chomp;
      $have_membs->{$_}=1;
    }
    close(LISTMEMB);
  }

  if($list->{debug}) {
    print("Have: ".join(",",sort(keys(%$have_membs)))."\n");
    print("Want: ".join(",",sort(keys(%$want_membs)))."\n");
  }
  foreach my $m (sort(keys(%$have_membs))) {
    my $s=seen($list->{name},$m);
    if(!defined($want_membs->{$m})) {
      # This existing mail is not in the wanted list
      if($s eq "auto-add") {
        # and was automatically added, so can be automatically removed
	push(@rems,$m);
      } elsif($s eq "unknown") {
        # not seen, so presumably manually added
        print "$m previously manually added, adding to journal.\n";
        $jnl->do("INSERT INTO journal (list,mail,mode) VALUES (?,?,'man-add')",undef,$list->{name},$m);
      } elsif($s eq "man-add") {
	# not in wanted list from datasource, but exists and recorded in journal so we do nothing
      }
    } else {
      # Existing mail is in wanted list, set to auto
      if($s eq "unknown") {
	# unknown, add to journal
        $jnl->do("INSERT INTO journal (list,mail,mode) VALUES (?,?,'auto-add')",undef,$list->{name},$m);
      } else {
	# set as automatic in journal
	$jnl->do("UPDATE journal SET mode='auto-add' WHERE list=? AND mail=?",undef,$list->{name},$m);
      }
    }
  }

  foreach my $m (sort(keys(%$want_membs))) {
    my $s=seen($list->{name},$m);
    if(!defined($have_membs->{$m})) {
      # This wanted mail is not on the existing list, 
      if($s eq "unknown") { 
        # It's not in the journal so we need to add it. 
	push(@adds,$m);
      } elsif($s eq "auto-rem") {
	# automatically removed in the past, readd it
	push(@adds,$m);
      } elsif($s eq "man-rem") {
	# Wanted by datasource, but not there now, but we know about it and do nothing
      } else {
	# It is in the journal, so must have been manually removed
	print "$m previously manually removed\n";
	$jnl->do("UPDATE journal SET mode='man-rem' WHERE list=? AND mail=?",undef,$list->{name},$m);
      } 
    }
  } 
  if($list->{no_change} && $list->{no_change} eq "yes") {
    foreach my $m (@adds) {
      print "Would Add: $m\n";
    }
    foreach my $m (@rems) {
      print "Would Rem: $m\n";
    }
  } elsif($list->{sympa}) {
    foreach my $m (@adds) {
      print "Add: $m\n";
      my $quiet="true";
      if($list->{welcome_message} eq "yes") {
        $quiet="false";
      }
      my $msg=$sympa->add($list->{name},$m,'',$quiet);
      if($msg->fault) {
        die "Add of $m to $list->{name} failed\n";
      }
      $jnl->do("INSERT INTO journal (list,mail,mode) VALUES (?,?,'auto-add')",undef,$list->{name},$m);
    }
    foreach my $m (@rems) {
      print "Rem: $m\n";
      my $quiet="true";
      if($list->{goodbye_message} eq "yes") {
        $quiet="false";
      }
      my $msg=$sympa->del($list->{name},$m,$quiet);
      if($msg->fault) {
        die "DEL of $m from $list->{name} failed\n";
      }
      $jnl->do("UPDATE journal SET mode='auto-rem' WHERE list=? AND mail=?",undef,$list->{name},$m);
    }
  } else { # Mailman2
    if(scalar(@adds)>0) {
      my $opts="";
      if($list->{notify_admin}) {
        $opts.="--admin-notify=$list->{notify_admin} ";
      }
      if($list->{welcome_message}) {
        $opts.="--welcome-msg=$list->{welcome_message} ";
      }
      open(MMADD,"| /usr/lib/mailman/bin/add_members $opts -r - $list->{name}");
      foreach my $m (@adds) {
        print "Add: $m\n";
        print(MMADD "$m\n");
      }
      if(close(MMADD)) {
        $jnl->do("INSERT INTO journal (list,mail,mode) VALUES (?,?,'auto-add')",undef,$list->{name},$m);
      } else {
        print "Warning: error occured with add_members. Journal not updated.\n";
      }
    }
    if(scalar(@rems)>0) {
      my $opts="";
      if($list->{notify_admin} && $list->{notify_admin} eq "no") {
        $opts.="-N ";
      }
      if($list->{goodbye_message} && $list->{goodbye_message} eq "no") {
        $opts.="-n ";
      }
      open(MMREM,"|/usr/lib/mailman/bin/remove_members -f - $opts $list->{name}");
      foreach my $m (@rems) {
        print "Rem: $m\n";
        print(MMREM "$m\n");
      }
      if(close(MMREM)) {
        $jnl->do("UPDATE journal SET mode='auto-rem' WHERE list=? AND mail=?",undef,$list->{name},$m);
      } else {
        print "Warning: error occured with remove_members. Journal not updated.\n";
      }
    }
  }
}

$ldap->unbind;

sub seen {
  my ($list,$mail)=@_;
  my $sth=$jnl->prepare("SELECT mode FROM journal WHERE list=? AND mail=?");
  my $r=$sth->execute($list,$mail);
  my @seen=$sth->fetchrow_array();
  if(!@seen) {
    return("unknown");
  } else {
    return(pop(@seen));
  }
}
