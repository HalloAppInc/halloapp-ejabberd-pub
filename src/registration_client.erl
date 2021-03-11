%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% Registration client using HTTP API that provides interface for
%%% creating accounts
%%% @end
%%% Created : 09. Mar 2021 4:26 PM
%%%-------------------------------------------------------------------
-module(registration_client).
-author("nikola").

-include("ha_types.hrl").

-define(DEFAULT_UA, "HalloApp/Android.130").
-define(DEFAULT_HOST, "localhost").

%% API
-export([
    request_sms/1,
    request_sms/2,
    register/3,
    register/4
]).


setup() ->
    application:ensure_started(inets).


-spec request_sms(Phone :: phone()) -> {ok, map()} | {error, term()}.
request_sms(Phone) ->
    request_sms(Phone, #{}).


-spec request_sms(Phone :: phone(), Options :: map()) -> {ok, map()} | {error, term()}.
request_sms(Phone, Options) ->
    setup(),
    Body = jiffy:encode(#{<<"phone">> => Phone}),
    UA = maps:get(user_agent, Options, ?DEFAULT_UA),
    Headers = [{"user-agent", UA}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Request = {"http://" ++ Host ++ ":5580/api/registration/request_sms", Headers, "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [], []),
    case Response of
        {{_, 200, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {ok, ResData};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {error, {HTTPCode, ResData}}
    end.

-spec register(Phone :: phone(), Code :: binary(), Name :: binary())
            -> {ok, Uid :: uid(), Password :: binary(), Response :: map()} | {error, term()}.
register(Phone, Code, Name) ->
    register(Phone, Code, Name, #{}).

-spec register(Phone :: phone(), Code :: binary(), Name :: binary(), Options :: map())
            -> {ok, Uid :: uid(), Password :: binary(), Response :: map()} | {error, term()}.
register(Phone, Code, Name, Options) ->
    setup(),
    Body = jiffy:encode(#{
        <<"phone">> => Phone,
        <<"code">> => Code,
        <<"name">> => Name
        % TODO: add support for whisper keys
    }),

    UA = maps:get(user_agent, Options, ?DEFAULT_UA),
    Headers = [{"user-agent", UA}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Request = {"http://" ++ Host ++ ":5580/api/registration/register", Headers, "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [], []),
    case Response of
        {{_, 200, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            #{
                <<"password">> := Password,
                <<"uid">> := Uid,
                <<"phone">> := Phone,
                <<"result">> := <<"ok">>
            } = ResData,
            {ok, Uid, Password, ResData};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {error, {HTTPCode, ResData}}
    end.
