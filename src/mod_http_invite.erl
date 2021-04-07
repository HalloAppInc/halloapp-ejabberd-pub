%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for invites redirecting clients to the right app stores
%%% @end
%%% Created : 08. Apr 2021 11:42 AM
%%%-------------------------------------------------------------------
-module(mod_http_invite).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

-define(HALLOAPP_COM, <<"https://halloapp.com">>).
-define(PLAY_STORE_URL, <<"https://play.google.com/store/apps/details?id=com.halloapp&referrer=ginvite-">>).
-define(APP_STORE_URL, <<"https://apps.apple.com/us/app/halloapp/id1501583052">>).

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /invite
process([],
        #request{method = 'GET', q = Q, data = Data, ip = IP, headers = Headers} = _R) ->
    try
        GroupToken = proplists:get_value(<<"g">>, Q, <<>>),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        ?INFO("request Q:~p R: ~p, UserAgent ~p Platform: ~p", [Q, _R, UserAgent, Platform]),
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
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {302, [?LOCATION_HEADER(?HALLOAPP_COM)], <<"">>}
    end;

process(Path, Request) ->
    ?WARNING("Bad Request: path: ~p, r:~p", [Path, Request]),
    util_http:return_400().


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
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
