%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for invites redirecting clients to the right app stores
%%% @end
%%% Created : 08. Apr 2021 11:42 AM
%%%-------------------------------------------------------------------
% TODO: does the name have to start with mod_ when this is not gen_mod
-module(mod_http_invite).
-author("nikola").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

-define(HALLOAPP_COM, <<"https://halloapp.com">>).
-define(PLAY_STORE_URL, <<"https://play.google.com/store/apps/details?id=com.halloapp&referrer=ginvite-">>).
-define(APP_STORE_URL, <<"https://apps.apple.com/us/app/halloapp/id1501583052">>).

%% API
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /invite
process([],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        GroupToken = proplists:get_value(<<"g">>, Q, <<>>),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("request Q:~p UserAgent ~p Platform: ~p, IP: ~p", [Q, UserAgent, Platform, IP]),
        Location = case Platform of
            android ->
                <<?PLAY_STORE_URL/binary, GroupToken/binary>>;
            ios ->
                <<?APP_STORE_URL/binary>>;
            unknown ->
                ?HALLOAPP_COM;
            Something ->
                ?WARNING("unexpected Platform ~p", [Something]),
                ?HALLOAPP_COM
        end,
        ?INFO("redirecting to ~p", [Location]),
        {302, [?LOCATION_HEADER(Location)], <<"">>}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {302, [?LOCATION_HEADER(?HALLOAPP_COM)], <<"">>}
    end;

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

