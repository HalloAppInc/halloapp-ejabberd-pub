%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 16. Oct 2020 2:21 PM
%%%-------------------------------------------------------------------
-module(util_http).
-author("nikola").

-include("logger.hrl").
-include("ha_types.hrl").
-include("util_http.hrl").

%% API
-export([
    return_400/0,
    return_400/1,
    return_500/0,
    get_header/2,
    get_user_agent/1,
    get_platform/1,
    get_ip/2
]).

-spec return_400(term()) -> http_response().
return_400(Error) ->
    ?WARNING("400 ~p", [Error]),
    {400, ?HEADER(?CT_JSON), jiffy:encode({[
        {result, fail},
        {error, Error}]})}.


-spec return_400() -> http_response().
return_400() ->
    return_400(bad_request).


-spec return_500() -> http_response().
return_500() ->
    {500, ?HEADER(?CT_JSON),
        jiffy:encode({[{result, <<"Internal Server Error">>}]})}.


-spec get_header(Header :: binary(), Headers :: list()) -> maybe(binary()).
get_header(Header, Headers) ->
    case lists:keyfind(Header, 1, Headers) of
        false -> undefined;
        {Header, Value} -> Value
    end.


-spec get_user_agent(Headers :: list()) -> maybe(binary()).
get_user_agent(Headers) ->
    get_header('User-Agent', Headers).

-spec get_platform(UserAgent :: binary()) -> android | ios | unknown.
get_platform(UserAgent) ->
    Subject = string:lowercase(binary_to_list(UserAgent)),
    IsAndroid = case re:run(Subject, "android") of
        {match, _} -> true;
        nomatch -> false
    end,
    IsiOS = case re:run(Subject, "ipad|iphone|ipod") of
        {match, _} -> true;
        nomatch -> false
    end,
    if
        IsAndroid -> android;
        IsiOS -> ios;
        true -> unknown
    end.


-spec get_ip(IP :: tuple(), Headers :: list()) -> list().
get_ip(IP, Headers) ->
    ForwardedIP = util_http:get_header('X-Forwarded-For', Headers),
    case ForwardedIP of
        undefined ->
            case IP of
                undefined -> "0.0.0.0";
                IP -> inet:ntoa(IP)
            end;
        ForwardedIP -> binary_to_list(ForwardedIP)
    end.

