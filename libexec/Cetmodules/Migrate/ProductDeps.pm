# -*- cperl -*-
package Cetmodules::Migrate::ProductDeps;

use 5.016;

use Cwd qw(abs_path chdir getcwd);
use English qw(-no_match_vars);
use Exporter qw(import);
use File::Basename qw(dirname);
use File::Copy;
use File::Spec;
use IO::File;
use List::Util qw();
use List::MoreUtils qw();
use POSIX qw(ceil);
use Readonly;

use Cetmodules::Migrate::Util;
use Cetmodules::UPS::ProductDeps;
use Cetmodules::UPS::Setup;
use Cetmodules::Util;

use strict;
use warnings FATAL => qw(
  Cetmodules
  io
  regexp
  severe
  syntax
  uninitialized
  void
);

use vars qw(
  $CETMODULES_UPS_VERSION
  $CETMODULES_VERSION
  $PRODUCT_DEPS_TAB_WIDTH
  $PRODUCT_TABLE_FORMAT
);

our (@EXPORT, @EXPORT_OK);

@EXPORT    = qw(write_product_deps);
@EXPORT_OK = qw(
  $CETMODULES_UPS_VERSION
  $CETMODULES_VERSION
  $PRODUCT_DEPS_TAB_WIDTH
  $PRODUCT_TABLE_FORMAT
);

my ($_cetmodules_top, $_product_deps_template);

# Initialize private and exported non-customizable constants.
_init_vars();

########################################################################
# Private variables
########################################################################

Readonly::Scalar my $_INIT_PRODUCT_TABLE_FORMAT   => 2;
Readonly::Scalar my $_INIT_PRODUCT_DEPS_TAB_WIDTH => 8;
Readonly::Scalar my $_DIVIDER_LENGTH              => 36;

########################################################################
# Exported variables
########################################################################

# Customizable constants.
$PRODUCT_TABLE_FORMAT   = $_INIT_PRODUCT_TABLE_FORMAT;
$PRODUCT_DEPS_TAB_WIDTH = $_INIT_PRODUCT_DEPS_TAB_WIDTH;

########################################################################
# Exported functions
########################################################################


