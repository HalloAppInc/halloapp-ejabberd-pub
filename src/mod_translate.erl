%%%-------------------------------------------------------------------
%%% File: mod_translate.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to translate server strings.
%%% TODO(murali@): add a makefile command to fetch translation files automatically.
%%% consider moving these english strings to en.strings in msgs directory.
%%%-------------------------------------------------------------------
-module(mod_translate).
-author('murali').
-behavior(gen_mod).

-include("logger.hrl").

-define(TRANSLATIONS, ha_translations).
-define(ARG_PATTERN, "%@").
-define(ENG_LANG_ID, <<"en-US">>).

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    translate/2,
    translate/3,
    reload_translations/0,
    ets_translations_exist/0,
    shorten_lang_id/1,
    normalize_langid/1
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ets:new(?TRANSLATIONS,
        [set, public, named_table, {keypos, 1},
        {write_concurrency, true}, {read_concurrency, true}]),
    load_files_to_ets(),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    case ets_translations_exist() of
        true -> ets:delete(?TRANSLATIONS);
        false -> ok
    end,
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

-spec translate(Token :: binary(), LangId :: binary()) ->
        {TranslatedMsg :: binary(), ResultLangId :: binary()}.
translate(Token, LangId) ->
    translate(Token, [], LangId).


-spec translate(Token :: binary(), Args :: [binary()],
        LangId :: binary()) -> {TranslatedMsg :: binary(), ResultLangId :: binary()}.
translate(Token, Args, undefined) ->
    %% TODO(murali@): handle undefined for now.
    translate(Token, Args, ?ENG_LANG_ID);

