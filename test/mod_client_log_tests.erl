%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_client_log_tests).
-author("nikola").

-include("xmpp.hrl").
-include("packets.hrl").
-include("time.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(NS1, <<"ns1">>).
-define(NS2, <<"ns2">>).
-define(BAD_NS1, <<"das*()">>).
-define(METRIC1, <<"m1">>).
-define(METRIC2, <<"m2">>).
-define(COUNT1, 2).
-define(COUNT2, 7).

-define(TERM, <<"teststring">>).
-define(SOURCE_SERVER, <<"s-test">>).
-define(HEADERS, [{"content-type", "text/plain"}]).

-define(EVENT1, #pb_media_upload{
    duration_ms = 1200,
    num_photos = 2,
    num_videos = 1
}).
-define(EVENT2, #pb_media_upload{
    duration_ms = 100,
    num_photos = 0,
    num_videos = 7
}).


setup() ->
    tutil:setup(),
    tutil:load_protobuf(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    os:putenv("EJABBERD_LOG_PATH", "../logs/"),
    del_dir(ha_events:client_log_dir()),
    filelib:ensure_dir(filename:join([ha_events:client_log_dir(), "FILE"])), % making sure fresh copy at each test
    ha_redis:start(),
    clear(),
    ok.

clear() ->
  tutil:cleardb(redis_accounts).

make_timer() ->
    {ok, Tref1} = timer:apply_interval(5 * ?MINUTES_MS, ?MODULE, fun() -> ok end, []),
    Tref1.

create_pb_count(Namespace, Metric, Count, Dims) ->
    #pb_count{
        namespace = Namespace,
        metric = Metric,
        count = Count,
        dims = Dims
    }.


create_pb_event_data(Uid, Platform, Version, Event) ->
    #pb_event_data{
        uid = Uid,
        platform = Platform,
        version = Version,
        edata = Event
    }.

create_client_log_IQ(Uid, Counts, Events) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
            #pb_client_log{
                counts = Counts,
                events = Events
            }
    }.

mod_client_log_test() ->
    setup(),
    % we don't start the gen_server through gen_mod in our tests because
    % of the ets table lookup that is done when start_child is called
    meck:new(gen_mod),
    meck:expect(gen_mod, start_child, fun(_, _, _, _) -> ok end),
    meck:expect(gen_mod, stop_child, fun(_) -> ok end),
    meck:expect(gen_mod, get_module_proc, fun(_, _) -> 1234 end),
    Host = <<"s.halloapp.net">>,
    ?assertEqual(ok, mod_client_log:start(Host, [])),
    ?assertEqual(ok, mod_client_log:stop(Host)),
    ?assertEqual([{ha_events, hard}], mod_client_log:depends(Host, [])),
    ?assertEqual([], mod_client_log:mod_options(Host)),
    meck:unload(gen_mod),
    ok.


