%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:25 PM
%%%-------------------------------------------------------------------
-module(client_log_parser_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("client_log.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% test data
%% -------------------------------------------- %%

-define(NS1, <<"ns1">>).
-define(NS2, <<"ns2">>).
-define(METRIC1, <<"m1">>).
-define(METRIC2, <<"m2">>).
-define(COUNT1, 43).
-define(COUNT2, 54).
-define(D1NAME, <<"d1name">>).
-define(D2NAME, <<"d2name">>).
-define(D1VALUE1, <<"d1value1">>).
-define(D1VALUE2, <<"d1value2">>).
-define(D2VALUE1, <<"d2value1">>).
-define(EVENT1, <<"event1">>).
-define(EVENT2, <<"event2">>).

-define(XMPP_CLIENT_LOG,
    #client_log_st{
        counts = [
            #count_st{namespace = ?NS1, metric = ?METRIC1, count = ?COUNT1, dims = [
                #dim_st{name = ?D1NAME, value = ?D1VALUE1},
                #dim_st{name = ?D2NAME, value = ?D2VALUE1}
            ]},
            #count_st{namespace = ?NS2, metric = ?METRIC2, count = ?COUNT2, dims = [
                #dim_st{name = ?D1NAME, value = ?D1VALUE2}
            ]}
        ],
        events = [
            #event_st{namespace = ?NS1, event = ?EVENT1},
            #event_st{namespace = ?NS2, event = ?EVENT2}
        ]
    }
).

-define(PB_CLIENT_LOG,
    #pb_client_log{
        counts = [
            #pb_count{namespace = ?NS1, metric = ?METRIC1, count = ?COUNT1, dims = [
                #pb_dim{name = ?D1NAME, value = ?D1VALUE1},
                #pb_dim{name = ?D2NAME, value = ?D2VALUE1}
            ]},
            #pb_count{namespace = ?NS2, metric = ?METRIC2, count = ?COUNT2, dims = [
                #pb_dim{name = ?D1NAME, value = ?D1VALUE2}
            ]}
        ],
        events = [
            #pb_event{namespace = ?NS1, event = ?EVENT1},
            #pb_event{namespace = ?NS2, event = ?EVENT2}
        ]
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_client_log_test() ->
    Proto = client_log_parser:xmpp_to_proto(?XMPP_CLIENT_LOG),
    ?assertEqual(true, is_record(Proto, pb_client_log)),
    ?assertEqual(?PB_CLIENT_LOG, Proto).


proto_to_xmpp_whisper_keys_test() ->
    Xmpp = client_log_parser:proto_to_xmpp(?PB_CLIENT_LOG),
    ?assertEqual(true, is_record(Xmpp, client_log_st)),
    ?assertEqual(?XMPP_CLIENT_LOG, Xmpp).

