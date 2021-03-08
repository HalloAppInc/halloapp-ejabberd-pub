%%%-------------------------------------------------------------------
%%% File: stat_opentsdb_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(stat_opentsdb_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-define(MACHINE_KEY, <<"machine">>).
-define(MACHINE_VALUE, <<"test_localhost">>).

%% record definitions from erlcloud.
%% including those header files directly is causing some issue.
-record(dimension,
{
    name    ::string(),
    value   ::string()
}).

-record(statistic_set,
{
    sample_count    ::non_neg_integer(),
    maximum         ::float(),
    minimum         ::float(),
    sum             ::float()
}).


setup() ->
    tutil:setup(),
    stringprep:start(),
    clear(),
    put(?MACHINE_KEY, ?MACHINE_VALUE),
    ok.


clear() ->
    erase(?MACHINE_KEY),
    ok.


convert_metric_to_map_test() ->
    setup(),
    Dims = [#dimension{name = test1, value = value1}, #dimension{name = "test2", value = 20}],
    Key = {metric, "server/data/namespace1", "test1", Dims, []},
    Value = #statistic_set{sum = 20},
    TimestampMs = 1612890476217,
    TagsAndValues = #{
        ?MACHINE_KEY => ?MACHINE_VALUE,
        <<"test1">> => <<"value1">>,
        <<"test2">> => <<"20">>
    },
    ?assertEqual(
            #{
                <<"metric">> => <<"server.data.namespace1.test1">>,
                <<"timestamp">> => 1612890476217,
                <<"value">> => 20,
                <<"tags">> => TagsAndValues
            }, stat_opentsdb:convert_metric_to_map({Key, Value}, TimestampMs)),
    ok.


compose_tags_test() ->
    setup(),
    ?assertEqual(#{?MACHINE_KEY => ?MACHINE_VALUE}, stat_opentsdb:compose_tags([])),

    Dims = [#dimension{name = test1, value = value1}, #dimension{name = "test2", value = 20}],
    ?assertEqual(#{
            ?MACHINE_KEY => ?MACHINE_VALUE,
            <<"test1">> => <<"value1">>,
            <<"test2">> => <<"20">>
        }, stat_opentsdb:compose_tags(Dims)),

    ?assertEqual(#{
            ?MACHINE_KEY => ?MACHINE_VALUE
        }, stat_opentsdb:compose_tags([])),
    ok.