sub write_product_deps {
  my ($pkg_path_label, $pdinfo, $options) = @_;

  info(<<"EOF");
generating $pkg_path_label/ups/$pdinfo->{filename}.new from $_product_deps_template
EOF

  # Adjustments and additions to product_deps info.
  $pdinfo->{qualifier_columns}->{qualifier} =
    { map { ($_ => $_); } keys %{ $pdinfo->{qualifier_rows} } };
  for (keys %{ $pdinfo->{qualifier_columns} }) {
    my $hash = $pdinfo->{qualifier_columns}->{$_};
    for (keys %{$hash}) {
      $hash->{$_} or $hash->{$_} = '-nq-';
    }
  }
  $pdinfo->{qualifier_columns}->{notes} =
    { map { ($_ => $pdinfo->{notes}->{$_}); }
      keys %{ $pdinfo->{qualifier_rows} } };
  $pdinfo->{table_fragment} = get_table_fragment($pdinfo->{filename});

  my $pd_out = IO::File->new("$pdinfo->{filename}.new", ">") or
    error_exit("unable to open $pdinfo->{filename}.new for write");

  my $pd_in = IO::File->new("$_product_deps_template", "<") or
    error_exit("unable to open $_product_deps_template for read");

  my ($quiet_through, $pending);

  my $gentime = gentime();

  my $divider = q(#) x $_DIVIDER_LENGTH;
  while (my $line = <$pd_in>) {
    if ($line eq "$divider\n") {
      $pd_out->print($line);
      if ($pending) {
        &{$pending}();
        undef $pending;
      } else {
        my $divider_line = $pd_in->input_line_number;
        $line = <$pd_in>;
        my ($label) = $line =~
          m&\#\s+(Basic|Directory|Product|Qualifier|Table|Backmatter)\b&msx;
        $label or error_exit(<<"EOF");
unexpected use of section divider $divider at $_product_deps_template:$divider_line


$line
EOF
        given ($label) {
          when ('Basic') {
            $pending = sub {
              _write_parent_info($pdinfo->{parent_info}, $pd_out);
            };
          }
          when ('Directory') {
            $pending = sub {
              _write_pathspecs($pdinfo->{pathspecs}, $pd_out);
            };
          }
          when ('Product') {
            $pending = sub {
              _write_product_table($pdinfo->{products}, $pd_out);
            };
          }
          when ('Qualifier') {
            $pending = sub {
              _write_qualifier_table($pdinfo->{qualifier_columns},
                                     $pdinfo->{headers}, $pd_out);
            };
          }
          when ('Table') {
            $pending = sub {
              _write_table_fragment($pdinfo->{table_fragment}, $pd_out);
            };
          }
          when ('Backmatter') { } # NOP.
          default {
            error_exit(<<"EOF");
INTERNAL ERROR: don't know how to migrate section $label in $_product_deps_template
EOF
          }
        } ## end given
      } ## end else [ if ($pending) ]
    } ## end if ($line eq "$divider\n")
    $line =~
s&\A(\#\s+Generated by\s+).*\z&${1}Cetmodules $CETMODULES_VERSION at $gentime&msx;
    if ($line =~ m&\Aproduct\s+version\s+qual&msx) {
      $quiet_through = "end_product_list";
    } elsif ($line =~ m&\Aqualifier\b\s*&msx) {
      $quiet_through = "end_qualifier_list";
    } elsif ($line =~ m&table_fragment_begin\b\s*&msx) {
      $quiet_through = "table_fragment_end";
    }
    if ($quiet_through) {

      # Ignore this section.
      $line =~ m&\A\s*\Q$quiet_through\E\b&msx or next;
      undef $quiet_through;
      next;
    } else {
      $pd_out->print($line);
    }
  } ## end while (my $line = <$pd_in>)
  $pd_in->close();
  $pd_out->close();
  if ($options->{"dry-run"}) {
    notify(
         "[DRY_RUN] proposed edits / annotations in $pdinfo->{filename}.new");
  } else {
    info(<<"EOF");
installing $pkg_path_label/ups/$pdinfo->{filename}.new as $pkg_path_label/ups/$pdinfo->{filename}
EOF
    move("$pdinfo->{filename}.new", "$pdinfo->{filename}") or
      error_exit(
          "unable to install $pdinfo->{filename}.new as $pdinfo->{filename}");
  }
  return;
} ## end sub write_product_deps

########################################################################
# Private functions
########################################################################


sub _init_vars {
  $_cetmodules_top =
    abs_path(File::Spec->catfile(dirname(__FILE__), q(..), q(..), q(..)));
  $_product_deps_template =
    "$_cetmodules_top/ups-templates/product_deps.template";
  if (-r $_product_deps_template) {
    ## no critic qw(InputOutput::ProhibitBacktickOperators)
    $CETMODULES_VERSION =
qx(sed -Ene 's&^#[[:space:]]+Generated by cetmodules ([^[:space:]]+).*\$&\\1&p' "$_product_deps_template");
    chomp $CETMODULES_VERSION;
  } else {

    # We're running from our own source tree.
    $_product_deps_template = "$_product_deps_template.in";
    -r $_product_deps_template or error_exit(<<"EOF");
unable to find a valid product_deps template file under $_cetmodules_top
EOF
    my $cpi = get_cmake_project_info($_cetmodules_top, quiet_warnings => 1);
    $CETMODULES_VERSION = $cpi->{cmake_project_version};
  } ## end else [ if (-r $_product_deps_template)]
  $CETMODULES_VERSION or
    error_exit("unable to ascertain current cetmodules version");
  $CETMODULES_UPS_VERSION = to_ups_version($CETMODULES_VERSION);
  return;
} ## end sub _init_vars


sub _max_for_column {
  my @args = @_;
  return
    scalar @args ?
    ceil(List::Util::max(map { length($_ // q()) + 1; } @args) /
         $PRODUCT_DEPS_TAB_WIDTH) :
    0;
}


sub _pad_to {
  my ($ntabs, $content) = @_;
  $content = trimline($content // q());
  my $column_width = $ntabs * $PRODUCT_DEPS_TAB_WIDTH;
  $column_width or return $content;
  my $tabs_to_add = List::Util::max(0,
                                    ceil(($column_width - length($content)) /
                                           $PRODUCT_DEPS_TAB_WIDTH
                                        ));
  return sprintf("$content%s", "\t" x $tabs_to_add);
} ## end sub _pad_to


sub _write_parent_info {
  my ($pi, $fh) = @_;
  my @directives = (qw(parent chains defaultqual));
  my @flags      = (qw(no_fq_dir noarch define_pythonpath));
  my $translate = {
     parent => $pi->{name},
     (exists $pi->{default_qual}) ? (defaultqual => $pi->{default_qual}) : (),
     (exists $pi->{chains} and scalar @{ $pi->{chains} }) ?
       (chains => join('\t', @{ $pi->{chains} })) : () };

  @{$translate}{ List::MoreUtils::all { defined $pi->{$_} } @flags } = q();
  my $ntabs = _max_for_column(keys %{$translate});
  $fh->print(
    map {
      exists $translate->{$_} ?
        trimline(_pad_to($ntabs, $_), "$translate->{$_}\n") :
        ();
    } @directives,
    @flags);
  return;
} ## end sub _write_parent_info


sub _write_pathspecs {
  my ($pathspecs, $fh) = @_;
  my $table   = [];
  my @columns = (qw(dirkey key path));
  foreach my $dirkey (sort keys %{$pathspecs}) {
    my $pathspec = $pathspecs->{$dirkey};
    my (@keys, @paths);
    if (ref $pathspec->{key} eq 'ARRAY') {
      @keys  = @{ $pathspec->{key} };
      @paths = @{ $pathspec->{path} };
    } else {
      @keys  = ($pathspec->{key});
      @paths = ($pathspec->{path});
    }
    while (scalar @keys) {
      push @{$table},
        { dirkey => $dirkey, key => shift @keys, path => shift @paths };
    }
  } ## end foreach my $dirkey (sort keys...)
  my $ntabs = {
    map {
      my $col = $_;
      $col => _max_for_column(map { $_->{$col}; } @{$table});
    } @columns[ 0 .. $#columns - 1 ] };
  $fh->print(
    map {
      my $row = $_;
      trimline(map({ _pad_to($ntabs->{$_} // 0, $row->{$_}); } @columns));
    } @{$table});
  return;
} ## end sub _write_pathspecs


sub _write_product_table {
  my ($products, $fh) = @_;
  delete $products->{cetbuildtools};
  $products->{cetmodules}->{q(-)} =
    { version => $CETMODULES_UPS_VERSION, only_for_build => 1 };
  my @columns   = (qw(product version qual flags));
  my $max_flags = {};
  my $product_table = [
    map {
      my $product  = $_;
      my @quals    = keys %{ $products->{$product} };
      my @versions = map { $products->{$product}->{$_}->{version}; } @quals;
      my @nflags   = ();
      my @flags    = map {
        my @pflags =
          grep { $_ ne 'version' } keys %{ $products->{$product}->{$_} };
        push @nflags, scalar @pflags;
        (@pflags);
      } @quals;
      $max_flags->{$product} = List::Util::max(@nflags);
      map {
        {
          product => $product,
          qual    => $_,
          version => shift @versions,
          flags   => shift @flags
        };
      } @quals;
    } keys %{$products} ];
  my $ntabs = {
    map {
      my $col = $_;
      ($col => _max_for_column(map({ $_->{$col}; } @{$product_table}), $col));
      } @columns
  };
  $fh->print(map({ _pad_to($ntabs->{$_}, $_); } @columns),
             "<table_format=$PRODUCT_TABLE_FORMAT>\n");
  $fh->print(
    map {
      my $row = $_;
      trimline(map({ _pad_to($ntabs->{$_} // 0, $row->{$_}); } @columns));
    } sort {
      $max_flags->{ $a->{product} } <=> $max_flags->{ $b->{product} } or
        $a->{product} cmp $b->{product} or
        version_cmp($a->{version}, $b->{version});
    } @{$product_table});
  $fh->print("end_product_list\n");
  return;
} ## end sub _write_product_table


sub _write_qualifier_table {
  my ($qualifier_table, $headers, $fh) = @_;
  scalar @{$headers} or return;
  my $ntabs = {
    map {
      ($_ => _max_for_column(values %{ $qualifier_table->{$_} }, $_));
    } @{$headers}[ 0 .. ($#{$headers} - 1) ] };
  $ntabs->{ $headers->[-1] } = 0; # No padding at end of table.
  $fh->print(trimline(map { _pad_to($ntabs->{$_}, $_); } @{$headers}));
  grep {
    my $qualifier = $_;
    $fh->print(
      trimline(
        map {
          my $hash = $qualifier_table->{$_};
          _pad_to($ntabs->{$_}, $hash->{$qualifier});
        } @{$headers}
      ),
      "\n");
  } sort keys %{ $qualifier_table->{qualifier} };
  $fh->print("end_qualifier_list\n");
  return;
} ## end sub _write_qualifier_table


sub _write_table_fragment {
  my ($table_fragment, $fh) = @_;
  $table_fragment or return;
  $fh->print("table_fragment_begin\n", map({ "$_\n"; } @{$table_fragment}),
             "table_fragment_end\n");
  return;
}

1;
