-module(auth_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

group() ->
    {auth, [sequence], [
        auth_dummy_test,
        auth_connect_test,
        auth_check_accounts_test,
        auth_no_user_test,
        auth_bad_password_test,
        auth_bad_resource_test,
        auth_login_success_test
    ]}.

dummy_test(_Conf) ->
    ok.

connect_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    ok = ha_client:stop(C),
    ok.

check_accounts_test(_Conf) ->
    ?assertEqual(true, model_accounts:account_exists(?UID1)),
    ?assertEqual(true, model_accounts:account_exists(?UID2)),
    ?assertEqual(false, model_accounts:account_exists(?UID6)),
    ok.

no_user_test(_Conf) ->
    % UID6 does not exist
    false = model_accounts:account_exists(?UID6),
    {error, spub_mismatch} = ha_client:connect_and_login(?UID6, ?KEYPAIR1),
    ok.

bad_password_test(_Conf) ->
    true = model_accounts:account_exists(?UID1),
    {error, spub_mismatch} = ha_client:connect_and_login(?UID1, ?KEYPAIR2),
    ok.

bad_resource_test(_Conf) ->
    true = model_accounts:account_exists(?UID1),
    {error, invalid_resource} = ha_client:connect_and_login(?UID1, ?KEYPAIR1,
        #{resource => <<"bad_resource">>}),
    ok.

login_success_test(_Conf) ->
    {ok, C} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    ok = ha_client:stop(C),
    ok.

spub_mismatch_test(_Conf) ->
    true = model_accounts:account_exists(?UID1),
    %% using a wrong keypair here.
    {error, spub_mismatch} = ha_client:connect_and_login(?UID1, ?KEYPAIR2),
    ok.

