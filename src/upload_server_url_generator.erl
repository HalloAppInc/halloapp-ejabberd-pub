%%   - To returns (key, patch_url) patch_url to patch content to an S3 object
%% via the upload server
%%-----------------------------------------------------------------------------

-module(upload_server_url_generator).

-include_lib("stdlib/include/assert.hrl").

-export([make_patch_url/1,
         init/1,
         close/0
        ]).

-include("logger.hrl").

-define(BACK_OFF_MS, 100).
-define(CONNECT_TIMEOUT_MS, 8000).
-define(CONTENT_TYPE, "application/json").
-define(HTTP_TIMEOUT_MS, 10000).
-define(MAX_TRIES, 10).

%% Generates signed url for Http patch, returns {Key, PatchUrl}.
- spec make_patch_url(integer()) -> {string(), string()}.
make_patch_url(ContentLength) ->
    case create_with_retry(ContentLength, ?MAX_TRIES, ?BACK_OFF_MS) of
        {error, _} ->
            {"", ""};
        {ok, LocationUrl} ->
            %% Extract the key.
            Key = string:slice(string:find(LocationUrl, get_upload_path()),
                               length(get_upload_path())),
            {Key, LocationUrl}
    end.

create_with_retry(ContentLength, MaxRetries, Backoff) ->
    create_with_retry(ContentLength, 0, MaxRetries, Backoff).
create_with_retry(ContentLength, Retries, MaxRetries, Backoff) ->
    case create(ContentLength) of
        %% Only retry on timeout errors
        {error, {http_error, {error,Error}}}
           when Retries < MaxRetries
           andalso (Error == 'timeout' orelse Error == 'connect_timeout') ->
            timer:sleep(round(math:pow(2, Retries)) * Backoff),
            create_with_retry(ContentLength, Retries+1, MaxRetries, Backoff);
        {error, _} ->
            {error, ""};
        {ok, {{_, 201, _}, Headers, _}} ->
           %% Extract location headers.
           LocationHdr = [Location || {"location", _} = Location <- Headers],
           [{_, LocationUrl}] = LocationHdr,
           {ok, LocationUrl}
    end.

create(ContentLength) ->
    Req = {url(), get_hdrs(ContentLength), to_list(?CONTENT_TYPE), <<>>},
    Begin = os:timestamp(),
    ejabberd_hooks:run(backend_api_call, get_upload_host(),
                       [get_upload_host(), post, get_upload_path()]),
    Result = httpc:request(post, Req, get_http_opts(), []),
    case Result of
        {error, {http_error, {error, timeout}}} ->
            ejabberd_hooks:run(backend_api_timeout, get_upload_host(),
                               [get_upload_host(), post, get_upload_path()]);
        {error, {http_error, {error, connect_timeout}}} ->
            ejabberd_hooks:run(backend_api_timeout, get_upload_host(),
                               [get_upload_host(), post, get_upload_path()]);
        {error, Error} ->
            ejabberd_hooks:run(backend_api_error, get_upload_host(),
                               [get_upload_host(), post, get_upload_path(),
                                Error]);
        _ ->
            End = os:timestamp(),
            Elapsed = timer:now_diff(End, Begin) div 1000, %% time in ms
            ejabberd_hooks:run(backend_api_response_time, get_upload_host(),
                               [get_upload_host(), post, get_upload_path(),
                                Elapsed])
    end,
    Result.

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
    Size = ejabberd_option:ext_api_http_pool_size(UploadHost),
    httpc:set_options([{max_sessions, Size}]).

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
