#!/usr/bin/perl -w
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);
use Getopt::Long;

my $verbose=0;
### all_flags : string contains all possible flags for a giving partition
my $all_flags = "boot root swap hidden raid lvm lba hp-service palo prep msftres bios_grub";

### --------------------------------------------------------
### info : Eye candy info reporting, print message
###        args : $message : message to output
sub info {
  if ($verbose) {
    my ($message) = @_;
    print "[ ".GREEN."Info".RESET." ] ";
    print join ( "\n[ ".GREEN."Info".RESET." ] ", split (/\n/, $message) ) ;
    print "\n";
  }
}

### --------------------------------------------------------
### is_flag : return true if arg is a flag
###        args : $expr : flag expression
sub is_flag {
  my ($expr) = @_;
  my @flags = split(',', $expr);
  return ($all_flags =~ /$flags[0]/);
}

### --------------------------------------------------------
### get_partitions_fdisk : return a hashtable containing the
###                        partition schema of the machine
###                        using fdisk
###        args : $device : device to scan for partitions
sub get_partitions_fdisk {
  my ($device) = @_;
  my %partscheme=();

  open(CMD, "fdisk -l $device |") or die "Can not launch fdisk command !";
  while (<CMD>) {
    chomp ;
    if (m/^\//) {
      #Device Boot      Start         End      Blocks   Id  System
      @output = split(" ") ;
      my $flags="";
      @output_g = @output;
      if ($output[1] =~ /\*/) {
	$flags = "boot";
	@output_g = @output[0,2..6];
      }
      #print join(":", @output_g)."\n";
      ($dev, $start, $end, $size, $fs, $type) = @output_g ;
      info ("$dev -> start : $start - end : $end ($size)");
      $device = $partnum = $dev;
      $partnum =~ s/.*(\d+)$/$1/;
      $device =~ s/$partnum$//;
      info ("Device key : $dev, device : $device, part : $partnum");
      $partscheme{$dev}{ 'device' } = $device;
      $partscheme{$dev}{ 'partnumber' } = $partnum ;
      $partscheme{$dev}{ 'start' } = $start ;
      $partscheme{$dev}{ 'end' } = $end ;
      $partscheme{$dev}{'mounted'} = 0;

      if ($type) {
	info (" -- Type: $type");
      }
      if ($fs) {
	info (" -- Filesystem : $fs");
	$partscheme{$dev}{ 'type' } = $fs ;
      }
      if ($flags) {
	info (" -- Flags : $flags");
	$partscheme{$dev}{'flags'} = $flags;
      }
    }
  }
  close CMD;
  return \%partscheme;
}

### --------------------------------------------------------
### get_partitions_parted : return a hashtable containing the
###                        partition schema of the machine
###                        using parted
###        args : $device : device to scan for partitions
sub get_partitions_parted {
  my ($device) = @_;
  my %partscheme = ();

  open(CMD, "parted -s $device print |") or die "Can not launch parted command !";
  while (<CMD>) {
    chomp ;
    if (m/^ \d+ /) {
      my $partnumi = "";
      my $start = "";
      my $end = "";
      my $size = "";
      my $type = "";
      my $fs = "";
      my $flags = "";
      #Number  Start   End    Size    Type      File system  Flags
      ($partnum, $start, $end, $size, $type, $fs, $flags) = split (" ", $_, 7) ;
      $key="$device$partnum" ;
      $partscheme{$key}{ 'device' } = $device ;
      $partscheme{$key}{ 'partnumber' } = $partnum ;
      $partscheme{$key}{ 'start' } = $start ;
      $partscheme{$key}{ 'end' } = $end ;
      $partscheme{$key}{ 'type' } = $type ;
      $partscheme{$key}{'mounted'} = 0;
      #if ( $type =~ /extended/i ) { $flags = $fs ; $fs = ""; }
      if ($fs && ( is_flag("$fs $flags") ) ) {
	$flags = "$fs $flags" ; $fs="" ;
      }
      if ( $fs ) {
	$partscheme{$key}{ 'fs' } = $fs ;
      } 
      if ( $flags ) {
	$partscheme{$key}{ 'flags' } = $flags ;
      } 
      info ("$device$partnum -> start : $start - end : $end ($size)");
      info (" -- Type: $type");
      if ($fs) {
	info (" -- Filesystem : $fs");
      }
      if ($flags) {
	info (" -- Flags : $flags");
      }
    }
  }
  close CMD;
  return \%partscheme;
}

