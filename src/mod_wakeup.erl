%%%-------------------------------------------------------------------------------------------
%%% File    : mod_wakeup.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Monitors when a client logs on due to push notifications
%%%-------------------------------------------------------------------------------------------

-module(mod_wakeup).
-author('michelle').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("push_message.hrl").
-include("proc.hrl").
-include("time.hrl").

-define(MAX_WAKEUP_PUSH_ATTEMPTS, 9).  %% exponential time: 512 minutes = ~4.5 hours

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

-export([c2s_session_opened/1, monitor_push/2]).

 -ifdef(TEST).
 -export([
     remind_wakeup/3,
     cancel_wakeup/2,
     check_wakeup/2
 ]).
 -endif.

%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    ok.

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-spec c2s_session_opened(State :: #{}) -> ok.
c2s_session_opened(#{user := Uid} = State) ->
    gen_server:cast(?PROC(), {cancel_wakeup, Uid}),
    State.


-spec monitor_push(Uid :: binary(), Message :: pb_msg()) -> ok.
monitor_push(Uid, Message) ->
    PayloadType = util:get_payload_type(Message),
    gen_server:cast(?PROC(), {remind_wakeup, Uid, PayloadType}),
    ok.



%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Host|_]) ->
    State = #{wakeup_map => #{}},
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({remind_wakeup, Uid, PayloadType}, #{wakeup_map := WakeupMap} = State) ->
    NewWakeupMap = remind_wakeup(Uid, WakeupMap, PayloadType),
    {noreply, State#{wakeup_map => NewWakeupMap}};

handle_cast({cancel_wakeup, Uid}, #{wakeup_map := WakeupMap} = State) ->
    NewWakeupMap = cancel_wakeup(Uid, WakeupMap),    
    {noreply, State#{wakeup_map => NewWakeupMap}};

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


handle_info({check_wakeup, Uid}, #{wakeup_map := WakeupMap} = State) ->
    NewWakeupMap = check_wakeup(Uid, WakeupMap),
    {noreply, State#{wakeup_map => NewWakeupMap}};

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec remind_wakeup(Uid :: uid(), WakeupMap :: #{uid() := {integer(), integer()}},
        PayloadType :: atom()) -> #{uid() := {integer(), integer()}}.
remind_wakeup(Uid, WakeupMap, PayloadType) ->
    {PushNum, OldTRef} = maps:get(Uid, WakeupMap, {0,0}),
    case is_reference(OldTRef) of
        true -> erlang:cancel_timer(OldTRef);
        false -> ok
    end,
    NewPushNum = case PayloadType of
        pb_wake_up -> PushNum + 1;
        % Reset backoff time on normal pushes
        _ -> 0
    end,
    % Check in 1 min, 2 min, 4 min, 8 min, ... 512 minutes
    BackoffTimeMs = trunc(math:pow(2, NewPushNum) * ?MINUTES_MS),
    ?INFO("Uid: ~s, Tracking if client comes online in ~p ms
            after ~p wake up pushes", [Uid, BackoffTimeMs, NewPushNum]),
    TRef = erlang:send_after(BackoffTimeMs, self(), {check_wakeup, Uid}),
    WakeupMap#{Uid => {NewPushNum, TRef}}.


-spec cancel_wakeup(Uid :: uid(), WakeupMap :: #{uid() := {integer(), integer()}}) ->
        #{uid() := {integer(), integer()}}.
cancel_wakeup(Uid, WakeupMap) ->
    {WakeupPushNum, TRef} = maps:get(Uid, WakeupMap, {0, 0}),
    case is_reference(TRef) of
        true -> erlang:cancel_timer(TRef);
        false -> ok
    end,
    Platform = case util:is_android_user(Uid) of
        true -> android;
        false -> ios
    end,
    NewWakeupMap = case maps:take(Uid, WakeupMap) of
        {_, FinalMap} when WakeupPushNum =:= 0 -> 
            mod_push_monitor:log_push_wakeup(success, Platform),
            ?INFO("Uid ~s, Connected after normal push", [Uid]),
            FinalMap;
        {_, FinalMap} -> 
            mod_push_monitor:log_push_wakeup(success, Platform),
            ?INFO("Uid ~s, Connected after ~p wakeup pushes", [Uid, WakeupPushNum]),
            FinalMap;
        _ -> WakeupMap
    end,
    NewWakeupMap.


-spec check_wakeup(Uid :: uid(), WakeupMap :: #{uid() := {integer(), integer()}}) ->
        #{uid() := {integer(), integer()}}.
check_wakeup(Uid, WakeupMap) ->
    Platform = case util:is_android_user(Uid) of
        true -> android;
        false -> ios
    end,
    NewWakeupMap = case maps:get(Uid, WakeupMap, undefined) of
        undefined ->
            ?INFO("Uid ~s, Client connected", [Uid]),
            WakeupMap;
        {PushNum, _} when PushNum < ?MAX_WAKEUP_PUSH_ATTEMPTS ->
            mod_push_monitor:log_push_wakeup(failure, Platform),
            MsgId = util_id:new_msg_id(),
            ?INFO("Uid ~s, Did not connect within ~p minutes. Sending wakeup push #~p,
                    msgId: ~p", [Uid, math:pow(2, PushNum - 1), PushNum, MsgId]),
            Msg = #pb_msg{
                id = MsgId,
                to_uid = Uid,
                payload = #pb_wake_up{}
            },
            ejabberd_router:route(Msg),
            WakeupMap;
        {PushNum, _} ->
            mod_push_monitor:log_push_wakeup(failure, Platform),
            ?INFO("Uid ~s, Did not connect within ~p minutes after
                ~p wakeup pushes", [Uid, math:pow(2, PushNum), PushNum]),
            {_Pushes, FinalMap} = maps:take(Uid, WakeupMap),
            FinalMap
    end,
    NewWakeupMap.

