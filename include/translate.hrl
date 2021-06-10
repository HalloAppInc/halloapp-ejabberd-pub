-ifndef(TRANSLATE_HRL).
-define(TRANSLATE_HRL, 1).

-define(T(S), <<S>>).

-define(TR(Msg, LangId),
    begin mod_translate:translate(Msg, LangId) end).

-define(TR(Msg, Args, LangId),
    begin mod_translate:translate(Msg, Args, LangId) end).

-endif.
