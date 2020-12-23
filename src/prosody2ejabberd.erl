%%%-------------------------------------------------------------------
%%% File    : prosody2ejabberd.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 20 Jan 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(prosody2ejabberd).

%% API
-export([from_dir/1]).

-include("scram.hrl").
-include("xmpp.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
from_dir(ProsodyDir) ->
    case code:ensure_loaded(luerl) of
	{module, _} ->
	    case file:list_dir(ProsodyDir) of
		{ok, HostDirs} ->
		    lists:foreach(
		      fun(HostDir) ->
			      Host = list_to_binary(HostDir),
			      lists:foreach(
				fun(SubDir) ->
					Path = filename:join(
						 [ProsodyDir, HostDir, SubDir]),
					convert_dir(Path, Host, SubDir)
				end, ["vcard", "accounts", "roster",
				      "private", "config",
				      "privacy", "pep", "pubsub"])
		      end, HostDirs);
		{error, Why} = Err ->
		    ?ERROR("Failed to list ~ts: ~ts",
			       [ProsodyDir, file:format_error(Why)]),
		    Err
	    end;
	{error, _} = Err ->
	    ?ERROR("The file 'luerl.beam' is not found: maybe "
		       "ejabberd is not compiled with Lua support", []),
	    Err
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
convert_dir(Path, Host, Type) ->
    case file:list_dir(Path) of
	{ok, Files} ->
	    lists:foreach(
	      fun(File) ->
		      FilePath = filename:join(Path, File),
		      case Type of
			  "pep" ->
			      case filelib:is_dir(FilePath) of
				  true ->
				      JID = list_to_binary(File ++ "@" ++ Host),
				      convert_dir(FilePath, JID, "pubsub");
				  false ->
				      ok
			      end;
			  _ ->
			      case eval_file(FilePath) of
				  {ok, Data} ->
				      Name = iolist_to_binary(filename:rootname(File)),
				      convert_data(url_decode(Host), Type,
						   url_decode(Name), Data);
				  Err ->
				      Err
			      end
		      end
	      end, Files);
	{error, enoent} ->
	    ok;
	{error, Why} = Err ->
	    ?ERROR("Failed to list ~ts: ~ts",
		       [Path, file:format_error(Why)]),
	    Err
    end.

eval_file(Path) ->
    case file:read_file(Path) of
	{ok, Data} ->
	    State0 = luerl:init(),
	    State1 = luerl:set_table([item],
				     fun([X], State) -> {[X], State} end,
				     State0),
	    NewData = case filename:extension(Path) of
			  ".list" ->
			      <<"return {", Data/binary, "};">>;
			  _ ->
			      Data
		      end,
	    case luerl:eval(NewData, State1) of
		{ok, _} = Res ->
		    Res;
		{error, Why} = Err ->
		    ?ERROR("Failed to eval ~ts: ~p", [Path, Why]),
		    Err
	    end;
	{error, Why} = Err ->
	    ?ERROR("Failed to read file ~ts: ~ts",
		       [Path, file:format_error(Why)]),
	    Err
    end.

maybe_get_scram_auth(Data) ->
    case proplists:get_value(<<"iteration_count">>, Data, no_ic) of
	IC when is_float(IC) -> %% A float like 4096.0 is read
	    #scram{
		storedkey = misc:hex_to_base64(proplists:get_value(<<"stored_key">>, Data, <<"">>)),
		serverkey = misc:hex_to_base64(proplists:get_value(<<"server_key">>, Data, <<"">>)),
		salt = base64:encode(proplists:get_value(<<"salt">>, Data, <<"">>)),
		iterationcount = round(IC)
	    };
	_ -> <<"">>
    end.

convert_data(Host, "accounts", User, [Data]) ->
    Password = case proplists:get_value(<<"password">>, Data, no_pass) of
	no_pass ->
	    maybe_get_scram_auth(Data);
	Pass when is_binary(Pass) ->
	    Pass
    end,
    case ejabberd_auth:try_register(User, Host, Password) of
	ok ->
	    ok;
	Err ->
	    ?ERROR("Failed to register user ~ts@~ts: ~p",
		       [User, Host, Err]),
	    Err
    end;
convert_data(Host, "private", User, [Data]) ->
    PrivData = lists:flatmap(
		 fun({_TagXMLNS, Raw}) ->
			 case deserialize(Raw) of
			     [El] ->
				 XMLNS = fxml:get_tag_attr_s(<<"xmlns">>, El),
				 [{XMLNS, El}];
			     _ ->
				 []
			 end
		 end, Data),
    mod_private:set_data(jid:make(User, Host), PrivData);
