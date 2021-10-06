-module(trace_tests).

-compile(export_all).
-include("suite.hrl").
-include("account_test_data.hrl").
-include("packets.hrl").
-include_lib("stdlib/include/assert.hrl").


group() ->
    {trace, [parallel], [
        trace_dummy_test,
        trace_slow_log_test
    ]}.

dummy_test(_Conf) ->
    ok.

get_trace_log_path() ->
    ConsoleLog = ejabberd_logger:get_log_path(),
    Dir = filename:dirname(ConsoleLog),
    filename:join([Dir, "msg_trace.log"]).

get_trace_log() ->
    {ok, Data} = file:read_file(get_trace_log_path()),
    Data.

% slow
slow_log_test(_Conf) ->
    mod_trace:start_trace(?UID1),
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, _C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    SendMsg = #pb_packet{
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = ?UID1,
            to_uid = ?UID2,
            payload = #pb_chat_stanza{payload = <<"HELLO">>}}},
    ha_client:send(C1, SendMsg),

    Ack = ha_client:wait_for(C1,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_ack{id = _Id}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_ack{id = <<"msgid1">>, timestamp = _ServerTs}
    } = Ack,
    % This is not great. But if we don't wait the data does not make it to the log
    timer:sleep(1000),
    TraceLog = get_trace_log(),
    % Checking if we can find the binary data into the tracelog
    ?assertNotEqual(nomatch,
        binary:match(TraceLog, base64:encode(enif_protobuf:encode(SendMsg)))),
    ?assertNotEqual(nomatch,
        binary:match(TraceLog, base64:encode(enif_protobuf:encode(Ack)))),
    ok.
