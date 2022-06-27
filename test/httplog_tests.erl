-module(httplog_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("util_http.hrl").
-include("account_test_data.hrl").
-include("packets.hrl").
%%-include("log_events.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ZIP_PREFIX, 16#50, 16#4b, 16#03, 16#04).

group() ->
    {httplog, [parallel], [
        httplog_dummy_test,
        httplog_upload_log_test,
        httplog_counts_and_events_test
    ]}.

dummy_test(_Conf) ->
    ok.

setup() ->
    application:ensure_started(inets).

upload_log_test(_Conf) ->
    setup(),
    Body = <<?ZIP_PREFIX, "dasdasdasdasdsadas">>,
    Query = io_lib:format("?uid=~s&phone=~s&version=~s&msg=~s", [?UID1, ?PHONE1, "Android0.94", "hello"]),
    Request = {"http://localhost:5580/api/logs/device" ++ Query, [], "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [], []),
%%    ct:pal("Response: ~p", [Response]),
    {{_, 200, _}, _, _} = Response,
    ok.

counts_and_events_test(_Conf) ->
    setup(),
    ClientLogs = #pb_client_log{
        counts = [
            #pb_count{namespace = <<"ns1">>, metric = <<"m1">>, count = 2},
            #pb_count{namespace = <<"ns1">>, metric = <<"m1">>, count = 2,
                dims = [#pb_dim{name = <<"dn1">>, value = <<"dv1">>}]}
        ],
        events = [
            #pb_event_data{platform = android, version = <<"0.1.2">>, edata = #pb_media_upload{
                num_photos = 2,
                num_videos = 1,
                total_size = 12312,
                type = post,
                duration_ms = 123
            }}
        ]
    },
    Body = enif_protobuf:encode(ClientLogs),
    Request = {
        "http://localhost:5580/api/logs/counts_and_events",
        [{"User-Agent", "Halloapp/Android0.94"}],
        "application/json",
        Body
    },
    {ok, Response} = httpc:request(post, Request, [], []),
%%    ct:pal("Response: ~p", [Response]),
    {{_, 200, _}, _, _} = Response,
    ok.