convert_data(Host, "vcard", User, [Data]) ->
    LServer = jid:nameprep(Host),
    case deserialize(Data) of
	[VCard] ->
	    mod_vcard:set_vcard(User, LServer, VCard);
	_ ->
	    ok
    end;
convert_data(HostStr, "pubsub", Node, [Data]) ->
    case decode_pubsub_host(HostStr) of
	Host when is_binary(Host);
		  is_tuple(Host) ->
	    Type = node_type(Host),
	    NodeData = convert_node_config(HostStr, Data),
	    DefaultConfig = mod_pubsub:config(Host, default_node_config, []),
	    Owner = proplists:get_value(owner, NodeData),
	    Options = lists:foldl(
			fun({_Opt, undefined}, Acc) ->
			    Acc;
			   ({Opt, Val}, Acc) ->
			    lists:keystore(Opt, 1, Acc, {Opt, Val})
			end, DefaultConfig, proplists:get_value(options, NodeData)),
	    case mod_pubsub:tree_action(Host, create_node, [Host, Node, Type, Owner, Options, []]) of
		{ok, Nidx} ->
		    case mod_pubsub:node_action(Host, Type, create_node, [Nidx, Owner]) of
			{result, _} ->
			    Access = open, % always allow subscriptions  proplists:get_value(access_model, Options),
			    Publish = open, % always allow publications  proplists:get_value(publish_model, Options),
			    MaxItems = proplists:get_value(max_items, Options),
			    Affiliations = proplists:get_value(affiliations, NodeData),
			    Subscriptions = proplists:get_value(subscriptions, NodeData),
			    Items = proplists:get_value(items, NodeData),
			    [mod_pubsub:node_action(Host, Type, set_affiliation,
						    [Nidx, Entity, Aff])
			     || {Entity, Aff} <- Affiliations, Entity =/= Owner],
			    [mod_pubsub:node_action(Host, Type, subscribe_node,
						    [Nidx, jid:make(Entity), Entity, Access, never, [], [], []])
			     || Entity <- Subscriptions],
			    [mod_pubsub:node_action(Host, Type, publish_item,
						    [Nidx, Publisher, Publish, MaxItems, ItemId, Payload, []])
			     || {ItemId, Publisher, Payload} <- Items];
			Error ->
			    Error
		    end;
		Error ->
		    ?ERROR("Failed to import pubsub node ~ts on ~p:~n~p",
			       [Node, Host, NodeData]),
		    Error
	    end;
	Error ->
	    ?ERROR("Failed to import pubsub node: ~p", [Error]),
	    Error
    end;
convert_data(_Host, _Type, _User, _Data) ->
    ok.

convert_room_affiliations(Data) ->
    lists:flatmap(
      fun({J, Aff}) ->
	      try jid:decode(J) of
		  #jid{luser = U, lserver = S} ->
		      [{{U, S, <<>>}, misc:binary_to_atom(Aff)}]
	      catch _:{bad_jid, _} ->
		      []
	      end
      end, proplists:get_value(<<"_affiliations">>, Data, [])).

convert_room_config(Data) ->
    Config = proplists:get_value(<<"_data">>, Data, []),
    Pass = case proplists:get_value(<<"password">>, Config, <<"">>) of
	       <<"">> ->
		   [];
	       Password ->
		   [{password_protected, true},
		    {password, Password}]
	   end,
    Subj = try jid:decode(
		  proplists:get_value(
		    <<"subject_from">>, Config, <<"">>)) of
	       #jid{lresource = Nick} when Nick /= <<"">> ->
		   [{subject, proplists:get_value(<<"subject">>, Config, <<"">>)},
		    {subject_author, Nick}]
	   catch _:{bad_jid, _} ->
		   []
	   end,
    Anonymous = case proplists:get_value(<<"whois">>, Config, <<"moderators">>) of
		    <<"moderators">> -> true;
		    _ -> false
		end,
    [{affiliations, convert_room_affiliations(Data)},
     {allow_change_subj, proplists:get_bool(<<"changesubject">>, Config)},
     {mam, proplists:get_bool(<<"archiving">>, Config)},
     {description, proplists:get_value(<<"description">>, Config, <<"">>)},
     {members_only,	proplists:get_bool(<<"members_only">>, Config)},
     {moderated, proplists:get_bool(<<"moderated">>, Config)},
     {persistent, proplists:get_bool(<<"persistent">>, Config)},
     {anonymous, Anonymous}] ++ Pass ++ Subj.

