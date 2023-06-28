%%%-------------------------------------------------------------------
%%% File    : mod_auth_monitor.erl
%%%
%%% copyright (C) 2020, HalloApp, Inc
%%%
%%%-------------------------------------------------------------------

-module(mod_auth_monitor).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ha_types.hrl").
-include("logger.hrl").
-include("time.hrl").
-include("proc.hrl").

-type queue() :: erlang:queue().
-record(state,
{
    authq :: queue(),
    is_auth_service_normal :: boolean()
}).
-type state() :: #state{}.
-type c2s_state() :: xmpp_stream_in:state().

-define(LOGIN_THRESHOLD_N, 10).    %% Need to update this as we scale.
-define(AUTH_ALERT_MESSAGE, <<"In order to restore the service, run: 'ejabberdctl reset_auth_service'">>).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    process_auth_result/3,
    is_auth_service_normal/0,
    reset_auth_service/0
]).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         gen_mod api                             %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    %% HalloApp
    ejabberd_hooks:add(pb_c2s_auth_result, halloapp, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:add(c2s_auth_result, halloapp, ?MODULE, process_auth_result, 50),
    %% Katchup
    ejabberd_hooks:add(pb_c2s_auth_result, katchup, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:add(c2s_auth_result, katchup, ?MODULE, process_auth_result, 50),
    %% Photo Sharing
    ejabberd_hooks:add(pb_c2s_auth_result, ?PHOTO_SHARING, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:add(c2s_auth_result, ?PHOTO_SHARING, ?MODULE, process_auth_result, 50),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    %% HalloApp
    ejabberd_hooks:delete(pb_c2s_auth_result, halloapp, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:delete(c2s_auth_result, halloapp, ?MODULE, process_auth_result, 50),
    %% Katchup
    ejabberd_hooks:delete(pb_c2s_auth_result, katchup, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:delete(c2s_auth_result, katchup, ?MODULE, process_auth_result, 50),
    %% Photo Sharing
    ejabberd_hooks:delete(pb_c2s_auth_result, ?PHOTO_SHARING, ?MODULE, process_auth_result, 50),
    ejabberd_hooks:delete(c2s_auth_result, ?PHOTO_SHARING, ?MODULE, process_auth_result, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].



-spec process_auth_result(State :: c2s_state(),
        Result :: true | {false, binary()}, Uid :: binary()) -> c2s_state().
process_auth_result(State, true, Uid) ->
    TimestampMs = util:now_ms(),
    gen_server:cast(?PROC(), {auth_success, Uid, TimestampMs}),
    State;
process_auth_result(State, {false, _Reason}, Uid) ->
    TimestampMs = util:now_ms(),
    gen_server:cast(?PROC(), {auth_failure, Uid, TimestampMs}),
    State.


-spec is_auth_service_normal() -> boolean().
is_auth_service_normal() ->
    gen_server:call(?PROC(), is_auth_service_normal).


-spec reset_auth_service() -> ok.
reset_auth_service() ->
    gen_server:call(?PROC(), reset_auth_service).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                     gen_server callbacks                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


init([_Host|_]) ->
    ?INFO("Start: ~p", [?MODULE]),
    {ok, #state{authq = queue:new(), is_auth_service_normal = true}}.


terminate(_Reason, _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    ok.


handle_call(is_auth_service_normal, _From,
        #state{is_auth_service_normal = IsAuthServiceNormal} = State) ->
    {reply, IsAuthServiceNormal, State};

handle_call(reset_auth_service, _From, State) ->
    NewState = State#state{is_auth_service_normal = true},
    ?INFO("reset_service, old_state: ~p, new_state: ~p", [State, NewState]),
    {reply, ok, NewState};

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({Result, Uid, TimestampMs}, #state{authq = AuthQueue} = State)
        when Result =:= auth_success; Result =:= auth_failure ->
    NewAuthQueue = clean_insert_into_queue({Result, Uid, TimestampMs}, AuthQueue),
    NewState = State#state{authq = NewAuthQueue},
    FinalState = monitor_auth_state(NewState),
    {noreply, FinalState};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


-spec monitor_auth_state(State :: state()) -> state().
monitor_auth_state(#state{authq = AuthQueue} = State) ->
    AuthList = queue:to_list(AuthQueue),
    NewState = case did_recent_logins_fail(AuthList) of
        true ->
            ?CRITICAL("Too many login failures in the last ~p attemps", [?LOGIN_THRESHOLD_N]),
            ok = alerts:send_alert(<<"login_failure">>, <<"AuthService">>,
                    <<"critical">>, ?AUTH_ALERT_MESSAGE),
            State#state{is_auth_service_normal = false};
        false -> State
    end,
    NewState.


-spec did_recent_logins_fail(AuthList :: list()) -> boolean().
did_recent_logins_fail(AuthList) ->
    LastnAuthList = lists:sublist(AuthList, ?LOGIN_THRESHOLD_N),
    {_SuccessCount, FailureCount, _} = lists:foldl(
        fun({Res, Uid, _TimestampMs}, {SuccessCount, FailureCount, UidSet} = Acc) ->
            case sets:is_element(Uid, UidSet) of
                true -> Acc;
                false ->
                    NewUidSet = sets:add_element(Uid, UidSet),
                    case Res of
                        auth_success -> {SuccessCount + 1, FailureCount, NewUidSet};
                        auth_failure -> {SuccessCount, FailureCount + 1, NewUidSet}
                    end
            end
        end, {0, 0, sets:new()}, LastnAuthList),
    FailureCount > (?LOGIN_THRESHOLD_N / 2).


clean_insert_into_queue({_Result, Uid1, _TimestampMs} = Item, AuthQueue) ->
    AuthList = queue:to_list(AuthQueue),
    NewAuthList = lists:dropwhile(
        fun ({_, Uid2, _}) ->
            Uid1 =:= Uid2
        end, AuthList),
    Len = length(AuthList),
    FinalAuthList = case Len > ?LOGIN_THRESHOLD_N of
        true -> lists:droplast(NewAuthList);
        false -> NewAuthList
    end,
    queue:in(Item, queue:from_list(FinalAuthList)).


