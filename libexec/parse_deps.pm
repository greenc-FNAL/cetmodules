########################################################################
# parse_deps.pm
#
#   Parse the information to be found in a package's ups/product_deps
#   file.
#
# For a full description of the product_deps file format, see comments
# to cetmodules/ups-templates/product_deps.template.in.
########################################################################

package parse_deps;

use strict;
use warnings;
use warnings::register;

use File::Spec; # For catfile;

use Exporter 'import';
our (@EXPORT, @EXPORT_OK);

use vars qw($btype_table $pathspec_info $VERBOSE $QUIET);

use File::Basename qw(basename dirname);

$pathspec_info =
  {
   bindir => { },
   cmakemoduledir => { project_var => 'CMAKE_MODULES_DIR' },
   fcldir => { project_var => 'FHICL_DIR' },
   fwdir => { },
   gdmldir => { },
   incdir => { project_var => 'INCLUDE_DIR' },
   libdir => { project_var => 'LIBRARY_DIR' },
   perllib => { },
   set_fwdir => { multiple_ok => 1, project_var => "FW_SEARCH_PATH" },
   set_wpdir => { multiple_ok => 1, project_var => "WIRECELL_PATH" },
   testdir => { },
   wpdir =>  { }
  };

my @known_keywords =
  qw(chain
     chains
     defaultqual
     define_pythonpath
     end_product_list
     end_qualifier_list
     no_fq_dir
     noarch
     parent
     product
     qualifier
     table_fragment_begin
     table_fragment_end
   );
push @known_keywords, sort keys %$pathspec_info;

my $chain_option_table =
  {
   -c => 'current',
   -d => 'development',
   -n => 'new',
   -o => 'old',
   -t => 'test'
  };

$btype_table = { debug => 'Debug',
                 prof => 'RelWithDebInfo',
                 opt => 'Release' };

@EXPORT =
  qw(
      cetpkg_info_file
      classify_deps
      compiler_for_quals
      deps_for_quals
      error_exit
      get_cmake_project_info
      get_derived_parent_data
      get_parent_info
      get_pathspec
      get_product_list
      get_qualifier_matrix
      get_table_fragment
      info
      print_dep_setup
      print_dep_setup_one
      print_dev_setup
      sort_qual
      table_dep_setup
      to_dot_version
      to_string
      to_ups_version
      ups_to_cmake
      var_stem_for_dirkey
      verbose
      version_cmp
      warning
      write_table_deps
      write_table_frag
   );

@EXPORT_OK = qw($btype_table $pathspec_info setup_err);

sub error_exit {
  my (@msg) = @_;
  chomp @msg;
  print STDERR map { "ERROR: $_\n"; } ("", (map { split("\n") } @msg), "");
  exit 1;
}

sub warning {
  my (@msg) = @_;
  chomp @msg;
  print STDERR map { "WARNING: $_\n"; } ("", (map { split("\n") } @msg), "");
}

sub info {
  return if $parse_deps::QUIET;
  my (@msg) = @_;
  chomp @msg;
  print map { "INFO: $_\n"; } map { split("\n") } @msg;
}

sub verbose {
  return unless $parse_deps::VERBOSE;
  my (@msg) = @_;
  chomp @msg;
  print map { "VERBOSE: $_\n"; } map { split("\n") } @msg;
}

sub get_parent_info {
  my ($pfile, %options) = @_;
  open(my $fh, "<", "$pfile") or error_exit("couldn't open $pfile");
  my $result = { pfile => $pfile };
  my $chains;
  while (<$fh>) {
    chomp;
    s&\s*\#.*$&&;
    m&\w+& or next;
    my ($keyword, @pars) = split;
    if ($keyword eq "parent") {
      warning("multi-argument version of \"parent\" in $pfile",
              "is deprecated: VERSION defined in CMakeLists.txt:project() governs.",
              "Use \"chain[s] [current|test|new|old|<chain>]...\" in $pfile to specify chains.")
        if ($pars[1] and not $options{quiet_warnings});
      $result->{name} = shift @pars;
      $result->{version} = shift @pars if $pars[0];
      @$chains{@pars} = (1) x scalar @pars if scalar @pars;
    } elsif ($keyword =~ m&^chains?$&) {
      @$chains{@pars} = (1) x scalar @pars if scalar @pars;
    } elsif ($keyword eq "defaultqual") {
      $result->{default_qual} = sort_qual(@pars);
      $result->{default_qual} =~ m&^-nq-?$& and $result->{default_qual} = "";
    } elsif (grep { $_ eq $keyword; } qw(no_fq_dir noarch define_pythonpath)) {
      scalar @pars and
        warning(sprintf("unexpected garbage following $keyword: %s",
                        join(" ", @pars)));
      $result->{$keyword} = 1;
    } else {
    }
  }
  close($fh);
  # Make the chain list, translating -c... ups declare options to their
  # corresponding chain names.
  $result->{chains} = [ sort map { exists $chain_option_table->{$_} ?
                                     $chain_option_table->{$_} : $_; }
                        keys %$chains ]
    if scalar keys %$chains;
  return $result;
}