url_decode(Encoded) ->
    url_decode(Encoded, <<>>).
url_decode(<<$%, Hi, Lo, Tail/binary>>, Acc) ->
    Hex = list_to_integer([Hi, Lo], 16),
    url_decode(Tail, <<Acc/binary, Hex>>);
url_decode(<<H, Tail/binary>>, Acc) ->
    url_decode(Tail, <<Acc/binary, H>>);
url_decode(<<>>, Acc) ->
    Acc.

decode_pubsub_host(Host) ->
    try jid:decode(Host) of
	#jid{luser = <<>>, lserver = LServer} -> LServer;
	#jid{luser = LUser, lserver = LServer} -> {LUser, LServer, <<>>}
    catch _:{bad_jid, _} -> bad_jid
    end.

node_type({_U, _S, _R}) -> <<"pep">>;
node_type(Host) -> hd(mod_pubsub:plugins(Host)).

max_items(Config, Default) ->
    case round(proplists:get_value(<<"max_items">>, Config, Default)) of
	I when I =< 0 -> Default;
	I -> I
    end.

convert_node_affiliations(Data) ->
    lists:flatmap(
      fun({J, Aff}) ->
	      try jid:decode(J) of
		  JID ->
		      [{JID, misc:binary_to_atom(Aff)}]
	      catch _:{bad_jid, _} ->
		      []
	      end
      end, proplists:get_value(<<"affiliations">>, Data, [])).

convert_node_subscriptions(Data) ->
    lists:flatmap(
      fun({J, true}) ->
	      try jid:decode(J) of
		  JID ->
		      [jid:tolower(JID)]
	      catch _:{bad_jid, _} ->
		      []
	      end;
	 (_) ->
	      []
      end, proplists:get_value(<<"subscribers">>, Data, [])).

convert_node_items(Host, Data) ->
    Authors = proplists:get_value(<<"data_author">>, Data, []),
    lists:flatmap(
      fun({ItemId, Item}) ->
	      try jid:decode(proplists:get_value(ItemId, Authors, Host)) of
		  JID ->
		      [El] = deserialize(Item),
		      [{ItemId, JID, El#xmlel.children}]
	      catch _:{bad_jid, _} ->
		      []
	      end
      end, proplists:get_value(<<"data">>, Data, [])).

convert_node_config(Host, Data) ->
    Config = proplists:get_value(<<"config">>, Data, []),
    [{affiliations, convert_node_affiliations(Data)},
     {subscriptions, convert_node_subscriptions(Data)},
     {owner, jid:decode(proplists:get_value(<<"creator">>, Config, Host))},
     {items, convert_node_items(Host, Data)},
     {options, [
	{deliver_notifications,
	 proplists:get_value(<<"deliver_notifications">>, Config, true)},
	{deliver_payloads,
	 proplists:get_value(<<"deliver_payloads">>, Config, true)},
	{persist_items,
	 proplists:get_value(<<"persist_items">>, Config, true)},
	{max_items,
	 max_items(Config, 10)},
	{access_model,
	 misc:binary_to_atom(proplists:get_value(<<"access_model">>, Config, <<"open">>))},
	{publish_model,
	 misc:binary_to_atom(proplists:get_value(<<"publish_model">>, Config, <<"publishers">>))},
	{title,
	 proplists:get_value(<<"title">>, Config, <<"">>)}
	       ]}
    ].

deserialize(L) ->
    deserialize(L, #xmlel{}, []).

deserialize([{Other, _}|T], El, Acc)
  when (Other == <<"key">>)
       or (Other == <<"when">>)
       or (Other == <<"with">>) ->
    deserialize(T, El, Acc);
deserialize([{<<"attr">>, Attrs}|T], El, Acc) ->
    deserialize(T, El#xmlel{attrs = Attrs ++ El#xmlel.attrs}, Acc);
deserialize([{<<"name">>, Name}|T], El, Acc) ->
    deserialize(T, El#xmlel{name = Name}, Acc);
deserialize([{_, S}|T], #xmlel{children = Els} = El, Acc) when is_binary(S) ->
    deserialize(T, El#xmlel{children = [{xmlcdata, S}|Els]}, Acc);
deserialize([{_, L}|T], #xmlel{children = Els} = El, Acc) when is_list(L) ->
    deserialize(T, El#xmlel{children = deserialize(L) ++ Els}, Acc);
deserialize([], #xmlel{children = Els} = El, Acc) ->
    [El#xmlel{children = lists:reverse(Els)}|Acc].
