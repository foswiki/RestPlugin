# Plugin for Foswiki Collaboration Platform, http://Foswiki.org/
#
# Copyright 2007-2009 SvenDowideit@fosiki.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::RestPlugin;

# Always use strict to enforce variable scoping
use strict;

require Foswiki::Func;    # The plugins API
require Foswiki::Plugins; # For the API version
#require Foswiki::Contrib::DojoToolkitContrib;

require JSON;

use vars qw( $VERSION $RELEASE $SHORTDESCRIPTION $debug $pluginName $NO_PREFS_IN_TOPIC );
$VERSION = '$Rev$';
$RELEASE = 'Foswiki-1.0';
$SHORTDESCRIPTION = 'Full implementation of REST';
$NO_PREFS_IN_TOPIC = 1;
$pluginName = 'RestPlugin';

sub initPlugin {
    my( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if( $Foswiki::Plugins::VERSION < 1.026 ) {
        Foswiki::Func::writeWarning( "Version mismatch between $pluginName and Plugins.pm" );
        return 0;
    }

    $debug = $Foswiki::cfg{Plugins}{RestPlugin}{Debug} || 0;
    Foswiki::Func::registerRESTHandler('RealRest', \&RealRest);
    
    #TODO: use the skin path
#    Foswiki::Contrib::DojoToolkitContrib::requireJS("dojo.parser");
#    Foswiki::Contrib::DojoToolkitContrib::requireJS("dijit.InlineEditBox");
#    Foswiki::Contrib::DojoToolkitContrib::requireJS("dijit.form.TextBox");
    my $javascript = Foswiki::Func::readTemplate('restpluginscript');
    Foswiki::Func::addToHEAD($pluginName.'.InlineHandler', $javascript);

    # Plugin correctly initialized
    return 1;
}

=pod

---++ RealRest($session) -> $text

This is an example of a sub to be called by the =rest= script. The parameter is:
   * =$session= - The Foswiki object associated to this session.


Addressing scheme is...

http://foswiki/cgi-bin/rest/RestPlugin/rest/Web.Topic:FormName.FieldName

http://quad/trunk/bin/rest/RestPlugin/RealRest/Sandbox.BugItem1:BugItemTemplate.Summary

eg:
        #if $pathInfo == '' %MAINWEB%.WebHome
        #if $pathInfo == 'Web' Web.WebHome
        #if $pathInfo == 'Web.Topic' Web.Topic
        #if $pathInfo == 'Web.Topic:FORM' the topic's form
        #if $pathInfo == 'Web.Topic:FIELD' the topic's form
        #if $pathInfo == 'Web.Topic:FIELD.Summary' The Summary field
        #if $pathInfo == 'Web.Topic:FIELD.S*' All fields starting with S ??


=cut

sub RealRest {
   my ($session) = @_;
   my $query = Foswiki::Func::getCgiQuery();
   my $request_method = $query->request_method();
   
    my $pathInfo = $query->path_info();
print STDERR "pathInfo = $pathInfo" if $debug;
    my $cgiScriptName = $ENV{'SCRIPT_NAME'} || '';
    $pathInfo =~ s!$cgiScriptName/!!i;
    $pathInfo =~ s!$pluginName/!!i;
    $pathInfo =~ s!RealRest/?!!i;
    $pathInfo =~ s!^/!!i;
    
    #anything after a : is in the SEARCH query syntax.
    $pathInfo =~ /([^:]*)(:.*)?/;

    my ($webTopic, $fieldName) = ($1, $2);
    $fieldName = 'text' unless (defined($fieldName));
    $fieldName =~ s/^://;

print STDERR "webTopic = $webTopic" if $debug;
    my ($web, $topic) = Foswiki::Func::normalizeWebTopicName('', $webTopic);
print STDERR "fieldName = $fieldName" if $debug;
    unless (Foswiki::Func::topicExists( $web, $topic )) {
        print $query->header(
            -type   => 'text/html',
            -status => '404'
        );
        print "ERROR: (404) topic ($web . $topic) does not exist)\n";
        print STDERR "ERROR: (404) topic ($web . $topic) does not exist)\n";
        return;
    }
    my( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );
    
    my $result;
    #TODO: need to add content_type
    #Accept needs to order by preference expressed ...(its a float)
    #want a urlparam to allow forcing the content_type
    #TODO: make the content types pluggable
    #eg, application/pdf would call getPdfPlugin
    my @acceptedContentTypes = sort {$query->Accept($b) <=> $query->Accept($a)} $query->Accept();
    
#print STDERR "".join(',', @acceptedContentTypes)."\n";
    #insert the requested content_type before the ones in the header (used mostly for debugging)
    unshift (@acceptedContentTypes, $query->param('content_type')) if (defined($query->param('content_type')));
#print STDERR "++".join(',', map {$_.'='.$query->Accept($_)} @acceptedContentTypes)."\n";
    
    if ($request_method eq 'HEAD') {
    } elsif ($request_method eq 'GET') {
        $result = parseField($meta, $fieldName);
        if (!defined($result)) {
            print $query->header(
                -type   => 'text/html',
                -status => '404'
            );
            $result = "ERROR: (404) element ($web . $topic : $fieldName) does not exist)\n";
            print STDERR "ERROR: (404) topic ($web . $topic : $fieldName) does not exist)\n";
            exit;
        }
        #TODO: replace foreach with hash of registrable subs..
		foreach my $content_type (@acceptedContentTypes) {
		    if (($content_type eq 'text/html')) {
		        $result = Foswiki::Func::renderText( $result, $web, $topic )
		    } elsif (($content_type eq 'text/json')) {
		        #remove Foswiki object
		        if (UNIVERSAL::isa($result, 'Foswiki::Meta')) {
		            #remove Foswiki object
		            undef $result->{_session};
		        }
		        #TODO: will need to escape the result..
		        $result = {
		            url => $query->path_info(),
		            web => $web,
		            topic => $topic,
		            field => $fieldName,
		            result => $result
		            };
		        use JSON;
		        $result = to_json($result, {pretty=>1});

	#TODO; form for dojo
	#        { label: 'uid',
	#          identifier: 'name',
	#          items: $elements
	#        }

		        last; #found a match..
		    } elsif (($content_type eq 'text/xml')) {
		        #last; #found a match..
		    } elsif (($content_type eq 'text/text')) {
		        #returns the $summary type text? (useful for search engines....)
		        last; #found a match..
		    } elsif (($content_type eq 'text/tml')) {
		    	#source - or shoudl this be text/source...
		        last; #found a match..
		    } else {
		    }
		}
    } elsif ($request_method eq 'POST') {
        my $value = $query->param('value');
        print STDERR "value = $value";
        
        #TODO: write a 'Set value/s' version of Foswiki::If::Parser
        
        if ( $fieldName =~ /^FIELD\.(.*)/ ) {
            my $name = $1;
            my $field = $meta->get('FIELD', $name );
            if ($field) {
                $field->{value} = $value;
                $meta->putKeyed( 'FIELD', $field );
                #TODO: obviously need to wrap it all in a try - catch
                my $error = Foswiki::Func::saveTopic( $web, $topic, $meta, $text, { comment => 'RestPlugin Request to change '.$pathInfo.' to '.$value } );
                #TODO: beware, there might be processing on the way IN, so we should ask the meta what the new value is (re-read)?
                #TODO: content type!
                #TODO: more meta?
                $result = $value;
                if ($error) {
                   #TODO: 404?
                    return 'FAILED: Request to change '.$pathInfo.' to '.$value.'  ERROR: '.$error;
                }
            } else {
               #TODO: 404?
                return 'FAILED: Request to change '.$pathInfo.' to '.$value.' ERROR: only FIELD types currently supported ';
            }
        } else {
           #TODO: 404?
            return 'FAILED: Request to change '.$pathInfo.' to '.$value;
        }
    } else {
    }
   
    return $result;
}

sub parseField {
    my ( $meta, $field) = @_;

my $ifParser;
#    unless( $ifParser ) {
        require Foswiki::If::Parser;
        $ifParser = new Foswiki::If::Parser();
#    }

    my $expr;
    my $result;
#    try {
        $expr = $ifParser->parse( $field );
        $result = $expr->evaluate( tom=>$meta, data=>$meta );
#        if( $expr->evaluate( tom=>$meta, data=>$meta )) {
#            $params->{then} = '' unless defined $params->{then};
#            $result = expandStandardEscapes( $params->{then} );
#        } else {
#            $params->{else} = '' unless defined $params->{else};
#            $result = expandStandardEscapes( $params->{else} );
#        }
#    } catch Foswiki::Infix::Error with {
#        my $e = shift;
#        print STDERR "ERROR: ".$e;
#    };
    return $result;
}


1;
