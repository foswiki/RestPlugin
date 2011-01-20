/*

Foswiki RestPlugin wrapper
    so far only tested for topics

Copyright (C) 2011 Sven Dowideit - http://fosiki.com

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 3
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.

*/

///////////////////////
// Simplified API to RestPlugin
// currently JSON only.
// Note: this is async - calling get() will not return the value - you need to use the success_callback
foswiki.RestPlugin = {
    //options == hash of {element, encoding, success_callback, failure_callback}
    get: function(query, options) {
        jQuery.ajax({
            url: foswiki.getPreference('SCRIPTURL') + '/query' + foswiki.getPreference('SCRIPTSUFFIX') + '/' + query + '/' + options.element + '.' + options.encoding,
            type: 'GET',
            dataType: options.encoding,
            //beforeSubmit:  showRequest,  // pre-submit callback 
            success: function(responseText, statusText, xhr) {
                foswiki.RestPlugin.gatherNonce(responseText, statusText, xhr);
                if (typeof(options.success_callback) != 'undefined') {
                    options.success_callback(responseText, statusText, xhr);
                }
            },
            // post-submit callback 
            beforeSend: foswiki.RestPlugin.setupHTTPHeader

        });
    },
    patch: function(query, dataObj, options) {
        foswiki.RestPlugin.send(query, 'PATCH', dataObj, options)
    },
    post: function(query, dataObj, options) {
        foswiki.RestPlugin.send(query, 'POST', dataObj, options)
    },
    put: function(query, dataObj, options) {
        foswiki.RestPlugin.send(query, 'PUT', dataObj, options)
    },
    delete: function(query, dataObj, options) {
        foswiki.RestPlugin.send(query, 'DELETE', dataObj, options)
    },
    //options == hash of {element, encoding, success_callback, failure_callback}
    //request = PUT,POST,PATCH
    //TODO: send can chain a get if it has no nonce - whereas 'get' doesn't need one
    send: function(query, request, dataObj, options) {
        jQuery.ajax({
            url: foswiki.getPreference('SCRIPTURL') + '/query' + foswiki.getPreference('SCRIPTSUFFIX') + '/' + query + '/' + options.element + '.' + options.encoding,
            type: request,
            dataType: options.encoding,

            contentType: 'text/json',
            data: JSON.stringify(dataObj),
            success: function(responseText, statusText, xhr) {
                foswiki.RestPlugin.gatherNonce(responseText, statusText, xhr);
                if (typeof(options.success_callback) != 'undefined') {
                    options.success_callback(responseText, statusText, xhr);
                }
            },
            // post-submit callback 
            beforeSend: foswiki.RestPlugin.setupHTTPHeader
        });
    },
    nonce: '',
    gatherNonce: function(responseText, statusText, xhr, cb) {
        if (xhr != null) {
            foswiki.RestPlugin.nonce = xhr.getResponseHeader("X-Foswiki-Nonce");
        } else {
            foswiki.RestPlugin.nonce = '';
        }
    },
    setupHTTPHeader: function(xhr) {
        //Add strikeone and SessionId to headers too
        xhr.setRequestHeader("Cookie", "IE is shite");
        xhr.setRequestHeader("Cookie", document.cookie);

        //jquery < 1.4.4 needs to use POST and the over-ride cos its busted and sends an empty payload.
        //xhr.setRequestHeader("X-HTTP-METHOD-OVERRIDE", 'PATCH');
        //combine the nonce with the cookie secret that is in the containing html..
        //which means we need to force strikeone.js to be loaded too (see RestPlugin::initPlugin
        //TODO: need to detect and do the right thing for non-strikeone
        //TODO: detect we don't have a nonce, and detect that its because we've never asked, and ask for one?
        xhr.setRequestHeader("X-Foswiki-Nonce", StrikeOne.calculateNewKey("?" + foswiki.RestPlugin.nonce));
    }
}