sub get_derived_parent_data {
  my ($pi, $sourcedir, @qualstrings) = @_;

  # CMake info.
  my ($cmake_project, $cmake_project_version) =
    get_cmake_project_info($sourcedir,
                           ($pi->{version}) ?
                           (quiet_warnings => 1) : ())
      unless $pi->{cmake_project} && $pi->{cmake_project_version};

  if ($cmake_project) {
    $pi->{cmake_project} = $cmake_project;
    $pi->{name} = to_product_name($cmake_project)
      unless exists $pi->{name};
  } else {
    $pi->{cmake_project} = $pi->{name};
  }

  if ($cmake_project_version) {
    $pi->{cmake_project_version} = $cmake_project_version;
    $pi->{version} = to_ups_version($cmake_project_version)
      unless exists $pi->{version};
  } else {
    $pi->{cmake_project_version} = to_dot_version($pi->{version});
  }

  my @sorted;
  $pi->{qualspec} = sort_qual(\@sorted, @qualstrings);
  @{$pi}{qw(cqual extqual build_type)} = @sorted;
  $pi->{cmake_build_type} = $btype_table->{$pi->{build_type}}
    if $pi->{build_type};

  # Derivatives of the product's UPS flavor.
  if ($pi->{no_fq_dir}) {
    $pi->{flavor} = "NULL";
  } else {
    my $fq_dir;
    my $flavor = `ups flavor -4`;
    error_exit("failure executing ups flavor: UPS not set up?") if $!;
    chomp $flavor;
    # We only care about OS major version no. for Darwin.
    $flavor =~ s&^(Darwin.*?\+\d+).*$&${1}&;
    $pi->{flavor} = $flavor;
    if ($pi->{noarch}) {
      $fq_dir = 'noarch';
    } else {
      $fq_dir = $ENV{CET_SUBDIR} or
        error_exit("CET_SUBDIR not set: missing cetpkgsupport?");
    }
    $pi->{fq_dir} = join('.', $fq_dir, split(':', $pi->{qualspec}));
  }
}

