%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for invites redirecting clients to the right app stores
%%% @end
%%% Created : 08. Apr 2021 11:42 AM
%%%-------------------------------------------------------------------
% TODO: does the name have to start with mod_ when this is not gen_mod
-module(mod_http_invite).
-author("nikola").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

-define(INVITE_SUBDOMAIN, <<"https://invite.halloapp.com/invite/subdomain?g=">>).
-define(HALLOAPP_COM, <<"https://halloapp.com">>).
-define(PLAY_STORE_URL, <<"https://play.google.com/store/apps/details?id=com.halloapp&referrer=ginvite-">>).
-define(APP_STORE_URL, <<"https://apps.apple.com/us/app/halloapp/id1501583052">>).
-define(HA_APPCLIP_URL, <<"https://halloapp.com/appclip/?g=">>).

%% API
-export([process/2]).

-define(INVITE_HTML_PAGE,
<<"
<!doctype html>

<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">

  <title>HalloApp Group Invite</title>
  <meta name=\"description\" content=\"HalloApp GroupA simple HTML5 Template for new projects.\">

  <meta property=\"og:title\" content=\"HalloApp Group Invite\">
  <meta property=\"og:type\" content=\"website\">
  <meta property=\"og:url\" content=\"https://halloapp.com/invite/\">
  <meta property=\"og:description\" content=\"HalloApp Group Invite\">
  <meta property=\"og:image\" content=\"https://halloapp.com/images/favicon.ico\">

  <meta name=\"apple-itunes-app\" content=\"app-id=1501583052, app-clip-bundle-id=com.halloapp.hallo.Clip\">

  <link rel=\"icon\" href=\"https://halloapp.com/images/favicon.ico\">

</head>

<body>
  You have been invited to a HalloApp Group.
  <br/>
  Please open the app clip.
</body>
</html>
">>).

%% https://halloapp.com/invite?g=ABCDEF in our group invite urls.
%% from the halloapp.com CDN we server /invite pages from the Origin
%% https://api.halloapp.net/invite?g=ABCDEF which is handled here.
%% To make the appclip work we redirect ios users to
%% https://invite.halloapp.com/invite/subdomain?g=ABCDEF
%% There is CDN for invite.halloapp.com that uses api.halloapp.com as Origin

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /invite
process([],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        GroupToken = proplists:get_value(<<"g">>, Q, <<>>),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("request Q:~p UserAgent ~p Platform: ~p, IP: ~p", [Q, UserAgent, Platform, IP]),
        Result = case Platform of
            android ->
                {redirect, <<?PLAY_STORE_URL/binary, GroupToken/binary>>};
            ios ->
                {redirect, <<?HA_APPCLIP_URL/binary, GroupToken/binary>>};
            unknown ->
                {redirect, ?HALLOAPP_COM};
            Something ->
                ?WARNING("unexpected Platform ~p", [Something]),
                {redirect, ?HALLOAPP_COM}
        end,
        case Result of
            {redirect, Location} ->
                ?INFO("redirecting to ~p", [Location]),
                {302, [?LOCATION_HEADER(Location)], <<"">>};
            webpage ->
                {200, ?HEADER(?CT_HTML), ?INVITE_HTML_PAGE}
        end
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {302, [?LOCATION_HEADER(?HALLOAPP_COM)], <<"">>}
    end;

% TODO: code is duplicated with the function above.

%% /invite/subdomain
process([<<"subdomain">>],
        #request{method = 'GET', q = Q, ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        GroupToken = proplists:get_value(<<"g">>, Q, <<>>),
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("request Q:~p UserAgent ~p Platform: ~p, IP: ~p", [Q, UserAgent, Platform, IP]),
        Location = case Platform of
            android ->
                <<?PLAY_STORE_URL/binary, GroupToken/binary>>;
            ios ->
                <<?APP_STORE_URL/binary>>;
            unknown ->
                ?HALLOAPP_COM;
            Something ->
                ?WARNING("unexpected Platform ~p", [Something]),
                ?HALLOAPP_COM
        end,
        ?INFO("redirecting to ~p", [Location]),
        {302, [?LOCATION_HEADER(Location)], <<"">>}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {302, [?LOCATION_HEADER(?HALLOAPP_COM)], <<"">>}
    end;

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

