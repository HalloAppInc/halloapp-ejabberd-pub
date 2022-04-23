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
-include("server.hrl").
-include("share_post.hrl").
-include("time.hrl").
-include("account.hrl").

-define(HOTSWAP_DTL_PATH, "/home/ha/pkg/ejabberd/current/lib/zzz_hotswap/dtl").
-define(NOT_FOUND_DTL, "not_found.dtl").
-define(NOKEY_POST_DTL, "nokey_post.dtl").
-define(TEXT_POST_DTL, "text_post.dtl").
-define(ALBUM_POST_DTL, "album_post.dtl").
-define(GROUP_INVITE_DTL, "group_invite.dtl").
-define(BOLD_CONTROL_TAG1, "--b--").
-define(BOLD_CONTROL_TAG1_LEN, length(?BOLD_CONTROL_TAG1)).
-define(BOLD_CONTROL_TAG2, "--/b--").
-define(BOLD_CONTROL_TAG2_LEN, length(?BOLD_CONTROL_TAG2)).
-define(BOLD_CONTROL_TAG_LEN, ?BOLD_CONTROL_TAG1_LEN + ?BOLD_CONTROL_TAG2_LEN).

-define(BOLD_HTML_TAG1, "<b>").
-define(BOLD_HTML_TAG2, "</b>").


%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

%% for testing.
-export([
    store_text_post/0,
    fetch_share_post/1,
    store_text_post_no_preview/0,
    construct_text_post/0,
    construct_text_post_no_preview/0,
    construct_album_post/0,
    construct_voice_post/0,
    construct_image_media/0,
    construct_voice_note/0,
    construct_encrypted_resource/0,
    show_post_content/3,
    convert_to_html/2,
    incorporate_mentions/2,
    incorporate_markdown/1,
    escape_html/1,
    get_push_name_and_avatar/1
]).

