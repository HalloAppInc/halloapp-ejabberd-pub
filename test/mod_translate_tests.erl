%%%-------------------------------------------------------------------
%%% File: mod_translate_tests.erl
%%% Copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_translate_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").

-define(TRANSLATIONS, ha_translations).


setup() ->
    mod_translate:stop(<<>>),
    mod_translate:start(<<>>, <<>>),
    ok.


table_exists_test() ->
    setup(),
    ?assertEqual(mod_translate:ets_translations_exist(), true),
    ok.


translate_en_test() ->
    setup(),
    CommentToken = <<"server.new.comment">>,
    ?assertEqual(<<"New Comment">>, mod_translate:translate(CommentToken, <<"en-US">>)),
    ?assertEqual(<<"New Comment">>, mod_translate:translate(CommentToken, <<"en-GB">>)),
    ?assertEqual(<<"New Comment">>, mod_translate:translate(CommentToken, <<"en">>)),
    ok.


translate_fallback_test() ->
    setup(),
    RandomString = <<"random string">>,
    ?assertEqual(RandomString, mod_translate:translate(RandomString, <<"en-US">>)),
    ?assertEqual(RandomString, mod_translate:translate(RandomString, <<"tr">>)),
    ?assertEqual(RandomString, mod_translate:translate(RandomString, <<"random">>)),
    ?assertEqual(<<"murali is now on HalloApp">>,
        mod_translate:translate(<<"server.new.contact">>, [<<"murali">>], <<"random">>)),
    ok.


translate_es_test() ->
    setup(),
    ?assertEqual(<<"Comentario nuevo">>, mod_translate:translate(<<"server.new.comment">>, <<"es">>)),
    ?assertEqual(<<"Mensaje nuevo">>, mod_translate:translate(<<"server.new.message">>, <<"es">>)),
    ?assertEqual(<<"Publicación nueva"/utf8>>, mod_translate:translate(<<"server.new.post">>, <<"es">>)),
    ?assertEqual(<<"murali ya está en HalloApp"/utf8>>,
        mod_translate:translate(<<"server.new.contact">>, [<<"murali">>], <<"es">>)),
    ok.


translate_de_test() ->
    setup(),
    ?assertEqual(<<"Neuer Kommentar">>, mod_translate:translate(<<"server.new.comment">>, <<"de">>)),
    ?assertEqual(<<"Neue Nachricht">>, mod_translate:translate(<<"server.new.message">>, <<"de">>)),
    ?assertEqual(<<"Neuer Beitrag">>, mod_translate:translate(<<"server.new.post">>, <<"de">>)),
    ?assertEqual(<<"murali ist nun auch auf HalloApp">>,
        mod_translate:translate(<<"server.new.contact">>, [<<"murali">>], <<"de">>)),
    ok.


translate_tr_test() ->
    setup(),
    ?assertEqual(<<"Yeni yorum">>, mod_translate:translate(<<"server.new.comment">>, <<"tr">>)),
    ?assertEqual(<<"Yeni mesaj">>, mod_translate:translate(<<"server.new.message">>, <<"tr">>)),
    ?assertEqual(<<"Yeni gönderi"/utf8>>, mod_translate:translate(<<"server.new.post">>, <<"tr">>)),
    %% includes some unprintable characters - so fails to show up here.
    ?assertEqual(<<109,117,114,97,108,105,32,197,159,105,109,100,105,32,72,97,108,108,111,65,112,112,39,116,101>>,
        mod_translate:translate(<<"server.new.contact">>, [<<"murali">>], <<"tr">>)),
    ok.

