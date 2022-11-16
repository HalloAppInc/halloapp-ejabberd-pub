%%%-------------------------------------------------------------------
%%% File: mod_location_tests.erl
%%%
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_location_tests).
-author('murali').

-include("packets.hrl").
-include("feed.hrl").

-include("tutil.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(PHONE1, <<"14703381473">>).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_name_iq_testset() ->
    [?_assertEqual(cal_ave, mod_location:get_geo_tag(?UID1, {37.4290788, -122.1432234})),
    ?_assertEqual(undefined, mod_location:get_geo_tag(?UID1, {37.4278570, -122.1420737}))].
