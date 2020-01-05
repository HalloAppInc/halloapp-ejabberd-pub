%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_upload_media_opt).

-export([aws_access_key/1]).
-export([aws_media_bucket/1]).
-export([aws_secret_access_key/1]).

-spec aws_access_key(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_access_key(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_access_key, Opts);
aws_access_key(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_access_key).

-spec aws_media_bucket(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_media_bucket(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_media_bucket, Opts);
aws_media_bucket(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_media_bucket).

-spec aws_secret_access_key(gen_mod:opts() | global | binary()) -> 'undefined' | binary().
aws_secret_access_key(Opts) when is_map(Opts) ->
    gen_mod:get_opt(aws_secret_access_key, Opts);
aws_secret_access_key(Host) ->
    gen_mod:get_module_opt(Host, mod_upload_media, aws_secret_access_key).

