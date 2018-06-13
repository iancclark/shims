#!/usr/bin/perl -w

use YAML;
use DBI;
use Net::LDAP;
use Data::Dumper;

my $conf=YAML::LoadFile("/usr/local/etc/db2mm.yml");

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

foreach my $list (@{$conf->{lists}}) {
  print "$list->{name}\n";
  next if($list->{enabled} ne "yes");
  my $opts="";
  if($list->{notify_admin}) {
    $opts.="-a=$list->{notify_admin} ";
  }
  if($list->{welcome_message}) {
    $opts.="-w=$list->{welcome_message} ";
  }
  if($list->{goodbye_message}) {
    $opts.="-g=$list->{goodbye_message} ";
  }
  if($list->{no_change}) {
    $opts.="-n ";
  }
  open(MMSYNC,"|/usr/sbin/sync_members $opts -f - $list->{name}");
  foreach my $q (@{$list->{queries}}) {
    print "$q->{type}> $q->{query}\n";
    if($q->{type} eq "sql") {
      my $sth=$dbh->prepare($q->{query});
      $sth->execute;
      while(my $r=$sth->fetchrow_hashref) {
        print MMSYNC $r->{mail}."\n";
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
              print MMSYNC $v.$a->{suffix}."\n";
	    }
	    last;
          } 
        }
      }
    }
  }
  close(MMSYNC);
}

$ldap->unbind;