-define(APPLE_APP_SITE_ASSOCIATION, <<"apple-app-site-association">>).
-define(ASSET_LINKS, <<"assetlinks.json">>).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /share_post/.well-known
process([<<".well-known">>, FileBin], #request{method = 'GET'} = _R)
        when FileBin =:= ?APPLE_APP_SITE_ASSOCIATION orelse FileBin =:= ?ASSET_LINKS ->
    try
        ?INFO("Well known, file: ~s", [FileBin]),
        FileName = filename:join(misc:share_post_dir(), FileBin),
        {200, [?CT_JSON], {file, FileName}}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

%% /share_post/appclip
process([<<"appclip">>], #request{method = 'GET', q = Q} = _R) ->
    try
        GroupInviteToken = proplists:get_value(<<"g">>, Q, <<>>),
        ?INFO("Group invite token: ~s", [GroupInviteToken]),
        HtmlPage = case mod_groups:web_preview_invite_link(GroupInviteToken) of
            {error, invalid_invite} ->
                ?INFO("Invalid Group invite token: ~s", [GroupInviteToken]),
                {ok, HtmlPage1} = dtl_group_invite:render([]),
                HtmlPage1;
            {ok, Name, null} ->
                {ok, HtmlPage2} = dtl_group_invite:render([
                    {group_name, Name},
                    {group_icon, <<"/images/appicon.png">>}
                ]),
                HtmlPage2;
             {ok, Name, Avatar} ->
                {ok, HtmlPage3} = dtl_group_invite:render([
                    {group_name, Name},
                    {group_icon, <<<<"https://avatar-cdn.halloapp.net/">>/binary, Avatar/binary>>}
                ]),
                HtmlPage3
        end,
        {200, [?CT_HTML], HtmlPage}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

%% /share_post/id
process([Path],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        URIMap = uri_string:parse(Path),
        Fragment = maps:get(fragment, URIMap, <<>>),
        case Fragment of
            <<>> -> ok;
            _ -> ?ERROR("Got uri fragment: ~s, shouldn't have received it on server", [Fragment])
        end,
        BlobId = maps:get(path, URIMap, <<>>),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("Share Id: ~p, UserAgent ~p Platform: ~p, IP: ~p", [BlobId, UserAgent, Platform, IP]),
        EncodedKey = proplists:get_value(<<"k">>, Q, <<>>),
        Format = proplists:get_value(<<"format">>, Q, <<>>),
        case EncodedKey of
            <<>> -> show_blob_nokey(BlobId, Format);
            _ -> show_blob(BlobId, EncodedKey)
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

show_blob(BlobId, EncodedKey) ->
    Key = decode_key(EncodedKey),
    %% TODO(vipin): Need to remove the debug.
    ?DEBUG("Share Id: ~p, Key: ~p", [BlobId, base64url:encode(Key)]),
    case fetch_share_post(BlobId) of
        {ok, Uid, EncBlobWithMac, _OgTagInfo} ->
            case util_crypto:decrypt_blob(EncBlobWithMac, Key, ?SHARE_POST_HKDF_INFO) of
                {ok, Blob} ->
                    show_post_content(BlobId, Blob, Uid);
                {error, CryptoReason} ->
                    show_crypto_error(BlobId, CryptoReason)
            end;
        {error, Reason} ->
            ?INFO("Share Post Id: ~p not found ", [BlobId]),
            show_expired_error(BlobId, Reason, <<>>)
    end.

show_blob_nokey(BlobId, Format) ->
    case fetch_share_post(BlobId) of
        {ok, Uid, EncBlobWithMac, OgTagInfo} ->
            show_encrypted_post_content(BlobId, EncBlobWithMac, Uid, OgTagInfo, Format);
        {error, Reason} ->
            ?INFO("Share Post Id: ~p not found ", [BlobId]),
            show_expired_error(BlobId, Reason, Format)
    end.
 
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

show_post_content(BlobId, Blob, Uid) ->
    {PushName, Avatar} = get_push_name_and_avatar(Uid),
    case enif_protobuf:decode(Blob, pb_client_post_container) of
         {error, Reason} ->
            ?ERROR("Failed to parse share post, BlobId: ~p, err: ~p", [BlobId, Reason]),
            HtmlPage = <<?HTML_PRE/binary, <<"Post Container Parse Error">>/binary, ?HTML_POST/binary>>,
            {200, ?HEADER(?CT_HTML), HtmlPage};
         #pb_client_post_container{post = Post} ->
            Content = case Post of
                #pb_client_text{} = Text ->
                      ?INFO("BlobId: ~p, Uid: ~p, Push Name: ~p, Avatar: ~p success",
                          [BlobId, Uid, PushName, Avatar]),
                      {ok, HtmlPage} = show_text_post_content(Text, PushName, Avatar),
                      HtmlPage;
                #pb_client_album{} = Album ->
                      ?INFO("Album BlobId: ~p success", [BlobId]),
                      %% TODO(vipin): Incorporate PushName and Avatar
                      {ok, HtmlPage} = show_album_post_content(Album),
                      HtmlPage;
                _ -> 
                      ?INFO("Non Text/Album BlobId: ~p success", [BlobId]),
                      json_encode(Blob)
            end,
            {200, ?HEADER(?CT_HTML), Content}
    end.

show_encrypted_post_content(BlobId, EncBlob, Uid, undefined, Format) ->
    ?INFO("Encrypted BlobId: ~p success", [BlobId]),
    {PushName, Avatar} = get_push_name_and_avatar(Uid),
    case Format of
        <<"pb">> ->
            Res = #pb_external_share_post_container{
                uid = Uid,
                name = PushName,
                avatar_id = Avatar,
                blob = EncBlob
            },
            {200, ?HEADER(?CT_BIN), enif_protobuf:encode(Res)};
        <<>> -> 
            {ok, HtmlPage} = dtl_nokey_post:render([
                {push_name, PushName}, {avatar, Avatar}, {enc_blob, EncBlob},
                {base64_enc_blob, base64url:encode(EncBlob)}
            ]),
            {200, ?HEADER(?CT_HTML), HtmlPage}
    end;

show_encrypted_post_content(BlobId, EncBlob, Uid, #pb_og_tag_info{
      title = Title, description = Descr, thumbnail_url = Thumbnail,
      thumbnail_width = Width, thumbnail_height = Height} = OgTagInfo, Format) ->
    ?INFO("Encrypted BlobId: ~p success", [BlobId]),
    {PushName, Avatar} = get_push_name_and_avatar(Uid),
    case Format of
        <<"pb">> ->
            Res = #pb_external_share_post_container{
                uid = Uid,
                name = PushName,
                avatar_id = Avatar,
                blob = EncBlob,
                og_tag_info = OgTagInfo
            },
            {200, ?HEADER(?CT_BIN), enif_protobuf:encode(Res)};
        _ ->
            {ok, HtmlPage} = dtl_nokey_post:render([
                {title, Title}, {description, Descr}, {thumbnail_url, Thumbnail},
                {thumbnail_width, Width}, {thumbnail_height, Height},
                {push_name, PushName}, {avatar, Avatar}, {enc_blob, EncBlob},
                {base64_enc_blob, base64url:encode(EncBlob)}
            ]),
            {200, ?HEADER(?CT_HTML), HtmlPage}
    end.

