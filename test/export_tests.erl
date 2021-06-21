%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Jun 2021 3:10 PM
%%%-------------------------------------------------------------------
-module(export_tests).
-author("nikola").

-compile(export_all).
-include("packets.hrl").
-include("time.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

group() ->
    {export, [sequence], [
        export_dummy_test,
        export_export_test
    ]}.

dummy_test(_Conf) ->
    ok.

export_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    Id = <<"iq_id1">>,
    Payload = #pb_export_data{
    },
    % export data
    Result1 = ha_client:send_iq(C1, Id, set, Payload),
    Result1Payload = Result1#pb_packet.stanza#pb_iq.payload,
    #pb_export_data{
        data_ready_ts = ReadyTs,
        data_url = <<>>,
        status = pending
    } = Result1Payload,

    ?assert(erlang:abs(util:now() + 3*?DAYS - ReadyTs) < 10),

    {ok, OriginalStartTs, ExportId} = model_accounts:get_export(?UID1),
    % set fake time in the database, making it look like the export request happened 3 days ago.
    model_accounts:test_set_export_time(?UID1, util:now() - 3*?DAYS - 100),
    {ok, ModifiedStartTs, ExportId} = model_accounts:get_export(?UID1),
    ct:pal("Create Group Result : ~p ~p", [OriginalStartTs, ModifiedStartTs]),

    % make the same request
    Result2 = ha_client:send_iq(C1, Id, set, Payload),
    Result2Payload = Result2#pb_packet.stanza#pb_iq.payload,
    #pb_export_data{
        data_ready_ts = ReadyTs2,
        data_url = DataUrl,
        status = ready
    } = Result2Payload,

    ?assertEqual("https://halloapp.com/export/" ++ binary_to_list(ExportId),
        binary_to_list(DataUrl)),

    % TODO: figure out how to test the actual data
    ok.
