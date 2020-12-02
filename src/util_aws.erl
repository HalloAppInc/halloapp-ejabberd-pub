%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. Nov 2020 5:11 PM
%%%-------------------------------------------------------------------
-module(util_aws).
-author("nikola").

-include("logger.hrl").
-include("ha_types.hrl").

%% API
-export([
    get_arn/0,
    is_jabber_iam_role/1,
    get_secret/1
]).

-spec get_arn() -> maybe(binary()).
get_arn() ->
    try
        Res = os:cmd("aws sts get-caller-identity"),
        ResMap = jiffy:decode(Res, [return_maps]),
        maps:get(<<"Arn">>, ResMap, undefined)
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("cant get_arn()\nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            undefined
    end.

-spec is_jabber_iam_role(Arn :: binary()) -> boolean().
is_jabber_iam_role(Arn) ->
    case Arn of
        <<"arn:aws:sts::356247613230:assumed-role/Jabber-instance-perms/", _Rest/binary>> ->
            true;
        _Any ->
            false
    end.

%% To fetch secret before mod_aws is ready. Not to be called more than once per secret.
-spec get_secret(SecretName :: binary()) -> string().
get_secret(SecretName) ->
    try
        Res = os:cmd("aws secretsmanager get-secret-value --region us-east-1 --secret-id "
                ++ binary_to_list(SecretName)),
        ResMap = jiffy:decode(Res, [return_maps]),
        maps:get(<<"SecretString">>, ResMap, undefined)
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("cant get_secret()\nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            undefined
    end.