client_log_test() ->
    setup(),
    model_accounts:set_client_version(?UID1, <<"HalloApp/Android0.129">>),
    start_gen_server(),
    Counts = [
        create_pb_count(?NS1, ?METRIC1, ?COUNT1, []),
        create_pb_count(?NS2, ?METRIC2, ?COUNT2, [])
    ],
    Events = [
        create_pb_event_data(undefined, android, <<"0.1.2">>, ?EVENT1),
        create_pb_event_data(undefined, android, <<"0.1.2">>, ?EVENT2)
    ],
    IQ = create_client_log_IQ(?UID1, Counts, Events),
    IQRes = mod_client_log:process_local_iq(IQ, #{client_version => <<"HalloApp/Android0.129">>}),
    tutil:assert_empty_result_iq(IQRes),
    kill_gen_server(),
    ok.

client_log_bad_namespace_test() ->
    setup(),
    model_accounts:set_client_version(?UID1, <<"HalloApp/Android0.129">>),
    Counts = [
        create_pb_count(?BAD_NS1, ?METRIC1, ?COUNT1, []),
        create_pb_count(?NS2, ?METRIC2, ?COUNT2, [])
    ],
    Events = [
        create_pb_event_data(undefined, android, <<"0.1.2">>, ?EVENT1),
        create_pb_event_data(undefined, android, <<"0.1.2">>, undefined)
    ],
    IQ = create_client_log_IQ(?UID1, Counts, Events),
    IQRes = mod_client_log:process_local_iq(IQ, #{client_version => <<"HalloApp/Android0.129">>}),
    ?assertEqual(util:err(bad_request), tutil:get_error_iq_sub_el(IQRes)),
    ok.

verify_s3_upload_test() ->
    setup(),
    start_gen_server(),
    Filename = get_log_file(today(), 1),
    file:write_file(Filename, ?TERM), % write a dummy file
    ha_events:trigger_upload_aws(),
    ha_events:flush(),
    {ok, FileList} = file:list_dir(ha_events:client_log_dir()),
    ?assertEqual([], FileList), % confirming file is deleted after s3 upload
    kill_gen_server(),
    ok.

more_complicated_s3_upload_test() ->
    setup(),
    start_gen_server(),
    Filename = get_log_file(today(), 1),
    FileOlder = get_log_file(today(), 10),
    FileEvenOlder = get_log_file(today(), 100),
    file:write_file(Filename, ?TERM),
    file:write_file(FileOlder, ?TERM),
    file:write_file(FileEvenOlder, ?TERM),
    ha_events:trigger_upload_aws(),
    ha_events:flush(),
    {ok, FileList} = file:list_dir(ha_events:client_log_dir()),
    ?assert(length(FileList) < 3), % at least one file has been uploaded and deleted
    ha_events:trigger_upload_aws(),
    ha_events:flush(),
    {ok, FileList2} = file:list_dir(ha_events:client_log_dir()),
    ?assert(length(FileList2) < 2), % at least two files have been uploaded and deleted
    ha_events:trigger_upload_aws(),
    ha_events:flush(),
    {ok, FileList3} = file:list_dir(ha_events:client_log_dir()),
    ?assert(length(FileList3) == 0),
    kill_gen_server(),
    ok.

file_contents_test() ->
    % verify the contents of the log file
    setup(),
    start_gen_server(),
    EventData = create_pb_event_data(101, android, <<"0.1.2">>, ?EVENT2),
    Bin = enif_protobuf:encode(EventData),
    Json = mod_client_log:json_encode(Bin),
    Filename = get_log_file(today(), 0),
    % start with a clean slate
    file:delete(Filename),
    Today = today(),
    ha_events:write_log(?NS1, Today, Json),
    ha_events:write_log(?NS1, Today, Json),
    ha_events:write_log(?NS1, Today, Json),
    ha_events:flush(),
    {ok, Data} = file:read_file(Filename),
    JsonString = binary_to_list(Data),
    Lines = string:tokens(JsonString, "\n"),
    MostRecentEntry = lists:last(Lines),
    Decoded = jiffy:decode(MostRecentEntry, [return_maps]),
    ?assertEqual(<<"101">>, maps:get(<<"uid">>, Decoded)),
    ?assertEqual(3, length(Lines)),
    kill_gen_server(),
    ok.

write_event_test() ->
    setup(),
    start_gen_server(),
    FullNamespace = <<"server.random_log">>,
    EventData = maps:from_list([{test_field, test_value}]),
    Filename = get_log_file(today(), 0, FullNamespace),
    % start with a clean slate
    file:delete(Filename),
    ha_events:log_event(FullNamespace, EventData, 100, android, <<"0.1.2">>),
    ha_events:flush(),
    {ok, Data} = file:read_file(Filename),
    JsonString = binary_to_list(Data),
    Lines = string:tokens(JsonString, "\n"),
    MostRecentEntry = lists:last(Lines),
    Decoded = jiffy:decode(MostRecentEntry, [return_maps]),
    ?assertEqual(100, maps:get(<<"uid">>, Decoded)),
    kill_gen_server(),
    ok.

today() ->
    erlang:date().

get_log_file(Date, NumDaysBack) ->
    New = calendar:date_to_gregorian_days(Date) - NumDaysBack,
    NewDate = calendar:gregorian_days_to_date(New),
    DateStr = ha_events:make_date_str(NewDate),
    ha_events:file_path(?NS1, DateStr).

get_log_file(Date, NumDaysBack, Namespace) ->
    New = calendar:date_to_gregorian_days(Date) - NumDaysBack,
    NewDate = calendar:gregorian_days_to_date(New),
    DateStr = ha_events:make_date_str(NewDate),
    ha_events:file_path(Namespace, DateStr).

del_dir(Directory) ->
    % list all files and delete each of them
    case file:list_dir(Directory) of
        {ok, Files} ->
            lists:foreach(
                fun(File) ->
                    Filename = filename:join([Directory, File]),
                    file:delete(Filename)
                end,
                Files),
            ok;
        {error, _} -> ok
    end.

start_gen_server() ->
    try
        mock_s3(),
        ha_events:start_link()
    catch
        % to guard against already_started exception
        {error, _} -> ok
    end.

kill_gen_server() ->
    ha_events:terminate(shutdown, #{tref => make_timer()}),
    finish_s3_mock().

mock_s3() ->
    meck:new(erlcloud_s3),
    meck:new(erlcloud),
    meck:new(erlcloud_aws),
    meck:expect(erlcloud_aws, auto_config, fun() -> {ok, "test_config"} end),
    meck:expect(erlcloud_aws, configure, fun(_) -> ok end),
    meck:expect(erlcloud_s3, put_object, fun(_, _, _, _, _) -> ok end).

finish_s3_mock() ->
    meck:unload(erlcloud),
    meck:unload(erlcloud_aws),
    meck:unload(erlcloud_s3),
    ok.
