package Jmespath::TreeInterpreter;
use parent 'Jmespath::Visitor';
use strict;
use warnings;
use Try::Tiny;
use List::Util qw(unpairs);
use Scalar::Util qw(looks_like_number);
use JSON;
no strict 'refs'; # Need this for sub dereferencing
use Jmespath::Expression;
use Jmespath::Functions;
use Jmespath::AttributeException;
use Jmespath::IndexException;
use Jmespath::UnknownFunctionException;


my $COMPARATOR_FUNC = { 'le' => 'le',
                        'ne' => 'ne',
                        'lt' => 'lt',
                        'lte' => 'lte',
                        'eq' => 'eq',
                        'gt' => 'gt',
                        'gte' => 'gte' };

my $MAP_TYPE = 'HASH';

my $OPTIONS_DEFAULT = { hash_cls => undef,
                        custom_functions => undef };

sub new {
  my ($class, $options) = @_;
  my $self = $class->SUPER::new($options);
  if ( not defined $options) { $options = $OPTIONS_DEFAULT; }
  $self->{_hash_cls} = $options->{ hash_cls }
    if defined $options->{hash_cls};
  $self->{_functions} = eval { 'use ' . $options->{custom_functions} }
    if defined $options->{custom_functions};

  return $self;
}

sub visit {
  my ($self, $node, $args) = @_;
  my $node_type = $node->{type};
  try {
    my $method = 'visit_' . $node->{type};
    return &$method( $self, $node, $args );
  } catch {
    $_->throw;
  }
}

sub default_visit {
  my ($self, $node, @args) = @_;
  return Jmespath::NotImplementedException($node->{type});
}

sub visit_subexpression {
  my ($self, $node, $value) = @_;
  my $result = $value;
  foreach my $node (@{$node->{children}}) {
    $result = $self->visit($node, $result);
  }
  return $result;
}

sub visit_field {
  my ($self, $node, $value) = @_;
  try {
    return $value->{$node->{value}};
  } catch {
    Jmespath::AttributeException->new->throw;
  };
}

sub visit_comparator {
  my ($self, $node, $value) = @_;

  my $comparator_func = 'jp_' . $node->{value};
  if ( not defined &$comparator_func ) {
    Jmespath::UnknownFunctionException
        ->new({ message => 'unknown-function: Unknown function: ' . $comparator_func })
        ->throw;
  }

  return &$comparator_func( $self->visit( @{$node->{children}}[0], $value ),
                            $self->visit( @{$node->{children}}[1], $value ) );
}

sub visit_current {
  my ( $self, $node, $value ) = @_;
  return $value;
}

sub visit_expref {
  my ( $self, $node, $value ) = @_;
  return Jmespath::Expression->new($node->{children}[0], $self);
}

sub visit_function_expression {
  my ($self, $node, $value) = @_;
  my $function = 'jp_' . $node->{value};
  if ( not exists &$function ) {
    Jmespath::UnknownFunctionException
        ->new({ message => 'unknown-function: Unknown function: ' . $function })
        ->throw;
  }

  my $resolved_args = [];
  foreach my $child ( @{$node->{ children}} ) {
    my $current = $self->visit($child, $value);
    push  @{$resolved_args}, $current;
  }

  return &$function(@$resolved_args);
}

sub visit_filter_projection {
  my ($self, $node, $value) = @_;
  my $base = $self->visit( @{$node->{children}}[0], $value);
  return undef if ref($base) ne 'ARRAY';
  return 'null' if scalar @$base == 0;
  my $comparator_node = @{ $node->{children} }[2];

  my $collected = [];
  foreach my $element (@$base) {
    if ( $self->_is_true($self->visit($comparator_node, $element))) {
      my $current = $self->visit(@{$node->{children}}[1], $element);
      if (defined $current) {
        push  @{$collected}, $current;
      }
    }
  }
  return $collected;
}

sub visit_flatten {
  my ($self, $node, $value) = @_;
  my $base = $self->visit(@{$node->{'children'}}[0], $value);

  return undef if ref($base) ne 'ARRAY';
  my $merged_list = [];
  foreach my $element (@$base) {
    if (ref($element) eq 'ARRAY') {
      push  @$merged_list, @$element;
    }
    else {
      push @$merged_list, $element;
    }
  }
  return $merged_list;
}

sub visit_identity {
  my ($self, $node, $value) = @_;
  return undef if not defined $value;
  # SHEER NEGATIVE ENERGY HACKERY - FORCE NUMBERS TO BE NUMBERS
  # THANK YOU JSON.PM
  $value = 1 * $value if $value =~ /^[0-9]+$/;
  return $value;
}

sub visit_index {
  my ($self, $node, $value) = @_;
  return undef if ref($value) ne 'ARRAY';
  try {
    return $value->[ $node->{value} ];
  } catch {
    Jmespath::IndexException->new({ message => 'Invalid index' })->throw;
  };
}

sub visit_index_expression {
  my ($self, $node, $value) = @_;
  my $result = $value;
  foreach my $node (@{$node->{children}}) {
    $result = $self->visit($node, $result);
  }
  return $result;
}

