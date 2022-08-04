%%%-------------------------------------------------------------------
%%% File    : ejabberd_iq.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Purpose :
%%% Created : 10 Nov 2017 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(ejabberd_iq).

-behaviour(gen_server).

%% API
-export([start_link/0, route/4, route/5, dispatch/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-include("logger.hrl").
-include("packets.hrl").
-include("ejabberd_stacktrace.hrl").

-record(state, {expire = infinity :: timeout()}).
-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    ?INFO("start ~w", [?MODULE]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec route(iq(), atom() | pid(), term(), non_neg_integer()) -> ok.
route(#pb_iq{type = T} = IQ, Proc, Ctx, Timeout) when T == set; T == get ->
    do_route(IQ, undefined, Proc, Ctx, Timeout).

-spec route(iq(), pid(), atom() | pid(), term(), non_neg_integer()) -> ok.
route(#pb_iq{type = T} = IQ, UserPid, Proc, Ctx, Timeout) when T == set; T == get ->
    do_route(IQ, UserPid, Proc, Ctx, Timeout).

-spec do_route(iq(), pid(), atom() | pid(), term(), non_neg_integer()) -> ok.
do_route(IQ, UserPid, Proc, Ctx, Timeout) ->
    Expire = current_time() + Timeout,
    Id = util_id:new_short_id(),
    ets:insert(?MODULE, {Id, Expire, Proc, Ctx}),
    gen_server:cast(?MODULE, {restart_timer, Expire}),
    FinalIQ = pb:set_id(IQ, Id),
    case UserPid of
        undefined -> ejabberd_router:route(FinalIQ);
        _ -> halloapp_c2s:route(UserPid, {route, FinalIQ})
    end.


-spec dispatch(iq()) -> boolean().
dispatch(#pb_iq{type = T} = IQ) when T == error; T == result ->
    check_ets_and_dispatch(IQ);
dispatch(_) ->
    false.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    _ = ets:new(?MODULE, [named_table, ordered_set, public]),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    noreply(State).

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({restart_timer, Expire}, State) ->
    State1 = State#state{expire = min(Expire, State#state.expire)},
    noreply(State1);
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    noreply(State).

handle_info({route, IQ}, State) ->
    % check to see if it is pb_iq or xmpp iq
    Key = pb:get_id(IQ),
    case ets:lookup(?MODULE, Key) of
        [{_, _, Proc, Ctx}] ->
            callback(Proc, IQ, Ctx),
            ets:delete(?MODULE, Key);
        [] ->
            ok
    end,
    noreply(State);
handle_info(timeout, State) ->
    Expire = clean(ets:first(?MODULE)),
    noreply(State#state{expire = Expire});
handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    noreply(State).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec check_ets_and_dispatch(IQ :: iq()) -> boolean().
check_ets_and_dispatch(IQ) ->
    Key = pb:get_id(IQ),
    case ets:lookup(?MODULE, Key) of
        [{_, _, _, _}] ->
            ejabberd_cluster:send(?MODULE, {route, IQ});
        _ ->
            false
    end.

-spec current_time() -> non_neg_integer().
current_time() ->
    erlang:system_time(millisecond).

-spec clean({non_neg_integer(), binary()} | '$end_of_table')
       -> non_neg_integer() | infinity.
clean('$end_of_table') ->
    infinity;
clean(Key) ->
    case ets:lookup(?MODULE, Key) of
        [{_, Expire, Proc, Ctx}] ->
            case current_time() of
                Time when Time >= Expire ->
                    callback(Proc, timeout, Ctx),
                    ets:delete(?MODULE, Key),
                    clean(ets:next(?MODULE, Key));
                _ ->
                    Expire
            end;
        [] ->
            clean(ets:next(?MODULE, Key))
    end.

-spec noreply(state()) -> {noreply, state()} | {noreply, state(), non_neg_integer()}.
noreply(#state{expire = Expire} = State) ->
    case Expire of
        infinity ->
            {noreply, State};
        _ ->
            Timeout = max(0, Expire - current_time()),
            {noreply, State, Timeout}
    end.

-spec callback(atom() | pid(), iq() | timeout, term()) -> any().
callback(undefined, IQRes, Fun) ->
    try Fun(IQRes)
    catch ?EX_RULE(Class, Reason, St) ->
        StackTrace = ?EX_STACK(St),
        ?ERROR("Failed to process iq response:~n~p~n** ~ts", [
            IQRes,
            misc:format_exception(2, Class, Reason, StackTrace)])
    end;
callback(Proc, IQRes, Ctx) ->
    try
        Proc ! {iq_reply, IQRes, Ctx}
    catch _:badarg ->
        ok
    end.
