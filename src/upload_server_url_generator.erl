%%   - To returns (key, patch_url) patch_url to patch content to an S3 object
%% via the upload server
%%-----------------------------------------------------------------------------

-module(upload_server_url_generator).

-include_lib("stdlib/include/assert.hrl").

-export([make_patch_url/2,
         init/1,
         close/0
        ]).

-include("logger.hrl").

-define(BACK_OFF_MS, 100).
-define(CONNECT_TIMEOUT_MS, 8000).
-define(CONTENT_TYPE, "application/json").
-define(HTTP_TIMEOUT_MS, 10000).
-define(MAX_TRIES, 10).
-define(UPLOAD_SERVER_HTTP_POOL_SIZE, 10).

%% Generates url for Http patch, returns {Key, PatchUrl} via the callback.
- spec make_patch_url(integer(), any()) -> ok.
make_patch_url(ContentLength, CBDetails) ->
    create_with_retry(ContentLength, CBDetails).

process_location_url(Location, CBDetails) ->
    {Param, CBModule, CBFunction} = CBDetails,
    case Location of
        {error, _} -> CBModule:CBFunction(Param, {"", ""});
        {ok, LocationUrl} ->
            %% Extract the key.
            Key = string:slice(string:find(LocationUrl, get_upload_path()),
                               length(get_upload_path())),
            CBModule:CBFunction(Param, {Key, LocationUrl})
    end.

create_with_retry(ContentLength, CBDetails) ->
    create_with_retry(ContentLength, 0, CBDetails).
create_with_retry(ContentLength, Retries, CBDetails) ->
    case create(ContentLength) of
        %% Only retry on timeout errors
        {error, {http_error, {error, Error}}}
           when Retries < ?MAX_TRIES
           andalso (Error == 'timeout' orelse Error == 'connect_timeout') ->
            timer:apply_after(round(math:pow(2, Retries)) * ?BACK_OFF_MS,
                              ?MODULE, create_with_retry,
                              [ContentLength, Retries+1, CBDetails]);
        {error, _} ->
            process_location_url({error, ""}, CBDetails);
        {ok, {{_, 201, _}, Headers, _}} ->
           %% Extract location headers.
           LocationHdr = [Location || {"location", _} = Location <- Headers],
           [{_, LocationUrl}] = LocationHdr,
           process_location_url({ok, LocationUrl}, CBDetails)
    end.

create(ContentLength) ->
    Req = {url(), get_hdrs(ContentLength), to_list(?CONTENT_TYPE), <<>>},
    httpc:request(post, Req, get_http_opts(), []).

url() ->
    lists:concat([get_protocol() , get_upload_host(), get_upload_path()]).

- spec init(string()) -> ok.
init(UploadHost) ->
    ?INFO_MSG("init UploadHost: ~p", [UploadHost]),
    internal_init(UploadHost),
    ssl:start().

- spec close() -> ok.
close() ->
    ?INFO_MSG("~p", [close]),
    internal_close().

%%-----------------------------------------------------------------------------
%% To keep config.
%%-----------------------------------------------------------------------------

internal_init(UploadHost) ->
    ?assert(not is_boolean(UploadHost)),
    UploadHostStr = binary_to_list(UploadHost),
    ?assert(length(UploadHostStr) > 0),
    persistent_term:put({?MODULE, upload_host}, UploadHostStr),

    application:start(inets),
    httpc:set_options([{max_sessions, ?UPLOAD_SERVER_HTTP_POOL_SIZE}]).

%% To clear state kept by this module.
internal_close() ->
    persistent_term:erase({?MODULE, upload_host}).

get_upload_host() ->
    persistent_term:get({?MODULE, upload_host}).

get_upload_path() ->
    "/files/".

get_protocol() ->
    "https://".

get_hdrs(ContentLength) ->
    [{"connection", "keep-alive"},
     {"Tus-Resumable", "1.0.0"},
     {"Upload-Length", integer_to_list(ContentLength)}].

get_http_opts() ->
    [{connect_timeout, ?CONNECT_TIMEOUT_MS}, {timeout, ?HTTP_TIMEOUT_MS}].

to_list(V) when is_binary(V) ->
    binary_to_list(V);
to_list(V) when is_list(V) ->
    V.
