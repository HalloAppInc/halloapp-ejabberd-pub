%%%-------------------------------------------------------------------
%%% File    : mod_server_ts.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%-------------------------------------------------------------------
-module(mod_server_ts).
-behaviour(gen_mod).

-include("xmpp.hrl").
-include("logger.hrl").


%% gen_mod API.
-export([
    start/2,
    stop/1,
    reload/3,
    mod_options/1,
    depends/2
]).

%% Hooks and API.
-export([
    user_send_packet/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 25),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 25),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

user_send_packet({#message{id = MsgId} = Packet, State}) ->
    % TODO: (nikola) in pb Timestamp is integer so we will soon be able to migrate out of binary ts.
    TimestampSec = util:now_binary(),
    Packet1 = util:set_timestamp(Packet, TimestampSec),
    ?DEBUG("setting timestamp MsgId: ~s Ts: ~s", [MsgId, TimestampSec]),
    {Packet1, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.
