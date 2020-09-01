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
    Size = case SubEl#upload_media.size of
        undefined -> undefined;
        <<>> -> 0;
        S -> binary_to_integer(S)
    end,
    ProtoUploadMedia = #pb_upload_media{
        size = Size,
        url = ProtoMediaURL
    },
    ProtoUploadMedia.


proto_to_xmpp(ProtoPayload) ->
    MediaURL = ProtoPayload#pb_upload_media.url,
    XmppUrls = case MediaURL of
        undefined -> [];
        _ -> [#media_urls{
                get = MediaURL#pb_media_url.get,
                put = MediaURL#pb_media_url.put,
                patch = MediaURL#pb_media_url.patch
            }]
    end,
    Size = case ProtoPayload#pb_upload_media.size of
        undefined -> undefined;
        0 -> <<>>;
        S -> integer_to_binary(S)
    end,
    #upload_media{
        size = Size,
        media_urls = XmppUrls
    }.

