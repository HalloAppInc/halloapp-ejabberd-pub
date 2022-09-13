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


% Note: these tests were previously disabled because AWS had some ssl connection issues. If that 
% happens again they may need to be disabled again.
% For example running `aws --debug sts get-caller-identity` sometimes took 25 secs.

get_arn_test_() ->
    Arn = util_aws:get_arn(),
    [
        ?_assertNotEqual(undefined, Arn),
        ?_assertEqual(<<"arn">>, binary:part(Arn, {0, 3}))
    ].

is_jabberd_iam_role_test_() ->
    Arn = util_aws:get_arn(),
    [
        ?_assertNotEqual(undefined, Arn),
        ?_assertNot(util_aws:is_jabber_iam_role(Arn))
    ].

