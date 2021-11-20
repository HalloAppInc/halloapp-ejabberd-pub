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

-behavior(gen_server).
-behaviour(gen_mod).

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([
    process_local_iq/2,
    process_client_count_log_st/3,
    trigger_upload_aws/0,
    log_event/2,
    log_event/5,
    log_user_event/2
]).

-ifdef(TEST).
-export([
    write_log/3,
    flush/0,
    make_date_str/1,
    file_path/2,
    client_log_dir/0,
    json_encode/1
]).
-endif.
-compile([{nowarn_unused_function, [{flush, 0}]}]). % used in tests only

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

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_client_log, ?MODULE, process_local_iq, 2),
    ok.


stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_client_log),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server callbacks
%%====================================================================

% for tests
start_link() ->
    gen_server:start_link({local, ?PROC()}, ?MODULE, [], []).

init(_Host) ->
    ?INFO("Start: ~p", [?MODULE]),
    init_erlcloud(),
    filelib:ensure_dir(filename:join(client_log_dir(), "file")),
    {ok, Tref1} = timer:apply_interval(5 * ?MINUTES_MS, ?MODULE, trigger_upload_aws, []),
    State = #{source_server => get_server(), file_list => [], tref => Tref1},
    {ok, State}.

terminate(_Reason, #{tref := Tref} = _State) ->
    timer:cancel(Tref),
    ?INFO("Terminate: ~p", [?MODULE]),
    ok.

handle_call(flush, _From, State) ->
    {reply, ok, State};
handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({write_log, Namespace, LogDate, Bin}, State) ->
    write_func_internal(Namespace, LogDate, Bin),
    {noreply, State};
handle_cast(upload_to_s3, State) ->
    {noreply, upload_func_internal(State)};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

init_erlcloud() ->
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    ok.

write_func_internal(Namespace, LogDate, Bin) ->
    try
        DateStr = make_date_str(LogDate),
        Filename = file_path(Namespace, DateStr),
        append_to_file(Bin, Filename),
        ok
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in write_func_internal: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end.

upload_func_internal(#{source_server := SourceServer, file_list := FileList} = State) ->
    try
        NewFileList = upload_files_to_s3(FileList, SourceServer),
        make_optional_call(NewFileList),
        State#{file_list := NewFileList}
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in upload_to_s3: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.

make_optional_call([]) ->
    ok;
make_optional_call(_FileList) ->
    gen_server:cast(?PROC(), upload_to_s3),
    ok.

%%====================================================================
%% client API
%%====================================================================

-spec trigger_upload_aws() -> ok.
trigger_upload_aws() ->
    gen_server:cast(?PROC(), upload_to_s3),
    ok.

-spec write_log(Namespace :: binary(), Date :: tuple(), Bin :: binary()) -> ok.
write_log(Namespace, Date, Bin) ->
    gen_server:cast(?PROC(), {write_log, Namespace, Date, Bin}),
    ok.

%%====================================================================
%% upload file queueing logic
%%====================================================================

-spec upload_files_to_s3(FileList :: list(), SourceServer :: binary()) -> list().
upload_files_to_s3([], SourceServer) ->
    FileList = get_old_log_files_in_dir(),
    case FileList of
        [] ->
            ?INFO("No old log files found",[]),
            FileList;
        _ ->
            ?INFO("Added ~p to file queue.", [FileList]),
            upload_files_to_s3(FileList, SourceServer)
    end;
upload_files_to_s3(FileList, SourceServer) ->
    % returns a new queue consisting of files that
    % haven't been uploaded to S3 yet
    % if there is an exception here, it occurred during uploading
    [FileToUpload | RestOfFileList] = FileList,
    upload_file_to_s3(FileToUpload, SourceServer),
    RestOfFileList.

-spec get_old_log_files_in_dir() -> list().
get_old_log_files_in_dir() ->
    % returns a list of old log files we haven't uploaded yet
    {ok, FileList} = file:list_dir(client_log_dir()),
    Today = erlang:date(), % Today = {Y, M, D}
    CandidateFiles = lists:filter(
        fun(ListElem) ->
            FileDate = date_from_filename(ListElem),
            FileDate =/= Today
        end,
        FileList
    ),
    [filename:join([client_log_dir(), File]) || File <- CandidateFiles].

-spec date_from_filename(Filename :: string()) -> tuple().
date_from_filename(Filename) ->
    %% tokenize the filename, get back a Year, Month, Date tuple
    Tokens = string:split(Filename, ".", all),
    YMD = lists:sublist(Tokens, length(Tokens) - 2, 3),
    {Year, Month, Date} = list_to_tuple([util:to_integer(X) || X <- YMD]),
    {Year, Month, Date}.

%%====================================================================
%% General event/count processing
%%====================================================================

% client_log
-spec process_local_iq(pb_iq(), halloapp_c2s:state()) -> pb_iq().
process_local_iq(#pb_iq{type = set, from_uid = Uid, payload = #pb_client_log{} = ClientLogsSt} = IQ,
        #{client_version := ClientVersion} = _State) ->
    try
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
            pb:make_error(IQ, util:err(server_error))
    end;

process_local_iq(#pb_iq{} = IQ, _State) ->
    pb:make_error(IQ, util:err(bad_request)).

-spec process_client_count_log_st(Uid :: maybe(uid()) | undefined, ClientLogSt :: pb_client_log(),
        Platform :: maybe(client_type())) -> ok | error.
process_client_count_log_st(Uid, ClientLogsSt, Platform) ->
    ServerDims = [{"platform", atom_to_list(Platform)}],
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


-spec process_counts(Uid :: uid(), Counts :: [pb_count()], ServerDims :: stat:tags()) -> [result()].
process_counts(Uid, Counts, ServerDims) ->
    lists:map(
        fun (C) ->
            process_count(Uid, C, ServerDims)
        end, Counts).


% TODO: validate the number of dims is < 6
% TODO: validate the name and value of each dimension
-spec process_count(Uid :: uid(), Counts :: pb_count(), ServerTags :: stat:tags()) -> result() .
process_count(Uid, #pb_count{namespace = Namespace, metric = Metric, count = Count, dims = DimsSt},
        ServerTags) ->
    try
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        Tags = dims_st_to_tags(DimsSt),
        Tags2 = Tags ++ ServerTags,
        % TODO: make sure to override duplicate keys in Tags with ServerTags
        %% TODO(murali@): remove these logs eventually.
        ?INFO("~s, ~s, ~s, ~p, ~p", [FullNamespace, Metric, Uid, Tags2, Count]),
        stat:count(binary_to_list(FullNamespace), binary_to_list(Metric), Count, Tags2),
        log_count(FullNamespace, Metric, Uid, Tags2, Count),
        ok
    catch
        error : bad_namespace : _ ->
            {error, bad_namespace};
        Class : Reason : Stacktrace ->
            ?ERROR("client count error: ~s", [
                lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
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
        Namespace = get_namespace(Edata),
        FullNamespace = full_namespace(Namespace),
        validate_namespace(FullNamespace),
        TsMs = util:now_ms(),
        Date = util:tsms_to_date(TsMs), % for knowing which log file to add to
        UidInt = case Uid of
            undefined -> 0;
            Uid -> binary_to_integer(Uid)
        end,
        Event2 = Event#pb_event_data{uid = UidInt, timestamp_ms = TsMs},
        case enif_protobuf:encode(Event2) of
            {error, Reason1} ->
                ?ERROR("Failed to process event ~p, Event: ~p", [Reason1, Event]),
                {error, bad_arg};
            Data when is_binary(Data) ->
                Json = json_encode(Data),
                write_log(FullNamespace, Date, Json),
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

-spec get_server() -> binary().
get_server() ->
    case config:is_prod_env() of
        true ->
            util:get_machine_name();
        false ->
            <<"localhost">>
    end.

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
    lists:map(
        fun (#pb_dim{name = Name, value = Value}) ->
            {binary_to_list(Name), fix_tag_value(binary_to_list(Value))}
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
post_process(EJson) ->
    case proplists:lookup(<<"call">>, EJson) of
        none -> EJson;
        {<<"call">>, CallData} ->
            CallData2 = case proplists:lookup(<<"webrtc_stats">>, CallData) of
                none -> CallData;
                {<<"webrtc_stats">>, Stats} ->
                    lists:keyreplace(<<"webrtc_stats">>, 1, CallData, jiffy:decode(Stats))
            end,
            lists:keyreplace(<<"call">>, 1, EJson, CallData2)
    end.

%%====================================================================
%% Event log helper functions
%%====================================================================

-spec upload_file_to_s3(Filename :: string(), SourceServer :: binary()) -> ok.
upload_file_to_s3(Filename, SourceServer) ->
    ObjectKey = make_object_key(SourceServer, Filename),
    upload_and_delete_file(ObjectKey, Filename),
    ok.

make_s3_date_str(Year, Month, Date) ->
    "year=" ++ Year ++ "/" ++ "month=" ++ Month ++ "/" ++ "date=" ++ Date.

-spec make_object_key(SourceServer :: string(), Filename :: string()) -> string().
make_object_key(SourceServer, Filename) ->
    % e.g. logs/event_logs/client.upload_timing.2021.01.20 on local machine
    % becomes client.upload_timing/year=2021/month=01/date=20/s-test.json on S3 later
    WithoutPrefix = filename:basename(Filename),
    Tokenized = string:split(WithoutPrefix, ".log.", trailing),
    OldDateStr = lists:nth(2, Tokenized),
    Namespace = lists:nth(1, Tokenized),
    [Year, Month, Date] = string:split(OldDateStr, ".", all),
    NewDateStr = make_s3_date_str(Year, Month, Date),
    FilenameWithServer = filename:join([Namespace, NewDateStr, binary_to_list(SourceServer) ++ ".json"]),
    FilenameWithServer.

-spec append_to_file(Json :: binary(), Filename :: string()) -> ok.
append_to_file(Json, Filename) ->
    file:write_file(Filename, <<Json/binary, "\n">>, [append]),
    ok.

-spec upload_and_delete_file(ObjectKey :: string(), Path :: string()) -> ok.
upload_and_delete_file(ObjectKey, Path) ->
    {ok, Binary} = file:read_file(Path),
    ?INFO("uploading ~p Size: ~p", [Path, byte_size(Binary)]),
    Headers = [{"content-type", "text/plain"}],
    upload_s3(config:get_hallo_env(), Headers, ObjectKey, Binary),
    ?INFO("Deleting ~p locally after successful upload", [Path]),
    file:delete(Path),
    ok.

-spec upload_s3(atom(), list(), string(), binary()) -> ok.
upload_s3(prod, Headers, ObjectKey, Data) ->
    Result = erlcloud_s3:put_object(binary_to_list(
        ?S3_CLIENT_LOGS_BUCKET), ObjectKey, Data, [], Headers),
    ?INFO("ObjectName: ~s, Result: ~p", [ObjectKey, Result]),
    ok;
upload_s3(localhost, _Headers, ObjectKey, Data) ->
    ?INFO("would have uploaded: ~p with data: ~p", [ObjectKey, Data]),
    ok;
upload_s3(_Env, _Headers, _ObjectKey, _Data) ->
    ok.

make_date_str({Year, Month, Date}) ->
    % converted to "/" later when uploading to AWS
    DateStr = io_lib:format("~B.~2..0B.~2..0B", [Year, Month, Date]),
    DateStr.

-spec file_path(Namespace :: binary(), DateStr :: string()) -> string().
file_path(Namespace, DateStr) ->
    LogFile = binary_to_list(Namespace) ++ ".log." ++ DateStr,
    filename:join([client_log_dir(), LogFile]).

client_log_dir() ->
    ConsoleLog = ejabberd_logger:get_log_path(),
    Dir = filename:dirname(ConsoleLog),
    filename:join([Dir, ?CLIENT_LOGS_DIR]).


%% Currently we only write crypto stats to files.
-spec log_count(Namespace :: binary(), Metric :: binary(),
        Uid :: binary(), Tags :: proplist(), Count :: integer()) -> ok.
log_count(<<"client.crypto">> = Namespace, Metric, Uid, Tags, Count) ->
    FinalNamespace = <<Namespace/binary, ".", Metric/binary>>,
    Tags2 = lists:map(fun({TagName, TagValue}) ->
                {util:to_binary(TagName), util:to_binary(TagValue)}
            end, Tags),
    DataMap1 = maps:from_list(Tags2),
    DataMap2 = DataMap1#{
        <<"uid">> => Uid,
        <<"count">> => Count
    },
    log_event(FinalNamespace, DataMap2),
    ok;
log_count(_Namespace, _Metric, _Uid, _Tags2, _Count) ->
    ok.

log_event(FullNamespace, EventDataMap, Uid, Platform, Version) ->
    EventDataMap2 = EventDataMap#{uid => Uid, platform => Platform, version => Version},
    log_event(FullNamespace, EventDataMap2),
    ok.
log_event(FullNamespace, EventDataMap) ->
    TimestampMs = util:now_ms(),
    Date = util:tsms_to_date(TimestampMs),
    EventDataMap2 = maps:put(timestamp_ms, util:to_binary(TimestampMs), EventDataMap),
    JsonBin = jiffy:encode(EventDataMap2),
    ?INFO("~p, ~p, ~p", [FullNamespace, Date, JsonBin]),
    write_log(FullNamespace, Date, JsonBin),
    ok.

-spec log_user_event(Uid :: uid(), EventType :: user_event_type()) -> ok.
log_user_event(Uid, EventType) ->
    try
        Event = #{
            uid => Uid,
            event_type => EventType,
            ts => util:now()
        },
        log_event(<<"server.user_event">>, Event)
    catch
        Class : Reason : St ->
            ?ERROR("failed to log event: ~p Uid: ~p, to log. ~p",
                [EventType, Uid, lager:pr_stacktrace(St, {Class, Reason})])
    end.


% used for tests to ensure a gen_server cast finishes before an assert
flush() ->
    gen_server:call(?PROC(), flush).
