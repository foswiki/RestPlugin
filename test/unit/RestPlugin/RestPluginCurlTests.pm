package RestPluginCurlTests;
use FoswikiFnTestCase;
our @ISA = qw( FoswikiFnTestCase );
use strict;

use Foswiki ();
use Foswiki::Func();
use Foswiki::Meta      ();
use Foswiki::Serialise ();
use JSON               ();

sub new {
    my $self = shift()->SUPER::new(@_);
    return $self;
}

sub list_tests {
    my ( $this, $suite ) = @_;
    my @set = $this->SUPER::list_tests($suite);

    my $curlError = `curl 2>&1`;
    if (
        not( $curlError =~
            /curl: try 'curl --help' or 'curl --manual' for more information/ )
      )
    {
        print STDERR
          "curl not installed and in path, skipping curl based tests\n";
        return;
    }
    return @set;
}

sub set_up {
    my $this = shift;
    $this->SUPER::set_up();

    my $meta =
      Foswiki::Meta->new( $this->{session}, $this->{test_web}, "Improvement2" );
    $meta->putKeyed(
        'FIELD',
        {
            name  => 'Summary',
            title => 'Summary',
            value => 'Its not broken, but its really painful to use'
        }
    );
    $meta->putKeyed(
        'FIELD',
        {
            name  => 'Details',
            title => 'Details',
            value => 'work it out yourself!'
        }
    );
    Foswiki::Func::saveTopic(
        $this->{test_web}, "Improvement2", $meta, "
typically, a spade made with a thorny handle is functional, but not ideal.
"
    );
}

