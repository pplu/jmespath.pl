#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Slurp qw(slurp);
use Jmespath;
use JSON;
use String::Escape qw(unbackslash);
$ENV{JP_UNQUOTED} = 1;
use Try::Tiny;

my $cdir = dirname(__FILE__) . '/compliance';

opendir(my $dh, $cdir) || die "can't opendir $cdir: $!";
my @files;
if ($ARGV[0]) {
  @files = $ARGV[0];
} else {
  @files = grep { /json$/ && -f "$cdir/$_" } readdir($dh);
}
closedir $dh;
$ENV{JP_UNQUOTED} = 1;

foreach my $file ( @files ) {
  next if $file eq 'benchmarks.json';
  my $json_data = slurp("$cdir/$file");
  my $perl_data = JSON->new->decode($json_data);
  my @parts = split /\./, $file;
  my $n = $parts[0];
  my $cn = 1;
  foreach my $block ( @$perl_data ) {
    my $text = JSON->new->allow_nonref->space_after->encode($block->{ given });
    foreach my $case ( @{ $block->{cases} } ) {
      my $comment = exists $case->{comment} ? $case->{ comment } : $case->{ expression };
      my $deeply = exists $case->{is_deeply} ? $case->{is_deeply} : 0;
      my $msg = $n . ' case ' . $cn . ' : ' . $comment;

      my $expr   = sq(JSON->new->allow_nonref->space_after->encode($case->{expression}));
#      print "$expr\n";
      $expr = unbackslash($expr);
#      print "$expr\n";
      my $expect = sq(JSON->new->allow_nonref->space_after->encode($case->{result}));
      my $r;
      if (exists $case->{error}) {
        try {
          my $r = Jmespath->search($expr, $text);
          fail('Expected exception');
        } catch {
          isa_ok $_, 'Jmespath::ValueException', $comment;
        };
      }
      else {
        try {
          my $r = Jmespath->search($expr, $text);
          if ($deeply) {
            $expect = $case->{result};
            $r = JSON->new->allow_nonref->space_after->decode($r);
            is_deeply $r, $expect, $msg;
          }
          else {
            is $r, $expect, $msg;
          }
        } catch {
           fail($comment . ' : ' . 'EXCEPTION MESSAGE: ' . $_->message )
        };
      }
      $cn++;
    }
  }
}


sub sq {
  my $string = shift;
  $string =~ s/^"|"$//g;
  return $string;
}

sub load_json {
}

sub test {
}

done_testing();