translate(Token, Args, LangId) ->
    try
        {Translation, ResultLangId} = case LangId of
            <<"en-US">> ->
                count_lang_id(?ENG_LANG_ID),
                {lookup_english_string(Token), ?ENG_LANG_ID};
            _ ->
                lookup_translation(Token, LangId)
        end,
        TranslatedString = format_translation(Translation, Args),
        {TranslatedString, ResultLangId}
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Failed translating Token: ~p, Args:~p, LangId: ~p", [Token, Args, LangId]),
            ?ERROR("Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            Translation2 = lookup_english_string(Token),
            {format_translation(Translation2, Args), ?ENG_LANG_ID}
    end.


%% reloads all translation files again.
-spec reload_translations() -> ok.
reload_translations() ->
    load_files_to_ets(),
    ok.


%%====================================================================
%% Internal functions
%%====================================================================

%% Formats the translated and replaces all arguments: %@ with the given arguments in order.
-spec format_translation(Translation :: binary(), Args :: [binary()]) -> binary().
format_translation(Translation, []) ->
    Translation;
format_translation(Translation, [Arg | RestArgs]) ->
    NewTranslation = re:replace(Translation, ?ARG_PATTERN, Arg, [{return, binary}]),
    format_translation(NewTranslation, RestArgs).


%% Looks up translation for Token in the ets table using LangId.
-spec lookup_translation(Token :: binary(), OriginalLangId :: binary()) -> Translation :: binary().
lookup_translation(Token, OriginalLangId) ->
    %% Recast LangId for some cases.
    LangId = recast_langid(OriginalLangId),

    %% If LangId is not en-US, lookup the translations table.
    %% if we dont find them in our translation table: we can return the english version.
    case ets:lookup(?TRANSLATIONS, {Token, LangId}) of
        [{_, Translation}] ->
            count_lang_id(LangId),
            {Translation, LangId};
        [{_, Translation} | _] ->
            ?WARNING("More than one translation exists, Token: ~p, LangId: ~p",
                [Token, LangId]),
            count_lang_id(LangId),
            {Translation, LangId};
        [] ->
            %% If no translations exists, try uppercasing the region and lookup again.
            NormalizedLangId = normalize_langid(LangId),
            case ets:lookup(?TRANSLATIONS, {Token, NormalizedLangId}) of
                [{_, Translation}] ->
                    count_lang_id(NormalizedLangId),
                    {Translation, LangId};
                [{_, Translation} | _] ->
                    ?WARNING("More than one translation exists, Token: ~p, LangId: ~p",
                        [Token, NormalizedLangId]),
                    count_lang_id(NormalizedLangId),
                    {Translation, LangId};
                [] ->
                    %% If no translations exists, try shortening the id and lookup again.
                    ShortLangId = shorten_lang_id(LangId),
                    case ShortLangId of
                        %% If shortLangId is english: then use default string,
                        %% since translations dont exist.
                        _ when ShortLangId =:= <<"en">> orelse ShortLangId =:= LangId ->
                            count_lang_id(?ENG_LANG_ID),
                            {lookup_english_string(Token), ?ENG_LANG_ID};
                        _ ->
                            %% Lookup translations using the shortId, else fallback to the default string.
                            case ets:lookup(?TRANSLATIONS, {Token, ShortLangId}) of
                                [{_, Translation}] ->
                                    count_lang_id(ShortLangId),
                                    {Translation, LangId};
                                [{_, Translation} | _] ->
                                    ?WARNING("More than one translation exists, Token: ~p, LangId: ~p",
                                        [Token, LangId]),
                                    count_lang_id(ShortLangId),
                                    {Translation, LangId};
                                _ ->
                                    ?INFO("Unable to find translation for Token: ~p, LangId: ~p",
                                        [Token, LangId]),
                                    count_lang_id(?ENG_LANG_ID),
                                    {lookup_english_string(Token), ?ENG_LANG_ID}
                            end
                    end
            end
    end.


%% Loads all translation files to ets.
-spec load_files_to_ets() -> ok.
load_files_to_ets() ->
    MsgsDir = misc:msgs_dir(),
    {ok, FileNames} = file:list_dir(MsgsDir),
    FullPaths = [filename:join(MsgsDir, FileName) || FileName <- FileNames],
    LangIds = [re:replace(FileName, ".strings", "", [{return, list}]) || FileName <- FileNames],
    ?INFO("Loading files: ~p for Languages: ~p", [FullPaths, LangIds]),
    lists:foreach(
        fun({LangId, FilePath}) ->
            read_and_load_file(LangId, FilePath)
        end, lists:zip(LangIds, FullPaths)),
    ok.


%% Reads and loads a single file corresponding to a specific LangId.
read_and_load_file(LangId, FilePath) ->
    ?INFO("Reading file: ~p, for LangId: ~p", [FilePath, LangId]),
    {ok, FileContentBin} = file:read_file(FilePath),
    ContentLines = binary:split(FileContentBin, <<"\n">>, [global]),
    lists:foreach(
        fun (<<>>) -> ok;
            (ContentLine) ->
            [<<>>, [], Token, [], <<" = ">>, [], Translation, [], <<";">>] = string:replace(ContentLine,
                "\"", "", all),
            ets:insert(?TRANSLATIONS,
                {{util:to_binary(Token), util:to_binary(LangId)}, util:to_binary(Translation)})
        end, ContentLines),
    ?INFO("Finished loading file: ~p, for LangId: ~p", [FilePath, LangId]),
    ok.


%% Mappings from specific tokens used in the translations file to default english strings.
-spec lookup_english_string(Token :: binary()) -> binary().
lookup_english_string(<<"server.new.message">>) -> <<"New Message">>;
lookup_english_string(<<"server.new.group.message">>) -> <<"New Group Message">>;
lookup_english_string(<<"server.new.inviter">>) -> <<"%@ just accepted your invite to join HalloApp 🎉"/utf8>>;
lookup_english_string(<<"server.new.contact">>) -> <<"%@ is now on HalloApp">>;
lookup_english_string(<<"server.new.post">>) -> <<"New Post">>;
lookup_english_string(<<"server.new.comment">>) -> <<"New Comment">>;
lookup_english_string(<<"server.new.group">>) -> <<"You were added to a new group">>;
lookup_english_string(<<"server.sms.verification">>) -> <<"Your HalloApp verification code">>;
lookup_english_string(<<"server.voicecall.verification">>) -> <<"Your HalloApp verification code is">>;
%% TODO: murali@: update these strings as necessary.
lookup_english_string(<<"server.marketing.title">>) -> <<"Hallo there!">>;
lookup_english_string(<<"server.marketing.body">>) -> <<"Invite your friends to enjoy HalloApp!">>;
lookup_english_string(Token) ->
    ?ERROR("unknown string: ~p", [Token]),
    Token.


%% Shortens the language id.
-spec shorten_lang_id(LangId :: binary()) -> binary().
shorten_lang_id(LangId) ->
    case str:tokens(LangId, <<"-">>) of
        [] -> LangId;
        [ShortId | _] -> ShortId
    end.


%% normalized the langId by uppercasing the region.
-spec normalize_langid(LangId :: binary()) -> binary().
normalize_langid(LangId) ->
    case str:tokens(LangId, <<"-">>) of
        [] -> LangId;
        [LangId] -> LangId;
        [ShortId, Region] ->
            UppercaseRegion = util:to_binary(string:uppercase(util:to_list(Region))),
            <<ShortId/binary, "-", UppercaseRegion/binary>>;
        [ShortId | _] -> ShortId
    end.


-spec ets_translations_exist() -> boolean().
ets_translations_exist() ->
    case ets:whereis(?TRANSLATIONS) of
        undefined -> false;
        _ -> true
    end.


-spec count_lang_id(LangId :: binary()) -> ok.
count_lang_id(LangId) ->
    LangIdList = util:to_list(LangId),
    stat:count("HA/translate", "lang", 1, [{"lang_id", LangIdList}]),
    ok.


-spec recast_langid(LangId :: binary()) -> binary().
%% We remap some language ids to something else for all translations.
%% Some android versions use 'in' and some use 'id' for indonesian language.
%% So we translate to the more standard langid here.
recast_langid(<<"in">>) -> <<"id">>;
recast_langid(<<"in", RestLangId/binary>>) -> <<"id", RestLangId/binary>>;
recast_langid(LangId) -> LangId.

