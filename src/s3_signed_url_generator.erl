%%%----------------------------------------------------------------------
%%% File    : s3_signed_url_generator.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%% - (put) returns (put_url, get_url) put_url to put content to an S3 object
%%% and get_url to fetch content of the uploaded S3 object.
%%%----------------------------------------------------------------------

-module(s3_signed_url_generator).
-author('vipin').

-include("erlcloud.hrl").
-include("erlcloud_aws.hrl").
-include_lib("lhttpc/include/lhttpc_types.hrl").
-include("logger.hrl").
-include("time.hrl").
-include_lib("stdlib/include/assert.hrl").


%% Name of env variable to decide if we need signed Http GET.
-define(IsSignedGetNeeded, "HALLO_MEDIA_IS_SIGNED_GET").

-define(S3_OBJECT_EXPIRES, 30 * ?DAYS).


-export([
    init/4,
    close/0,
    make_signed_url/1,
    make_signed_url/2,
    make_signed_url/3,
    refresh_url/1
]).


-spec init(Region :: binary(), Bucket :: binary(), PutHost :: binary(), GetHost :: binary()) -> ok.
init(Region, Bucket, PutHost, GetHost) ->
    ?INFO("~p", [init]),
    internal_init(Region, Bucket, PutHost, GetHost),
    ssl:start(),
    erlcloud:start().

-spec close() -> ok.
close() ->
    ?INFO("~p", [close]),
    internal_close().


%% Generates signed url for Http put, returns {Key, SignedUrl}.
-spec make_signed_url(Expires :: integer()) -> {Key :: string(), SignedUrl :: string()}.
make_signed_url(Expires) ->
    %% Generate uuid, reference: RFC 4122. Do url friendly base64 encoding of
    %% the uuid.
    Key = binary_to_list(base64url:encode(util_id:new_uuid())),
    SignedUrl = make_signed_url(put, Expires, Key),
    {Key, SignedUrl}.


%% Generates signed url for Http get, returns SignedUrl.
-spec make_signed_url(Expires :: integer(), Key :: string()) -> SignedUrl :: string().
make_signed_url(Expires, Key) ->
    make_signed_url(get, Expires, Key).


-spec make_signed_url(Method :: atom(), ExpireTime :: integer(),
        Key :: string()) -> SignedUrl :: string().
make_signed_url(Method, ExpireTime, Key) ->
    URI = "/" ++ Key,

    case {Method, is_signed_get_needed()} of
        {get, false} -> lists:flatten(["https://", get_get_host(), URI]);
        {get, true} -> make_signed_url(Method, ExpireTime, get_get_host(), URI);
        {put, _} -> make_signed_url(Method, ExpireTime, get_put_host(), URI);
        {_, _} -> throw({error, "Works for get/put only at this point."})
    end.


-spec refresh_url(Url :: string()) -> boolean().
refresh_url(Url) ->
    ?INFO("refreshing Url ~p", [Url]),
    case string:find(Url, "/", trailing) of
        nomatch -> false;
        SlashKey ->
            Key = string:slice(SlashKey, 1),
            {_, AwsConfig} = erlcloud_aws:auto_config(),
            try
                % update the Expires value
                % http-date looks like this: Wed, 21 Oct 2015 07:28:00 GMT
                ExpireValue = httpd_util:rfc1123_date(
                    calendar:gregorian_seconds_to_datetime(calendar:datetime_to_gregorian_seconds(
                        calendar:local_time()) + ?S3_OBJECT_EXPIRES)),
                %% Following call will touch the s3 object so that its lifetime will be extended.
                erlcloud_s3:copy_object(get_bucket(), Key, get_bucket(), Key,
                    [
                        {metadata_directive, "REPLACE"},
                        {meta, [
                            {"Cache-Control", "public"},
                            {"Expires", ExpireValue},
                            {"touch", "true"}]}],
                    AwsConfig)
            of
                {aws_error, _} = Error ->
                    ?ERROR("Refresh Url Error: ~p", [Error]),
                    false;
                Result ->
                    ?INFO("Refresh Url Success: ~p", [Result]),
                    true
            catch
                C:R:S ->
                    ?ERROR("Refresh Url Error: ~s", [lager:pr_stacktrace(S, {C, R})]),
                    false
            end
    end.


-spec make_signed_url(Method :: atom(), ExpireTime :: integer(),
        Host :: string(), URI :: string()) -> SignedUrl :: string().
make_signed_url(Method, ExpireTime, Host, URI) ->
    %% TODO(tbd): Use erlcloud_aws:auto_config_metadata() after building
    %% awareness, auto_config_metadata() builds specifically from ec2 instance
    %% metadata whereas auto_config() looks at env, user profile, ecs task
    %% profile and then instance metadata.
    {_, AwsConfig} = erlcloud_aws:auto_config(),
    erlcloud_aws:sign_v4_url(Method, URI, AwsConfig, Host, get_region(), "s3", [], ExpireTime).


%%====================================================================
%% To keep the env and configuration variables.
%%====================================================================

internal_init(Region, Bucket, PutHost, GetHost) ->
    ?assert(not is_boolean(Region)),
    RegionStr = binary_to_list(Region),
    ?assert(length(RegionStr) > 0),
    persistent_term:put({?MODULE, region}, RegionStr),

    ?assert(not is_boolean(Bucket)),
    BucketStr = binary_to_list(Bucket),
    ?assert(length(BucketStr) > 0),
    persistent_term:put({?MODULE, bucket}, BucketStr),

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

    ?INFO("Region: ~s, Bucket: ~s, PutHost: ~s, GetHost: ~s",
        [RegionStr, BucketStr, PutHostStr, GetHostStr]),

    % Do we need to generate signed 'GET' from S3, default false.
    Val = os:getenv(?IsSignedGetNeeded),
    case Val of
        "true" -> persistent_term:put({?MODULE, is_signed_get_needed}, true);
        _ ->  persistent_term:put({?MODULE, is_signed_get_needed}, false)
    end,
    ?INFO("Need signed get?: ~p", [is_signed_get_needed()]).

%% To clear state kept by this module.
internal_close() ->
    persistent_term:erase({?MODULE, get_host}),
    persistent_term:erase({?MODULE, put_host}),
    persistent_term:erase({?MODULE, bucket}),
    persistent_term:erase({?MODULE, region}),
    persistent_term:erase({?MODULE, is_signed_get_needed}).

get_region() ->
    persistent_term:get({?MODULE, region}).

get_bucket() ->
    persistent_term:get({?MODULE, bucket}).

get_put_host() ->
    persistent_term:get({?MODULE, put_host}).

get_get_host() ->
    persistent_term:get({?MODULE, get_host}).

is_signed_get_needed() ->
    persistent_term:get({?MODULE, is_signed_get_needed}).

