%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Aug 2020 1:44 PM
%%%-------------------------------------------------------------------
-module(mod_aws_tests).
-author("josh").

-include("mod_aws.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(SECRET1, <<"Secret1">>).
-define(SECRET2, <<"Secret2">>).
-define(SECRET1_VALUE, <<"{\"api_key\": \"data\"}">>).

%%====================================================================
%% Tests
%%====================================================================

create_delete_table_test() ->
    setup(),
    ?assertNotEqual(undefined, ets:info(?SECRETS_TABLE)),
    ?assertNotEqual(undefined, ets:info(?IP_TABLE)),
    finish(),
    ?assertEqual(undefined, ets:info(?SECRETS_TABLE)),
    ?assertEqual(undefined, ets:info(?IP_TABLE)).


fetch_secret_test() ->
    setup(),
    ?assertEqual(?SECRET1_VALUE, mod_aws:retrieve_secret(?SECRET1)),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    finish().


%% get_cached_* api is accessible for test only.
%% test if caching works properly.
get_cached_secret_test() ->
    setup(),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    ?assertEqual(?SECRET1_VALUE, mod_aws:get_and_cache_secret(?SECRET1)),
    ?assert(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(?SECRET1_VALUE, mod_aws:get_cached_secret(?SECRET1)),
    finish().


get_cached_ips_test() ->
    setup(),
    ?assertNot(ets:member(?IP_TABLE, ?LOCALHOST_IPS)),
    ?assertEqual(undefined, mod_aws:get_cached_machines()),
    ?assertEqual(?LOCALHOST_IPS, mod_aws:get_and_cache_machines()),
    ?assert(ets:member(?IP_TABLE, ip_list)),
    ?assertEqual(?LOCALHOST_IPS, mod_aws:get_cached_machines()),
    finish().


get_secret_test() ->
    setup(),
    %% Test that the secret is always dummy_secret for any id in testing environment.
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    ?assertEqual(?DUMMY_SECRET, mod_aws:get_secret(?SECRET1)),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(?DUMMY_SECRET, mod_aws:get_secret(?SECRET2)),
    finish().

get_secret_value_test() ->
    setup(),
    tutil:meck_init(mod_aws, get_secret, fun(_Name) -> ?SECRET1_VALUE end),
    ?assertEqual("data", mod_aws:get_secret_value(?SECRET1, <<"api_key">>)),
    tutil:meck_finish(mod_aws),
    finish(),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

% this only properly mocks the part being inspected by mod_aws code
mock_get_secret_value(SecretName, _Opts) ->
    case SecretName of
        ?SECRET1 ->
            {ok, [arn, created_date, name,
                {<<"SecretString">>, ?SECRET1_VALUE}, id, stage]}
    end.


% mock format of what erlcloud_ec2:describe_instances would return
mock_get_ec2_instances(_, _, _) ->
    [{Name, Ip}] = ?LOCALHOST_IPS,
    Res = [[a, b, {instances_set, [[{ip_address, Ip}, {tag_set, [[{key, "Name"}, {value, Name}]]}]]}]],
    {ok, Res}.


setup() ->
    tutil:meck_init(ejabberd_hooks, [
        {add, fun(_, _, _, _) -> ok end},
        {delete, fun(_, _, _, _) -> ok end}]),
    ok = mod_aws:start(util:get_host(), []),
    application:ensure_all_started(erlcloud),
    tutil:meck_init(erlcloud_sm, get_secret_value, fun mock_get_secret_value/2),
    tutil:meck_init(erlcloud_ec2, describe_instances, fun mock_get_ec2_instances/3),
    ok.


finish() ->
    ok = mod_aws:stop(util:get_host()),
    tutil:meck_finish(ejabberd_hooks),
    tutil:meck_finish(erlcloud_sm),
    tutil:meck_finish(erlcloud_ec2),
    ok.

