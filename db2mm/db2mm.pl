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
  mail TEXT);
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
      $have_membs->{$_}=1;
    }
    close(LISTMEMB);
  }

  if(!$list->{sympa}) {
    my $opts="";
    if($list->{notify_admin} eq "no") {
      $opts.="-N ";
    }
    if($list->{goodbye_message} eq "no") {
      $opts.="-n ";
    }
    open(MMREM,"|/usr/lib/mailman/bin/remove_members $opts $list->{name}");
  }
  foreach my $m (sort(keys(%$have_membs))) {
    # This existing mail is not in the wanted list, and it's in the journal
    # so we added it in the first place so should remove it now
    if(!defined($want_membs->{$m}) && seen($list->{name},$m)!=0) {
      if($list->{no_change} eq "yes") {
        print "Would del $m\n";
      } else {
        if($list->{sympa}) {
          my $quiet="true";
          if($list->{goodbye_message} eq "yes") {
            $quiet="false";
          }
          my $msg=$sympa->del($list->{name},$m,$quiet);
          if($msg->fault) {
            die "DEL of $m from $list->{name} failed\n";
          }
          print "Del: $m\n";
        } else {
          print(MMREM $m);
        }
        $jnl->do("DELETE FROM journal WHERE list=? AND mail=?",undef,$list->{name},$m);
      } 
    }
  }
  if(!$list->{sympa}) {
    close(MMREM);
    my $opts="";
    if($list->{notify_admin}) {
      $opts.="--admin-notify=$list->{notify_admin} ";
    }
    if($list->{welcome_message}) {
      $opts.="--welcome-msg=$list->{welcome_message} ";
    }
    open(MMADD,"| /usr/lib/mailman/bin/add_members $opts -r - $list->{name}");
  }

  foreach my $m (sort(keys(%$want_membs))) {
    # This wanted mail is not on the existing list, and it's not in the
    # journal so we need to add it. If it were in the journal it was
    # automatically added previously, but has been removed by other means
    if(!defined($have_membs->{$m}) && seen($list->{name},$m)==0) {
      if($list->{no_change} && $list->{no_change} eq "yes") {
        print "Would add $m\n";
      } else {
        if($list->{sympa}) {
          my $quiet="true";
          if($list->{welcome_message} eq "yes") {
            $quiet="false";
          }
          my $msg=$sympa->add($list->{name},$m,'',$quiet);
          if($msg->fault) {
            die "Add of $m to $list->{name} failed\n";
          }
          print "Add: $m\n";
        } else {
          print "Adding $m to $list->{name}\n";
          print(MMADD $m);
        }
        $jnl->do("INSERT INTO journal (list,mail) VALUES (?,?)",undef,$list->{name},$m);
      }
    }
  } 
  if(!$list->{sympa}) {
    close(MMADD);
  }
}

$ldap->unbind;

sub seen {
  my ($list,$mail)=@_;
  my $sth=$jnl->prepare("SELECT COUNT(*) FROM journal WHERE list=? AND mail=?");
  my $r=$sth->execute($list,$mail);
  my ($count)=$sth->fetchrow_array();
  return $count;
}
