%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% Module to handle client request to log events and counts.
%%% Spec: https://github.com/HalloAppInc/server/blob/master/doc/client_event_logger.md
%%% @end
%%% Created : 12. Aug 2020 10:00 AM
%%%-------------------------------------------------------------------
-module(mod_client_log).

-author('nikola').

-behaviour(gen_mod).

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([
    process_local_iq/2,
    process_client_count_log_st/3,
    json_encode/1  % test
]).


-include("logger.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("packets.hrl").
-include("proc.hrl").
-include("user_events.hrl").

-define(NS_CLIENT_LOG, <<"halloapp:client_log">>).
-define(CLIENT_NS, <<"client.">>).
-define(S3_CLIENT_LOGS_BUCKET, <<"ha-event-logs">>).
-define(CLIENT_LOGS_DIR, "event_logs").
-define(VALID_NAMESPACE_RE, "^[a-zA-Z][a-zA-Z0-9.\-/_]*$").

-type result() :: ok | {error, any()}.

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_client_log, ?MODULE, process_local_iq, 2),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_client_log, ?MODULE, process_local_iq, 2),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_client_log),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_client_log),
    ok.

depends(_Host, _Opts) ->
    [{ha_events, hard}].

mod_options(_Host) ->
    [].


% client_log
-spec process_local_iq(iq(), halloapp_c2s:state()) -> iq().
process_local_iq(#pb_iq{type = set, from_uid = Uid, payload = #pb_client_log{events = EventsDirty} = ClientLogsStDirty} = IQDirty,
        #{client_version := ClientVersion} = _State) ->
    try
        % clean all the events and replace them
        {Events, Uid} = lists:mapfoldl(fun clean_event/2, Uid, EventsDirty),
        ClientLogsSt = ClientLogsStDirty#pb_client_log{events = Events},
        IQ = IQDirty#pb_iq{payload = ClientLogsSt},
        Platform = util_ua:get_client_type(ClientVersion),
        case process_client_count_log_st(Uid, ClientLogsSt, Platform) of
            ok ->
                pb:make_iq_result(IQ);
            error ->
                pb:make_error(IQ, util:err(bad_request))
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("client log error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            pb:make_error(IQDirty, util:err(server_error))
    end;

process_local_iq(#pb_iq{} = IQ, _State) ->
    pb:make_error(IQ, util:err(bad_request)).

-spec process_client_count_log_st(Uid :: maybe(uid()), ClientLogSt :: pb_client_log(),
        Platform :: maybe(client_type())) -> ok | error.
process_client_count_log_st(Uid, ClientLogsSt, Platform) ->
    AppType = util_uid:get_app_type(Uid),
    ServerDims = [{"platform", atom_to_list(Platform)}, {"app_type", util:to_list(AppType)}],
    Counts = ClientLogsSt#pb_client_log.counts,
    Events = ClientLogsSt#pb_client_log.events,
    ?INFO("Uid: ~s counts: ~p, events: ~p", [Uid, length(Counts), length(Events)]),
    CountResults = process_counts(Uid, Counts, ServerDims),
    EventResults = process_events(Uid, Events),
    CountError = lists:any(fun has_error/1, CountResults),
    EventError = lists:any(fun has_error/1, EventResults),
    case CountError or EventError of
        true -> error;
        false -> ok
    end.


-spec process_counts(Uid :: maybe(uid()), Counts :: [pb_count()], ServerDims :: stat:tags()) -> [result()].
process_counts(Uid, Counts, ServerDims) ->
    lists:map(
        fun (C) ->
            process_count(Uid, C, ServerDims)
        end, Counts).


% TODO: validate the number of dims is < 6
% TODO: validate the name and value of each dimension
-spec process_count(Uid :: maybe(uid()), Counts :: pb_count(), ServerTags :: stat:tags()) -> result() .
process_count(Uid, #pb_count{namespace = Namespace, metric = Metric, count = Count, dims = DimsSt} = PbCount,
        ServerTags) ->
    try
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Tags = dims_st_to_tags(DimsSt),
        Tags2 = Tags ++ ServerTags,
        % TODO: make sure to override duplicate keys in Tags with ServerTags
        %% TODO(murali@): remove these logs eventually.
        ?INFO("~s, ~s, ~s, ~p, ~p", [FullNamespace, Metric, Uid, Tags2, Count]),
        HookName = util:to_atom(<<"count_", FullNamespace/binary>>),
        {Metric2, Count2, Tags3} = ejabberd_hooks:run_fold(HookName, {Metric, Count, Tags2}, []),
        stat:count(binary_to_list(FullNamespace), binary_to_list(Metric2), Count2, Tags3),
        log_count(FullNamespace, Metric2, Uid, Tags3, Count2),
        ok
    catch
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR("client count error: ~s, PbCount: ~p", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason}), PbCount]),
            {error, badarg}
    end.


