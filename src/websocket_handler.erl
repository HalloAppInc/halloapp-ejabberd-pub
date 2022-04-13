%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(websocket_handler).
-author("vipin").

-include("logger.hrl").

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).

init(Req, Opts) ->
    ?INFO("called init, ~p", [self()]),
    {cowboy_websocket, Req, Opts, #{idle_timeout => 30000}}.

websocket_init(State) ->
    ?INFO("called websocket init, ~p", [self()]),
    erlang:start_timer(1000, self(), pid_to_list(self())),
    {[], State}.

websocket_handle({text, Msg}, State) ->
    ?INFO("called websocket handle, msg: ~p, ~p", [Msg, self()]),
    {[{text, << "That's what she said! ", Msg/binary >>}], State};
websocket_handle(_Data, State) ->
    {[], State}.

websocket_info({timeout, _Ref, Msg}, State) ->
    ?INFO("called websocket info, msg: ~p, ~p", [Msg, self()]),
    erlang:start_timer(1000, self(), pid_to_list(self())),
    {[{text, Msg}], State};
websocket_info(_Info, State) ->
    {[], State}.
