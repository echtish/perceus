#!/usr/bin/perl
#
# Copyright (c) 2006-2009, Greg M. Kurtzer, Arthur A. Stevens and
# Infiscale, Inc. All rights reserved
#


BEGIN {
   require "/etc/perceus/Perceus_Include.pm";
   push(@INC, "$Perceus_Include::libdir");
}

use Perceus::Config;
use File::Basename;
use IO::Socket;
use IO::Interface;

$| = 1;

my $hostname = $ENV{'NODENAME'};
my $output;
my $match = ();
my $global = ();
my %config = &parse_config("/etc/perceus/perceus.conf");


my @configs = qw(
   /etc/sysconfig/network-scripts/ifcfg-
   /etc/sysconfig/nics/./
);

open(IPADDR, "/etc/perceus/modules/ipaddr")
    or die "ERROR: could not open /etc/perceus/modules/ipaddr\n";
while(my $entry = <IPADDR> ) {
    my $string = ();
    chomp $entry;
    $entry =~ s/#.*$//;
    next if ! $entry;

    if ( $entry =~ /^$hostname\s+(.+)$/ ) {
        $string = $1;
        $match = 1;
        $output = ();
    } elsif ( $entry =~ /^([^ ]+)\s+(.+)$/ ) {
        my $regex = $1;
        my $rest = $2;
        $regex =~ s/([^\.]?)\*/$1.*/g;
        if ( $hostname =~ /^$regex$/ ) {
            $string = $rest;
            $global = 1;
        }
    }
    if ( defined($match) or defined($global) ) {
        my @addrs = split(/\s+/, $string);
        foreach my $addr ( @addrs ) {
            my ( @options, @extra_options, $dev, @string, $type);
            if ( $addr =~ /^([^\(]+)\(([^\)]+)+\):(.*)/ ) {
                $dev = $1;
                push(@string, $3);
                foreach my $option ( split(/\&/, $2)) {
                    push(@extra_options, $option);
                }
            } else {
                ($dev, @string) = split(/:/, $addr);
            }
            if ( $dev =~ /^([a-z]+\d)_(\d+)$/ ) {
               $dev = "$1:$2";
               $type = "alias";
            } else {
               $type = "ethernet";
            }
            push(@options, "DEVICE=$dev");
            push(@options, "ONBOOT=yes");
            push(@options, "TYPE=$type");
            my ( $ipaddr, $netmask, $gateway ) = split(/\//, join(":", @string));
            if ( $dev and $ipaddr and $netmask ) {
                if ( $ipaddr =~ /^\[(?:default|hostfile)\]$/ ) {
                    $ipaddr = &get_hostentry($hostname, $dev);
                } elsif ( $ipaddr =~ /^\[(?:default|hostfile):(.+)\]$/ ) {
                    my $lookup_host = $1;

                    $lookup_host =~ s/NAME/$hostname/g;
                    $lookup_host =~ s/NIC/$dev/g;
                    $ipaddr = &get_hostentry($lookup_host, $dev);
                } elsif ( $ipaddr =~ /\[nodenum\]/ ) {
                    if ( $hostname =~ /(\d+).*?$/ ) {
                        my $tmpip = sprintf("%d", $1);
                        $ipaddr =~ s/\[nodenum\]/$tmpip/;
                    }
                }
                if ( $netmask =~ /^\[default\]$/ ) {
                    $netmask = &get_netmask();
                } elsif ( $netmask =~ /^\[(?:default:)?(.+)\]$/ ) {
                    my $lookup_host = $1;

                    $lookup_host =~ s/NAME/$hostname/g;
                    $lookup_host =~ s/NIC/$dev/g;
                    $netmask = &get_netmask($lookup_host);
                }
                if ( $gateway =~ /^\[default\]$/ ) {
                    $gateway = &get_ipaddr();
                } elsif ( $gateway =~ /^\[default:(.+)\]$/ ) {
                    my $lookup_host = $1;

                    $lookup_host =~ s/NAME/$hostname/g;
                    $lookup_host =~ s/NIC/$dev/g;
                    $gateway = &get_ipaddr($lookup_host);
                }
            } 
            if ( $dev and $ipaddr eq "dhcp" ) {
                push(@options, "PROTO=dhcp");
                push(@options, "BOOTPROTO=dhcp");
            } elsif ( $dev and ! $ipaddr ) {
                # No default entries
            } else {
                push(@options, "PROTO=static");
                push(@options, "BOOTPROTO=static");
                push(@options, "IPADDR=$ipaddr");
                push(@options, "NETMASK=$netmask");
                push(@options, "GATEWAY=$gateway");
            }
            foreach my $conf ( @configs ) {
                $output .= "mkdir -p \$DESTDIR". dirname($conf) ."\n";
                $output .= "# This configuration has been automatically generated by the\n";
                $output .= "# 'ipaddr' Perceus module, and configured in:\n";
                $output .= "# /etc/perceus/modules/ipaddr\n";
                $output .= "if [ -f \$DESTDIR$conf$dev ]; then\n";
                $output .= "rm \$DESTDIR$conf$dev\n";
                $output .= "fi\n";
                foreach my $option ( @options ) {
                    $output .= "echo '$option' >> \$DESTDIR$conf$dev\n";
                }
                foreach my $option ( @extra_options ) {
                    $output .= "echo '$option' >> \$DESTDIR$conf$dev\n";
                }
            }
        }
    }
    if ( defined($match) ) {
        last;
    }
}
close IPADDR;

sub get_default_nic {

   return($config{"master network device"}[0]);
}

sub get_netmask {

    my $dev = shift || &get_default_nic;

    my $s                = IO::Socket::INET->new(Proto => 'udp');
    my $return           = $s->if_netmask($dev);

    return $return;

}

sub get_ipaddr {

    my $dev = shift || &get_default_nic;

    my $s                = IO::Socket::INET->new(Proto => 'udp');
    my $return           = $s->if_addr($dev);

    return $return;

}

sub get_hostentry {
    my $name = shift;
    my $device = shift;
    my $ipaddr;
    my $entry;

    open(HOSTS, "/etc/hosts")
        or die "ERROR: could not open /etc/hosts\n";
    while(my $entry = <HOSTS> ) {
        chomp $entry;
        $entry =~ s/#.*$//;
        next if ! $entry;
        if ( $entry =~ /^([^\s]+).*\s+$name(\s|$)/ ) {
            $ipaddr = $1;
            last;
        }
    }
    close HOSTS;
    if ( ! defined $ipaddr ) {
       warn "WARNING: Did not locate IP Address for $name:$device, defaulting to DHCP\n";
       print "echo\n";
       print "echo 'WARNING: There is no entry for \"$name\" in the masters /etc/hosts file thus'\n";
       print "echo 'WARNING: DHCP will be used instead for device '$device'.'\n";
       print "sleep 2\n";
       $ipaddr = "dhcp";
    }
    return($ipaddr);
}

print $output;

