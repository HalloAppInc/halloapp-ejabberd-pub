%%%---------------------------------------------------------------------------------
%%% File    : mod_call_stats.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%%---------------------------------------------------------------------------------

-module(mod_call_stats).
-author(nikola).
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").

%% gen_mod API.
%% IQ handlers and hooks.
-export([
    start/2,
    stop/1,
    depends/2,
    mod_options/1,
    event_call/1
]).

-define(CALLS_NS, "HA/call").



start(_Host, _Opts) ->
    ejabberd_hooks:add(event_call, ?MODULE, event_call, 50),
    ok.

stop(_Host) ->
    ejabberd_hooks:delete(event_call, ?MODULE, event_call, 50),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% iq handlers
%%====================================================================

-spec event_call(Event :: pb_event_data()) -> pb_event_data().
event_call(#pb_event_data{uid = UidInt, platform = Platform, cc = CC,
        edata = #pb_call{
            call_id = CallId, peer_uid = PeerUidInt, type = CallType, answered = Answered,
            duration_ms = PBDurationMs, end_call_reason = EndCallReason,
            is_krisp_active = IsKrispActive}} = Event) ->
    Uid = util:to_binary(UidInt),
    PeerUid = util:to_binary(PeerUidInt),
    DurationMs = case PBDurationMs of
        undefined -> 0;
        _ -> PBDurationMs
    end,
    ?INFO("CallID: ~s Uid: ~s PeerUid: ~s Type: ~s Duration: ~.1fs IsKrispActive: ~p",
        [CallId, Uid, PeerUid, CallType, DurationMs / 1000, IsKrispActive]),
    PeerCC = case model_accounts:get_phone(PeerUid) of
        {ok, PeerPhone} -> mod_libphonenumber:get_cc(PeerPhone);
        % TODO(nikola) make mod_libphonenumber return ZZ?
        {error, missing} -> <<"ZZ">>
    end,
    International = (CC =:= PeerCC),
    stat:count(?CALLS_NS, "call_count", 1, [{type, CallType}]),
    stat:count(?CALLS_NS, "call_count_krisp", 1, [{type, CallType}, {is_krisp_active, IsKrispActive}]),
    stat:count(?CALLS_NS, "call_count_by_cc", 1, [{cc, CC}, {type, CallType}, {platform, Platform}]),
    stat:count(?CALLS_NS, "call_count_by_platform", 1, [{platform, Platform}]),

    stat:count(?CALLS_NS, "call_by_answered", 1,
        [{answered, Answered}, {type, CallType}, {platform, Platform}]),
    stat:count(?CALLS_NS, "end_reason", 1,
        [{end_reason, EndCallReason}, {type, CallType}, {platform, Platform}]),
    stat:count(?CALLS_NS, "call_by_int", 1, [{international, International}, {type, CallType}]),

    DurationSec = round(DurationMs / 1000),
    case DurationSec > 0 of
        true ->
            stat:count(?CALLS_NS, "call_duration_sec", DurationSec, [{type, CallType}]),
            stat:count(?CALLS_NS, "call_duration_sec_krisp", DurationSec, [{type, CallType}, {is_krisp_active, IsKrispActive}]),
            stat:count(?CALLS_NS, "call_duration_sec_by_cc", DurationSec,
                [{cc, CC}, {type, CallType}, {platform, Platform}]),
            stat:count(?CALLS_NS, "call_duration_sec_by_platform", DurationSec, [{platform, Platform}]),

            stat:count(?CALLS_NS, "call_duration_by_int", DurationSec,
                [{international, International}, {type, CallType}]);
        false ->
            ok
    end,
    Event.

