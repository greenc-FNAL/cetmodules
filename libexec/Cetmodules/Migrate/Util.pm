# -*- cperl -*-
package Cetmodules::Migrate::Util;

use 5.016;
use Exporter qw(import);
use POSIX qw(strftime);
use strict;
use warnings FATAL => qw(io regexp severe syntax uninitialized void);

our (@EXPORT);

@EXPORT = qw(
  gentime
  trimline
);


sub gentime {
  my @lt = localtime;
  return strftime('%a %b %d %H:%M:%S %Z', @lt);
}


sub trimline {
  my @text = @_;
  my $line = join(q(), @text);
  $line =~ s&(?-s:\s+)$&&msgx;
  return "$line\n";
} #-# End sub trimline
1;