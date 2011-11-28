package Foswiki::Plugins::RestPlugin;

# Always use strict to enforce variable scoping
use strict;

require Foswiki::Func;       # The plugins API
require Foswiki::Plugins;    # For the API version

require JSON;

use vars
  qw( $VERSION $RELEASE $SHORTDESCRIPTION $debug $pluginName $NO_PREFS_IN_TOPIC );
$VERSION           = '1';
$RELEASE           = '2.0.0-a1';
$SHORTDESCRIPTION  = 'REST based CRUD API for javascript and applications';
$NO_PREFS_IN_TOPIC = 1;
$pluginName        = 'RestPlugin';

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning(
            "Version mismatch between $pluginName and Plugins.pm");
        return 0;
    }

    $debug = $Foswiki::cfg{Plugins}{RestPlugin}{Debug} || 0;

    #tell Foswiki::UI about the new handler.
    $Foswiki::cfg{SwitchBoard}{query} = {
        package  => 'Foswiki::UI::Query',
        function => 'query',
        context  => { query => 1 },
    };

    # Add the JS module to the page. Note that this is *not*
    # incorporated into the foswikilib.js because that module
    # is conditionally loaded under the control of the
    # templates, and we have to be *sure* it gets loaded.
    my $src = $Foswiki::Plugins::SESSION->{prefs}->getPreference('FWSRC') || '';
    $Foswiki::Plugins::SESSION->addToZone( 'head', 'JavascriptFiles/strikeone',
        <<JS );
<script type="text/javascript" src="$Foswiki::cfg{PubUrlPath}/$Foswiki::cfg{SystemWebName}/JavascriptFiles/strikeone$src.js"></script>
JS

    return 1;
}

1;

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
