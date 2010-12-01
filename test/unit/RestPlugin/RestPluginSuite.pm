package RestPluginSuite;
use Unit::TestSuite;
our @ISA = qw( Unit::TestSuite );

sub include_tests {
    qw( RestPluginTests );
}

1;

