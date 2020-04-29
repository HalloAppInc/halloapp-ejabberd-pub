%%   - To returns (key, patch_url) patch_url to patch content to an S3 object
%% via the upload server
%%-----------------------------------------------------------------------------

-module(upload_server_url_generator).

-include_lib("stdlib/include/assert.hrl").

-export([make_patch_url/2, create_with_retry/3,
         init/2,
         close/0
        ]).

-include("logger.hrl").

-define(BACK_OFF_MS, 100).
-define(CONNECT_TIMEOUT_MS, 8000).
-define(CONTENT_TYPE, "application/json").
-define(HTTP_TIMEOUT_MS, 10000).
-define(MAX_TRIES, 8).
-define(UPLOAD_SERVER_HTTP_POOL_SIZE, 10).

%% Generates url for Http patch, returns {Key, PatchUrl} via the callback.
- spec make_patch_url(integer(), any()) -> ok.
make_patch_url(ContentLength, CBDetails) ->
    create_with_retry(ContentLength, CBDetails).

process_location_url(Location, CBDetails) ->
    {CBModule, CBFunction, Param} = CBDetails,
    case Location of
        {error, _} -> CBModule:CBFunction(Param, error);
        {ok, LocationUrl} -> CBModule:CBFunction(Param, {ok, LocationUrl})
    end.

create_with_retry(ContentLength, CBDetails) ->
    create_with_retry(ContentLength, 0, CBDetails).
create_with_retry(ContentLength, Retries, CBDetails) ->
    case create(ContentLength) of
        {ok, {{_, 201, _}, Headers, _}} ->
           %% Extract location headers.
           LocationHdr = [Location || {"location", _} = Location <- Headers],
           [{_, LocationUrl}] = LocationHdr,
           process_location_url({ok, LocationUrl}, CBDetails);
        %% Retry on http errors.
        {_, Error}
           when Retries < ?MAX_TRIES ->
            BackOff = round(math:pow(2, Retries)) * ?BACK_OFF_MS,
            ?WARNING_MSG("~pth request to: ~p, error: ~p, backoff: ~p",
                         [Retries, get_upload_host(), Error, BackOff]),
            timer:apply_after(round(math:pow(2, Retries)) * ?BACK_OFF_MS,
                              ?MODULE, create_with_retry,
                              [ContentLength, Retries+1, CBDetails]);
        {_, Error} ->
            ?ERROR_MSG("Giving up on: ~p, tried: ~p times, error: ~p",
                       [get_upload_host(), Retries, Error]),
            process_location_url({error, ""}, CBDetails)
    end.

create(ContentLength) ->
    Req = {url(), get_hdrs(ContentLength), ?CONTENT_TYPE, <<>>},
    httpc:request(post, Req, get_http_opts(), []).

- spec init(binary(), integer()) -> ok.
init(UploadHost, UploadPort) ->
    ?INFO_MSG("init UploadHost: ~p, UploadPort: ~p", [UploadHost, UploadPort]),
    ?assert(not is_boolean(UploadHost)),
    UploadHostStr = binary_to_list(UploadHost),
    ?assert(length(UploadHostStr) > 0),
    persistent_term:put({?MODULE, upload_host}, UploadHostStr),

    ?assert(UploadPort > 0),
    ?assert(UploadPort < 65000),
    persistent_term:put({?MODULE, upload_port}, UploadPort),

    application:start(inets),
    httpc:set_options([{max_sessions, ?UPLOAD_SERVER_HTTP_POOL_SIZE}]),
    ssl:start().

- spec close() -> ok.
close() ->
    ?INFO_MSG("~p", [close]),
    persistent_term:erase({?MODULE, upload_host}).

%%-----------------------------------------------------------------------------

url() ->
    lists:concat([get_protocol() , get_upload_host(), ":",
                  integer_to_list(get_upload_port()),
                  get_upload_path()]).

get_upload_host() ->
    persistent_term:get({?MODULE, upload_host}).

get_upload_port() ->
    persistent_term:get({?MODULE, upload_port}).

get_upload_path() ->
    "/files/".

%% Call to create the upload object is expected to happen within our VPC and
%% that is the reason for using http instead of https.
get_protocol() ->
    "http://".

get_hdrs(ContentLength) ->
    [{"connection", "keep-alive"},
     {"Tus-Resumable", "1.0.0"},
     {"Upload-Length", integer_to_list(ContentLength)}].

get_http_opts() ->
    [{connect_timeout, ?CONNECT_TIMEOUT_MS}, {timeout, ?HTTP_TIMEOUT_MS}].
