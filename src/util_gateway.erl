%%%----------------------------------------------------------------------
%%% File    : util_gateway.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%%----------------------------------------------------------------------

-module(util_gateway).
-author('murali').
-include("logger.hrl").

-export([
    get_gateway_lang/3
]).


-spec get_gateway_lang(LangId :: binary(), GatewayLangMap :: #{},
        DefaultLangId :: iolist() | binary()) -> iolist() | binary().
get_gateway_lang(LangId, GatewayLangMap, DefaultLangId) ->
    case maps:get(LangId, GatewayLangMap, DefaultLangId) of
        DefaultLangId ->
            NormalizedLangId = mod_translate:normalize_langid(LangId),
            case maps:get(NormalizedLangId, GatewayLangMap, DefaultLangId) of
                DefaultLangId ->
                    ShortLangId = mod_translate:shorten_lang_id(LangId),
                    maps:get(ShortLangId, GatewayLangMap, DefaultLangId);
                GatewayLangId -> GatewayLangId
            end;
        GatewayLangId -> GatewayLangId
    end.

