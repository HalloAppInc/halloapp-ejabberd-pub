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
    ProtoMediaURL = #pb_media_url{
        get = MediaURL#media_urls.get,
        put = MediaURL#media_urls.put,
        patch = MediaURL#media_urls.patch
    },
    ProtoUploadMedia = #pb_upload_media{
        size = binary_to_integer(SubEl#upload_media.size),
        url = ProtoMediaURL
    },
    ProtoUploadMedia.


proto_to_xmpp(ProtoPayload) ->
    MediaURL = ProtoPayload#pb_upload_media.url,
    XmppUrls = #media_urls{
        get = MediaURL#pb_media_url.get,
        put = MediaURL#pb_media_url.put,
        patch = MediaURL#pb_media_url.patch
    },
    #upload_media{
        size = integer_to_binary(ProtoPayload#pb_upload_media.size),
        media_urls = [XmppUrls]
    }.