### --------------------------------------------------------
### output_partitions_parted : output parted command for
###                          the given hashmap containing the
###                          patition table
###        args : $partscheme_ref : a reference on the hashmap
###               containing the partition table
sub output_partitions_parted {
  my ($partscheme_ref) = @_ ;
  my %partscheme = %$partscheme_ref ;
  my $device="";

  if (!%partscheme){
      print STDERR "No output for selected device\n";
      exit (1);
  }

  for my $parts (sort keys %partscheme) {
    my $fs="";
    $device = $partscheme{$parts}{'device'};
    $fs = $partscheme{$parts}{'fs'} if $partscheme{$parts}{'fs'} ;
    info "Creating partion : $partscheme{$parts}{'partnumber'}";
    print "parted -s $device mkpart $partscheme{$parts}{'type'} $fs "
      .$partscheme{$parts}{'start'}." ".$partscheme{$parts}{'end'}."\n";
    if ($partscheme{$parts}{'flags'}) {
      foreach $f ( split ",", $partscheme{$parts}{'flags'}) {
	print "parted -s $device set ".$partscheme{$parts}{'partnumber'}." $f on\n";
      }
    }
  }
}

### --------------------------------------------------------
### output_partitions_fdisk : output fdisk command for
###                          the given hashmap containing the
###                          patition table
###        args : $partscheme_ref : a reference on the hashmap
###               containing the partition table
sub output_partitions_fdisk {
  my ($partscheme_ref) = @_ ;
  my %partscheme = %$partscheme_ref ;
  my $device="";
  my $started=0;

  if (!%partscheme){
      print STDERR "No output for selected device\n";
      exit (1);
  }

  print "cat <<EOF | fdisk ";
  for my $parts (sort keys %partscheme) {
    my $fs="";
    $device = $partscheme{$parts}{'device'};
    if (! $started) {
	$started = 1;
	print "$device\n";
	info "Deleting partions : $partscheme{$parts}{'partnumber'}";
	print "d\n1\n";
	print "d\n2\n";
	print "d\n3\n";
	print "d\n4\n";
    }
    $fs = $partscheme{$parts}{'fs'} if $partscheme{$parts}{'fs'} ;
    info "Creating partion : $partscheme{$parts}{'partnumber'}";
    print "n\n";
    if ($partscheme{$parts}{'partnumber'} >= 5){
	print "l\n";
    } elsif ($partscheme{$parts}{'type'} eq "5"){
	print "e\n";
    } else {
	print "p\n";
    }
    print "$partscheme{$parts}{'partnumber'}\n";
    print "$partscheme{$parts}{'start'}\n";
    print "$partscheme{$parts}{'end'}\n";
    print "t\n";
    if ($partscheme{$parts}{'partnumber'} ne "1"){
	print "$partscheme{$parts}{'partnumber'}\n";
    }
    print "$partscheme{$parts}{'type'}\n";
    if ($partscheme{$parts}{'flags'}){
	print "a\n";
	print "$partscheme{$parts}{'partnumber'}\n";
    }
  }
  print "w\nEOF\n";
}

### --------------------------------------------------------
### print_table : print the partition table
###        args : $partscheme_ref : a reference on the hashmap
###               containing the partition table
sub print_table {
  my ($partscheme_ref) = @_ ;
  my %partscheme = %$partscheme_ref ;
  foreach $part ( keys(%partscheme)){
    print "$part \n";
    my $temp = $partscheme{$part};
    foreach $prop (keys( %$temp ) ) {
      print "    $prop -> $temp->{$prop} \n";
    }
  }
}

### --------------------------------------------------------
### set_filesystem : correctly set the filesystem of patitions
###                  inside the giving hashtable containing the
###                  partition table
###        args : $partscheme_ref : a reference on the hashmap
###                             containing the partition table
###               $mounts : file containing the mounted devices
sub set_filesystem {
  local ($partscheme_ref, $mounts) = @_ ;
  local %partscheme = %$partscheme_ref ;
  open(MOUNTS, "<$mounts") or die "Can open mounts file ($mounts) !";
  while (<MOUNTS>){
    chomp;
    local ($device, $mountpoint, $fs, $options, $dump, $pass) = split (" ", $_) ;
    #print " device: $device | mountpoint : $mountpoint | fs : $fs | options : $options | $dump | $pass\n";
    if (!  $partscheme{$device}{'mounted'} ) {
      $partscheme{$device}{'fs'} = $fs;
      $partscheme{$device}{'mounted'} = 1;
      $partscheme{$device}{'mountpoint'} = $mountpoint;
      $partscheme{$device}{'fs_options'} = $options;
      $partscheme{$device}{'dump'} = $dump;
      $partscheme{$device}{'pass'} = $pass;
    }
  }
  close(MOUNTS);
}

