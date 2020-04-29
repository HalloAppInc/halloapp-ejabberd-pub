%%%----------------------------------------------------------------------
%%% File    : mod_upload_media.erl, to manage upload media metadata.
%%%           This module expects {aws_media_region, aws_media_put_host,
%%%           aws_media_get_host} to be present in ejabberd.yml file.
%%            If not specified, loading of this module will fail.
%%%
%%%----------------------------------------------------------------------

-module(mod_upload_media).

-author('tbd').

-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, process_local_iq/1,
    process_patch_url_result/2, mod_opt_type/1, mod_options/1, depends/2]).

-include("logger.hrl").
-include("xmpp.hrl").

start(Host, Opts) ->
    ?INFO_MSG("------ Starting Media module on:~p", [Host]),
    Region = mod_upload_media_opt:aws_media_region(Opts),
    PutHost = mod_upload_media_opt:aws_media_put_host(Opts),
    GetHost = mod_upload_media_opt:aws_media_get_host(Opts),
    s3_signed_url_generator:init(Region, PutHost, GetHost),
    UploadHost = mod_upload_media_opt:upload_host(Opts),
    UploadPort = mod_upload_media_opt:upload_port(Opts),
    upload_server_url_generator:init(UploadHost, UploadPort),
    xmpp:register_codec(upload_media),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
                                  <<"ns:upload_media">>, 
                                  ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO_MSG("----- Stopping Media module on:~p", [Host]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, 
                                     <<"ns:upload_media">>),
    xmpp:unregister_codec(upload_media),
    s3_signed_url_generator:close(),
    upload_server_url_generator:close(),
    ok.

generate_s3_urls() ->
    {Key, PutUrl} = s3_signed_url_generator:make_signed_url(3600),

    %% Url to read content with max expiry.
    GetUrl = s3_signed_url_generator:make_signed_url(604800, Key),
    {GetUrl, PutUrl}.

process_patch_url_result(IQ, PatchResult) ->
    MediaUrls = 
      case PatchResult of
        error ->
            %% Attempt to fetch Resumable Patch URL failed.
            ?WARNING_MSG("Attempt to fetch resumable patch url failed", []),
            {GetUrl, PutUrl} = generate_s3_urls(),
            #media_urls{get = GetUrl, put = PutUrl};
        {ok, ResumablePatch} -> #media_urls{patch = ResumablePatch}
      end,
    IQResult = xmpp:make_iq_result(IQ, #upload_media{media_urls = [MediaUrls]}),
    ejabberd_router:route(IQResult).
    
 
generate_resumable_urls(Size, IQ) ->
    %% Generate the patch url. Send in details of what needs to be called when
    %% patch url is available.
    upload_server_url_generator:make_patch_url(Size, 
                                               {?MODULE,
                                                process_patch_url_result, IQ}).

process_local_iq(#iq{type = get, sub_els = [#upload_media{size = Size}]} = IQ) ->
    case Size of
        <<>> -> 
          {GetUrl, PutUrl} = generate_s3_urls(),
          MediaUrls = #media_urls{get = GetUrl, put = PutUrl},
          xmpp:make_iq_result(IQ, #upload_media{media_urls = [MediaUrls]});
        _ ->
          %% Do not return IQ result in this case. IQ result will be sent once
          %% the resumable urls are ready.
          generate_resumable_urls(binary_to_integer(Size), IQ),
          ignore
    end.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_opt_type(aws_media_region) ->
    econf:binary();
mod_opt_type(aws_media_put_host) ->
    econf:binary();
mod_opt_type(aws_media_get_host) ->
    econf:binary();
mod_opt_type(upload_host) ->
    econf:binary();
mod_opt_type(upload_port) ->
    econf:int().

mod_options(_Host) ->
    [{aws_media_region, undefined},
     {aws_media_put_host, undefined},
     {aws_media_get_host, undefined},
     {upload_host, undefined},
     {upload_port, undefined}].
