%%%----------------------------------------------------------------------
%%% File    : mod_upload_media.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%% This file manages upload media metadata.
%%%----------------------------------------------------------------------

-module(mod_upload_media).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

-define(AWS_MEDIA_REGION, <<"us-east-1">>).
-define(AWS_MEDIA_BUCKET, <<"us-e-halloapp-media">>).
%% Accelerated dualstack endpoint.
%% Ref: https://docs.aws.amazon.com/AmazonS3/latest/dev/transfer-acceleration.html
-define(AWS_MEDIA_PUT_HOST, <<"us-e-halloapp-media.s3-accelerate.dualstack.amazonaws.com">>).
%% Cloudfront based distribution.
%% Ref: https://aws.amazon.com/premiumsupport/knowledge-center/cloudfront-https-requests-s3/
-define(AWS_MEDIA_GET_HOST, <<"u-cdn.halloapp.net">>).
%% Resumable upload server internal host names.
-define(UPLOAD_HOSTS, ["u2.ha","u3.ha"]).
%% Resumable upload server port.
-define(UPLOAD_PORT, 1080).

-define(GIGABYTE, 1000000000).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    process_patch_url_result/2
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    initialize_url_generators(),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_upload_media, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_upload_media),
    s3_signed_url_generator:close(),
    upload_server_url_generator:close(),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{from_uid = Uid, type = get, payload = #pb_upload_media{
        size = Size, download_url = DUrl, type = Type}} = IQ)
        when DUrl =/= undefined andalso byte_size(DUrl) > 0 ->
    ?INFO("Uid: ~p, refresh_url ~p", [Uid, DUrl]),
    case s3_signed_url_generator:refresh_url(binary_to_list(DUrl)) of
        true ->
            ?INFO("Uid: ~p, refresh ok ~p", [Uid, DUrl]),
            stat:count("HA/media", "refresh_upload"),
            pb:make_iq_result(IQ, #pb_upload_media{download_url = DUrl});
        false ->
            ?INFO("Uid: ~p, failed refreshing ~p", [Uid, DUrl]),
            process_local_iq(IQ#pb_iq{payload = #pb_upload_media{size = Size, type = Type}})
    end;
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_upload_media{size = Size, type = Type}} = IQ) ->
    ?INFO("Uid: ~p, Type: ~p, Size: ~p", [Uid, Type, Size]),
    case Size of 
        LargeSize when LargeSize >= 2.5 * ?GIGABYTE -> 
            pb:make_error(IQ, util:err(size_too_large));
        _ ->
            DirectUpload = (Type =:= default andalso Size =:= 0) orelse (Type =:= direct),
            case DirectUpload of
                true ->
                    stat:count("HA/media", "direct_upload"),
                    {GetUrl, PutUrl} = generate_s3_urls(),
                    MediaUrl = #pb_media_url{get = GetUrl, put = PutUrl},
                    pb:make_iq_result(IQ, #pb_upload_media{url = MediaUrl});
                _ ->
                    %% Do not return IQ result in this case. IQ result will be sent once
                    %% the resumable urls are ready.
                    %% TODO(murali@): Add CT tests for this.
                    generate_resumable_urls(Size, IQ),
                    ignore
            end
    end.


-spec generate_s3_urls() -> {GetUrl :: string(), PutUrl :: string()}.
generate_s3_urls() ->
    {Key, PutUrl} = s3_signed_url_generator:make_signed_url(604800),
    %% Url to read content with max expiry.
    GetUrl = s3_signed_url_generator:make_signed_url(604800, Key),
    {GetUrl, PutUrl}.


-spec process_patch_url_result(IQ :: iq(), PatchResult :: {ok, binary()} | error) -> ok.
process_patch_url_result(IQ, PatchResult) ->
    MediaUrl =
      case PatchResult of
        error ->
            %% Attempt to fetch Resumable Patch URL failed.
            ?WARNING("Attempt to fetch resumable patch url failed", []),
            stat:count("HA/media", "direct_upload"),
            {GetUrl, PutUrl} = generate_s3_urls(),
            #pb_media_url{get = GetUrl, put = PutUrl};
        {ok, ResumablePatch} ->
            stat:count("HA/media", "resumable_upload"),
            #pb_media_url{patch = ResumablePatch}
      end,
    IQResult = pb:make_iq_result(IQ, #pb_upload_media{url = MediaUrl}),
    ?INFO("Uid: ~p, MediaUrl: ~p", [IQResult#pb_iq.to_uid, MediaUrl]),
    %% All of the logic to generate resumable urls is running on the c2s process.
    %% So use self pid as the destination.
    halloapp_c2s:route(self(), {route, IQResult}),
    ok.
    

-spec generate_resumable_urls(Size :: integer(), IQ :: iq()) -> ok.
generate_resumable_urls(Size, IQ) ->
    %% Generate the patch url. Send in details of what needs to be called when
    %% patch url is available.
    upload_server_url_generator:make_patch_url(Size, {?MODULE, process_patch_url_result, IQ}).


%%====================================================================
%% internal functions
%%====================================================================

-spec initialize_url_generators() -> ok.
initialize_url_generators() ->
    s3_signed_url_generator:init(?AWS_MEDIA_REGION, ?AWS_MEDIA_BUCKET, ?AWS_MEDIA_PUT_HOST,
        ?AWS_MEDIA_GET_HOST),
    upload_server_url_generator:init(?UPLOAD_HOSTS, ?UPLOAD_PORT),
    ok.

