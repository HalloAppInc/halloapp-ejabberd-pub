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

-export([monitor_push/2]).

 -ifdef(TEST).
 -export([
     remind_wakeup/3,
     check_wakeup/2
 ]).
 -endif.

%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
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
    Now = util:now(),
    {PushNum, OldTRef, OldTs} = maps:get(Uid, WakeupMap, {0, 0, Now}),
    case is_reference(OldTRef) of
        true -> erlang:cancel_timer(OldTRef);
        false -> ok
    end,
    {NewPushNum, Ts} = case PayloadType of
        pb_wake_up -> {PushNum + 1, OldTs};
        % Reset backoff time on normal pushes
        _ -> {0, Now}
    end,
    % Check in 1 min, 2 min, 4 min, 8 min, ... 512 minutes
    BackoffTimeMs = trunc(math:pow(2, NewPushNum) * ?MINUTES_MS),
    ?INFO("Uid: ~s, Tracking if client comes online in ~p ms
            after ~p wake up pushes", [Uid, BackoffTimeMs, NewPushNum]),
    TRef = erlang:send_after(BackoffTimeMs, self(), {check_wakeup, Uid}),
    WakeupMap#{Uid => {NewPushNum, TRef, Ts}}.


-spec check_wakeup(Uid :: uid(), WakeupMap :: #{uid() := {integer(), integer()}}) ->
        #{uid() := {integer(), integer()}}.
check_wakeup(Uid, WakeupMap) ->
    Platform = case util:is_android_user(Uid) of
        true -> android;
        false -> ios
    end,
    LastActiveTime = case model_accounts:get_last_connection_time(Uid) of
        undefined -> undefined;
        LastConnectionTime -> LastConnectionTime div 1000
    end,
    NewWakeupMap = case maps:get(Uid, WakeupMap, undefined) of
        undefined ->
            WakeupMap;
        _ when LastActiveTime =:= undefined ->
            send_wakeup_push(Uid, Platform, 0),
            WakeupMap;
        {PushNum, _, PushTs} when LastActiveTime >= PushTs ->
            mod_push_monitor:log_push_wakeup(Uid, success, Platform),
            ?INFO("Uid ~s, Client connected in ~p seconds after ~p wakeup pushes", [Uid, (LastActiveTime - PushTs), PushNum]),
            WakeupMap;
        {PushNum, _, _} when PushNum < ?MAX_WAKEUP_PUSH_ATTEMPTS ->
            send_wakeup_push(Uid, Platform, PushNum),
            WakeupMap;
        {PushNum, _, _} ->
            mod_push_monitor:log_push_wakeup(Uid, failure, Platform),
            ?INFO("Uid ~s, Did not connect within ~p minutes after ~p wakeup pushes, 
                platform: ~p", [Uid, math:pow(2, PushNum), PushNum, Platform]),
            {_Pushes, FinalMap} = maps:take(Uid, WakeupMap),
            FinalMap
    end,
    NewWakeupMap.


-spec send_wakeup_push(Uid :: uid(), Platform :: atom(), PushNum :: integer()) -> ok.
send_wakeup_push(Uid, Platform, PushNum) ->
    mod_push_monitor:log_push_wakeup(Uid, failure, Platform),
    % Send 4 alert pushes, then alternate between silent and alert pushes
    AlertType = case PushNum of
        Num when Num < 4 -> alert;
        Num when Num rem 2 =:= 0 -> silent;
        _ -> alert
    end,
    MsgId = util_id:new_msg_id(),
    ?INFO("Uid ~s, Did not connect within ~p minutes. Sending wakeup push #~p, msgId: ~p type: ~p
        platform: ~p", [Uid, math:pow(2, PushNum - 1), PushNum, MsgId, AlertType, Platform]),
    Msg = #pb_msg{
        id = MsgId,
        to_uid = Uid,
        payload = #pb_wake_up{alert_type = AlertType}
    },
    ejabberd_router:route(Msg),
    ok.

