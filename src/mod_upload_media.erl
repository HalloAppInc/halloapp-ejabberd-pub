%%%----------------------------------------------------------------------
%%% File    : mod_upload_media.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%% This file manages upload media metadata.
%%% This module expects {aws_media_region, aws_media_put_host,
%%% aws_media_get_host} to be present in ejabberd.yml file.
%%% If not specified, loading of this module will fail.
%%%----------------------------------------------------------------------

-module(mod_upload_media).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_opt_type/1, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    process_patch_url_result/2
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, self()]),
    initialize_url_generators(Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_upload_media, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO("stop ~w ~p", [?MODULE, self()]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_upload_media),
    s3_signed_url_generator:close(),
    upload_server_url_generator:close(),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_opt_type(aws_media_region) ->
    econf:binary();
mod_opt_type(aws_media_bucket) ->
    econf:binary();
mod_opt_type(aws_media_put_host) ->
    econf:binary();
mod_opt_type(aws_media_get_host) ->
    econf:binary();
mod_opt_type(upload_hosts) ->
    econf:non_empty(econf:list(econf:string(), [unique]));
mod_opt_type(upload_port) ->
    econf:int().

mod_options(_Host) ->
    [
        {aws_media_region, undefined},
        {aws_media_bucket, undefined},
        {aws_media_put_host, undefined},
        {aws_media_get_host, undefined},
        {upload_hosts, []},
        {upload_port, undefined}
    ].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{type = get, payload = #pb_upload_media{
        size = Size, download_url = DUrl, type = Type}} = IQ)
        when DUrl =/= undefined andalso byte_size(DUrl) > 0 ->
    ?INFO("refresh_url ~p", [DUrl]),
    case s3_signed_url_generator:refresh_url(binary_to_list(DUrl)) of
        true ->
            ?INFO("refresh ok ~p", [DUrl]),
            stat:count("HA/media", "refresh_upload"),
            pb:make_iq_result(IQ, #pb_upload_media{download_url = DUrl});
        false ->
            ?INFO("fail ~p", [DUrl]),
            process_local_iq(IQ#pb_iq{payload = #pb_upload_media{size = Size, type = Type}})
    end;
process_local_iq(#pb_iq{type = get, payload = #pb_upload_media{size = Size, type = Type}} = IQ) ->
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
    end.


-spec generate_s3_urls() -> {GetUrl :: binary(), PutUrl :: binary()}.
generate_s3_urls() ->
    {Key, PutUrl} = s3_signed_url_generator:make_signed_url(3600),
    %% Url to read content with max expiry.
    GetUrl = s3_signed_url_generator:make_signed_url(604800, Key),
    {GetUrl, PutUrl}.


-spec process_patch_url_result(IQ :: pb_iq(), PatchResult :: {ok, binary()} | error) -> ok.
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
    ejabberd_router:route(IQResult).
    

-spec generate_resumable_urls(Size :: binary(), IQ :: pb_iq()) -> ok.
generate_resumable_urls(Size, IQ) ->
    %% Generate the patch url. Send in details of what needs to be called when
    %% patch url is available.
    upload_server_url_generator:make_patch_url(Size, {?MODULE, process_patch_url_result, IQ}).


%%====================================================================
%% internal functions
%%====================================================================

-spec initialize_url_generators(Opts :: gen_mod:opts()) -> ok.
initialize_url_generators(Opts) ->
    Region = mod_upload_media_opt:aws_media_region(Opts),
    Bucket = mod_upload_media_opt:aws_media_bucket(Opts),
    PutHost = mod_upload_media_opt:aws_media_put_host(Opts),
    GetHost = mod_upload_media_opt:aws_media_get_host(Opts),
    s3_signed_url_generator:init(Region, Bucket, PutHost, GetHost),

    UploadHosts = mod_upload_media_opt:upload_hosts(Opts),
    UploadPort = mod_upload_media_opt:upload_port(Opts),
    upload_server_url_generator:init(UploadHosts, UploadPort),
    ok.

