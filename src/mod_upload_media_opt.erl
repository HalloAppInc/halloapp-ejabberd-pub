%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_upload_media_opt).

-export([aws_media_bucket/1]).
-export([aws_media_get_host/1]).
-export([aws_media_put_host/1]).
-export([aws_media_region/1]).
-export([upload_hosts/1]).
-export([upload_port/1]).

-spec aws_media_bucket(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_bucket(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_bucket, Opts);
aws_media_bucket(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_bucket).

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

-spec upload_hosts(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
upload_hosts(Opts) when is_map(Opts) ->
    gen_mod:get_opt(upload_hosts, Opts);
upload_hosts(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, upload_hosts).

-spec upload_port(gen_mod:opts() | global | binary()) -> 'undefined' | integer().
upload_port(Opts) when is_map(Opts) ->
    gen_mod:get_opt(upload_port, Opts);
upload_port(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, upload_port).

