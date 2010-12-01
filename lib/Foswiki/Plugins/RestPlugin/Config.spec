# ---+ Extensions
# ---++ RestPlugin
# **PERL H**
# This setting is required to enable executing the query script from the bin directory
$Foswiki::cfg{SwitchBoard}{query} = {
    package  => 'Foswiki::UI::Query',
    function => 'query',
    context  => { query => 1,
                },
    };
1;
