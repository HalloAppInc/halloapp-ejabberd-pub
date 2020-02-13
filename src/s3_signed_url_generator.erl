%%   - (put) returns (put_url, get_url) put_url to put content to an S3 object
%%           and get_url to fetch content of the uploaded S3 object.
%%-----------------------------------------------------------------------------

-module(s3_signed_url_generator).

-include_lib("stdlib/include/assert.hrl").

-export([make_signed_url/1,
         make_signed_url/2,
         make_signed_url/3,
         init/1,
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
    %% Generate uuid, reference: RFC 4122.
    Key = uuid:to_string(uuid:uuid1()),

    %% We use region specific keys depending on the location of the uploading
    %% client.
    %% TODO(tbd): Implement region specific keys.
    RegionKey = "001-" ++ Key,
    SignedUrl = make_signed_url(put, Expires, RegionKey),
    {RegionKey, SignedUrl}.

%% Generates signed url for Http get, returns SignedUrl.
- spec make_signed_url(integer(), string()) -> string().
make_signed_url(Expires, Key) ->
    make_signed_url(get, Expires, Key).

-spec make_signed_url(atom(), integer(), string()) -> string().
make_signed_url(Method, ExpireTime, Key) ->
    %% TODO(tbd): Compute S3Region depending on the region id present in the
    %% key.
    S3Region = "us-west-2",
    %% Use accelerated dualstack endpoint.
    %% Ref: https://docs.aws.amazon.com/AmazonS3/latest/dev/transfer-acceleration.html
    S3Host = "s3-accelerate.dualstack.amazonaws.com",
    Host = lists:flatten([get_bucket_name(), ".", S3Host]),
    URI = "/" ++ Key,

    case {Method, is_signed_get_needed()} of
        {get, false} -> lists:flatten(["https://", Host, URI]);
        {get, true} -> make_signed_url(Method, ExpireTime, S3Region, Host, URI);
        {put, _} -> make_signed_url(Method, ExpireTime, S3Region, Host, URI);
        {_, _} -> throw({error, "Works for get/put only at this point."})
    end.

- spec make_signed_url(atom(), integer(), string(), string(), string()) -> string().
make_signed_url(Method, ExpireTime, S3Region, Host, URI) ->
    %% TODO(tbd): Use erlcloud_aws:auto_config_metadata() after building
    %% awareness, auto_config_metadata() builds specifically from ec2 instance
    %% metadata whereas auto_config() looks at env, user profile, ecs task
    %% profile and then instance metadata.
    {_, AwsConfig} = erlcloud_aws:auto_config(),
    erlcloud_aws:sign_v4_url(Method, URI, AwsConfig,
                             Host, S3Region, "s3", [], ExpireTime).

- spec init(string()) -> ok.
init(Bucket) ->
    ?INFO_MSG("~p", [init]),
    internal_init(Bucket),
    ssl:start(),
    erlcloud:start().

- spec close() -> ok.
close() ->
    ?INFO_MSG("~p", [close]),
    internal_close().

%%-----------------------------------------------------------------------------
%% To keep the env and configuration variables.
%%-----------------------------------------------------------------------------

internal_init(Bucket) ->
    ?assert(not is_boolean(Bucket)),
    BucketStr = binary_to_list(Bucket),
    ?assert(length(BucketStr) > 0),
    persistent_term:put({?MODULE, bucket}, BucketStr),

    % Do we need to generate signed 'GET' from S3, default false.
    Val = os:getenv(?IsSignedGetNeeded),
    case Val of
        "true" -> persistent_term:put({?MODULE, is_signed_get_needed},
                                      true);
        _ ->  persistent_term:put({?MODULE, is_signed_get_needed}, false)
    end,
    ?INFO_MSG("S3 Bucket: ~p", [get_bucket_name()]),
    ?INFO_MSG("Need signed get?: ~p", [is_signed_get_needed()]).

%% To clear state kept by this module.
internal_close() ->
    persistent_term:erase({?MODULE, bucket}),
    persistent_term:erase({?MODULE, is_signed_get_needed}).

get_bucket_name() ->
    persistent_term:get({?MODULE, bucket}).

is_signed_get_needed() ->
    persistent_term:get({?MODULE, is_signed_get_needed}).
