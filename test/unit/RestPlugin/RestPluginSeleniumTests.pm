use strict;
use warnings;

package RestPluginSeleniumTests;

use FoswikiSeleniumTestCase;
our @ISA = qw( FoswikiSeleniumTestCase );

use Foswiki::Func;

sub new {
    my $self = shift()->SUPER::new( 'RestPluginSelenium', @_ );
    return $self;
}

sub verify_SeleniumRc_config {
    my $this = shift;
    $this->selenium->open_ok(
        Foswiki::Func::getScriptUrl(
            $this->{test_web}, $this->{test_topic}, 'view'
        )
    );
    $this->login();
    print STDERR "---------(" . $this->selenium->get_body_text() . ")\n";

}

sub verify_SeleniumRc_ok_Main_WebHome_topic_perl {

    #fails as Selenium seem to presume html
    my $this = shift;
    eval {
        $this->selenium->open_ok(
            Foswiki::Func::getScriptUrl( 'Main', 'WebHome', 'query' )
              . '/topic.perl' );
    };
    print STDERR "---------(" . $this->selenium->get_body_text() . ")\n";

    #$this->assert_matches( "^\nopen, ", $@, "Expected an exception" );
}

sub verify_SeleniumRc_ok_Main_WebHome_topic_json {

    #fails as Selenium seem to presume html
    my $this = shift;
    eval {
        $this->selenium->open_ok(
            Foswiki::Func::getScriptUrl( 'Main', 'WebHome', 'query' )
              . '/topic.json' );
        sleep(30);
    };
    print STDERR "---------(" . $this->selenium->get_body_text() . ")\n";

    #$this->assert_matches( "^\nopen, ", $@, "Expected an exception" );
}

sub NONOverify_SeleniumRc_like_failure_reporting {
    my $this = shift;
    $this->selenium->open_ok(
        Foswiki::Func::getScriptUrl(
            $this->{test_web}, $this->{test_topic}, 'view'
        )
    );
    eval {
        $this->selenium->title_like(
qr/There is no way that this would ever find its way into the title of web page. That would be simply insane!/
        );
    };
    $this->assert_matches( "^\nget_title, ", $@, "Expected an exception" );
}

1;
