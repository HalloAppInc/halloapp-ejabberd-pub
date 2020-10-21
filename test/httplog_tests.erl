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


%%
%%connect_test(_Conf) ->
%%    {ok, C} = ha_client:start_link(),
%%    ok = ha_client:stop(C),
%%    ok.
%%
%%check_accounts_test(_Conf) ->
%%    ?assertEqual(true, model_accounts:account_exists(?UID1)),
%%    ?assertEqual(true, model_accounts:account_exists(?UID2)),
%%    ?assertEqual(false, model_accounts:account_exists(?UID3)),
%%    ok.
%%
%%no_user_test(_Conf) ->
%%    % UID6 does not exist
%%    false = model_accounts:account_exists(?UID6),
%%    {error, 'invalid uid or password'} = ha_client:connect_and_login(?UID6, <<"wrong_password">>),
%%    ok.
%%
%%bad_password_test(_Conf) ->
%%    true = model_accounts:account_exists(?UID1),
%%    {error, 'invalid uid or password'} = ha_client:connect_and_login(?UID1, <<"wrong_password">>),
%%    ok.
%%
%%
%%login_success_test(_Conf) ->
%%    {ok, C} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
%%    ok = ha_client:stop(C),
%%    ok.
%%