### --------------------------------------------------------
### set_swap : correctly set the swap partition inside the 
###            giving hashtable containing the partition table
### --------------------------------------------------------
###        args : $partscheme_ref : a reference on the hashmap
###                             containing the partition table
###               $swap : file containing the swap devices
sub set_swap {
  local ($partscheme_ref, $swap) = @_ ;
  local %partscheme = %$partscheme_ref ;
  local $count = 0;
  open(SWAP, "<$swap") or die "Can open swap file ($swap) !";
  while (<SWAP>){
    chomp ;

    # We skip the first line
    if ($count == 0 ){
      $count++;
      next;
    }
    #local ($device, $type, $size, $used, $priority) = split (" ", $_) ;
    local ($device) = split (" ", $_) ;
    #print " device: $device | type : $type | size : $size | used : $used | $priority\n";
    $partscheme{$device}{'swap'} = 1 ;
  }
  close(SWAP);
}

### --------------------------------------------------------
### output_fstab : output the fstab of the hashtable
###                containing the partition table
### WARNING : seems not useful, in fact the fstab will be in the
###           image archive, so no need to generate
# sub output_fstab {
#
# }



### --------------------------------------------------------
### output_mkfs : output the mkfs of the hashtable
###                containing the partition table
sub output_mkfs {
  my ($partscheme_ref) = @_ ;
  my %partscheme = %$partscheme_ref ;
  foreach $part ( keys(%partscheme)){
    if ($partscheme{$part}{'swap'}){
      print "mkswap ".$partscheme{$part}{'device'}.$partscheme{$part}{'partnumber'}."\n";
    }elsif ($partscheme{$part}{'fs'}){
      print "mkfs -t ".$partscheme{$part}{'fs'}." ".$partscheme{$part}{'device'}.$partscheme{$part}{'partnumber'}."\n";
      if (($partscheme{$part}{'mountpoint'})&&($partscheme{$part}{'fs'} =~ /^ext[234]/)){
	  # If filesystem is ext[234] and mounted
	  print "e2label ".$partscheme{$part}{'device'}.$partscheme{$part}{'partnumber'}." ".$partscheme{$part}{'mountpoint'}."\n";
      }
    }
  }
}

### --------------------------------------------------------
### print_usage : output the help summary of this script
###
sub print_usage {
    my $returncode=$_;

    print "Usage: \t$0 [-hv] [--parted] [--fdisk] [--device <device>] [--mountfile <mountfile>] [--swapfile <swapfile>]\n";
    print "This tool gives the nodes where you can deploy\n";
    print "\n";
    print "\t--fdisk\t- output format for fdisk\n";
    print "\t--parted\t- output format for parted (default)\n";
    print "\t--device\t- device to scan (default /dev/sda)\n";
    print "\t--mountfile\t- file containing the current mount status (default: /etc/mtab)\n";
    print "\t--swapfile\t- file containing the current swap status (default: /proc/swaps)\n";
    print "\t-h\n";
    print "\t--help\t\t- gives this message\n";
    print "\t-v\n";
    print "\t--verbose\t- turn on verbose mode\n";
    exit $returncode ;
}

### Main ###
my $device="/dev/sda";
my $mounts="/etc/mtab";
my $swap="/proc/swaps";

my $display_help=0;
my $parted=0;
my $fdisk=0;

# get the command-line options
GetOptions('device=s'                  => \$device,
	   'mountfile=s'               => \$mounts,
	   'swapfile=s'                => \$swap,
	   'parted!'                   => \$parted,
	   'fdisk!'                    => \$fdisk,
	   'h!'                        => \$display_help,
	   'help!'                     => \$display_help,
	   'v!'                        => \$verbose,
	   'verbose!'                  => \$verbose,
    ) or print_usage(1);

if ($display_help){
    print_usage(0);
}

# If no option given, use parted
$parted = 1 if !($parted || $fdisk);

if ($parted){
    info "With parted :";
    $partitions = get_partitions_parted($device);
    output_partitions_parted($partitions);
}
if ($fdisk){
    info "With fdisk :";
    $partitions = get_partitions_fdisk($device);
    output_partitions_fdisk($partitions);
}
set_filesystem($partitions, $mounts);
set_swap($partitions, $swap);
output_mkfs($partitions);
