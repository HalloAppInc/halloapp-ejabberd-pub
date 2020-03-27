%%%----------------------------------------------------------------------
%%% File    : mod_user_activity.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles storing and retrieving activity/last seen status
%%% of all the users. We basically register for 3 hooks:
%%% set_presence_hook and unset_presence_hook:
%%% every presence update from a user is triggered here
%%% and we use it to set the activity status of that user.
%%% register_user: we register an empty activity status for the user upon
%%% registration, so that it is available immediately for others.
%%% remove_user: we remove the last known activity of the user when
%%% the user is removed from the app.
%%%----------------------------------------------------------------------

-module(mod_user_activity).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_user_activity.hrl").
-include("translate.hrl").

-type c2s_state() :: ejabberd_c2s:state().

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% hooks.
-export([set_presence_hook/4, unset_presence_hook/4, register_user/2, remove_user/2]).
%% API
-export([get_user_activity/2]).


start(Host, Opts) ->
    mod_user_activity_mnesia:init(Host, Opts),
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50).

stop(Host) ->
    mod_user_activity_mnesia:close(Host),
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% hooks
%%====================================================================

-spec register_user(binary(), binary()) -> {ok, any()} | {error, any()}.
register_user(User, Server) ->
    Status = undefined,
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    mod_user_activity_mnesia:store_user_activity(User, Server, Timestamp, Status).


%% remove_user hook deletes the last known activity of the user.
-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    mod_user_activity_mnesia:remove_user(User, Server).


-spec set_presence_hook(binary(), binary(), binary(), #presence{}) -> {ok, any()} | {error, any()}.
set_presence_hook(User, Server, _Resource, #presence{type = Type}) ->
    Status = case Type of
                available -> available;
                away -> away;
                unavailable -> away;
                _ -> away
            end,
    store_user_activity(User, Server, Status).


-spec unset_presence_hook(binary(), binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
unset_presence_hook(User, Server, _Resource, _PStatus) ->
    Status = away,
    store_user_activity(User, Server, Status).


-spec store_user_activity(binary(), binary(), atom()) -> {ok, any()} | {error, any()}.
store_user_activity(User, Server, Status) ->
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    mod_user_activity_mnesia:store_user_activity(User, Server, Timestamp, Status).


-spec get_user_activity(binary(), binary()) -> {binary(), atom()}.
get_user_activity(User, Server) ->
    case mod_user_activity_mnesia:get_user_activity(User, Server) of
        {ok, #user_activity{last_seen = LastSeen, status = Status}} -> {LastSeen, Status};
        {ok, undefined} -> {<<"">>, away};
        {error, _} -> {<<"">>, away}
    end.

