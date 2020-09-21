-module(ha_SUITE).

%% Suite
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

%% Tests
-export([
    dummy_test/1,
    connect_test/1,
    check_accounts_test/1,
    auth_no_user_test/1,
    auth_bad_password_test/1,
    auth_success_test/1,
    run_eunit/1
]).

-export([
    '$handle_undefined_function'/2
]).

-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").


suite() ->
    [{timetrap, {seconds, 5}}].


groups() -> [
    {groups, [sequence], [
        groups_tests:groups_cases()
    ]},
    {feed, [sequence], feed_tests()},
    {registration, [sequence], registration_tests()},
    {chat, [sequence], chat_tests()},
    {privacy_lists, [sequence], privacy_lists_tests()},
    {misc, [sequence], misc_tests()}
].


all() -> [
    {group, groups},
    {group, feed},
    {group, registration},
    {group, chat},
    {group, privacy_lists},
    {group, misc},
    dummy_test,
    connect_test,
    check_accounts_test,
    auth_no_user_test,
    auth_bad_password_test,
    auth_success_test,
    run_eunit
].

feed_tests() -> [dummy_test].
registration_tests() -> [dummy_test].
chat_tests() -> [dummy_test].
privacy_lists_tests() -> [dummy_test].
misc_tests() ->[dummy_test].

% TODO: figure out what to do with APNS push failing
init_per_suite(InitConfigData) ->
    ct:pal("Config ~p", [InitConfigData]),
    NewConfig = suite_ha:init_config(InitConfigData),
    % TODO: move this to suite_ha unitility function
    inet_db:add_host({127, 0, 0, 1}, [
        binary_to_list(?S2S_VHOST),
        binary_to_list(?MNESIA_VHOST),
        binary_to_list(?UPLOAD_VHOST)]),
    inet_db:set_domain(binary_to_list(p1_rand:get_string())),
    inet_db:set_lookup([file, native]),
    start_ejabberd(NewConfig),
    create_test_accounts(),
    NewConfig.


start_ejabberd(_Config) ->
    {ok, _} = application:ensure_all_started(ejabberd, transient).


end_per_suite(_Config) ->
    application:stop(ejabberd).

flush_db() ->
    % TODO: Instead of this we should somehow clear the redis before
    % we even start the ejabberd
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb),
    ok.

% TODO: move those function in some util file, maybe suite_ha
create_test_accounts() ->
    flush_db(),
    % TODO: instead of the model functions it is better to use the higher level API.
    % TODO: create all 5 accounts
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA, ?TS1),
    ok = ejabberd_auth:set_password(?UID1, ?PASSWORD1),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA, ?TS2),
    ok = ejabberd_auth:set_password(?UID2, ?PASSWORD2),
    ok.


dummy_test(_Conf) ->
    ok = ok.

connect_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    ok = ha_client:close(C),
    ok.

check_accounts_test(_Conf) ->
    ?assertEqual(true, model_accounts:account_exists(?UID1)),
    ?assertEqual(true, model_accounts:account_exists(?UID2)),
    ?assertEqual(false, model_accounts:account_exists(?UID3)),
    ok.

auth_no_user_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    % UID6 does not exist
    false = model_accounts:account_exists(?UID6),
    Result = ha_client:send_auth(C, ?UID6, <<"wrong_password">>),
    #pb_auth_result{result = <<"failure">>, reason = <<"invalid uid or password">>} = Result,
    ok = ha_client:close(C),
    ok.

auth_bad_password_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    true = model_accounts:account_exists(?UID1),
    Result = ha_client:send_auth(C, ?UID1, <<"wrong_password">>),
    #pb_auth_result{result = <<"failure">>, reason = <<"invalid uid or password">>} = Result,
    ok = ha_client:close(C),
    ok.


auth_success_test(_Conf) ->
    {ok, C} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    ok = ha_client:close(C),
    ok.


run_eunit(_Config) ->
    % TODO: apparently you can run the eunit tests from here but this did not work
    % See if we can make the eunit tests run here.
    %%    ok = eunit:test(model_accounts).
    ok.

%% This gets called when you try to call function on this module that is not defined.
%% Tests defined in other modules will do this and here we look at the name and call
%% the right module.
%% (Nikola:) It took me long time to find how this worked in the ejabberd_SUITE.erl
%% spend lots of time trying to understand why the ejabberd_SUITE tests were able to
%% be split in different files.
%% Alternative to doing this would be to split the test code in many different test
%% suites but the downside is that each test suite will have to stop and start ejabberd,
%% which will be a problem.
%% TODO: instead of splitting the name with of the module and test with _ use :
%% This will make it more clear that we are specifying the module name.

'$handle_undefined_function'(F, [Config]) when is_list(Config) ->
    ct:pal("Function ~p", [F]),
    case re:split(atom_to_list(F), "_", [{return, list}, {parts, 2}]) of
        [M, T] ->
            Module = list_to_atom(M ++ "_tests"),
            Function = list_to_atom(T),
            ct:pal("Module ~p Function ~p", [Module, Function]),
            case erlang:function_exported(Module, Function, 1) of
                true ->
                    Module:Function(Config);
                false ->
                    erlang:error({undef, F})
            end;
        _ ->
            erlang:error({undef, F})
    end;
'$handle_undefined_function'(_, _) ->
    erlang:error(undef).

