%%%-------------------------------------------------------------------------
%%% Common Test Suite of tests for HalloApp.
%%% Please define your tests in their own files and include them here
%%% in the all() and groups() API.
%%% Tests files have be named foo_tests and test names have to be
%%% foo_t1 and the test function itself has to be foo_tests:t1()
%%%
%%% This works because of the $handle_undefined_function declared here.
%%%-------------------------------------------------------------------------
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
    ping_test/1,
    delete_account_test/1,
    run_eunit/1
]).

-export([
    '$handle_undefined_function'/2
]).

-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

% TODO: figure out to remove debug logs.
suite() ->
    [{timetrap, {seconds, 10}}].


groups() -> [
    auth_tests:group(),
    feed_tests:group(),
    groups_tests:group(),
    groupfeed_tests:group(),
    chat_tests:group(),
    {registration, [sequence], registration_tests()},
    {privacy_lists, [sequence], privacy_lists_tests()},
    {misc, [sequence], misc_tests()},
    httplog_tests:group(),
    trace_tests:group(),
    window_tests:group()
].

% List of all the tests or group of tests that are part of this SUITE.
% groups have to be defined by groups() method
all() -> [
    {group, auth},
    {group, feed},
    {group, chat},
    {group, groups},
    {group, groupfeed},
    {group, registration},
    {group, privacy_lists},
    {group, misc},
    {group, httplog},
    {group, trace},
    {group, window},
    dummy_test,
    ping_test,
    delete_account_test,
    run_eunit
].

registration_tests() -> [dummy_test].
privacy_lists_tests() -> [dummy_test].
misc_tests() ->[dummy_test].

% TODO: figure out what to do with APNS push failing
init_per_suite(InitConfigData) ->
    true = config:is_testing_env(),
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
    tutil:cleardb(redis_accounts),
    ok.

% TODO: move those function in some util file, maybe suite_ha
create_test_accounts() ->
    flush_db(),
    % TODO: instead of the model functions it is better to use the higher level API.
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA, ?TS1),
    ok = ejabberd_auth:set_password(?UID1, ?PASSWORD1),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA, ?TS2),
    ok = ejabberd_auth:set_password(?UID2, ?PASSWORD2),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA, ?TS3),
    ok = ejabberd_auth:set_password(?UID3, ?PASSWORD3),
    ok = model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA, ?TS4),
    ok = ejabberd_auth:set_password(?UID4, ?PASSWORD4),
    ok = model_accounts:create_account(?UID5, ?PHONE5, ?NAME5, ?UA, ?TS4),
    ok = ejabberd_auth:set_password(?UID5, ?PASSWORD5),
    ok = model_friends:add_friend(?UID1, ?UID2),
    ok = model_friends:add_friend(?UID1, ?UID3),
    ok = model_friends:add_friend(?UID1, ?UID5),
    ok = model_privacy:block_uid(?UID5, ?UID1),
    ok.


ping_test(_Conf) ->
    {ok, C} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    Id = <<"iq_id_1">>,
    Payload = #pb_ping{},
    Result = ha_client:send_iq(C, Id, get, Payload),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = undefined
        }
    } = Result,
    ok.


delete_account_test(_Conf) ->
    Phone = <<"14703381473">>,
    ok = model_accounts:create_account(?UID7, Phone, ?NAME3, ?UA, ?TS1),
    ok = model_phone:add_phone(Phone, ?UID7),
    ok = ejabberd_auth:set_password(?UID7, ?PASSWORD1),
    {ok, C} = ha_client:connect_and_login(?UID7, ?PASSWORD1),
    Id = <<"iq_id_1">>,
    Payload = #pb_delete_account{phone = <<"+14703381473">>},
    Result = ha_client:send_iq(C, Id, set, Payload),
    ?assertEqual(result, Result#pb_packet.stanza#pb_iq.type),
    ?assertEqual(#pb_delete_account{}, Result#pb_packet.stanza#pb_iq.payload),
    ok.


dummy_test(_Conf) ->
    ok = ok.


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

