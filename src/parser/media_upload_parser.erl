-module(media_upload_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) ->
    MediaURLs = SubEl#upload_media.media_urls,
    [MediaURL] = MediaURLs,
    ProtoMediaURL = #pb_media_urls{
        get = MediaURL#media_urls.get,
        put = MediaURL#media_urls.put,
        patch = MediaURL#media_urls.patch
    },
    ProtoUploadMedia = #pb_upload_media{
        size = binary_to_integer(SubEl#upload_media.size),
        urls = [ProtoMediaURL]
    },
    ProtoUploadMedia.


proto_to_xmpp(ProtoPayload) ->
    [MediaURL] = ProtoPayload#pb_upload_media.urls,
    XmppUrls = #media_urls{
        get = MediaURL#pb_media_urls.get,
        put = MediaURL#pb_media_urls.put,
        patch = MediaURL#pb_media_urls.patch
    },
    #upload_media{
        size = integer_to_binary(ProtoPayload#pb_upload_media.size),
        media_urls = [XmppUrls]
    }.

