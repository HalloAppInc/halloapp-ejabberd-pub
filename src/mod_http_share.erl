%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for sharing HalloApp Post
%%% @end
%%%-------------------------------------------------------------------
-module(mod_http_share).
-author("vipin").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("clients.hrl").

-define(INVITE_SUBDOMAIN, <<"https://share.halloapp.com/share/ID?k=KEY">>).
-define(HALLOAPP_CDN_URL, "https://u-cdn.halloapp.net").
-define(HKDF_INFO, <<"HalloApp Share Post">>).
-define(HKDF_SECRET_SIZE, 80).
-define(IV_LENGTH_BYTES, 16).
-define(AESKEY_LENGTH_BYTES, 32).
-define(HMACKEY_LENGTH_BYTES, 32).
-define(HMAC_LENGTH_BYTES, 32).
-define(HTML_PRE, <<"<html><body>">>).
-define(HTML_POST, <<"</body></html>">>).

%% API
-export([process/2]).

%% TODO(vipin): Figure out redirect so that share.halloapp.com points
%% to api.halloapp.com/share

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /share/id
process([ShareId],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        Key = base64url:decode(proplists:get_value(<<"k">>, Q, <<>>)),
        %% TODO(vipin): Need to remove the debug.
        ?DEBUG("Share Id: ~p, Key: ~p", [ShareId, Key]),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("Share Id: ~p, UserAgent ~p Platform: ~p, IP: ~p", [ShareId, UserAgent, Platform, IP]),
        URL = ?HALLOAPP_CDN_URL ++ "/" ++ ShareId,
        case fetch_url(URL) of
            {ok, EncBlobWithMac} ->
                Secret = hkdf:derive_secrets(sha256, Key, ?HKDF_INFO, ?HKDF_SECRET_SIZE),
                <<IV:?IV_LENGTH_BYTES/binary, AESKey:?AESKEY_LENGTH_BYTES/binary,
                    HMACKey:?HMACKEY_LENGTH_BYTES/binary>> = Secret,
                EncBlobSize = byte_size(EncBlobWithMac) - ?HMAC_LENGTH_BYTES,
                <<EncBlob:EncBlobSize/binary, Mac/binary>> = EncBlobWithMac,
                Blob = crypto:block_decrypt(aes_cbc256, AESKey, IV, EncBlob),
                ComputedMac = crypto:mac(hmac, sha256, HMACKey, EncBlob),
                IsMacMatch = Mac =:= ComputedMac,
                case IsMacMatch of
                    true ->
                        show_post_content(Blob);
                    false ->
                        show_crypto_error()
                end;
            {error, not_found} ->
                ?INFO("URL: ~p not found ", [URL]),
                show_expired_error();
            {error, FetchError} ->
                ?INFO("URL: ~p, returned error: ~p", [URL, FetchError]),
                util_http:return_500()
        end
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process([], Request) ->
    ?INFO("404 Empty Share Id, r:~p", [Request]),
    util_http:return_404();

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().


show_post_content(Blob) ->
    try enif_protobuf:decode(Blob, pb_client_post_container) of
        #pb_client_post_container{} = PostContainer ->
        %% TODO(vipin): Need to render the PostContainer
        PostContainerBin = util:to_binary(io_lib:format("~p", [PostContainer])),
        HtmlPage = <<?HTML_PRE/binary, PostContainerBin/binary, ?HTML_POST/binary>>,
        {200, ?HEADER(?CT_HTML), HtmlPage}
    catch Class : Reason : St ->
        ?ERROR("Failed to parse post container: ~p", [lager:pr_stacktrace(St, {Class, Reason})]),
        HtmlPage = <<?HTML_PRE/binary, <<"Post Container Parse Error">>/binary, ?HTML_POST/binary>>,
        {200, ?HEADER(?CT_HTML), HtmlPage}
    end.

show_crypto_error() ->
    HtmlPage = <<?HTML_PRE/binary, <<"Crypto Error">>/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

show_expired_error() ->
    HtmlPage = <<?HTML_PRE/binary, <<"Post Expired">>/binary, ?HTML_POST/binary>>,
    {200, ?HEADER(?CT_HTML), HtmlPage}.

fetch_url(URL) ->
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

