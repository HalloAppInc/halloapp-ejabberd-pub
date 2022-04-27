%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(ha_websocket).
-author("vipin").

%% API
-export([
    start/0
]).

-include("logger.hrl").

start() ->
    ?INFO("start"),
    Dispatch = cowboy_router:compile([{'_', [
        {"/_ok", cowboy_static, {priv_file, ejabberd, "data/_ok",
            [{mimetypes, {<<"text">>, <<"plain">>, []}}]}},
        {"/ws", websocket_handler, #{}}
    ]}]),
    {ok, _} = cowboy:start_clear(http, [{port, 8080}], #{env => #{dispatch => Dispatch}}),
    ?INFO("start done"),
    ok.

