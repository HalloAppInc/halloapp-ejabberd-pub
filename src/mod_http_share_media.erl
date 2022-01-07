%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for sharing HalloApp Media
%%% @end
%%%-------------------------------------------------------------------
-module(mod_http_share_media).
-author("vipin").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("share_post.hrl").

-define(HALLOAPP_CDN_URL, "https://u-cdn.halloapp.net").

%% API
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /share_media/id
process([MediaId], #request{method = 'GET'} = R) ->
    URL = ?HALLOAPP_CDN_URL ++ "/" ++ MediaId,
    process_media(URL, R);

process([], #request{method = 'GET', q = Q} = R) ->
    URL = proplists:get_value(<<"u">>, Q, <<>>),
    process_media(URL, R);

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

process_media(URL, #request{q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        Key = base64url:decode(proplists:get_value(<<"k">>, Q, <<>>)),
        Hash = base64url:decode(proplists:get_value(<<"h">>, Q, <<>>)),
        Type = proplists:get_value(<<"t">>, Q, <<>>),
        %% TODO(vipin): Need to remove the debug.
        ?DEBUG("Media URL: ~p, Key: ~p, Hash: ~p, Type: ~p",
            [URL, base64url:encode(Key), base64url:encode(Hash), Type]),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("Media URL: ~p, Type: ~p, UserAgent ~p Platform: ~p, IP: ~p",
            [URL, Type, UserAgent, Platform, IP]),
        case fetch_object(URL) of
            {ok, EncBlobWithMac} ->
                ComputedHash = crypto:hash(sha256, EncBlobWithMac),
                case ComputedHash =:= Hash of
                    true -> decrypt_media(URL, EncBlobWithMac, Key, Type);
                    false -> show_crypto_error(URL, hash_mismatch)
                end;
            {error, not_found} ->
                show_expired_error(URL);
            {error, FetchError} ->
                ?INFO("URL: ~p, returned error: ~p", [URL, FetchError]),
                util_http:return_500()
        end
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end.

decrypt_media(URL, _EncBlobWithMac, _Key, Type) when Type =/= <<"I">> andalso Type =/= <<"V">> ->
    show_crypto_error(URL, invalid_media_type);
decrypt_media(URL, EncBlobWithMac, Key, Type) ->
    HkdfInfo = case Type of
        <<"I">> -> ?IMAGE_HKDF_INFO;
        <<"V">> -> ?VIDEO_HKDF_INFO
    end,
    %% TODO(vipin): Video needs to be de-chunked when applicable.
    case util_crypto:decrypt(EncBlobWithMac, Key, HkdfInfo) of
       {ok, Blob} ->
           show_media_content(URL, Blob);
       {error, CryptoReason} ->
           show_crypto_error(URL, CryptoReason)
    end.

show_media_content(URL, Blob) ->
    ?INFO("Media URL: ~p success ", [URL]),
    {200, ?HEADER(?CT_BIN), Blob}.

show_crypto_error(URL, Reason) ->
    ?ERROR("Media URL: ~p, Crypto Error: ~p", [URL, Reason]),
    ReasonBin = util:to_binary(Reason),
    HtmlPage = <<?HTML_PRE/binary, <<"Crypto Error: ">>/binary, ReasonBin/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

show_expired_error(URL) ->
    ?INFO("Media URL: ~p not found ", [URL]),
    HtmlPage = <<?HTML_PRE/binary, <<"Media Expired">>/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

fetch_object(URL) ->
    ?DEBUG("URL: ~s", [URL]),
    Response = httpc:request(get, {URL, []}, [], []),
    ?DEBUG("Response: ~p", [base64url:encode(Response)]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            {ok, ResBody};
        {ok, {{_, 403, _}, _, _}} ->
            ?ERROR("URL: ~s not found, Response: ~p", [URL, Response]),
            {error, not_found};
        _ ->
            ?ERROR("URL ~s, Response: ~p", [URL, Response]),
            {error, url_fail}
    end.

