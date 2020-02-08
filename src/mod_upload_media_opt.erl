%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_upload_media_opt).

-export([aws_media_bucket/1]).

-spec aws_media_bucket(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_bucket(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_bucket, Opts);
aws_media_bucket(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_bucket).