sub callCurl {
    my $self               = shift;
    my $httpRequest        = shift;
    my $requestContentType = shift;
    my $requestContent     = shift;
    my $url                = shift;

#curl -X PATCH -H "Content-Type:text/json" -d '{"_text": "set the topic text to something new again"}' http://x61/f/bin/query/Main/SvenDowideit/topic.json
#curl -X PATCH -H "Content-Type:text/json" -d '{"_text": "set the topic text to something new again"}' http://x61/f/bin/query/Main/SvenDowideit/topic.json
    my $curlCommand =
        'curl -s --trace-time -v -X '
      . $httpRequest
      . ' -H "Content-Type:'
      . $requestContentType
      . '" -d \''
      . $requestContent . '\' '
      . $url;
    my $result = `$curlCommand 2>&1`
      ;    # grrrr, aparently they output the header info into stderr

    #now separate into headers and content.
    #14:48:54.853392 * Connected to x61 (127.0.1.1) port 80 (#0)
    #14:48:54.853517 > GET

    my $data = { '*' => '', '>' => '', '<' => '', '{' => '' };
    $result =~
s/(\d\d:\d\d:\d\d\.\d\d\d\d\d\d) ([<*>{]) (.*)(\r\n)/addToResultHash($1, $2, $3, $data)/gem;

#argh. \r?\n isn't working for me, so i'll just run the regex twice until i get enough sleep to have a clue.
    $result =~
s/(\d\d:\d\d:\d\d\.\d\d\d\d\d\d) ([<*>{]) (.*)(\n)/addToResultHash($1, $2, $3, $data)/gem;

    #print STDERR "\n================\n$result\n==========\n";

#print STDERR join("\n-----------------\n", ($result, $data->{'*'}, $data->{'>'}, $data->{'<'}));

    return ( $result, $data );
}

sub addToResultHash {
    my ( $timestamp, $type, $text, $hash ) = @_;

    $hash->{$type} .= "$timestamp $type $text\n";
    if ( $type eq '<' ) {    #response header
                             #HTTP/1.1 200 OK
        if ( $text =~ /HTTP\/1.1\s(\d*)\s(.*)/ ) {
            $hash->{HTTP_RESPONSE_STATUS}      = $1;
            $hash->{HTTP_RESPONSE_STATUS_TEXT} = $2;
        }

        #X-Foswiki-Rest-Query: 'Main.SvenDowideit'/topic etc
        if ( $text =~ /(.*):\s*(.*)/ ) {
            $hash->{$1} = $2;
        }
    }

    return '';
}

sub testGET {
    my $this = shift;

    {

        #/Main/WebHome/topic.json
        my ( $replytext, $extraHash ) = $this->callCurl( 'GET', 'text/json', '',
            Foswiki::Func::getScriptUrl( undef, undef, 'query' )
              . '/Main/WebHome/topic.json' );

        #print STDERR $replytext;
        my $fromJSON = JSON::from_json( $replytext, { allow_nonref => 1 } );
        my ( $meta, $text ) = Foswiki::Func::readTopic( 'Main', 'WebHome' );
        $this->assert_deep_equals( $fromJSON,
            Foswiki::Serialise::convertMeta($meta) );
        $this->assert_equals( '200', $extraHash->{HTTP_RESPONSE_STATUS} );
        $this->assert_equals( 'OK',  $extraHash->{HTTP_RESPONSE_STATUS_TEXT} );
        $this->assert_equals( "'Main.WebHome'/topic",
            $extraHash->{'X-Foswiki-Rest-Query'} );

        #TODO: test the other values we're returning
    }

    {

        #/Main/TopicDoesNotTexit/topic.json
        my ( $replytext, $extraHash ) = $this->callCurl( 'GET', 'text/json', '',
            Foswiki::Func::getScriptUrl( undef, undef, 'query' )
              . '/Main/TopicDoesNotTexit/topic.json' );

        #no payload
        #        $this->assert_deep_equals( $fromJSON,
        #            Foswiki::Serialise::convertMeta($meta) );
        $this->assert_equals( '404', $extraHash->{HTTP_RESPONSE_STATUS} );
        $this->assert_equals( 'Not Found',
            $extraHash->{HTTP_RESPONSE_STATUS_TEXT} );
        $this->assert_equals(
            undef,

            #"'Main.TopicDoesNotTexit'/topic",
            $extraHash->{'X-Foswiki-Rest-Query'}
        );

        #TODO: test the other values we're returning
    }

}

sub testPATCH {
    my $this = shift;

   #THIS MUST FAIL, guest should never have the ability to change System.WebHome
   #/System/WebHome/topic.json
    $this->runTest(
        'PATCH',
        'text/json',
        '{"_text": "Some text"}',
        'System', 'WebHome', 'topic',
        'json',
        {
            HTTP_RESPONSE_STATUS      => '401',
            HTTP_RESPONSE_STATUS_TEXT => 'Authorization Required',
            'X-Foswiki-Rest-Query'    => undef,
        }
    );
    
    $this->runTest(
        'PATCH',
        'text/json',
        '{"_text": "Some text"}',
        'Sandbox', 'TestTopicAUTOINC001', 'topic',
        'json',
        {
            HTTP_RESPONSE_STATUS      => '404',
            HTTP_RESPONSE_STATUS_TEXT => 'Not Found',
            'X-Foswiki-Rest-Query'    => undef,
        }
    );
    #$this->{test_web}, "Improvement2"
#ER POOP. the test web is created with the wrong filesystem user, so can't be accessed by the web server (in some setups.)
    $this->runTest(
        'PATCH',
        'text/json',
        '{"_text": "Some text"}',
        $this->{test_web},'Improvement2','topic',
        'json',
        {
            HTTP_RESPONSE_STATUS      => '500',
#            HTTP_RESPONSE_STATUS_TEXT => 'OK',
#            'X-Foswiki-Rest-Query'    => '\''.$this->{test_web}.'.Improvement2\'/topic',
        }
    );
#TODO: {rest_test_web}  needs to be created using curl - so that the webserver permissions are useable.
return;
    #COPY 
    #$this->{rest_test_web}, "Improvement2"
    $this->runTest(
        'PATCH',
        'text/json',
        '{"_topic": "ACopyOfImprovement2"}',
        $this->{rest_test_web},'Improvement2','topic',
        'json',
        {
            HTTP_RESPONSE_STATUS      => '200',
            HTTP_RESPONSE_STATUS_TEXT => 'OK',
            'X-Foswiki-Rest-Query'    => '\''.$this->{rest_test_web}.'.ACopyOfImprovement2\'/topic',
        }
    );
}

sub runTest {
    my ( $this, $OP, $sendType, $sendPayload, $web, $topic, $element, $receiveType,
        $expectedHash, $expectedReplyPayload )
      = @_;
      
      my $query = '/'.$web.'/'.$topic.'/'.$element;

    my ( $replytext, $extraHash ) = $this->callCurl(
        $OP,
        $sendType,
        $sendPayload,
        Foswiki::Func::getScriptUrl( undef, undef, 'query' ) 
          . $query . '.'
          . $receiveType
    );

    foreach my $key ( keys(%$expectedHash) ) {

        #if scalar..
        $this->assert_equals( $expectedHash->{$key}, $extraHash->{$key} );
    }

      $this->assert_equals('topic', $element, 'only topic element implemented below');
      $this->assert_equals('json', $receiveType, 'only JSON implemented below');
    #TODO: this presumes that $element == topic
    if (defined($expectedReplyPayload)) {
       #print STDERR $replytext;
       my $replyObj = JSON::from_json( $replytext, { allow_nonref => 1 } );
       my $expectedObj = JSON::from_json( $expectedReplyPayload, { allow_nonref => 1 } );
       $this->assert_deep_equals( $expectedObj, $replyObj );
       #TODO: can also compare to the meta obj we get??
       #my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
       #$this->assert_deep_equals( convertMETA($meta), $replyObj );
    }

}

1;