-spec process_events(Uid :: maybe(uid()), Events :: [pb_event_data()]) -> [result()].
process_events(Uid, Events) ->
    lists:map(
        fun(Event) ->
            process_event(Uid, Event)
        end,
        Events).


-spec process_event(Uid :: maybe(uid()), Event :: pb_event_data()) -> ok.
process_event(Uid, #pb_event_data{edata = Edata} = Event) ->
    try
        AppType = util_uid:get_app_type(Uid),
        _AppTypeBin = util:to_binary(AppType),
        Namespace = get_namespace(Edata),
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        TsMs = util:now_ms(),
        Date = util:tsms_to_date(TsMs), % for knowing which log file to add to
        {UidInt, CC} = case Uid of
            undefined -> {0, <<"ZZ">>};
            Uid ->
                CC1 = case model_accounts:get_phone(Uid) of
                    {ok, Phone} -> mod_libphonenumber:get_cc(Phone);
                    {error, missing} -> <<"ZZ">>
                end,
                {binary_to_integer(Uid), CC1}
        end,
        Event2 = Event#pb_event_data{uid = UidInt, timestamp_ms = TsMs, cc = CC},
        %% TODO: fix these event hooks in other modules.
        % Event3 = ejabberd_hooks:run_fold(util:to_atom(<<AppTypeBin/binary, "_event_", Namespace/binary>>), Event2, []),
        Event3 = ejabberd_hooks:run_fold(util:to_atom(<<"event_", Namespace/binary>>), Event2, []),
        case enif_protobuf:encode(Event3) of
            {error, Reason1} ->
                ?ERROR("Failed to process event ~p, Event: ~p", [Reason1, Event3]),
                {error, bad_arg};
            Data when is_binary(Data) ->
                Json = json_encode(Data),
                ha_events:write_log(FullNamespace, Date, Json),
                ?INFO("~s, ~s, ~p, size:~p", [FullNamespace, Uid, TsMs, size(Data)]),
                ok
        end
        % TODO: log the event into CloudWatch Log or Kinesis Stream or S3
    catch
        error : bad_edata : _ ->
            ?WARNING("bad_edata Uid: ~s Event: ~p", [Uid, Event]),
            {error, bad_edata};
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR("client event error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, badarg}
    end.

-spec clean_event(Event :: pb_event_data(), Uid :: uid()) -> {pb_event_data(), uid()}.
clean_event(#pb_event_data{platform = Platform, cc = CC,
        edata = #pb_push_received{id = Id, client_timestamp = Stamp} = Edata} = Event, Uid) ->
    ?INFO("Uid: ~p Platform: ~s CC: ~s PushId: ~s", [Uid, Platform, CC, Id]),
    % temporary fix, TODO: remove once iOS pushes are changed
    NewStamp = util:check_and_convert_sec_to_ms(Stamp),
    {Event#pb_event_data{edata = Edata#pb_push_received{client_timestamp = NewStamp}}, Uid};
clean_event(#pb_event_data{edata = #pb_invite_request_result{invited_phone = Phone} = Edata} = Event,
        Uid) ->
    NewEvent = case model_accounts:get_phone(Uid) of
        {ok, InviterPhone} ->
            RegionId = mod_libphonenumber:get_region_id(InviterPhone),
            case mod_libphonenumber:normalize(Phone, RegionId) of
                {ok, NormalPhone} ->
                    ?INFO("InviteRequestResult: normalized ~p to ~p, RegionId ~p", [Phone, NormalPhone, RegionId]),
                    Event#pb_event_data{edata = Edata#pb_invite_request_result{invited_phone = NormalPhone}};
                {error, Reason} ->
                    ?ERROR("Can't normalize phone ~p from pb_invite_request_result: ~s", [Phone, Reason]),
                    Event
            end;
        Err ->
            ?ERROR("Failed to fetch phone for Uid ~s: ~p", [Uid, Err]),
            Event
    end,
    {NewEvent, Uid};
clean_event(Event, Uid) ->
    {Event, Uid}.

-spec get_namespace(Edata :: tuple()) -> binary().
get_namespace(Edata) when is_tuple(Edata) ->
    Namespace1 = atom_to_list(element(1, Edata)),
    % removing the "pb_"
    Namespace2 = case string:sub_string(Namespace1, 1, 3) of
        "pb_" -> string:sub_string(Namespace1, 4);
        _ -> Namespace1
    end,
    list_to_binary(Namespace2);
get_namespace(_Edata) ->
    error(bad_edata).


-spec is_valid_namespace(Namespace :: binary()) -> boolean().
is_valid_namespace(Namespace) ->
    case re:run(Namespace, ?VALID_NAMESPACE_RE, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.


-spec validate_namespace(Namespace :: binary()) -> ok. % or error bad_namespace
validate_namespace(Namespace) ->
    case is_valid_namespace(Namespace) of
        true ->
            ok;
        false ->
            ?WARNING("Invalid namespace ~p", [Namespace]),
            erlang:error(bad_namespace)
    end.


-spec full_namespace(Namespace :: binary()) -> binary().
full_namespace(Namespace) ->
    <<?CLIENT_NS/binary, Namespace/binary>>.


dims_st_to_tags(DimsSt) ->
    %% Dont crash on invalid values here.
    %% Get rid of these checks once clients fixes their issues.
    lists:filtermap(
        fun (#pb_dim{name = _Name, value = undefined}) ->
            false;
            (#pb_dim{name = undefined, value = _Value}) ->
            false;
            (#pb_dim{name = Name, value = Value}) ->
            {true, {binary_to_list(Name), fix_tag_value(binary_to_list(Value))}}
        end,
        DimsSt
    ).

fix_tag_value(Value) ->
    lists:flatten(string:replace(Value, " ", "_", all)).


-spec has_error(Result :: result()) -> boolean().
has_error(Result) ->
    case Result of
        ok -> false;
        {error, _} -> true
    end.

json_encode(PBBin) ->
    DecodedMessage = log_events:decode_msg(PBBin, pb_event_data),
    EJson = log_events:to_json(DecodedMessage),
    EJson2 = post_process(EJson),
    jiffy:encode(EJson2).

%% webrtc_stats in the the call event is json encoded string. This function
%% helps to unpack it
post_process({EJson}) ->
    case proplists:lookup(<<"call">>, EJson) of
        none -> {EJson};
        {<<"call">>, {_CallData}} ->
            %TODO: uncomment this again and extract what we need from call data!
            %CallData2 = case proplists:lookup(<<"webrtc_stats">>, CallData) of
            %    none -> {CallData};
            %    {<<"webrtc_stats">>, Stats} ->
            %        {lists:keyreplace(<<"webrtc_stats">>, 1, CallData, {<<"webrtc_stats">>, jiffy:decode(Stats)})}
            %end,
            %{lists:keyreplace(<<"call">>, 1, EJson, {<<"call">>,CallData2})}
            {EJson}
    end.

%% Currently we only write crypto and call stats to files.
-spec log_count(Namespace :: binary(), Metric :: binary(),
        Uid :: binary(), Tags :: proplist(), Count :: integer()) -> ok.
log_count(Namespace, Metric, Uid, Tags, Count)
        when Namespace =:= <<"client.crypto">>; Namespace =:= <<"client.call">> ->
    FinalNamespace = <<Namespace/binary, ".", Metric/binary>>,
    Tags2 = lists:map(fun({TagName, TagValue}) ->
                {util:to_binary(TagName), util:to_binary(TagValue)}
            end, Tags),
    DataMap1 = maps:from_list(Tags2),
    DataMap2 = DataMap1#{
        <<"uid">> => Uid,
        <<"count">> => Count
    },
    ha_events:log_event(FinalNamespace, DataMap2),
    ok;
log_count(_Namespace, _Metric, _Uid, _Tags2, _Count) ->
    ok.
