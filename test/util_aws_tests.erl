%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. Mar 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(util_aws_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").


% get_arn is somehow slow if called few times in a row. Maybe AWS is doing some backoff
%%get_arn_test() ->
%%    Arn = util_aws:get_arn(),
%%    ?assertNotEqual(undefined, Arn),
%%    ?assertEqual(<<"arn">>, binary:part(Arn, {0, 3})),
%%    ok.

is_jabberd_iam_role_test() ->
    Arn = util_aws:get_arn(),
    ?assertNotEqual(undefined, Arn),
    ?assertEqual(false, util_aws:is_jabber_iam_role(Arn)),
    ok.

