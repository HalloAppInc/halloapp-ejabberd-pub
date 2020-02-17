%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_upload_media_opt).

-export([aws_media_get_host/1]).
-export([aws_media_put_host/1]).
-export([aws_media_region/1]).

-spec aws_media_get_host(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_get_host(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_get_host, Opts);
aws_media_get_host(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_get_host).

-spec aws_media_put_host(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_put_host(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_put_host, Opts);
aws_media_put_host(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_put_host).

-spec aws_media_region(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_region(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_region, Opts);
aws_media_region(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_region).

