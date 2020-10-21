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
-include("util_http.hrl").

%% API
-export([
    return_400/0,
    return_400/1,
    return_500/0,
    get_user_agent/1
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


-spec get_user_agent(Headers :: list()) -> binary().
get_user_agent(Hdrs) ->
    {_, S} = lists:keyfind('User-Agent', 1, Hdrs),
    S.