get_push_name_and_avatar(Uid) ->
    case model_accounts:get_account(Uid) of
        {ok, Account} ->
            {Account#account.name, Account#account.avatar_id};
        {error, missing} ->
            {undefined, undefined}
    end.

show_text_post_content(#pb_client_text{text = Text, mentions = undefined, link = undefined},
        PushName, Avatar) ->
    EscText = escape_html(util:to_list(Text)),
    dtl_text_post:render([{title, EscText}, {push_name, PushName}, {avatar, Avatar}]);
show_text_post_content(#pb_client_text{text = Text, mentions = Mentions, link = undefined},
        PushName, Avatar) ->
    FinText = convert_to_html(util:to_list(Text), Mentions),
    dtl_text_post:render([{title, FinText}, {push_name, PushName}, {avatar, Avatar}]);
show_text_post_content(#pb_client_text{text = Text, mentions = undefined, link = Link},
        PushName, Avatar) ->
    EscText = escape_html(util:to_list(Text)),
    dtl_text_post:render([{title, EscText}, {push_name, PushName}, {avatar, Avatar}, {link, Link}]);
show_text_post_content(#pb_client_text{text = Text, mentions = Mentions, link = Link},
        PushName, Avatar) ->
    FinText = convert_to_html(util:to_list(Text), Mentions),
    dtl_text_post:render([{title, FinText}, {push_name, PushName}, {avatar, Avatar}, {link, Link}]).

show_album_post_content(#pb_client_album{text = undefined, media = Media, voice_note = undefined}) ->
    dtl_album_post:render([{media, Media}]);
show_album_post_content(#pb_client_album{text = undefined, media = Media, voice_note = Voice}) ->
    dtl_album_post:render([{media, Media}, {voice, Voice}]);
show_album_post_content(#pb_client_album{text = Text, media = Media, voice_note = undefined}) ->
    dtl_album_post:render([{text, Text}, {media, Media}]);
show_album_post_content(#pb_client_album{text = Text, media = Media, voice_note = Voice}) ->
    dtl_album_post:render([{text, Text}, {media, Media}, {voice, Voice}]).

convert_to_html(Text, Mentions) ->
    NewText = incorporate_mentions(Text, Mentions),
    NewText2 = incorporate_markdown(NewText),
    EscText = escape_html(NewText2),
    Text1 = string:replace(EscText, ?BOLD_CONTROL_TAG1, ?BOLD_HTML_TAG1, all),
    lists:flatten(string:replace(Text1, ?BOLD_CONTROL_TAG2, ?BOLD_HTML_TAG2, all)).

%% Implement: https://github.com/HalloAppInc/server/blob/master/doc/mentions.md
incorporate_mentions(Text, Mentions) ->
    SortedMentions = lists:sort(
        fun(#pb_client_mention{index = Index1}, #pb_client_mention{index = Index2}) ->
            Index1 =< Index2
        end, Mentions),
    {NewText, _AdditionalBytes} = lists:foldl(
        fun(#pb_client_mention{index = Index, user_id = _UserId, name = UserName},
                {OldText, OldAdditionalBytes}) ->
            BeforeText = util:to_list(string:slice(OldText, 0, Index + OldAdditionalBytes)),
            AfterText = util:to_list(string:slice(OldText, Index + OldAdditionalBytes + 1)),
            NewText = BeforeText ++ ?BOLD_CONTROL_TAG1 ++ "@" ++ util:to_list(UserName)
                ++ ?BOLD_CONTROL_TAG2 ++ AfterText,
            NewAdditionalBytes = OldAdditionalBytes + string:length(UserName) + ?BOLD_CONTROL_TAG_LEN,
            {NewText, NewAdditionalBytes}
        end, {Text, 0}, SortedMentions),
    NewText.

%% TODO(vipin): Implement.
incorporate_markdown(Text) ->
  Text.

escape_html(Text) ->
  lists:flatten(lists:map(fun escape/1, Text)).

escape($<) -> "&lt;";
escape($>) -> "&gt;";
escape($&) -> "&amp;";
escape($") -> "&quot;";
escape(C) -> C.

json_encode(PBBin) ->
    DecodedMessage = clients:decode_msg(PBBin, pb_client_post_container),
    EJson = clients:to_json(DecodedMessage),
    jiffy:encode(EJson).

show_crypto_error(BlobId, Reason) ->
    ?ERROR("BlobId: ~p, Crypto Error: ~p", [BlobId, Reason]),
    ReasonBin = util:to_binary(io_lib:format("~p", [Reason])),
    HtmlPage = <<?HTML_PRE/binary, <<"Crypto Error: ">>/binary, ReasonBin/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

show_expired_error(BlobId, Reason, Format) ->
    ?INFO("BlobId: ~p, Expired", [BlobId]),
    case Format of
        <<"pb">> ->
            Res = #pb_error_stanza{reason = util:to_binary(Reason)},
            {410, ?HEADER(?CT_BIN), enif_protobuf:encode(Res)};
         _ ->
            {ok, HtmlPage} = dtl_not_found:render([]),
            {410, ?HEADER(?CT_HTML), HtmlPage}
    end.

fetch_share_post(BlobId) ->
    case mod_external_share_post:get_share_post(BlobId) of
        {error, Reason} ->
            ?INFO("Get share post: ~p, error: ~p", [BlobId, Reason]),
            {error, not_found};
        {ok, #pb_external_share_post_container{
                uid = Uid, blob = Blob, og_tag_info = OgTagInfo}} ->
            {ok, Uid, Blob, OgTagInfo}
    end. 


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    load_templates(),
    ok.

load_templates() ->
    GroupInvitePath = dtl_path(?HOTSWAP_DTL_PATH, ?GROUP_INVITE_DTL),
    ?INFO("Loading group invite template: ~s", [GroupInvitePath]),
    erlydtl:compile_file(
        GroupInvitePath,
        dtl_group_invite,
        [{auto_escape, false}]
    ),
    NokeyPostPath = dtl_path(?HOTSWAP_DTL_PATH, ?NOKEY_POST_DTL),
    ?INFO("Loading nokey post template: ~s", [NokeyPostPath]),
    erlydtl:compile_file(
        NokeyPostPath,
        dtl_nokey_post,
        [{auto_escape, false}]
    ),
    NotFoundPath = dtl_path(?HOTSWAP_DTL_PATH, ?NOT_FOUND_DTL),
    ?INFO("Loading not found template: ~s", [NotFoundPath]),
    erlydtl:compile_file(
        NotFoundPath,
        dtl_not_found,
        [{auto_escape, false}]
    ),
    TextPostPath = dtl_path(?HOTSWAP_DTL_PATH, ?TEXT_POST_DTL),
    ?INFO("Loading text post template: ~s", [TextPostPath]),
    erlydtl:compile_file(
        TextPostPath,
        dtl_text_post,
        [
            {auto_escape, false},
            {record_info, [
                {pb_client_mention, record_info(fields, pb_client_mention)},
                {pb_client_link, record_info(fields, pb_client_link)},
                {pb_client_image, record_info(fields, pb_client_image)},
                {pb_client_encrypted_resource, record_info(fields, pb_client_encrypted_resource)}
            ]}
        ]
    ),
    AlbumPostPath = dtl_path(?HOTSWAP_DTL_PATH, ?ALBUM_POST_DTL),
    ?INFO("Loading album post template: ~s", [AlbumPostPath]),
    erlydtl:compile_file(
        AlbumPostPath,
        dtl_album_post,
        [
            {auto_escape, false},
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
    ?INFO("reload ~w", [?MODULE]),
    load_templates(),
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

dtl_path(HotSwapDtlDir, DtlFileName) ->
    HotSwapTextPostPath = filename:join(HotSwapDtlDir, DtlFileName),
    case filelib:is_regular(HotSwapTextPostPath) of
        true -> HotSwapTextPostPath;
        false -> filename:join(misc:dtl_dir(), DtlFileName)
    end.

%% -------------------------------------------------------------------------------
%% Test Code Below.
%% -------------------------------------------------------------------------------

-define(SOME_TEXT, "Drinking Coffee with @ and @ @Starbucks").
-define(MENTION1_INDEX, 21).
-define(MENTION1_USERID, "123").
-define(MENTION1_USERNAME, "John").
-define(MENTION2_INDEX, 27).
-define(MENTION2_USERID, "321").
-define(MENTION2_USERNAME, "Tony").
-define(SOME_USERID, <<"322">>).
-define(SOME_USERNAME, <<"Don">>).
-define(SOME_PHONE, <<"16502109999">>).
-define(SOME_USER_AGENT, <<"Android">>).
-define(SOME_AVATAR_ID, <<"SOME_AVATAR">>).
-define(SOME_URL, "https://www.halloapp.com").
-define(SOME_URL_TITLE, "HalloApp Inc.").
-define(SOME_URL_DESC, "Real Content from Real Friends").
-define(SOME_WIDTH, 100).
-define(SOME_HEIGHT, 400).
-define(SOME_DOWNLOAD_URL, "https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png").
-define(SOME_KEY, <<"enc_key">>).
-define(SOME_HASH, <<"enc_hash">>).

store_text_post() ->
    store_blob(enif_protobuf:encode(construct_text_post())).

store_text_post_no_preview() ->
    store_blob(enif_protobuf:encode(construct_text_post_no_preview())).

store_blob(Blob) ->
    {ok, Key, EncBlob} = util_crypto:encrypt_blob(Blob, 15, ?SHARE_POST_HKDF_INFO),
    ok = model_accounts:create_account(?SOME_USERID, ?SOME_PHONE, ?SOME_USERNAME, ?SOME_USER_AGENT),
    ok = model_accounts:set_avatar_id(?SOME_USERID, ?SOME_AVATAR_ID),
    {ok, BlobId} = mod_external_share_post:store_share_post(?SOME_USERID, EncBlob, 4 * ?WEEKS, 1),
    ?INFO("Stored Text Blob, id: ~s, key: ~s", [BlobId, base64url:encode(Key)]).

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
    Mention1 = #pb_client_mention{index = ?MENTION1_INDEX, user_id = ?MENTION1_USERID, name = ?MENTION1_USERNAME},
    Mention2 = #pb_client_mention{index = ?MENTION2_INDEX, user_id = ?MENTION2_USERID, name = ?MENTION2_USERNAME},
    Link = #pb_client_link{url = ?SOME_URL, title = ?SOME_URL_TITLE, description = ?SOME_URL_DESC,
        preview = [construct_image()]},
    #pb_client_text{text = ?SOME_TEXT, mentions = [Mention1, Mention2], link = Link}.

construct_text_no_preview() ->
    Mention1 = #pb_client_mention{index = ?MENTION1_INDEX, user_id = ?MENTION1_USERID, name = ?MENTION1_USERNAME},
    Mention2 = #pb_client_mention{index = ?MENTION2_INDEX, user_id = ?MENTION2_USERID, name = ?MENTION2_USERNAME},
    Link = #pb_client_link{url = ?SOME_URL, title = ?SOME_URL_TITLE, description = ?SOME_URL_DESC},
    #pb_client_text{text = ?SOME_TEXT, mentions = [Mention1, Mention2], link = Link}.

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