sub visit_slice {
  my ($self, $node, $value) = @_;
  return undef if ref($value) ne 'ARRAY';
  # slice defaults
  my $start = defined $node->{children}->[0] ? $node->{children}->[0] : 0;
  my $end = defined $node->{children}->[1] ? $node->{children}->[1] : scalar @$value;
  my $step = defined $node->{children}->[2] ? $node->{children}->[2] : 1;
  $start  = scalar(@$value) + $start if $start < 0;
  $end    = scalar(@$value) + $end   if $end   < 0;
  @$value = reverse @$value          if $step  < 0;
  $step   = abs $step;

  my @selected;
  for ( my $idx = $start; $idx < $end; $idx += $step ) {
    my $val =  @{$value}[$idx];
    push @selected, $val;
  }
  return \@selected;
}

sub visit_key_val_pair {
  my ($self, $node, $value) = @_;
  return $self->visit(@{$node->{children}}[0], $value);
}

sub visit_literal {
  my ($self, $node, $value) = @_;
  return $node->{value};
}

# XXX Change sub suffix to 'hash'
sub visit_multi_select_hash {
  my ($self, $node, $value) = @_;
  return undef if not defined $value;
  # XXX We should change this to use _hash_cls which enables the user
  # to choose the data structure method
  my %merged;
  foreach my $child (@{$node->{children}}) {
    my $result = $self->visit($child, $value);
    return undef if not defined $child->{value};
    return undef if not defined $result;
    %merged = (%merged,(  $child->{value} , $result ));
  }
  return \%merged;
}

sub visit_multi_select_list {
  my ($self, $node, $value) = @_;
  return undef if not defined $value;
  return 'null' if scalar @{$node->{children}} == 0;
  my $collected = [];
  foreach my $child ( @{$node->{children}}) {
    my $result = $self->visit($child, $value);
    next if not defined $result;
    push @$collected, $self->visit($child, $value);
  }
  return $collected;
}

sub visit_or_expression {
  my ($self, $node, $value) = @_;
  my $matched = $self->visit( @{$node->{children}}[0], $value );
  if ( $self->_is_false($matched)) {
    $matched = $self->visit(@{$node->{children}}[1], $value);
  }
  return $matched;
}

sub visit_and_expression {
  my ($self, $node, $value) = @_;
  my $matched = $self->visit(@{$node->{children}}[0], $value);
  # return if the left side eval is found to be false
  return $matched if $self->_is_false($matched);
  # if this isn't true then the whole evaluation is false
  $matched = $self->visit(@{$node->{children}}[1], $value);
  return $matched;
}

sub visit_not_expression {
  my ($self, $node, $value) = @_;
  my $original_result = $self->visit(@{$node->{children}}[0], $value);
  my $result = $self->_is_true($original_result);
  $result = $result == 0 ? 1 : 0;

  return 'true' if $result == 1;
  return 'false';
}

sub visit_pipe {
  my ($self, $node, $value) = @_;
  my $result = $value;
  foreach my $node ( @{$node->{children}}) {
    $result = $self->visit($node, $result);
  }
  return $result;
}

sub visit_projection {
  my ($self, $node, $value) = @_;
  my $base = $self->visit(@{$node->{children}}[0], $value);
  return undef if ref($base) ne 'ARRAY';
  return 'null' if scalar @$base == 0;

  my $collected = [];
  foreach my $element (@$base) {
    my $current = $self->visit(@{$node->{children}}[1], $element);
    push (@$collected, $current) if defined $current;
  }
  return $collected;
}

sub visit_value_projection {
  my ($self, $node, $value) = @_;
  my $base = $self->visit(@{$node->{children}}[0], $value);
  my @basekeys;
  try {
    @basekeys = map { $_ => $base->{ $_ } } sort keys %$base ;
  } catch {
    Jmespath::AttributeException->new->throw;
  };

  return 'null' if scalar @basekeys == 0;
  my $collected = [];
  foreach my $element (@basekeys) {
    my $current = $self->visit(@{$node->{children}}[1], $element);
    push( @$collected, $current ) if defined $current;
  }
  return $collected;
}

sub _is_false {
  my ($self, $value) = @_;
  return 1 if not defined $value;
#  return 1 if looks_like_number($value) and $value == 0;
  return 1 if $value eq 'false';
  return 0 if $value eq 'true';
  return 1 if $value eq '';
  return 1 if JSON::is_bool($value) and $value == 0;
  return 0 if JSON::is_bool($value) and $value == 1;
  return 1 if ( ref($value) eq 'SCALAR' and not $value );
  return 1 if ( ref($value) eq 'SCALAR' and $value eq '' );
  return 1 if ( ref($value) eq 'ARRAY'  and scalar @$value == 0 );
  return 1 if ( ref($value) eq 'HASH'   and scalar keys %$value == 0 );
  return 0;
}

sub _is_true {
  return ! shift->_is_false(shift);
}

1;
