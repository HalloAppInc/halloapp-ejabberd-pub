-module(ha_SUITE).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    dummy_test/1,
    connect_test/1,
    auth_no_user_test/1,
    run_eunit/1
]).

-include("suite.hrl").


all() -> [
    dummy_test,
    connect_test,
    auth_no_user_test,
    run_eunit
].


init_per_suite(InitConfigData) ->
    ct:pal("Config ~p", [InitConfigData]),
    NewConfig = suite_ha:init_config(InitConfigData),
    inet_db:add_host({127,0,0,1}, [
        binary_to_list(?S2S_VHOST),
        binary_to_list(?MNESIA_VHOST),
        binary_to_list(?UPLOAD_VHOST)]),
    inet_db:set_domain(binary_to_list(p1_rand:get_string())),
    inet_db:set_lookup([file, native]),
    start_ejabberd(NewConfig),
    NewConfig.


start_ejabberd(_Config) ->
    {ok, _} = application:ensure_all_started(ejabberd, transient).


end_per_suite(_Config) ->
    application:stop(ejabberd).


dummy_test(_Conf) ->
    ok = ok.


connect_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
%%    ha_client:send_auth(C, 1, <<"wrong_password">>),
%%    M = ha_client:recv(C),
%%    ct:pal("Got Auth Reply ~p", [M]),
    ok = ha_client:close(C),
    ok.

auth_no_user_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    ha_client:send_auth(C, 1, <<"wrong_password">>),
    Result = ha_client:recv(C),

    ct:pal("Got Auth Reply ~p", [Result]),
    ok = ha_client:close(C),
    ok.


run_eunit(_Config) ->
    % TODO: apparently you can run the eunit tests from here but this did not work
    % See if we can make the eunit tests run here.
    %%    ok = eunit:test(model_accounts).
    ok.