sub get_table_fragment {
  my $pfile = shift;
  my $reading_frag;
  my @fraglines = ();
  open(my $fh, "<", "$pfile") or error_exit("couldn't open $pfile");
  while (<$fh>) {
    chomp;
    next if (m&^\s*#& and not $reading_frag);
    m&^\s*table_fragment_end& and undef $reading_frag;
    push @fraglines, $_ if $reading_frag;
    m&^\s*table_fragment_begin& and $reading_frag = 1;
  }
  close($fh);
  return (scalar @fraglines) ? \@fraglines : undef;
}

sub dirkey_is_valid {
  my $dirkey = shift;
  return $dirkey && grep { $_ eq $dirkey } keys %{$pathspec_info};
}

my $valid_pathkeys = [ "product_dir", "fq_dir", "-" ];

sub pathkey_is_valid {
  my $pathkey = shift;
  return $pathkey && grep { $_ eq $pathkey } @$valid_pathkeys;
}

sub get_pathspec {
  my ($pi, $dirkey) = @_;
  error_exit("unrecognized directory key $dirkey")
    if not dirkey_is_valid($dirkey);
  $pi->{pathspec_cache} = {} unless exists $pi->{pathspec_cache};
  my $pathspec_cache = $pi->{pathspec_cache};
  unless ($pathspec_cache->{$dirkey}) {
    my $multiple_ok = $pathspec_info->{$dirkey}->{multiple_ok} || 0;
    open(PD, "<", "$pi->{pfile}") or error_exit("couldn't open $pi->{pfile}");
    my ($seen_dirkey, $pathkeys, $dirnames) = (undef, [], []);
    while (<PD>) {
      chomp;
      # Skip full-line comments and whitespace-only lines.
      next if m&^\s*#&o or !m&\S&o;
      my ($found_dirkey, $pathkey, $dirname) = (m&^\s*(\Q$dirkey\E)\b(?:\s+(\S+)\s*(\S*?))?(?:\s*#.*)?$&);
      next unless $found_dirkey;
      error_exit("dangling directory key $dirkey seen in $pi->{pfile} at line $.:",
                 "path key is required") unless $pathkey;
      error_exit("unrecognized path key $pathkey for directory key $dirkey in $pi->{pfile}",
                 " at line $.") unless pathkey_is_valid($pathkey);

      if ($seen_dirkey) {
        error_exit("illegal duplicate directory key $dirkey seen in $pi->{pfile} ",
                   "at line $. (first seen at line $seen_dirkey)")
          unless $multiple_ok;
        error_exit("elision request (pathkey '-' with no path) at line $.",
                   "is only valid for the first mention of a directory key",
                   "($dirkey first seen at line $seen_dirkey)")
          if ($pathkey eq "-" and not $dirname);
      } else {
        $seen_dirkey = $.;
      }
      push @$pathkeys, $pathkey;
      if ($pathkey eq "-" and not $dirname) {
        undef $dirnames;
        last;
      }
      push @$dirnames, $dirname;
    }
    close(PD);
    $pathspec_cache->{$dirkey} =
      { key => (scalar @$pathkeys > 1) ? $pathkeys : $pathkeys->[0],
        (defined $dirnames) ?
        (path => (scalar @$dirnames > 1) ? $dirnames : $dirnames->[0]) : () }
        if $seen_dirkey;
  }
  return $pathspec_cache->{$dirkey};
}

sub get_product_list {
  my ($pfile) = @_;
  open(my $fh, "<", "$pfile") or error_exit("couldn't open $pfile");
  my $get_phash;
  my $pv="";
  my $dqiter=-1;
  my $piter=-1;
  my $phash = {};
  my $pl_format = 1; # Default format.
  while (<$fh>) {
    chomp;
    s&\s*\#.*$&&;
    m&\w+& or next;
    my (@words) = split;
    my $keyword = $words[0];
    if ($keyword eq "end_product_list") {
      last; # Done.
    } elsif ($keyword eq "product") {
      $get_phash="true";
      if ($words[$#words] =~ /^<\s*(?:table_)?format\s*=\s*(\d+)\s*>/o) {
        $pl_format = ${1};
      }
    } elsif ($get_phash) {
      unwanted_keyword($keyword) and
        error_exit(sprintf("unexpected keyword $keyword at $pfile:%d - missing end_product_list?",
                           $fh->input_line_number));

      # Also covers archaic "only_for_build" lines: do *not* put a
      # special case above.
      ++$piter;
      my ($prod, $version, $qualspec, $modifier) = @words;
      $qualspec = '-' unless $qualspec;
      $modifier = '' unless $modifier;

      if ($prod eq "only_for_build") {
        # Archaic form.
        ($prod, $version, $qualspec, $modifier) =
          ($version, $qualspec, '-', $prod);
        warning("Deprecated only_for_build entry found in $pfile: please replace:\n",
                "  \"$_\"\n",
                "with\n",
                "  \"$prod\t$version\t$qualspec\t$modifier\"\n",
                "This accommodation will be removed in future.");
      }

      if ($qualspec and $qualspec eq "-nq-") {
        # Under format version 1, "-nq-" meant, "always." Since format
        # version 2, it means, "when we have no qualifiers," and "-"
        # means, "always."
        $qualspec = ($pl_format == 1) ? "-" : "";
      }

      $phash->{$prod}->{$qualspec} =
        {version => (($version eq "-") ? "-c" : $version),
         ($modifier ? ($modifier => 1) : ()) };
    } else {
    }
  }
  close($fh);
  return $phash;
}

sub deps_for_quals {
  my ($pfile, $phash, $qhash, $qualspec) = @_;
  my $results = {};
  foreach my $prod (sort keys %{$phash}) {
    # Find matching version hashes for this product, including default
    # and empty. $phash is the product list hash as produced by
    # get_product_list().
    my $matches =
      { map { match_qual($_, $qualspec) ?
                ( $_ => $phash->{${prod}}->{$_} ) : ();
            } sort keys %{$phash->{$prod}}
      };
    # Remove the default entry from the set of matches (if it exists)
    # and save it.
    my $default = delete $matches->{"-default-"}; # undef if missing.
    error_exit("ambiguous result matching version for dependency $prod against parent qualifiers $qualspec")
      if (scalar keys %{$matches} > 1);
    # Use $default if we need to.
    my $result = (values %{$matches})[0] || $default || next;
    $result = { %{$result} }; # Copy contents for amendment.
    if (exists $qhash->{$prod} and
        exists $qhash->{$prod}->{$qualspec}) {
      if ($qhash->{$prod}->{$qualspec} eq '-b-') {
        # Old syntax for unqualified build-only deps.
        $result->{only_for_build} = 1;
        $result->{qualspec} = '';
      } elsif ($qhash->{$prod}->{$qualspec} eq '-') {
        # Not needed here.
        next;
      } else {
        # Normal case.
        $result->{qualspec} = $qhash->{$prod}->{$qualspec} || '';
      }
    } elsif (not $result->{only_for_build}) {
      if (not exists $qhash->{$prod}) {
        error_exit("dependency $prod has no column in the qualifier table.",
                   "Please check $pfile");
      } else {
        error_exit(sprintf("dependency %s has no entry in the qualifier table for %s.",
                           $prod,
                           ($qualspec ? "parent qualifier $qualspec" :
                            "unqualified parent")),
                   "Please check $pfile");
      }
    } else {
      $result->{qualspec} = $qhash->{$prod}->{$qualspec} || '';
    }
    $results->{$prod} = $result;
  } # foreach $prod.
  return $results;
}

sub wanted_keyword {
  my ($keyword, @whitelist) = @_;
  return grep { $keyword eq $_ } @whitelist;
}

sub unwanted_keyword {
  my ($keyword, @whitelist) = @_;
  return (not grep { $keyword eq $_ } @whitelist and
          grep { $keyword eq $_ } @known_keywords);
}

sub get_qualifier_list {
  my ($pfile) = @_;
  my $get_quals;
  my $qlen = 0;
  my @qlist = ();
  my @notes = ();
  open(my $fh, "<", "$pfile") or error_exit("couldn't open $pfile");
  while (<$fh>) {
    chomp;
    s&\s*\#.*$&&;
    m&\w+& or next;
    my (@words) = split;
    my $keyword = $words[0];
    if ($keyword eq "end_qualifier_list") {
      last; # Done.
    } elsif ($keyword eq "qualifier") {
      $get_quals = 1;
      for (; $qlen < $#words and $words[$qlen + 1] ne "notes"; ++$qlen) { }
      push @notes, $words[$qlen + 1] || '';
      push @qlist, [@words[0..$qlen]];
    } elsif ($get_quals) {
      unwanted_keyword($keyword) and
        error_exit(sprintf("unexpected keyword $keyword at $pfile:%d - missing end_qualifier_list?",
                           $fh->input_line_number));
      scalar @words < $qlen and
        error_exit("require $qlen qualifier_list entries for $keyword: found only $#words");
      push @notes, $words[$qlen + 1] || '';
      push @qlist, [ map { (not $_ or $_ eq "-nq-") ? "" : sort_qual($_); }
                     @words[0..$qlen] ];
    } else {
    }
  }
  close($fh);
  return ($qlen, \@qlist, \@notes);
}

sub get_qualifier_matrix {
  my ($qlen, $qlist, $notes) = get_qualifier_list(shift);
  my ($qhash, $qqhash, $nhash); # (by-column, by-row, notes)
  my @prods = @{shift @$qlist}; # Drop header row from @$qlist.
  $qhash = { map { my $idx = $_; ( $prods[$idx] => { map { (@$_[0] => @$_[$idx]); } @$qlist } ); } 1..$qlen };
  $qqhash = { map { my @dq = @$_; ( $dq[0] => { map { ( $prods[$_] => $dq[$_] ); } 1..$qlen } ); } @$qlist };
  my @headers = (@prods, shift @$notes || ());
  $nhash = { map { ( $_->[0] => (shift @$notes or '')); } @$qlist };
  return ($qlen, $qhash, $qqhash, $nhash, \@headers);
}

sub match_qual {
  my ($match_spec, $qualstring) = @_;
  my @quals = split(/:/, $qualstring);
  my ($neg, $qual_spec) = ($match_spec =~ m&^(!)?(.*)$&);
  return ($qual_spec eq '-' or
          $qual_spec eq '-default-' or
          ($neg xor grep { $qual_spec eq $_ } @quals));
}

sub sort_qual {
  my ($cqual, $btype);
  # If the first argument is a reference to ARRAY, then it is an output
  # array reference for the result.
  my $sorted =
    ( $_[0] and (ref $_[0] || '') eq 'ARRAY') ? shift : [];
  my @extquals=();
  foreach my $q (map { s&^\+&&o; $_; } split(':', join(':', @_))) {
    if ($q =~ m&^[ce]\d+$&o) {
      error_exit("multiple primary qualifiers encountered: $cqual, $q")
        if $cqual;
      $cqual = $q;
    } elsif (exists $btype_table->{$q}) {
      error_exit("multiple build type qualifiers encountered: $btype, $q")
        if $btype;
      $btype = $q;
    } elsif ($q ne '-nq-') {
      push @extquals, $q;
    }
  }
  # Re-order.
  my $eq = join(':', sort @extquals);
  @$sorted = ($cqual, $eq, $btype);
  return join(':', map { $_ || (); } @$sorted);
}

sub output_info {
  my ($fh, $info, $for_export, @keys) = @_;
  my @defined_vars = ();
  foreach my $key (@keys) {
    my $var = "CETPKG_\U$key";
    $var="export $var" if grep { $var eq $_; } @$for_export;
    my $val = $info->{$key} || "";
    print $fh "$var=";
    if (not ref $val) {
      print $fh "\Q$val\E\n";
    } elsif (ref $val eq "SCALAR") {
      print $fh "\Q$$val\E\n";
    } elsif (ref $val eq "ARRAY") {
      printf $fh "(%s)\n", join(" ", map { "\Q$_\E" } @$val);
    } else {
      verbose(sprintf("ignoring unexpected info $key of type %s", ref $val));
    }
    push @defined_vars, $var;
  }
  return @defined_vars;
}

# Output information for buildtool.
sub cetpkg_info_file {
  my (%info) = @_;
  my @expected_keys =
    qw(source build name version chains qualspec cqual build_type extqual use_time_deps
       build_only_deps cmake_project cmake_project_version cmake_args);
  my @for_export = (qw(CETPKG_SOURCE CETPKG_BUILD));
  my $cetpkgfile = File::Spec->catfile($info{build} || ".", "cetpkg_info.sh");
  open(my $fh, ">", "$cetpkgfile") or
    error_exit("couldn't open $cetpkgfile for write");
  print $fh <<'EOD';
#!/bin/bash
########################################################################
# cetpkg_info.sh
#
#   Generated script to define variables required by buildtool to
#   compose the build environment.
#
# If we're being sourced, define the expected shell and environment
# variables; otherwise, print the definitions for user information.
#
##################
# NOTES
#
# * The definitions printed by executing this script are formatted to be
#   human-readable; they may *not* be suitable for feeding to a shell.
#
# * This script is *not* shell-agnostic, as it is not intended to be a 
#   general setup script.
#
# * Most items are not exported to the environment and will therefore
#   not be visible downstream of the shell sourcing this file.
#
########################################################################

( return 0 2>/dev/null ) && eval "__EOF__() { :; }" && \
  _cetpkg_catit=(:) || _cetpkg_catit=(cat '<<' __EOF__ '|' sed -Ee "'"'s&\\([^\\]|$)&\1&g'"'" )
eval "${_cetpkg_catit[@]}"$'\n'\
EOD
  my $var_data;
  open(my $tmp_fh, ">", \$var_data);
  # Output known info in expected order, followed by any remainder in
  # lexical order.
  my @output_items =
    output_info($tmp_fh, \%info, \@for_export,
                (map { my $key = $_;
                       (grep { $key eq $_ } keys %info) ? ($key) : () }
                 @expected_keys),
              (map { my $key = $_;
                     (grep { $key eq $_ } @expected_keys) ? () : ($key) }
               sort keys %info));
  close($tmp_fh);
  open($tmp_fh, "<", \$var_data);
  while (<$tmp_fh>) {
    chomp;
    print $fh "\Q$_\E\$'\\n'\\\n";
  }
  close($tmp_fh);
  print $fh <<'EOD';
$'\n'\
__EOF__
( return 0 2>/dev/null ) && unset __EOF__ \
EOD
  print $fh "  || true\n";
  close($fh);
  chmod 0755, $cetpkgfile;
  return $cetpkgfile;
}

sub classify_deps {
  my ($pi, $dep_info) = @_;
  foreach my $dep (sort keys $dep_info) {
    $pi->{($dep_info->{$dep}->{only_for_build}) ?
          'build_only_deps' : 'use_time_deps'}->{$dep} = 1;
  }
  foreach my $key (qw(build_only_deps use_time_deps)) {
    $pi->{$key} = [ sort keys %{$pi->{$key}} ];
  }
}

sub compiler_for_quals {
  my ($compilers, $qualspec) = @_;
  my $compiler;
  my @quals = split /:/o, $qualspec;
  if ($compilers->{$qualspec} and $compilers->{$qualspec} ne '-') {
    #print $dfile "product_setup_loop debug info: compiler entry for $qualspec is $compilers->{$qualspec}\n";
    $compiler = $compilers->{$qualspec};
  } elsif (grep /^(?:e13|c(?:lang)?\d+)$/o, @quals) {
    $compiler = "clang";
  } elsif (grep /^(?:e|gcc)\d+$/o, @quals) {
    $compiler = "gcc";
  } elsif (grep /^(?:i|icc)\d+$/o, @quals) {
    $compiler = "icc";
  } else {
    $compiler = "cc";           # Native.
  }
  return $compiler;
}

sub offset_annotated_items;

sub to_string {
  my $incremental_indent = 2;
  my $hash_indent = length('{ ');
  my $max_incremental_indent = 10;
  my $item = shift;
  $item = (defined $item) ? $item : "<undef>";
  my $indent;
  my $options = shift;
  if (not defined $options) {
    $options = {};
  } elsif (not (ref $options eq 'HASH')) {
    $indent = $options;
    $options = {};
  } else {
    $indent = (delete $options->{indent}) || 0;
  }
  if (exists $options->{preamble}) {
    my ($hanging_preamble) =
      ($options->{preamble} =~ m&^(?:.*?\n)*(.*?)[ 	]*$&);
    my $hplen = length($hanging_preamble);
    if ($hplen > $max_incremental_indent) {
      $indent += $incremental_indent;
    } else {
      $indent += $hplen + 1;
    }
  }
  my $type = ref $item;
  my $result;
  if (not $type) {
    $result = "$item";
  } elsif ($type eq "SCALAR") {
    $result = "$$item";
  } elsif ($type eq "ARRAY") {
    $result =
      sprintf("\%s ]", offset_annotated_items($indent, '[ ', @$item));
  } elsif ($type eq "HASH") {
    $indent += $hash_indent;
    $result =
      sprintf("{ \%s }",
              join(sprintf(",\n\%s", ' ' x $indent),
                   map {
                     to_string($item->{$_},
                               { preamble => "$_ => ",
                                 indent => $indent });
                   } keys %$item));
    $indent -= $hash_indent;
  } else {
    print STDERR "ERROR: cannot print item of type $type.\n";
    exit(1);
  }
  return sprintf('%s%s', $options->{preamble} || '', $result);
}

sub offset_annotated_items {
  my ($offset, $preamble, @args) = @_;
  my $indent = length($preamble) + $offset;
  return sprintf('%s%s', $preamble,
                 join(sprintf(",\n\%s", ' ' x $indent),
                      map { to_string($_, $indent); } @args));
}

# Sort order:
#
# alpha[[-_]NN] (alpha releases);
# beta[[-_]NN] (beta releases);
# rc[[-_]NN] or pre[[-_]NN] (prereleases);
# <empty>;
# p[-_]NN or patch[[-_]NN] (patch releases);
# Anything else.
sub parse_version_extra {
  my $vInfo = shift;
  # Swallow optional _ or - separator to 4th field.
  if (($vInfo->{micro} // '') =~ m&^(\d+)[-_]?((.*?)[-_]?(\d*))$&o) {
    $vInfo->{micro} = "$1";
  } else {
    $vInfo->{micro} = undef;
  }
  my ($extra, $etext, $enum) = (${2} // "", ${3} // "", (defined ${2} and ${4} or -1));
  if (not $etext) {
    $vInfo->{extra_type} = 0;
  } elsif ($etext eq "patch" or ($enum >= 0 and $etext eq "p")) {
    $vInfo->{extra_type} = 1;
  } elsif ($etext eq "rc" or
           $etext eq "pre") {
    $vInfo->{extra_type} = -1;
    $etext = "pre";
  } elsif ($etext eq "beta") {
    $vInfo->{extra_type} = -2;
  } elsif ($etext eq "alpha") {
    $vInfo->{extra_type} = -3;
  } else {
    $vInfo->{extra_type} = 2;
  }
  $vInfo->{extra} = $extra;
  $vInfo->{extra_num} = $enum;
  $vInfo->{extra_text} = $etext;
}

sub parse_version_string {
  my $dv = shift // "";
  $dv =~ s&^v&&o;
  my $result = {};
  if ($dv) {
    @{$result}{qw(major minor micro)} = split /[_.]/, $dv, 3;
    parse_version_extra($result);
  } else {
    my @keys = qw(major minor micro extra_type extra extra_text extra_num);
    @{$result}{@keys} = (undef) x scalar @keys;
  }
  return $result;
}

sub _format_version {
  my $v = shift;
  $v = parse_version_string($v) unless ref $v;
  my $separator = shift // '.';
  my $preamble = shift // '';
  return sprintf("${preamble}%s%s",
                 join($separator,
                      $v->{major} // (),
                      $v->{minor} // (),
                      $v->{micro} // ()),
                 $v->{extra} // '');
}

sub to_dot_version {
  return _format_version(shift);
}

sub to_ups_version {
  return _format_version(shift, '_', 'v');
}

sub to_product_name {
  my $name = lc shift or error_exit("vacuous name");
  $name =~ s&[^a-z0-9]&_&g;
  return $name;
}

sub version_cmp($$) {
  # Use slower prototype method due to package scope issues for $a, $b;
  my ($vInfoA, $vInfoB) = map { parse_version_string($_); } @_;
  return
    ($vInfoA->{major} // 0) <=> ($vInfoB->{major} // 0) ||
      ($vInfoA->{minor} // 0) <=> ($vInfoB->{minor} // 0) ||
        ($vInfoA->{micro} // 0) <=> ($vInfoB->{micro} // 0) ||
          ($vInfoA->{extra_type} // 0) <=> ($vInfoB->{extra_type} // 0) ||
            ($vInfoA->{extra_text} // '') cmp ($vInfoB->{extra_text} // '') ||
              ($vInfoA->{extra_num} // 0) <=> ($vInfoB->{extra_num} // 0);
}

my $cqual_table =
  { e2 => ['gcc', 'g++', 'GNU', '4.7.1', '11', 'gfortran', 'GNU', '4.7.1'],
    e4 => ['gcc', 'g++', 'GNU', '4.8.1', '11', 'gfortran', 'GNU', '4.8.1'],
    e5 => ['gcc', 'g++', 'GNU', '4.8.2', '11', 'gfortran', 'GNU', '4.8.2'],
    e6 => ['gcc', 'g++', 'GNU', '4.9.1', '14', 'gfortran', 'GNU', '4.9.1'],
    e7 => ['gcc', 'g++', 'GNU', '4.9.2', '14', 'gfortran', 'GNU', '4.9.2'],
    e8 => ['gcc', 'g++', 'GNU', '5.2.0', '14', 'gfortran', 'GNU', '5.2.0'],
    e9 => ['gcc', 'g++', 'GNU', '4.9.3', '14', 'gfortran', 'GNU', '4.9.3'],
    e10 => ['gcc', 'g++', 'GNU', '4.9.3', '14', 'gfortran', 'GNU', '4.9.3'],
    e14 => ['gcc', 'g++', 'GNU', '6.3.0', '14', 'gfortran', 'GNU', '6.3.0'],
    e15 => ['gcc', 'g++', 'GNU', '6.4.0', '14', 'gfortran', 'GNU', '6.4.0'],
    e17 => ['gcc', 'g++', 'GNU', '7.3.0', '17', 'gfortran', 'GNU', '7.3.0'],
    e19 => ['gcc', 'g++', 'GNU', '8.2.0', '17', 'gfortran', 'GNU', '8.2.0'],
    e20 => ['gcc', 'g++', 'GNU', '9.3.0', '17', 'gfortran', 'GNU', '9.3.0'],
    e21 => ['gcc', 'g++', 'GNU', '10.1.0', '17', 'gfortran', 'GNU', '10.1.0'],
    c1 => ['clang', 'clang++', 'Clang', '5.0.0', '17', 'gfortran', 'GNU', '7.2.0'],
    c2 => ['clang', 'clang++', 'Clang', '5.0.1', '17', 'gfortran', 'GNU', '6.4.0'],
    c3 => ['clang', 'clang++', 'Clang', '5.0.1', '17', 'gfortran', 'GNU', '7.3.0'],
    c4 => ['clang', 'clang++', 'Clang', '6.0.0', '17', 'gfortran', 'GNU', '6.4.0'],
    c5 => ['clang', 'clang++', 'Clang', '6.0.1', '17', 'gfortran', 'GNU', '8.2.0'],
    # Technically c6 referred to LLVM/Clang 7.0.0rc3, but CMake can't
    # tell the difference.
    c6 => ['clang', 'clang++', 'Clang', '7.0.0', '17', 'gfortran', 'GNU', '8.2.0'],
    c7 => ['clang', 'clang++', 'Clang', '7.0.0', '17', 'gfortran', 'GNU', '8.2.0'],
    c8 => ['clang', 'clang++', 'Clang', '10.0.0', '20', 'gfortran', 'GNU', '10.1.0']
  };

sub cmake_project_var_for_pathspec {
  my ($pi, $dirkey) = @_;
  my $pathspec = get_pathspec($pi, $dirkey);
  return () unless ($pathspec and $pathspec->{key});
  my $var_stem = $pathspec->{var_stem} || var_stem_for_dirkey($dirkey);
  $pathspec->{var_stem} = $var_stem;
  return ("-D$pi->{cmake_project}_${var_stem}_INIT=")
    unless exists $pathspec->{path};
  my @result_elements = ();
  if (ref $pathspec->{key}) {   # PATH-like.
    foreach my $pskey (@{$pathspec->{key}}) {
      error_exit("unrecognized pathkey $pskey for $dirkey")
        unless pathkey_is_valid($pskey);
      my $path = shift @{$pathspec->{path}};
      if ($pskey eq '-') {
        last unless $path;
        error_exit("non-empty path $path must be absolute",
                   "with pathkey \`$pskey' for directory key $dirkey")
          unless $path =~ m&^/&;
      } elsif ($pskey eq 'fq_dir' and
               $pi->{fq_dir} and
               not $path =~ m&^/&) {
        # Prepend EXEC_PREFIX here to avoid confusion with defaults in CMake.
        $path = File::Spec->catfile($pi->{fq_dir}, $path);
      } elsif ($path =~ m&^/&o) {
        warning("redundant pathkey $pskey ignored for absolute path $path",
                "specified for directory key $dirkey: use '-' as a placeholder.");
      }
      push @result_elements, $path;
    }
    $pathspec->{fq_path} = [ @result_elements ];
  } else {
    # Single non-elided value.
    push @result_elements, $pathspec->{path};
  }
  return (scalar @result_elements ne 1 or $result_elements[0]) ?
    sprintf("-D$pi->{cmake_project}_${var_stem}_INIT=%s",
            join(';', @result_elements)) : undef;
}

sub get_cmake_project_info {
  my ($pkgtop, %options) = @_;
  my $cmakelists = File::Spec->catfile($pkgtop, "CMakeLists.txt");
  open(CML, "<", "$cmakelists") or error_exit("missing CMakeLists.txt from ${pkgtop}");
  my $filedata = join('',<CML>);
  my ($prod, $ver) =
    $filedata =~ m&^\s*(?:(?i)project)\s*\(\s*([^\s)]+)(?:.*\s+VERSION\s+"?(\S+)"?)?&ms;
  error_exit("unable to find suitable CMake project() declaration in $cmakelists")
    unless $prod;
  $ver or $options{quiet_warnings} or
    warning("unable to extract version information from project call for $prod");
  return ($prod, ${ver} || undef);
}

sub ups_to_cmake {
  my ($pi) = @_;
  $pi->{cmake_project} and
    $pi->{name} and
      $pi->{cmake_project} ne
        $pi->{name} and
          warning("UPS product name is $pi->{name}.",
                  "CMake project name is $pi->{cmake_project}.",
                  "CMake variable names will be based on CMake project name.");

  (not $pi->{cqual}) or
    (exists $cqual_table->{$pi->{cqual}} and
     my ($cc, $cxx, $compiler_id, $compiler_version, $cxx_standard, $fc, $fc_id, $fc_version) =
     @{$cqual_table->{$pi->{cqual}}} or
     error_exit("unrecognized compiler qualifier $pi->{cqual}"));

  my @cmake_args=();

  ##################
  # UPS-specific CMake configuration.

  push @cmake_args, '-DWANT_UPS:BOOL=ON';
  push @cmake_args,
    "-DUPS_C_COMPILER_ID:STRING=$compiler_id",
      "-DUPS_C_COMPILER_VERSION:STRING=$compiler_version",
        "-DUPS_CXX_COMPILER_ID:STRING=$compiler_id",
          "-DUPS_CXX_COMPILER_VERSION:STRING=$compiler_version",
            "-DUPS_Fortran_COMPILER_ID:STRING=$fc_id",
              "-DUPS_Fortran_COMPILER_VERSION:STRING=$fc_version"
                if $compiler_id;
  push @cmake_args, sprintf('-D%s_UPS_PRODUCT_NAME:STRING=%s',
                            $pi->{cmake_project},
                            $pi->{name}) if $pi->{name};
  push @cmake_args, sprintf('-D%s_UPS_PRODUCT_VERSION:STRING=%s',
                            $pi->{cmake_project},
                            $pi->{version}) if $pi->{version};
  push @cmake_args, sprintf('-D%s_UPS_QUALIFIER_STRING:STRING=%s',
                            $pi->{cmake_project},
                            $pi->{qualspec}) if $pi->{qualspec};
  push @cmake_args, sprintf('-DUPS_%s_CMAKE_PROJECT_NAME:STRING=%s',
                            $pi->{name}, $pi->{cmake_project});
  push @cmake_args, sprintf('-DUPS_%s_CMAKE_PROJECT_VERSION:STRING=%s',
                            $pi->{name}, $pi->{cmake_project_version});
  push @cmake_args, sprintf('-D%s_UPS_PRODUCT_FLAVOR:STRING=%s',
                            $pi->{cmake_project},
                            $pi->{flavor});
  push @cmake_args, sprintf('-D%s_UPS_BUILD_ONLY_DEPENDENCIES=%s',
                            $pi->{cmake_project},
                            join(';', @{$pi->{build_only_deps}}))
    if $pi->{build_only_deps};
  push @cmake_args, sprintf('-D%s_UPS_USE_TIME_DEPENDENCIES=%s',
                            $pi->{cmake_project},
                            join(';', @{$pi->{use_time_deps}}))
    if $pi->{use_time_deps};

  push @cmake_args, sprintf('-D%s_UPS_PRODUCT_CHAINS=%s',
                            $pi->{cmake_project},
                            join(';', (sort @{$pi->{chains}})))
    if $pi->{chains};

  ##################
  # General CMake configuration.
  push @cmake_args, "-DCMAKE_BUILD_TYPE:STRING=$pi->{cmake_build_type}"
    if $pi->{cmake_build_type};
  push @cmake_args,
    "-DCMAKE_C_COMPILER:STRING=$cc",
      "-DCMAKE_CXX_COMPILER:STRING=$cxx",
        "-DCMAKE_Fortran_COMPILER:STRING=$fc",
          "-DCMAKE_CXX_STANDARD:STRING=$cxx_standard",
            "-DCMAKE_CXX_STANDARD_REQUIRED:BOOL=ON",
              "-DCMAKE_CXX_EXTENSIONS:BOOL=OFF"
                if $compiler_id;
  push @cmake_args, sprintf('-D%s_EXEC_PREFIX_INIT:STRING=%s',
                            $pi->{cmake_project},
                            $pi->{fq_dir}) if $pi->{fq_dir};
  push @cmake_args, sprintf('-D%s_NOARCH:BOOL=ON',
                            $pi->{cmake_project}) if $pi->{noarch};
  push @cmake_args,
    sprintf("-D$pi->{cmake_project}_DEFINE_PYTHONPATH_INIT:BOOL=ON")
      if $pi->{define_pythonpath};

  ##################
  # Pathspec-related CMake configuration.

  push @cmake_args,
    (map { cmake_project_var_for_pathspec($pi, $_) || ();
         } keys %{$pathspec_info});

  my @arch_pathspecs = ();
  my @noarch_pathspecs = ();
  foreach my $pathspec (values %{$pi->{pathspec_cache}}) {
    if ($pathspec->{var_stem} and
        not ref $pathspec->{path} and
        $pathspec->{key} ne '-') {
      push @{$pathspec->{key} eq 'fq_dir' ?
               \@arch_pathspecs : \@noarch_pathspecs},
                 $pathspec->{var_stem};
    }
  }
  push @cmake_args,
    sprintf('-D%s_ADD_ARCH_DIRS:STRING=%s',
            $pi->{cmake_project}, join(';', @arch_pathspecs))
      if scalar @arch_pathspecs;
  push @cmake_args,
    sprintf('-D%s_ADD_NOARCH_DIRS:STRING=%s',
            $pi->{cmake_project}, join(';', @noarch_pathspecs))
      if scalar @noarch_pathspecs;

  ##################
  # Done.
  return \@cmake_args;
}

sub print_dep_setup {
  my ($deps, $out) = @_;

  my ($setup_cmds, $only_for_build_cmds);

  # Temporary variable connected as a filehandle.
  open(my $setup_cmds_fh, ">", \$setup_cmds) or
    die "could not open memory stream to variable \$setup_cmds";

  # Second temporary variable connected as a filehandle.
  open(my $only_cmds_fh, ">", \$only_for_build_cmds) or
    die "could not open memory stream to variable \$only_for_build_cmds";

  my $onlyForBuild="";
  foreach my $dep (keys %$deps) {
    my $dep_info = $deps->{$dep};
    my $fh;
    if ($dep_info->{only_for_build}) {
      next if $dep eq "cetmodules"; # Dealt with elsewhere.
      $fh = $only_cmds_fh;
    } else {
      $fh = $setup_cmds_fh;
    }
    print_dep_setup_one($dep, $dep_info, $fh);
  }
  close($setup_cmds_fh);
  close($only_cmds_fh);

  print $out <<'EOF';
# Add '-B' to UPS_OVERRIDE for safety.
tnotnull UPS_OVERRIDE || setenv UPS_OVERRIDE ''
expr "x $UPS_OVERRIDE" : '.* -[^- 	]*B' >/dev/null || setenv UPS_OVERRIDE "$UPS_OVERRIDE -B"
EOF

  # Build-time dependencies first.
  print $out <<'EOF', $only_for_build_cmds if $only_for_build_cmds;

####################################
# Build-time dependencies.
####################################
EOF

  # Now use-time dependencies.
  if ( $setup_cmds ) {
    print $out <<'EOF', $setup_cmds if $setup_cmds;

####################################
# Use-time dependencies.
####################################
EOF
  }
}

sub print_dep_setup_one {
  my ($dep, $dep_info, $out) = @_;
  my $ql =
    sprintf(" -q +\%s",
            join(":+", split(':', $dep_info-> {qualspec} || '')));
  my $thisver =
    (not $dep_info->{version} or $dep_info->{version} eq "-") ? "" :
      $dep_info->{version};
  print $out "# > $dep <\n";
  if ($dep_info->{optional}) {
    print $out <<"EOF";
# Setup of $dep is optional.
ups exist $dep $thisver$ql
test "\$?" != 0 && \\
  echo \QINFO: skipping missing optional product $dep $thisver$ql\E || \\
EOF
    print $out "  ";
  }
  print $out "setup -B $dep $thisver$ql; ";
  setup_err($out, "setup -B $dep $thisver$ql failed");
}

sub setup_err {
  my $out = shift;
  print $out 'test "$?" != 0 && \\', "\n";
  foreach my $msg_line (@_) {
    chomp $msg_line;
    print $out "  echo \QERROR: $msg_line\E && \\\n";
  }
  print $out "  return 1 || true\n";
}

sub fq_path_for {
  my ($pi, $dirkey, $default) = @_;
  my $pathspec = get_pathspec($pi, $dirkey) ||
    { key => '-', path => $default };
  my $fq_path = $pathspec->{fq_path} || undef;
  unless ($fq_path or ($pathspec->{key} eq '-' and not $pathspec->{path})) {
    my $want_fq = $pi->{fq_dir} and
      ($pathspec->{key} eq 'fq_dir' or
       ($pathspec->{key} eq '-' and grep { $_ eq $dirkey } qw(bindir libdir)));
    $fq_path =
      File::Spec->catfile($want_fq ? $pi->{fq_dir} : (),
              $pathspec->{path} || $default || ());
  }
  return $fq_path;
}

sub print_dev_setup_var {
  my ($var, $val, $no_errclause) = @_;
  my @vals;
  if (ref $val eq 'ARRAY') {
    @vals=@$val;
  } else {
    @vals=($val);
  }
  my $result;
  open(my $out, ">", \$result) or
    die "could not open memory stream to variable \$out";
  print $out "# $var\n",
    "setenv $var ", '"`dropit -p \\"${', "$var", '}\\" -sfe ';
  print $out join(" ", map { sprintf('\\"%s\\"', $_); } @vals), '`"';
  if ($no_errclause) {
    print $out "\n";
  } else {
    print $out "; ";
    setup_err($out, "failure to prepend to $var");
  }
  close($out);
  return $result;
}

sub print_dev_setup {
  my ($pi, $out) = @_;
  my $fqdir;
  print $out <<"EOF";

####################################
# Development environment.
####################################
EOF
  my $libdir = fq_path_for($pi, 'libdir', 'lib');
  if ($libdir) {
    # (DY)LD_LIBRARY_PATH.
    print $out
      print_dev_setup_var(sprintf("%sLD_LIBRARY_PATH",
                                  ($pi->{flavor} =~ m&\bDarwin\b&) ? "DY" : ""),
                          File::Spec->catfile('${CETPKG_BUILD}', $libdir));
    # CET_PLUGIN_PATH. We only want to add to this if it's already set
    # or we're cetlib, which is the package that makes use of it.
    my ($head, @output) =
      split("\n",
            print_dev_setup_var("CET_PLUGIN_PATH",
                                File::Spec->catfile('${CETPKG_BUILD}',
                                                    $libdir)));
    print $out "$head\n",
      ($pi->{name} ne 'cetlib') ?
        "test -z \"\${CET_PLUGIN_PATH}\" || \\\n  " : '',
          join("\n", @output), "\n";
  }
  # ROOT_INCLUDE_PATH.
  print $out
    print_dev_setup_var("ROOT_INCLUDE_PATH",
                        [ qw(${CETPKG_SOURCE} ${CETPKG_BUILD}) ]);
  # CMAKE_PREFIX_PATH.
  print $out
    print_dev_setup_var("CMAKE_PREFIX_PATH", '${CETPKG_BUILD}', 1);
  # FHICL_FILE_PATH.
  $fqdir = fq_path_for($pi, 'fcldir') and
    print $out
      print_dev_setup_var("FHICL_FILE_PATH",
                          File::Spec->catfile('${CETPKG_BUILD}', $fqdir));
  # PYTHONPATH.
  if ($pi->{define_pythonpath}) {
    print $out
      print_dev_setup_var("PYTHONPATH",
                          File::Spec->catfile('${CETPKG_BUILD}',
                                              $libdir ||
                                              ($pi->{fq_dir} || (), 'lib')));

  }
  # PATH.
  $fqdir = fq_path_for($pi, 'bindir', 'bin') and
    print $out
      print_dev_setup_var("PATH",
                          [ File::Spec->catfile('${CETPKG_BUILD}', $fqdir),
                            File::Spec->catfile('${CETPKG_SOURCE}', $fqdir) ]);
}

sub table_dep_setup {
  my ($dep, $dep_info, $fh) = @_;
  printf $fh
    "setup%s(%s %s -q+%s)\n",
      $dep_info->{optional} ? "Optional" : "Required",
        $dep,
          $dep_info->{version},
            join(":+", split(':', $dep_info->{qualspec} || ''));
}

sub var_stem_for_dirkey {
  my $dirkey = shift;
  return uc($pathspec_info->{$dirkey}->{project_var} ||
            (($dirkey =~ m&^(.*?)_*dir$&) ? "${1}_dir" :
             "${dirkey}_dir"));
}

sub write_table_deps {
  my ($parent, $deps) = @_;
  open(my $fh, ">", "table_deps_$parent") or return;
  foreach my $dep (sort keys %{$deps}) {
    my $dep_info = $deps->{$dep};
    table_dep_setup($dep, $dep_info, $fh)
      unless $dep_info->{only_for_build};
  }
  close($fh);
  1;
}

sub write_table_frag {
  my ($parent, $pfile) = @_;
  my $fraglines = get_table_fragment($pfile);
  return 1 unless $fraglines and scalar @$fraglines;
  open(my $fh, ">", "table_frag_$parent") or return;
  print $fh join("\n", @$fraglines), "\n";
  close($fh);
  1;
}

1;