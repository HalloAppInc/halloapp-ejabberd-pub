%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Nov 2021 5:24 PM
%%%-------------------------------------------------------------------
-module(ha_events).
-author("nikola").

-behavior(gen_server).

-include("logger.hrl").
-include("proc.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("user_events.hrl").

-define(NS_CLIENT_LOG, <<"halloapp:client_log">>).
-define(CLIENT_NS, <<"client.">>).
-define(S3_CLIENT_LOGS_BUCKET, <<"ha-event-logs">>).
-define(CLIENT_LOGS_DIR, "event_logs").
-define(VALID_NAMESPACE_RE, "^[a-zA-Z][a-zA-Z0-9.\-/_]*$").



-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    log_event/2,
    log_event/5,
    log_user_event/2,
    log_friend_event/4,
    write_log/3,
    trigger_upload_aws/0,
    client_log_dir/0,
    flush/0,
    make_date_str/1,
    file_path/2
]).
-compile([{nowarn_unused_function, [{flush, 0}]}]). % used in tests only

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

% TODO(nikola): don't store this in the state. It is fast to call every time
-spec get_server() -> binary().
get_server() ->
    case config:is_prod_env() of
        true ->
            util:get_machine_name();
        false ->
            <<"localhost">>
    end.

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


-spec log_friend_event(Uid :: uid(), OUid :: uid(), ItemId :: binary(), EventType :: user_event_type()) -> ok.
log_friend_event(Uid, OUid, _ItemId, _EventType) when Uid =:= OUid ->
    ok;
log_friend_event(Uid, OUid, ItemId, EventType) ->
    try
        Event = #{
            uid => Uid,
            ouid => OUid,
            item_id => ItemId,
            event_type => EventType,
            ts => util:now()
        },
        log_event(<<"server.friend_event">>, Event)
    catch
        Class : Reason : St ->
            ?ERROR("failed to log event: ~p Uid: ~p, to log. ~p",
                [EventType, Uid, lager:pr_stacktrace(St, {Class, Reason})])
    end.

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
