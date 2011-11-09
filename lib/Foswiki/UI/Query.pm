# See bottom of file for license and copyright information

=begin TML

---+ package Foswiki::UI::Query

provide a REST based CRUD API to foswiki objects using the Query language as the addressing scheme.

=cut

package Foswiki::UI::Query;

use strict;
use warnings;

use Assert;
use Foswiki            ();
use Foswiki::Serialise ();
use Foswiki::Query::Parser;
use Foswiki::Infix::Error  ();
use Foswiki::OopsException ();
use Foswiki::AccessControlException();
use Foswiki::Validation ();

use Time::HiRes ();
use REST::Utils qw( :all );
use Error qw( :try );

# Set to 1 for debug
use constant MONITOR_ALL => 0;

#map MIME type to serialiseFunctions
our %serialiseFunctions = (
    'text/json'        => 'json',
    'application/json' => 'json',
    'text/perl'        => 'perl',

    #'text/html' => 'Foswiki::Serialise::html',
    'text/plain' => 'raw',

    #'application/x-www-form-urlencoded' => ''
);

sub workoutSerialisation {
    my $query         = shift;
    my $url_mediatype = shift;

    #a URL specified mediatype will over-ride the request header one..
    if ( defined($url_mediatype) ) {
        $url_mediatype =~ s/^\.//;

#known shorcuts..
#TODO: EXTRACT and add registerable bits for plugins can add their own - ie, any one of the Pdf plugins can add a .pdf
        my %extensions = (
            json => 'text/json',
            perl => 'text/perl',
            html => "text/html",
            text => "text/plain"
        );
        $url_mediatype = $extensions{$url_mediatype};
        return $url_mediatype if ( defined($url_mediatype) );
    }

    my @supportedContentTypes = keys(%serialiseFunctions);

    #try out REST::Utils::media_type
    my $prefered = REST::Utils::media_type( $query, \@supportedContentTypes );
    $prefered = 'text/json'
      if ( not defined($prefered) or ( $prefered eq '' ) );

    ASSERT($prefered) if DEBUG;
    return $prefered;
}

sub mapMimeType {
    my $ContentType = shift;

    return $serialiseFunctions{$ContentType};
}

#WARNING: danger will-robinson - remember that the typical size limit on a payload is 2MB
#TODO: redo the payloads to be _just_ the item, and plonk everything else in the header.
#       that way we can do: curl -X PATCH -d "{fieldName: 'value to set to'}" http://x61/bin/query/Main/SvenDowideit/topic.json

#TODO: work out how to apply the contentType to EngineExceptions..

#don't reply to PUT/POST/PATCH with the changed item, send a 303 (assuming we're allowed to) so that we cna simplify the code..
#generalise into container and endpoint ops / elements
#implement a text/tml seiralisation that uses the http header  for all the non-topic info (same again with text/html
#js UI and class to interact with this - the UI creates a new html form foreach element - so we can then post/patch/whtever
#    add tunneling option etc
#    then use that for selenium... so i can test auth via apache/template and the different strikeone's .....

