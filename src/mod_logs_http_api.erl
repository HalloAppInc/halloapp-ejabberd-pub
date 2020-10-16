%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% HTTP API for clients to upload logs
%%% @end
%%% Created : 30. Mar 2020 11:42 AM
%%%-------------------------------------------------------------------
-module(mod_logs_http_api).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("account.hrl").
-include("ha_types.hrl").

-define(MAX_LOG_SIZE, 10485760). % 10MB
% Zip files must start with those 4 bytes
-define(ZIP_PREFIX, 16#50, 16#4b, 16#03, 16#04).
-define(S3_CLIENT_LOGS_BUCKET, <<"halloapp-client-logs">>).


%% API
-export([start/2, stop/1, reload/3, init/1, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
% TODO: duplicate code with mod_halloapp_http_api

%% /api/logs
-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([],
        #request{method = 'POST', q = Q, data = Data, ip = IP} = R) ->
    try
        {Uid, Phone, Version, _Msg} = parse_logs_query(Q),
        ?INFO_MSG("Logs from Uid: ~p Phone: ~p Version: ~p: ip: ~p", [Uid, Phone, Version, IP]),
        ok = check_data(Data),
        Date = iso8601:format(now()),
        ObjectKey = make_object_key(Uid, Phone, Date, Version),
        ?INFO_MSG("ObjectKey: ~p", [ObjectKey]),

        case upload_log(ObjectKey, Data) of
            ok ->
                {200, ?HEADER(?CT_PLAIN), <<"ok">>};
            error ->
                util_http:return_500()
        end
    catch
        error : Reason when
                Reason =:= invalid_uid orelse
                Reason =:= invalid_phone orelse
                Reason =:= invalid_version orelse
                Reason =:= log_in_not_zip orelse
                Reason =:= log_too_big ->
            util_http:return_400(Reason);
        error : Reason : Stacktrace ->
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process(Path, Request) ->
    ?WARNING("Bad Request: path: ~p, r:~p", [Path, Request]),
    util_http:return_400().

-spec parse_logs_query(Q :: proplist()) ->
        {Uid :: binary(), Phone :: binary(), Version :: binary(), Msg :: binary()}.
parse_logs_query(Q) ->
    Uid = proplists:get_value(<<"uid">>, Q, <<"NOUID">>),
    Phone = proplists:get_value(<<"phone">>, Q, <<"NOPHONE">>),
    Version = proplists:get_value(<<"version">>, Q, undefined),
    Msg = proplists:get_value(<<"msg">>, Q, undefined),
    ?INFO_MSG("~p ~p ~p ~p", [Uid, Phone, Version, Msg]),
    case Uid of
        <<"NOUID">> -> ok;
        _ ->
            case util:to_integer(Uid) =:= undefined orelse byte_size(Uid) =/= util_uid:uid_size() of
                true -> error({invalid_uid, Uid});
                false -> ok
            end
    end,
    case Phone of
        <<"NOPHONE">> -> ok;
        _ ->
            case util:to_integer(Phone) =:= undefined orelse byte_size(Phone) > 20 of
                true -> error({invalid_phone, Phone});
                false -> ok
            end
    end,
    case Version of
        <<"Android", _Rest/binary>> when byte_size(Version) < 20 -> ok;
        _ -> error({invalid_version, Version})
    end,
    Msg2 = binary:part(Msg, 0, min(byte_size(Msg), 1000)),
    {Uid, Phone, Version, Msg2}.

% Make sure the data is not too big and zip file
-spec check_data(Data :: binary()) -> ok. % or exception
check_data(Data) ->
    case Data of
        % check if it looks like zip, and is not too big
        <<?ZIP_PREFIX, Rest/binary>> when byte_size(Rest) < ?MAX_LOG_SIZE -> ok;
        <<?ZIP_PREFIX, _Rest/binary>> -> error(log_too_big);
        _ -> error(log_is_not_zip)
    end.


make_object_key(Uid, Phone, Date, Version) ->
    <<Uid/binary, "-", Phone/binary, "/", Date/binary, "_", Version/binary, ".zip">>.


% TODO: duplicated code with mod_user_avatar
-spec upload_log(ObjectName :: binary(), Date :: binary()) -> ok | error.
upload_log(ObjectKey, Data) ->

    Headers = [{"content-type", "application/zip"}],
    try
        init_erlcloud(),
        Result = erlcloud_s3:put_object(binary_to_list(
            ?S3_CLIENT_LOGS_BUCKET), binary_to_list(ObjectKey), Data, [], Headers),
        ?INFO("ObjectName: ~s, Result: ~p", [ObjectKey, Result]),
        ok
    catch Class : Reason : St ->
        ?ERROR("ObjectKey: ~s, Error uploading object to s3: Stacktrace: ~s",
            [ObjectKey, lager:pr_stacktrace(St, {Class, Reason})]),
        error
    end.


init_erlcloud() ->
    % TODO: this code is duplicated in other modules using erlcloud...
    % one solution is to make a module to initialize erlcloud and make other modules depend on it
    {ok, _} = application:ensure_all_started(erlcloud),
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    ok.

start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

init(_Opts) ->
    ?INFO("~p init ~p", [?MODULE, _Opts]),
    process_flag(trap_exit, true),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
