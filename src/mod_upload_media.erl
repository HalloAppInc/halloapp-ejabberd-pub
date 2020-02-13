%%%----------------------------------------------------------------------
%%% File    : mod_upload_media.erl, to manage upload media metadata.
%%%           This module expects {aws_media_bucket} to be present
%%%           in ejabberd.yml file.
%%            If not specified, loading of this module will fail.
%%%
%%%----------------------------------------------------------------------

-module(mod_upload_media).

-author('tbd').

-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, process_local_iq/1,
	 mod_opt_type/1, mod_options/1, depends/2]).

-include("logger.hrl").
-include("xmpp.hrl").

start(Host, Opts) ->
    ?INFO_MSG("------ Starting Media module on:~p", [Host]),
    Bucket = mod_upload_media_opt:aws_media_bucket(Opts),
    s3_signed_url_generator:init(Bucket),
    xmpp:register_codec(upload_media),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, <<"ns:upload_media">>, 
                                  ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO_MSG("----- Stopping Media module on:~p", [Host]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, 
                                     <<"ns:upload_media">>),
    xmpp:unregister_codec(upload_media),
    s3_signed_url_generator:close(),
    ok.

process_local_iq(#iq{type = get} = IQ) ->
    {Key, PutUrl} = s3_signed_url_generator:make_signed_url(3600),

    %% Url to read content with max expiry.
    GetUrl = s3_signed_url_generator:make_signed_url(604800, Key),

    MediaUrls = #media_urls{put = PutUrl, get = GetUrl},
    xmpp:make_iq_result(IQ, #upload_media{media_urls = [MediaUrls]}).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_opt_type(aws_media_bucket) ->
    econf:binary().

mod_options(_Host) ->
    [{aws_media_bucket, undefined}].