sub query {
    my ( $session, %initialContext ) = @_;

    my $req = $session->{request};
    my $res = $session->{response};
    my $err;

  #support tunneling of requests using X-HTTP-METHOD-OVERRIDE or ?_method=DELETE
    my $request_method = uc( REST::Utils::request_method($req) );

#REST::Utils doesn't seem to cope with the shenanigans we pull when running from UIFn unit tests / commandline.
    $request_method = uc( $req->method() )
      if ( not defined($request_method) or ( $request_method eq '' ) );

    #TODO: detect commandline use and set to GET / $ENV{FOSWIKI_ACTION}, or...
    $request_method = 'GET'
      if ( $request_method eq 'QUERY' )
      ;  #TODO: for some reason the cmdline method is returning the script name.
         #make sure we're doing a suported HTTP op
    unless ( $request_method =~ /(GET|OPTIONS|PUT|POST|PATCH|DELETE)/ ) {
        $res->header( -type => 'text/html', -status => '400' );
        $err =
"ERROR: (400) Invalid query invocation - unsupported HTTP method $request_method";
        $res->print($err);
        throw Foswiki::EngineException( 400, $err, $res );
    }

    authenticate($session)
      ; #actually, this does login if ?username is there, and then tests if the script needs auth.
    writeDebug( "after auth, running as "
          . Foswiki::Func::getWikiName( Foswiki::Func::getCanonicalUserID() )
          . "\n" )
      if MONITOR_ALL;

#delegate to POSTquery
#return POSTquery($session, %initialContext) if ($request_method eq 'POST');
#Rest and View have a pageCache->getPage, which could be extracted and reused for some GET ops.

    my $pathInfo = $req->path_info();

    #query requests have the form 'Query/element[.mediatype]'
    unless ( $pathInfo =~ m#^(.*)/([^./]*)(\..*)?$# ) {

        $res->header( -type => 'text/html', -status => '400' );
        $err = "ERROR: (400) Invalid query invocation - $pathInfo is malformed";
        $res->print($err);
        throw Foswiki::EngineException( 400, $err, $res );
    }
    my ( $query, $elementAlias, $url_mediatype ) = ( $1, $2, $3 );
    writeDebug("---- elementAlias: $elementAlias\n") if MONITOR_ALL;

    #find the best mediatype
    #a URL specified mediatype will over-ride the request header one..
    my $responseContentType = workoutSerialisation( $req, $url_mediatype );
    writeDebug( "---- responseContentType: $responseContentType (was "
          . ( $url_mediatype || 'undef' )
          . ")\n" )
      if MONITOR_ALL;

    #validate alias
    #TODO: there appear to me other 'aliases' defined in QueryAlgo::getField..
    unless ( ( $elementAlias =~ /^(webs|web|topic|text|name)$/ )
        or ( defined( $Foswiki::Meta::aliases{$elementAlias} ) ) )
    {
        $res->header( -type => 'text/html', -status => '400' );
        $err =
"ERROR: (400) Invalid query invocation - unsupported element requested: $elementAlias";
        $res->print($err);
        throw Foswiki::EngineException( 400, $err, $res );
    }

    #validate query
    #ensure we have the authorisation to do what we're requesting
    $session->logEvent( 'query', $query,
        "$elementAlias, $responseContentType" );

##############################
# begin with the presumption that all queries are the simplified 'http://server/query/System/WebHome/alias.ext' type..
    my ( $web, $topic, $attachment, $baseObjectExists );
    if ( $query =~ /^\/?(.*)\/(.*?)$/ ) {
        $web   = $1;
        $topic = $2;

        #TODO: nasty hack to stop webs/topics from starting with a /
        $web   =~ s/^\/*//;
        $topic =~ s/^\/*//;
        $query =~ s/^\/*//;

#TODO: actually, this parsing has to work diferently for POST, as the uri in POST's refer to the container (and so a cntextural on the elementAlias
        if ( $elementAlias eq 'webs' ) {

#base webs $query ~~ '', otherwise, if it is defined, then we're making a new subweb..
            $topic = undef;
            $web   = $query;
            $baseObjectExists =
              ( ( $web eq '' ) or Foswiki::Func::webExists($web) );

           #$elementAlias = ':topic_meta:';    # if ( $elementAlias eq 'webs' );
            $query = "'$web'/$elementAlias";
        }
        elsif ( $elementAlias eq 'topic' ) {

#I created a quick hack in the QueryAlgo::getField so that element ':topic_meta:' returned the meta object
#need to map topic==:topic_meta:
            my $webExists = Foswiki::Func::webExists($web);
            my $topicExists = Foswiki::Func::topicExists( $web, $topic );
            $baseObjectExists = ( $webExists and $topicExists );

            #$elementAlias = ':topic_meta:';# if ( $elementAlias eq 'topic' );
            $query = "'$web.$topic'/$elementAlias";

            if (   ( ( $web eq '' ) and defined($topic) )
                or ( $webExists and not $topicExists ) )
            {

              #perhaps its a request of the web container for a list of topics..
                my $testWeb = $web;
                $testWeb .= '/' if ( length($testWeb) );
                $testWeb .= $topic if ( defined($topic) and ( $topic ne '' ) );

                if ( Foswiki::Func::webExists($testWeb) ) {
                    $baseObjectExists = 1;
                    $web              = $testWeb;
                    $topic            = undef;
                    $query            = "'$web'/$elementAlias";

                }
            }
        }
        else {

            #attachments are to a topic, so the simple regex above is ok
            my $webExists = Foswiki::Func::webExists($web);
            my $topicExists = Foswiki::Func::topicExists( $web, $topic );
            writeDebug( "****************($web)($topic)  (web:"
                  . ( $webExists ? 'exists' : 'unknown' )
                  . ", topic:"
                  . ( $topicExists ? 'exists' : 'unknown' )
                  . ")\n" )
              if MONITOR_ALL;
            $baseObjectExists = ( $webExists and $topicExists );
            $query = "'$web.$topic'/$elementAlias";

            if ( not($webExists) and ( $web =~ /^\/?(.*)\/(.*?)$/ ) ) {
                $attachment = $topic;
                $web        = $1;
                $topic      = $2;

            #perhaps we're requesting Web/Topic/attachmentname/attachment.json..
                $webExists = Foswiki::Func::webExists($web);
                $topicExists = Foswiki::Func::topicExists( $web, $topic );
                my $attachmentExists =
                  Foswiki::Func::attachmentExists( $web, $topic, $attachment );
                writeDebug(
                        "******************($web)($topic)($attachment)  (web:"
                      . ( $webExists ? 'exists' : 'unknown' )
                      . ", topic:"
                      . ( $topicExists ? 'exists' : 'unknown' )
                      . ", attach:"
                      . ( $attachmentExists ? 'exists' : 'unknown' )
                      . ")\n" )
                  if MONITOR_ALL;
                $baseObjectExists =
                  ( $webExists and $topicExists and $attachmentExists );
                $query =
                  "'$web.$topic'/" . $elementAlias . "[name='$attachment']";
            }
        }

    }
    elsif ( ( $query eq '' ) and ( $elementAlias eq 'webs' ) ) {

        #we're getting all the webs..
        $web              = '';
        $topic            = undef;
        $baseObjectExists = 1;
    }
    else {
        die 'not implemented (' . $query . ')';
    }
    writeDebug("----------- request_method : ||$request_method||\n")
      if MONITOR_ALL;
    writeDebug("----------- query : ||$query||\n") if MONITOR_ALL;

#need to test if this topic exists, as Meta->new currently returns an obj, even if the web, or the topic don't exist. totally yuck.
#TODO: note that if we're PUT-ing and the item does not exist, we're basically POSTing, but to a static URI, not to a collection.
    if ( not $baseObjectExists ) {
        $res->header( -type => 'text/html', -status => '404' );
        $err =
"ERROR: (404) Invalid query invocation - web or topic do not exist ($web . $topic)";
        $res->print($err);
        throw Foswiki::EngineException( 404, $err, $res );
    }
    my $topicObject = Foswiki::Meta->new( $session, $web, $topic );
    writeDebug( "---- new($web, "
          . ( $topic || '>UNDEF<' )
          . ") ==  actual Meta ("
          . $topicObject->web . ", "
          . ( $topicObject->topic || '>UNDEF<' )
          . ")\n" );

#TODO: this will need ammending when we actually query, as we don't know what topics we're talking about at this point.
    my $accessType = 'CHANGE';
    $accessType = 'VIEW'   if ( $request_method eq 'GET' );
    $accessType = 'RENAME' if ( $request_method eq 'DELETE' );

    if ( not $topicObject->haveAccess($accessType) ) {
        $res->header( -type => 'text/html', -status => '401' );
        $err = "ERROR: (401) $accessType not permitted to ($web . $topic)";
        $res->print($err);
        throw Foswiki::EngineException( 401, $err, $res );
    }

    #show header as we seem to have received item
    writeDebug(
        "::::::::::::::::::::::::: header:\n    "
          . join(
            "\n    ", map { $_ . ' : ' . $req->header($_) } $req->header()
          )
          . "\n"
    ) if MONITOR_ALL;

    my ( $requestContentType, $requestCharSet ) =
      split( /;/, $req->header('Content-Type') || 'text/json' );

    my $requestPayload = REST::Utils::get_body($req);

    #untaint randomly :/
    $requestPayload =~ /(.*)/s;
    $requestPayload = $1;

    writeDebug("----------- request_method : ||$request_method||\n")
      if MONITOR_ALL;
    writeDebug("----------- query : ||$query||\n") if MONITOR_ALL;
    writeDebug("----------- requestContentType : ||$requestContentType||\n")
      if MONITOR_ALL;
    writeDebug("----------- accessType : ||$accessType||\n") if MONITOR_ALL;
    writeDebug("----------- requestPayload : ||$requestPayload||\n")
      if MONITOR_ALL;

    if (    ( $request_method ne 'GET' )
        and ( $request_method ne 'OPTIONS' )
        and ( $Foswiki::cfg{Validation}{Method} ne 'none' )
        and ( not $session->inContext('command_line') ) )
    {

        #test if the anti-CSRF is present and correct.

        my $nonce = $session->{request}->header('X-Foswiki-Nonce');
        writeDebug("%%%%%%%%%%%%%%%%%%%%%%%% $nonce testing \n");
        if (
            !defined($nonce)
            || !Foswiki::Validation::isValidNonce(
                $session->getCGISession(), $nonce
            )
          )
        {
            $res->header( -type => 'text/html', -status => '401' );
            $err = "ERROR: (401) Foswiki validation key error";
            writeDebug("$err\n");
            $res->print($err);
            throw Foswiki::EngineException( 401, $err, $res );
        }
    }

    if ( ( $request_method ne 'GET' ) and ( $requestPayload eq '' ) ) {
        writeDebug(
            "@@@@@@@@@@@@@@@@@@@@ no payload. writing to /tmp/cgi.out\n");
        open( OUT, '>', '/tmp/cgi.out' );
        $req->save( \*OUT );
        close(OUT);

        #        return '';
    }

    #DOIT
    my $result;
    try {

        #time it.
        my $startTime = [Time::HiRes::gettimeofday];

        if ( $request_method eq 'GET' ) {

        #TODO: the query language currently presumes that the LHS of / isa topic
            if (   ( $elementAlias eq 'topic' )
                or ( $elementAlias eq 'attachments' ) )
            {
                if ( ( $elementAlias eq 'topic' ) and not( defined($topic) ) ) {

                #asking for a list of topics..
                #TODO: really bad idea - use a paging itr, or use a real query..
                    my @topicList =
                      map { { '_topic' => $_ } }
                      Foswiki::Func::getTopicList($web);
                    $result = \@topicList;

            #TODO: can't do this atm, it returns a topic location and thus a 302
            #$res->pushHeader( 'Location',
            #    getResourceURI( $topicObject, $elementAlias) );
                }

#                elsif (( $elementAlias eq 'attachments' ) and not(defined($topic))) {
#                }
                else {
                    my $evalParser = new Foswiki::Query::Parser();
                    my $querytxt   = $query;
                    $querytxt =~ s/(topic)$/:topic_meta:/;
                    writeDebug(
"~~~~~~~~~~~~~~~~~~~~~~~topic: use query evaluate $querytxt\n"
                    ) if MONITOR_ALL;

#                    ($Foswiki::cfg{Store}{QueryAlgorithm} eq 'Foswiki::Store::QueryAlgorithms::MongoDB')
#                        || die "Check Foswiki::Store::QueryAlgorithm: For now, only MongoDB knows how to resolve a ':topic_meta:' element";
                    my $node = $evalParser->parse($querytxt);

                    $result = $node->evaluate(
                        tom  => $topicObject,
                        data => $topicObject
                    );

#TODO: this isn't a topic..
#                    $res->pushHeader( 'Location',
#                        getResourceURI( $result, $elementAlias) ) if (defined($result));
                }
            }
            elsif ( $elementAlias eq 'webs' ) {

      #TODO: get all subwebs of LHS - so ''/webs == /webs == all webs recursive.
      #TODO: consider filter of Func::getListOfWebs( $filter [, $web] )
                my $filter = '';
                my @webs = Foswiki::Func::getListOfWebs( $filter, $web );
                unshift( @webs, $web ) if ( $web ne '' );
                my @results = map {
                    my $m =
                      Foswiki::Meta->load( $Foswiki::Plugins::SESSION, $_ );
                    writeDebug( "::::: load($_) == " . $m->web . "\n" )
                      if MONITOR_ALL;
                    $m
                } @webs;
                $result = \@results;
                $res->pushHeader( 'Location',
                    getResourceURI( $topicObject, $elementAlias ) );
            }
            $res->status(200);
        }
        elsif ( $request_method eq 'PUT' ) {
            die 'not implemented';
        }
        elsif ( $request_method eq 'PATCH' ) {
            ASSERT( $requestPayload ne '' ) if DEBUG;
            my $value =
              Foswiki::Serialise::deserialise( $session, $requestPayload,
                mapMimeType($requestContentType) );
            if ( $elementAlias eq 'topic' ) {
                mergeFrom( $topicObject, $value );    #copy meta..

#writeDebug(")))))".Foswiki::Serialise::serialise( $session, $value, 'perl' )."(((((\n" if MONITOR_ALL;
                $topicObject->text( $value->{_text} )
                  if ( defined( $value->{_text} ) );
                $topicObject->save();
                $res->pushHeader( 'Location',
                    getResourceURI( $topicObject, $elementAlias ) );
                $result = Foswiki::Serialise::convertMeta($topicObject);
            }
            elsif ( $elementAlias eq 'attachments' ) {
                if ( ( not defined($attachment) ) or ( $attachment eq '' ) ) {
                    my $hash = { "FILEATTACHMENT" => $value };
                    mergeFrom( $topicObject, $hash );    #copy meta..

#writeDebug(")))))".Foswiki::Serialise::serialise( $session, $value, 'perl' )."(((((\n" if MONITOR_ALL;
                }
                else {
                    my $info =
                      $topicObject->getAttachmentRevisionInfo($attachment);
                    use Data::Dumper;
                    writeDebug( ">>>>>>>>>>>>>>>>>>>>>>>>>>"
                          . Dumper($info)
                          . "<<<<<<<<<<<<<<<<<<<<<<n" )
                      if MONITOR_ALL;
                    @{$info}{ keys(%$value) } = values(%$value)
                      ;  #over-ride the server version with whats in the payload
                    writeDebug( ">>>>>>>>>>>>>>>>>>>>>>>>>>"
                          . Dumper($info)
                          . "<<<<<<<<<<<<<<<<<<<<<<n" )
                      if MONITOR_ALL;

                    #TODO: shoudl make sure there's no stream or file set
                    #                    delete $info->{stream};
                    #                    delete $info->{file};
                    $topicObject->attach(%$info);
                }
                $topicObject->save();

                #COPY&PASTE from GET...
                my $evalParser = new Foswiki::Query::Parser();
                my $querytxt   = $query;
                $querytxt =~ s/(topic)$/:topic_meta:/;
                writeDebug(
"~~~~~~~~~~~~~~~~~~~~~~~topic: use query evaluate $querytxt\n"
                );
                my $node = $evalParser->parse($querytxt);

                $result = $node->evaluate(
                    tom  => $topicObject,
                    data => $topicObject
                );
                $res->pushHeader( 'Location',
                    getResourceURI( $result, $elementAlias ) );
                $result =
                  Foswiki::Serialise::convertMeta($result);   ###TODO: Extractme
            }

            $res->status(201);
        }
        elsif ( $request_method eq 'POST' ) {
            ASSERT( $requestPayload ne '' ) if DEBUG;

            my $value =
              Foswiki::Serialise::deserialise( $session, $requestPayload,
                mapMimeType($requestContentType) );

            if ( $elementAlias eq 'topic' ) {
                require Foswiki::UI::Save;
                $topic =
                  Foswiki::UI::Save::expandAUTOINC( $session, $web,
                    $value->{_topic} );

                #TODO: actually, consider using the UI::Manage::_create
                #new topic...
                $topicObject = Foswiki::Meta->new( $session, $web, $topic );
                writeDebug( "\n\nPOST: create new topic Meta ("
                      . $topicObject->web . ", "
                      . ( $topicObject->topic || '>UNDEF<' )
                      . ")\n\n\n" )
                  if MONITOR_ALL;

                copyFrom( $topicObject, $value );
                $topicObject->text( $value->{_text} )
                  if ( defined( $value->{_text} ) );
                $topicObject->save();
                $result = $topicObject;
                $res->pushHeader( 'Location',
                    getResourceURI( $result, $elementAlias ) );
            }
            elsif ( $elementAlias eq 'webs' ) {

                #web creation - call UI::Manage::createWeb()
                ASSERT( not defined($topic) ) if DEBUG;
                $value->{newweb} = $web . '/' . $value->{newweb}
                  if ( defined($web) and ( $web ne '' ) );

         #it seems that the UI::Manage code is destructive to the input hash, so
                my $newWeb = $value->{newweb};
                require Foswiki::UI::Manage;
                my $newReq = new Foswiki::Request($value)
                  ;    #use the payload to initialise the manage request
                       #$newReq->path_info($url);
                $newReq->method('manage');
                my $oldReq = $session->{request};
                $session->{request} = $newReq;

                #TODO: disable strikone for now
                my $validation = $Foswiki::cfg{Validation}{Method};
                $Foswiki::cfg{Validation}{Method} = 'none';
                try {
                    Foswiki::UI::Manage::_action_createweb($session);
                }
                catch Foswiki::OopsException with {
                    my $e = shift;
                    die 'whatever: ' . $e->{template} . '....' . $e->stringify()
                      if not(     $e->{template} eq 'attention'
                              and $e->{def} eq 'created_web' );
                }
                catch Foswiki::AccessControlException with {
                    my $e = shift;
                    die 'error creating web';
                }
                finally {};

                my @results = ();
                ASSERT( Foswiki::Func::webExists($newWeb) ) if DEBUG;
                my $webObject =
                  Foswiki::Meta->load( $Foswiki::Plugins::SESSION, $newWeb );
                ASSERT( $webObject->existsInStore() ) if DEBUG;
                push( @results, $webObject );
                $result                           = \@results;
                $session->{request}               = $oldReq;
                $Foswiki::cfg{Validation}{Method} = $validation;

                $res->pushHeader( 'Location',
                    getResourceURI( $webObject, 'webs' ) );

            }
            else {
                die 'not implemented';
            }

    #if we created something and are returning it, and a uri for it, status=201
    #need a location header
    #if we created something, but are not returning it, then status = 200 or 204
    #could use 303 to redirect to the created resource too..?
            $res->status('201  Created');

        }
        elsif ( $request_method eq 'DELETE' ) {
            require Foswiki::UI::Save;
            if ( $elementAlias eq 'webs' ) {
                ASSERT( Foswiki::Func::webExists($web) ) if DEBUG;
                my $trashWeb = $web . time();
                $trashWeb =~ s/[\/.]/_/g;
                writeDebug(
" Foswiki::Func::moveWeb($web, $Foswiki::cfg{TrashWebName}.'.'.$trashWeb)\n"
                ) if MONITOR_ALL;
                Foswiki::Func::moveWeb( $web,
                    $Foswiki::cfg{TrashWebName} . '.' . $trashWeb );
                ASSERT( not Foswiki::Func::webExists($web) ) if DEBUG;
            }
            elsif ( $elementAlias eq 'topic' ) {
                ASSERT( Foswiki::Func::topicExists( $web, $topic ) ) if DEBUG;
                my $trashTopic = Foswiki::UI::Save::expandAUTOINC(
                    $session,
                    $Foswiki::cfg{TrashWebName},
                    $topic . 'AUTOINC0000'
                );
                Foswiki::Func::moveTopic( $web, $topic,
                    $Foswiki::cfg{TrashWebName}, $trashTopic );
                ASSERT( not Foswiki::Func::topicExists( $web, $topic ) )
                  if DEBUG;

            }
            elsif ( $elementAlias eq 'attachments' ) {
                ASSERT(
                    Foswiki::Func::attachmentExists(
                        $web, $topic, $attachment
                    )
                ) if DEBUG;
                Foswiki::Func::moveAttachment( $web, $topic, $attachment,
                    $Foswiki::cfg{TrashWebName},
                    'TrashAttament', time() . '_' . $attachment );
                ASSERT(
                    not Foswiki::Func::attachmentExists(
                        $web, $topic, $attachment
                    )
                ) if DEBUG;
            }
            else {
                die 'you cant remove that';
            }

            $result = {};
            $res->status('204  No Content');
        }
        elsif ( $request_method eq 'OPTIONS' ) {

         #TODO: detect where we are pointing, and give a list of verbs we can do
         #fill the body with info wrt what object types are available here
         #(GET|PUT|POST|PATCH|DELETE)
            $res->pushHeader( 'Allow', 'GET, OPTIONS, POST, PATCH, DELETE' );
            $res->status(200);
            my $script = Foswiki::Func::getScriptUrl( undef, undef, 'query' );
            $result = [
                {
                    element     => 'webs',
                    example_uri => '' . $script . '/webs',
                    meaning     => 'get a list of webs'
                },
                {
                    element     => 'webs',
                    example_uri => '' . $script . '/{WebName}/webs',
                    meaning => 'get/set meta information for the specificed web'
                },
                {
                    element     => 'topic',
                    example_uri => '' . $script . '/{WebName}/topic',
                    meaning     => 'get a list of topics in the specified web'
                },
                {
                    element     => 'topic',
                    example_uri => '' 
                      . $script
                      . '/{WebName}/{TopicName}/topic',
                    meaning =>
                      'get/set meta information for the specificed topic'
                },
                {
                    element     => 'attachments',
                    example_uri => '' 
                      . $script
                      . '/{WebName}/{TopicName}/attachments',
                    meaning =>
                      'get a list of attachments to the specificed topic'
                },
                {
                    element     => 'attachments',
                    example_uri => '' 
                      . $script
                      . '/{WebName}/{TopicName}/{attachmentname}/attachments',
                    meaning =>
                      'get/set meta information for the specificed attachment'
                },
            ];
        }
        else {

            #throw something  - this should have been noticed before
            die 'not implemented';
        }

#might be an array of Meta's
#TODO: should the reply _always_ be an array?
#writeDebug("------------------ ref(result): " . ref($result) . "\n" if MONITOR_ALL;
        if ( ref($result) eq 'ARRAY' ) {
            for ( my $i = 0 ; $i < scalar(@$result) ; $i++ ) {

#writeDebug("------------------ ref(result->[$i]): " . ref($result->[$i]) . "\n" if MONITOR_ALL;
                if ( ref( $result->[$i] ) eq 'Foswiki::Meta' ) {
                    $result->[$i] =
                      Foswiki::Serialise::convertMeta( $result->[$i] );
                }
            }
        }
        else {
            if ( ref($result) eq 'Foswiki::Meta' ) {
                $result = Foswiki::Serialise::convertMeta($result);
            }
        }

#TODO: the elementAlias and query != what was requested - it should be what is returned (for eg, POST is the item, not the container

        #end timer
        my $endTime = [Time::HiRes::gettimeofday];
        my $timeDiff = Time::HiRes::tv_interval( $startTime, $endTime );

     #push this into the HTTP header, as the HTTP payload _is_ the resource data
        my $header_info = {
            query     => $query,
            element   => $elementAlias,
            mediatype => $responseContentType,
            action    => $request_method,
            rev       => '',
            startTime => $startTime,
            endTime   => $endTime,
            time      => $timeDiff,
        };
        map { $res->pushHeader( 'X-Foswiki-REST-' . $_, $header_info->{$_} ) }
          keys(%$header_info);

        use Scalar::Util qw(blessed reftype);
        if ( blessed($result) ) {
            writeDebug("WARNING: result is a blessed object\n") if MONITOR_ALL;
            ASSERT( not defined( blessed($result) ) );
        }

        $result =
          Foswiki::Serialise::serialise( $session, $result,
            mapMimeType($responseContentType) );

        # add anti-CSRF magic to Header
        my $cgis = $session->getCGISession();
        my $context = $req->url( -full => 1, -path => 1, -query => 1 ) . time();
        my $useStrikeOne = ( $Foswiki::cfg{Validation}{Method} eq 'strikeone' );
        my $nonce = Foswiki::Validation::generateValidationKey( $cgis, $context,
            $useStrikeOne );

      #TODO: I'm presuming there is only one action - this may be an issue later
        $res->pushHeader( 'X-Foswiki-Nonce', $nonce );
        $res->cookies(
            [ $res->cookies(), Foswiki::Validation::getCookie($cgis) ] );
    }
    catch Error::Simple with {

        #ouchie, VC::Handler errors
        my $e = shift;
        use Data::Dumper;
        writeDebug(
            "Result Payload would have been: " . Dumper($result) . "\n" )
          if MONITOR_ALL;
        $result = $e->{-text};
        writeDebug("SimpleERROR: $result\n") if MONITOR_ALL;
        $res->status( '500 ' . $result );
    }
    catch Foswiki::Infix::Error with {
        my $e = shift;
        $result = $e->{-text};
        $res->status( '500 ' . $result );
    }
    finally {};

    #these will be processed and selected..
    writeDebug("--------result ($result)\n") if MONITOR_ALL;

    _writeCompletePage( $session, $result, 'view', $responseContentType );
}

sub getResourceURI {
    my $meta         = shift;
    my $elementAlias = shift;    #TODO: derive this from the meta..

    #ASSERT($meta->isa('Foswiki::Meta')) if DEBUG;

    writeDebug( "getResourceURI - getScriptUrl("
          . $meta->web . ", "
          . ( $meta->topic || '>UNDEF<' )
          . ", 'query')\n" );

    #TODO: er, and what about attchments?
    #TODO: and allow mimetype to be added later
    my ( $web, $topic ) = ( $meta->web, $meta->topic );
    $topic = 'ZZyZZyyyayyayyaSven' if ( $elementAlias eq 'webs' );
    my $uri =
      Foswiki::Func::getScriptUrl( $web, $topic, 'query' ) . "/$elementAlias";
    $uri =~ s/\/ZZyZZyyyayyayyaSven//
      ;    #it seems that getScriptUrl doesn't like $topic=undef
    writeDebug("   getResourceURI -> $uri\n") if MONITOR_ALL;
    return $uri;
}

sub _writeCompletePage {
    my ( $session, $text, $pageType, $responseContentType ) = @_;

#TODO: because writeCompletePage is badly broken by renderZones and other new cruft, I have to re-implement it here
#$session->writeCompletePage($result, $pageType, $responseContentType);

#not sure its a good idea to run the completePageHandler, but i'm sure its not a goot idea not to run it :/
#    my $hdr = "Content-type: " . $responseContentType . "\r\n";
# Call final handler
#    $session->{plugins}->dispatch( 'completePageHandler', $text, $hdr );

    my $cachedPage;
    $session->generateHTTPHeaders( $pageType, $responseContentType, $text,
        $cachedPage );
    writeDebug( $session->{response}->printHeaders() )
      ;    #these are not printed for cmdline..
    $session->{response}->print($text);
}

#thows an exception if something isn't right.
sub authenticate {
    my $session = shift;
    my $req     = $session->{request};
    my $res     = $session->{response};
    my $err;

    # If there's login info, try and apply it
    my $login = $req->param('username');
    if ($login) {
        my $pass = $req->param('password');
        my $validation = $session->{users}->checkPassword( $login, $pass );
        unless ($validation) {
            $res->header( -type => 'text/html', -status => '401' );
            $err = "ERROR: (401) Can't login as $login";
            $res->print($err);
            throw Foswiki::EngineException( 401, $err, $res );
        }

        my $cUID     = $session->{users}->getCanonicalUserID($login);
        my $WikiName = $session->{users}->getWikiName($cUID);
        $session->{users}->getLoginManager()->userLoggedIn( $login, $WikiName );
    }

    # Check that the script is authorised under the standard
    # {AuthScripts} contract
    try {
        $session->getLoginManager()->checkAccess();
    }
    catch Error with {
        my $e = shift;
        $res->header( -type => 'text/html', -status => '401' );
        $err = "ERROR: (401) $e";
        $res->print($err);
        throw Foswiki::EngineException( 401, $err, $res );
    };
}

########################
#yes, this is a simplified copy from Foswiki::Meta::copyFrom so we can copy from a random hashref
sub copyFrom {
    my ( $meta, $other, $type, $filter ) = @_;

    if ($type) {
        return if $type =~ /^_/;
        my @data;
        foreach my $item ( @{ $other->{$type} } ) {
            if ( !$filter
                || ( $item->{name} && $item->{name} =~ /$filter/ ) )
            {
                my %datum = %$item;
                push( @data, \%datum );
            }
        }
        $meta->putAll( $type, @data );
    }
    else {
        foreach my $k ( keys %$other ) {
            unless ( $k =~ /^_/ ) {
                copyFrom( $meta, $other, $k );
            }
        }
    }
}

#this is the PATCH version of copyfrom
sub mergeFrom {
    my ( $meta, $other, $type, $filter ) = @_;

    if ($type) {
        return if $type =~ /^_/;
        foreach my $item ( @{ $other->{$type} } ) {
            if ( !$filter
                || ( $item->{name} && $item->{name} =~ /$filter/ ) )
            {
                my $old = $meta->get( $type, $item->{name} );
                my %hash = ();

#Merge old element with new data - that way keys that are not in the payload still get used.
                %hash = %$old if ( defined($old) );
                @hash{ keys(%$item) } = values(%$item);
                $meta->putKeyed( $type, \%hash );
            }
        }
    }
    else {
        foreach my $k ( keys %$other ) {
            unless ( $k =~ /^_/ ) {
                mergeFrom( $meta, $other, $k );
            }
        }
    }
}

{

    package Foswiki::Serialise;

    #TODO: have to work out what these are, and how they come out..
    sub html {
        my ( $session, $result ) = @_;
        my ( $web, $topic );
        $result = Foswiki::Func::renderText( $result, $web, $topic );
        return $result;
    }

    sub raw {
        my ( $session, $result ) = @_;
        my ( $web, $topic );
        $result = Foswiki::Func::renderText( $result, $web, $topic );
        return $result;
    }
}

sub writeDebug {
    my ($message) = @_;

    Foswiki::Func::writeDebug($message);

    #print STDERR $message;

    return;
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2010 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.

author: SvenDowideit@fosiki.com
