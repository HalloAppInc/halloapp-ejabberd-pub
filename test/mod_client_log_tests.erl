%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_client_log_tests).
-author("nikola").

-include("xmpp.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(NS1, <<"ns1">>).
-define(NS2, <<"ns2">>).
-define(BAD_NS1, <<"das*()">>).
-define(METRIC1, <<"m1">>).
-define(METRIC2, <<"m2">>).
-define(COUNT1, 2).
-define(COUNT2, 7).

-define(EVENT1, <<"{\"duration\": 1.2, \"num_photos\": 2, \"num_videos\": 1}">>).
-define(EVENT2, <<"{\"duration\": 0.1, \"num_photos\": 0, \"num_videos\": 7}">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ok.


create_count_st(Namespace, Metric, Count, Dims) ->
    #count_st{
        namespace = Namespace,
        metric = Metric,
        count = Count,
        dims = Dims
    }.


create_event_st(Namespace, Event) ->
    #event_st{
        namespace = Namespace,
        event = Event
    }.

create_client_log_IQ(Uid, Counts, Events) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #client_log_st{
                counts = Counts,
                events = Events
            }
        ]
    }.


mod_client_log_test() ->
    setup(),
    Host = <<"s.halloapp.net">>,
    ?assertEqual(ok, mod_client_log:start(Host, [])),
    ?assertEqual(ok, mod_client_log:stop(Host)),
    ?assertEqual([], mod_client_log:depends(Host, [])),
    ?assertEqual([], mod_client_log:mod_options(Host)),
    ok.


client_log_test() ->
    setup(),
    Counts = [
        create_count_st(?NS1, ?METRIC1, ?COUNT1, []),
        create_count_st(?NS2, ?METRIC2, ?COUNT2, [])
    ],
    Events = [
        create_event_st(?NS1, ?EVENT1),
        create_event_st(?NS1, ?EVENT2)
    ],
    IQ = create_client_log_IQ(?UID1, Counts, Events),
    IQRes = mod_client_log:process_local_iq(IQ),
    tutil:assert_empty_result_iq(IQRes),
    ok.

client_log_bad_namespace_test() ->
    setup(),
    Counts = [
        create_count_st(?BAD_NS1, ?METRIC1, ?COUNT1, []),
        create_count_st(?NS2, ?METRIC2, ?COUNT2, [])
    ],
    Events = [
        create_event_st(?NS2, ?EVENT1),
        create_event_st(?BAD_NS1, ?EVENT2)
    ],
    IQ = create_client_log_IQ(?UID1, Counts, Events),
    IQRes = mod_client_log:process_local_iq(IQ),
    ?assertEqual(util:err(bad_request), tutil:get_error_iq_sub_el(IQRes)),
    ok.

