%%   - (put) returns (put_url, get_url) put_url to put content to an S3 object
%%           and get_url to fetch content of the uploaded S3 object.
%%-----------------------------------------------------------------------------

-module(s3_signed_url_generator).

-include_lib("stdlib/include/assert.hrl").

-export([make_signed_url/1,
         make_signed_url/2,
         make_signed_url/3,
         init/3,
         close/0
        ]).

%% Name of env variable to decide if we need signed Http GET.
-define(IsSignedGetNeeded, "HALLO_MEDIA_IS_SIGNED_GET").

-include("deps/erlcloud/include/erlcloud.hrl").
-include("deps/erlcloud/include/erlcloud_aws.hrl").
-include_lib("lhttpc/include/lhttpc_types.hrl").
-include("logger.hrl").

%% Generates signed url for Http put, returns {Key, SignedUrl}.
- spec make_signed_url(integer()) -> {string(), string()}.
make_signed_url(Expires) ->
    %% Generate uuid, reference: RFC 4122. Do url friendly base64 encoding of
    %% the uuid.
    Key = binary_to_list(base64url:encode(uuid:uuid1())),
    SignedUrl = make_signed_url(put, Expires, Key),
    {Key, SignedUrl}.

%% Generates signed url for Http get, returns SignedUrl.
- spec make_signed_url(integer(), string()) -> string().
make_signed_url(Expires, Key) ->
    make_signed_url(get, Expires, Key).

-spec make_signed_url(atom(), integer(), string()) -> string().
make_signed_url(Method, ExpireTime, Key) ->
    URI = "/" ++ Key,

    case {Method, is_signed_get_needed()} of
        {get, false} -> lists:flatten(["https://", get_get_host(), URI]);
        {get, true} -> make_signed_url(Method, ExpireTime, get_get_host(), URI);
        {put, _} -> make_signed_url(Method, ExpireTime, get_put_host(), URI);
        {_, _} -> throw({error, "Works for get/put only at this point."})
    end.

- spec make_signed_url(atom(), integer(), string(), string()) -> string().
make_signed_url(Method, ExpireTime, Host, URI) ->
    %% TODO(tbd): Use erlcloud_aws:auto_config_metadata() after building
    %% awareness, auto_config_metadata() builds specifically from ec2 instance
    %% metadata whereas auto_config() looks at env, user profile, ecs task
    %% profile and then instance metadata.
    {_, AwsConfig} = erlcloud_aws:auto_config(),
    erlcloud_aws:sign_v4_url(Method, URI, AwsConfig,
                             Host, get_region(), "s3", [], ExpireTime).

- spec init(string(), string(), string()) -> ok.
init(Region, PutHost, GetHost) ->
    ?INFO_MSG("~p", [init]),
    internal_init(Region, PutHost, GetHost),
    ssl:start(),
    erlcloud:start().

- spec close() -> ok.
close() ->
    ?INFO_MSG("~p", [close]),
    internal_close().

%%-----------------------------------------------------------------------------
%% To keep the env and configuration variables.
%%-----------------------------------------------------------------------------

internal_init(Region, PutHost, GetHost) ->
    ?assert(not is_boolean(Region)),
    RegionStr = binary_to_list(Region),
    ?assert(length(RegionStr) > 0),
    persistent_term:put({?MODULE, region}, RegionStr),

    ?assert(not is_boolean(PutHost)),
    PutHostStr = binary_to_list(PutHost),
    ?assert(length(PutHostStr) > 0),
    persistent_term:put({?MODULE, put_host}, PutHostStr),

    ?assert(not is_boolean(GetHost)),
    GetHostStr = binary_to_list(GetHost),
    ?assert(length(GetHostStr) > 0),
    persistent_term:put({?MODULE, get_host}, GetHostStr),

    % Do we need to generate signed 'GET' from S3, default false.
    Val = os:getenv(?IsSignedGetNeeded),
    case Val of
        "true" -> persistent_term:put({?MODULE, is_signed_get_needed},
                                      true);
        _ ->  persistent_term:put({?MODULE, is_signed_get_needed}, false)
    end,
    ?INFO_MSG("Need signed get?: ~p", [is_signed_get_needed()]).

%% To clear state kept by this module.
internal_close() ->
    persistent_term:erase({?MODULE, get_host}),
    persistent_term:erase({?MODULE, put_host}),
    persistent_term:erase({?MODULE, region}),
    persistent_term:erase({?MODULE, is_signed_get_needed}).

get_region() ->
    persistent_term:get({?MODULE, region}).

get_put_host() ->
    persistent_term:get({?MODULE, put_host}).

get_get_host() ->
    persistent_term:get({?MODULE, get_host}).

is_signed_get_needed() ->
    persistent_term:get({?MODULE, is_signed_get_needed}).
