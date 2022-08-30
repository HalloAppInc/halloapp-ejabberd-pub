%%%----------------------------------------------------------------------
%%% File    : upload_server_url_generator.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%% To returns (key, patch_url) patch_url to patch content to an S3 object
%%% via the upload server
%%%----------------------------------------------------------------------

-module(upload_server_url_generator).
-author('vipin').

-include_lib("stdlib/include/assert.hrl").
-include("logger.hrl").


-define(BACK_OFF_MS, 1000).
-define(CONNECT_TIMEOUT_MS, 1000).
-define(CONTENT_TYPE, "application/json").
-define(HTTP_TIMEOUT_MS, 2000).
-define(MAX_TRIES, 2).
-define(UPLOAD_SERVER_HTTP_POOL_SIZE, 10).


-export([
    init/2,
    close/0,
    make_patch_url/2,
    make_patch_url_with_retry/3,
    get_hdrs/1  %% for debugging
]).


-spec init(UploadHosts :: [string()], UploadPort :: integer()) -> ok.
init(UploadHosts, UploadPort) ->
    ?INFO("init UploadHosts: ~p, UploadPort: ~p", [UploadHosts, UploadPort]),
    ?assert(length(UploadHosts) > 0),
    persistent_term:put({?MODULE, upload_hosts}, UploadHosts),

    ?assert(UploadPort > 0),
    ?assert(UploadPort < 65000),
    persistent_term:put({?MODULE, upload_port}, UploadPort),

    application:start(inets),
    httpc:set_options([{max_sessions, ?UPLOAD_SERVER_HTTP_POOL_SIZE}]),
    ssl:start().


-spec close() -> ok.
close() ->
    ?INFO("~p", [close]),
    persistent_term:erase({?MODULE, upload_hosts}),
    ok.


%% Generates url for Http patch, returns {Key, PatchUrl} via the callback.
-spec make_patch_url(integer(), any()) -> ok.
make_patch_url(ContentLength, CBDetails) ->
    make_patch_url_with_retry(ContentLength, 0, CBDetails).


-spec make_patch_url_with_retry(integer(), integer(), any()) -> ok.
make_patch_url_with_retry(ContentLength, Retries, CBDetails) ->
    UploadHosts = get_upload_hosts(),
    create_with_retry(ContentLength, UploadHosts, Retries, CBDetails).


-spec create_with_retry(ContentLength :: integer(), UploadHosts :: [string()],
    Retries :: integer(), CBDetails :: term()) -> ok.
create_with_retry(ContentLength, UploadHosts, Retries, CBDetails) ->
    ToPick = p1_rand:uniform(1, length(UploadHosts)),
    ?assert(length(UploadHosts) > 0),
    PickedHost = lists:nth(ToPick, UploadHosts),
    NewUploadHosts = UploadHosts -- [PickedHost],

    ?INFO("Trying: ~p, retry attempt number: ~p", [PickedHost, Retries]),
    Req = {url(PickedHost), get_hdrs(ContentLength), ?CONTENT_TYPE, <<>>},
    case httpc:request(post, Req, get_http_opts(), []) of
        {ok, {{_, 201, _}, Headers, _}} ->
           %% Extract location headers.
           LocationHdr = [Location || {"location", _} = Location <- Headers],
           [{_, LocationUrl}] = LocationHdr,
           process_location_url({ok, LocationUrl}, CBDetails);
        %% Retry on http errors.
        {_, Error} ->
            case NewUploadHosts of
                [] ->
                    case Retries < ?MAX_TRIES of
                        true ->
                            BackOff = round(math:pow(2, Retries)) * ?BACK_OFF_MS,
                            ?WARNING("~pth retry backoff: ~p, last error: ~p,",
                                [Retries+1, BackOff, Error]),
                            timer:apply_after(round(math:pow(2, Retries)) * ?BACK_OFF_MS,
                                ?MODULE, make_patch_url_with_retry,
                                [ContentLength, Retries+1, CBDetails]);
                        false ->
                            ?ERROR("Unable to create upload server url after ~p retries, last error: ~p",
                                [?MAX_TRIES, Error]),
                            process_location_url({error, ""}, CBDetails)
                    end;
                _ ->
                    create_with_retry(ContentLength, NewUploadHosts, Retries, CBDetails)
            end
  end.


%%====================================================================
%% internal functions
%%====================================================================

-spec process_location_url(Location :: {ok, binary()} | {error, any()}, CBDetails :: term()) -> ok.
process_location_url(Location, CBDetails) ->
    {CBModule, CBFunction, Param} = CBDetails,
    case Location of
        {error, _} -> CBModule:CBFunction(Param, error);
        {ok, LocationUrl} -> CBModule:CBFunction(Param, {ok, LocationUrl})
    end.


url(UploadHost) ->
    lists:concat([get_protocol() , UploadHost, ":",
            integer_to_list(get_upload_port()), get_upload_path()]).

get_upload_hosts() ->
    persistent_term:get({?MODULE, upload_hosts}).

get_upload_port() ->
    persistent_term:get({?MODULE, upload_port}).

get_upload_path() ->
    "/files/".

%% Call to create the upload object is expected to happen within our VPC and
%% that is the reason for using http instead of https.
get_protocol() ->
    "http://".

get_hdrs(ContentLength) ->
    ContentHeader = case ContentLength of
        0 -> {"Upload-Defer-Length", "1"};
        _ -> {"Upload-Length", integer_to_list(ContentLength)}
    end,
    [{"connection", "keep-alive"}, {"Tus-Resumable", "1.0.0"} , ContentHeader].

get_http_opts() ->
    [
        {connect_timeout, ?CONNECT_TIMEOUT_MS},
        {timeout, ?HTTP_TIMEOUT_MS}
    ].

