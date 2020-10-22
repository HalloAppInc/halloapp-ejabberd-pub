-module(httplog_tests).

-compile(export_all).
-include("suite.hrl").
-include("util_http.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(ZIP_PREFIX, 16#50, 16#4b, 16#03, 16#04).

group() ->
    {httplog, [parallel], [
        httplog_dummy_test,
        httplog_upload_log_test
    ]}.

dummy_test(_Conf) ->
    ok.

upload_log_test(_Conf) ->
    application:ensure_started(inets),
    Body = <<?ZIP_PREFIX, "dasdasdasdasdsadas">>,
    Query = io_lib:format("?uid=~s&phone=~s&version=~s&msg=~s", [?UID1, ?PHONE1, "Android0.94", "hello"]),
    Request = {"http://localhost:5580/api/logs" ++ Query, [], "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [], []),
    ct:pal("Response: ~p", [Response]),
    ok.

