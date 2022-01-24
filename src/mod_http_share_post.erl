%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for sharing HalloApp Post
%%% @end
%%%-------------------------------------------------------------------
-module(mod_http_share_post).
-author("vipin").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("clients.hrl").
-include("share_post.hrl").

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

%% for testing.
-export([
    construct_text_post/0,
    construct_text_post_no_preview/0,
    construct_album_post/0,
    construct_voice_post/0,
    construct_image_media/0,
    construct_voice_note/0,
    construct_encrypted_resource/0,
    show_post_content/2
]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /share_post/id
process([BlobId],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        Key = decode_key(proplists:get_value(<<"k">>, Q, <<>>)),
        %% TODO(vipin): Need to remove the debug.
        ?DEBUG("Share Id: ~p, Key: ~p, Q: ~p", [BlobId, base64url:encode(Key), Q]),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("Share Id: ~p, UserAgent ~p Platform: ~p, IP: ~p", [BlobId, UserAgent, Platform, IP]),
        case fetch_share_post(BlobId) of
            {ok, EncBlobWithMac} ->
                case util_crypto:decrypt_blob(EncBlobWithMac, Key, ?SHARE_POST_HKDF_INFO) of
                    {ok, Blob} ->
                        show_post_content(BlobId, Blob);
                    {error, CryptoReason} ->
                        show_crypto_error(BlobId, CryptoReason)
                end;
            {error, not_found} ->
                ?INFO("Share Post Id: ~p not found ", [BlobId]),
                show_expired_error(BlobId)
        end
    catch
        error : empty_key ->
            ?INFO("Empty Key", []),
            util_http:return_400();
        error : {bad_key, K1} ->
            ?INFO("Bad Key: ~p", [K1]),
            util_http:return_400();
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process([], Request) ->
    ?INFO("404 Empty Share Id, r:~p", [Request]),
    util_http:return_404();

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

decode_key(<<>>) ->
    error(empty_key);
decode_key(K) ->
    try
        base64url:decode(K)
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            error({bad_key, K})
    end.

show_post_content(BlobId, Blob) ->
    try enif_protobuf:decode(Blob, pb_client_post_container) of
        #pb_client_post_container{post = Post} ->
            Content = case Post of
                #pb_client_text{} = Text ->
                      ?INFO("Text BlobId: ~p success", [BlobId]),
                      {ok, HtmlPage} = show_text_post_content(Text),
                      HtmlPage;
                #pb_client_album{} = Album ->
                      ?INFO("Album BlobId: ~p success", [BlobId]),
                      {ok, HtmlPage} = show_album_post_content(Album),
                      HtmlPage;
                _ -> 
                      ?INFO("Non Text/Album BlobId: ~p success", [BlobId]),
                      json_encode(Blob)
            end,
            {200, ?HEADER(?CT_HTML), Content}
    catch Class : Reason : St ->
        ?ERROR("Failed to parse share post, BlobId: ~p, err: ~p",
            [BlobId, lager:pr_stacktrace(St, {Class, Reason})]),
        HtmlPage = <<?HTML_PRE/binary, <<"Post Container Parse Error">>/binary, ?HTML_POST/binary>>,
        {200, ?HEADER(?CT_HTML), HtmlPage}    end.

show_text_post_content(#pb_client_text{text = Text, mentions = undefined, link = undefined}) ->
    dtl_text_post:render([{title, Text}]);
show_text_post_content(#pb_client_text{text = Text, mentions = Mentions, link = undefined}) ->
    dtl_text_post:render([{title, Text}, {mentions, Mentions}]);
show_text_post_content(#pb_client_text{text = Text, mentions = undefined, link = Link}) ->
    dtl_text_post:render([{title, Text}, {link, Link}]);
show_text_post_content(#pb_client_text{text = Text, mentions = Mentions, link = Link}) ->
    dtl_text_post:render([{title, Text}, {mentions, Mentions}, {link, Link}]).

show_album_post_content(#pb_client_album{text = undefined, media = Media, voice_note = undefined}) ->
    dtl_album_post:render([{media, Media}]);
show_album_post_content(#pb_client_album{text = undefined, media = Media, voice_note = Voice}) ->
    dtl_album_post:render([{media, Media}, {voice, Voice}]);
show_album_post_content(#pb_client_album{text = Text, media = Media, voice_note = undefined}) ->
    dtl_album_post:render([{text, Text}, {media, Media}]);
show_album_post_content(#pb_client_album{text = Text, media = Media, voice_note = Voice}) ->
    dtl_album_post:render([{text, Text}, {media, Media}, {voice, Voice}]).

json_encode(PBBin) ->
    DecodedMessage = clients:decode_msg(PBBin, pb_client_post_container),
    EJson = clients:to_json(DecodedMessage),
    jiffy:encode(EJson).

show_crypto_error(BlobId, Reason) ->
    ?ERROR("BlobId: ~p, Crypto Error: ~p", [BlobId, Reason]),
    ReasonBin = util:to_binary(io_lib:format("~p", [Reason])),
    HtmlPage = <<?HTML_PRE/binary, <<"Crypto Error: ">>/binary, ReasonBin/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

show_expired_error(BlobId) ->
    ?INFO("BlobId: ~p, Expired", [BlobId]),
    HtmlPage = <<?HTML_PRE/binary, <<"Post Expired">>/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

fetch_share_post(BlobId) ->
    case model_feed:get_external_share_post(BlobId) of
        {ok, undefined} -> {error, not_found};
        {ok, Payload} -> {ok, Payload}
    end. 


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    erlydtl:compile_file(
        filename:join(misc:dtl_dir(), "text_post.dtl"),
        dtl_text_post,
        [
            {record_info, [
                {pb_client_mention, record_info(fields, pb_client_mention)},
                {pb_client_link, record_info(fields, pb_client_link)},
                {pb_client_image, record_info(fields, pb_client_image)},
                {pb_client_encrypted_resource, record_info(fields, pb_client_encrypted_resource)}
            ]}
        ]
    ),
    erlydtl:compile_file(
        filename:join(misc:dtl_dir(), "album_post.dtl"),
        dtl_album_post,
        [
            {record_info, [
                {pb_client_text, record_info(fields, pb_client_text)},
                {pb_client_mention, record_info(fields, pb_client_mention)},
                {pb_client_link, record_info(fields, pb_client_link)},
                {pb_client_album_media, record_info(fields, pb_client_album_media)},
                {pb_client_voice_note, record_info(fields, pb_client_voice_note)},
                {pb_client_encrypted_resource, record_info(fields, pb_client_encrypted_resource)}
            ]}
        ]
    ),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

%% -------------------------------------------------------------------------------
%% Test Code Below.
%% -------------------------------------------------------------------------------

-define(SOME_TEXT, "text").
-define(SOME_INDEX, 1).
-define(SOME_USERID, "123").
-define(SOME_USERNAME, "john").
-define(SOME_URL, "https://www.halloapp.com").
-define(SOME_URL_TITLE, "HalloApp Inc.").
-define(SOME_URL_DESC, "Real Content from Real Friends").
-define(SOME_WIDTH, 100).
-define(SOME_HEIGHT, 400).
-define(SOME_DOWNLOAD_URL, "https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png").
-define(SOME_KEY, <<"enc_key">>).
-define(SOME_HASH, <<"enc_hash">>).

construct_text_post() ->
    Text = construct_text(),
    #pb_client_post_container{post = Text}.

construct_text_post_no_preview() ->
    Text = construct_text_no_preview(),
    #pb_client_post_container{post = Text}.

construct_album_post() ->
    Text = construct_text(),
    AlbumMedia = construct_image_media(),
    #pb_client_post_container{post = #pb_client_album{text = Text, media = [AlbumMedia]}}.

construct_voice_post() ->
    VoiceNote = construct_voice_note(),
    #pb_client_post_container{post = VoiceNote}.

construct_text() ->
    Mention = #pb_client_mention{index = ?SOME_INDEX, user_id = ?SOME_USERID, name = ?SOME_USERNAME},
    Link = #pb_client_link{url = ?SOME_URL, title = ?SOME_URL_TITLE, description = ?SOME_URL_DESC,
        preview = [construct_image()]},
    #pb_client_text{text = ?SOME_TEXT, mentions = [Mention], link = Link}.

construct_text_no_preview() ->
    Mention = #pb_client_mention{index = ?SOME_INDEX, user_id = ?SOME_USERID, name = ?SOME_USERNAME},
    Link = #pb_client_link{url = ?SOME_URL, title = ?SOME_URL_TITLE, description = ?SOME_URL_DESC},
    #pb_client_text{text = ?SOME_TEXT, mentions = [Mention], link = Link}.

construct_image_media() ->
    #pb_client_album_media{media = construct_image()}.

construct_image() ->
    #pb_client_image{width = ?SOME_WIDTH, height = ?SOME_HEIGHT,
        img = construct_encrypted_resource()}.

construct_voice_note() ->
    #pb_client_voice_note{audio = construct_encrypted_resource()}. 

construct_encrypted_resource() ->
    #pb_client_encrypted_resource{download_url = ?SOME_DOWNLOAD_URL, encryption_key = ?SOME_KEY,
        ciphertext_hash = ?SOME_HASH}.

