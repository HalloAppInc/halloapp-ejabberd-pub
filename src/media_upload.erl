%% -*- coding: utf-8 -*-
%% @private
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.13.0
-module(media_upload).

-export([encode_msg/1, encode_msg/2, encode_msg/3]).
-export([decode_msg/2, decode_msg/3]).
-export([merge_msgs/2, merge_msgs/3, merge_msgs/4]).
-export([verify_msg/1, verify_msg/2, verify_msg/3]).
-export([get_msg_defs/0]).
-export([get_msg_names/0]).
-export([get_group_names/0]).
-export([get_msg_or_group_names/0]).
-export([get_enum_names/0]).
-export([find_msg_def/1, fetch_msg_def/1]).
-export([find_enum_def/1, fetch_enum_def/1]).
-export([enum_symbol_by_value/2, enum_value_by_symbol/2]).
-export([get_service_names/0]).
-export([get_service_def/1]).
-export([get_rpc_names/1]).
-export([find_rpc_def/2, fetch_rpc_def/2]).
-export([fqbin_to_service_name/1]).
-export([service_name_to_fqbin/1]).
-export([fqbins_to_service_and_rpc_name/2]).
-export([service_and_rpc_name_to_fqbins/2]).
-export([fqbin_to_msg_name/1]).
-export([msg_name_to_fqbin/1]).
-export([fqbin_to_enum_name/1]).
-export([enum_name_to_fqbin/1]).
-export([get_package_name/0]).
-export([uses_packages/0]).
-export([source_basename/0]).
-export([get_all_source_basenames/0]).
-export([get_all_proto_names/0]).
-export([get_msg_containment/1]).
-export([get_pkg_containment/1]).
-export([get_service_containment/1]).
-export([get_rpc_containment/1]).
-export([get_enum_containment/1]).
-export([get_proto_by_msg_name_as_fqbin/1]).
-export([get_proto_by_service_name_as_fqbin/1]).
-export([get_proto_by_enum_name_as_fqbin/1]).
-export([get_protos_by_pkg_name_as_fqbin/1]).
-export([gpb_version_as_string/0, gpb_version_as_list/0]).

-include("media_upload.hrl").
-include("gpb.hrl").

%% enumerated types

-export_type([]).

%% message types
-type pb_media_url() :: #pb_media_url{}.

-type pb_upload_media() :: #pb_upload_media{}.

-export_type(['pb_media_url'/0, 'pb_upload_media'/0]).

-spec encode_msg(#pb_media_url{} | #pb_upload_media{}) -> binary().
encode_msg(Msg) when tuple_size(Msg) >= 1 -> encode_msg(Msg, element(1, Msg), []).

-spec encode_msg(#pb_media_url{} | #pb_upload_media{}, atom() | list()) -> binary().
encode_msg(Msg, MsgName) when is_atom(MsgName) -> encode_msg(Msg, MsgName, []);
encode_msg(Msg, Opts) when tuple_size(Msg) >= 1, is_list(Opts) -> encode_msg(Msg, element(1, Msg), Opts).

-spec encode_msg(#pb_media_url{} | #pb_upload_media{}, atom(), list()) -> binary().
encode_msg(Msg, MsgName, Opts) ->
    case proplists:get_bool(verify, Opts) of
      true -> verify_msg(Msg, MsgName, Opts);
      false -> ok
    end,
    TrUserData = proplists:get_value(user_data, Opts),
    case MsgName of
      pb_media_url -> encode_msg_pb_media_url(id(Msg, TrUserData), TrUserData);
      pb_upload_media -> encode_msg_pb_upload_media(id(Msg, TrUserData), TrUserData)
    end.


encode_msg_pb_media_url(Msg, TrUserData) -> encode_msg_pb_media_url(Msg, <<>>, TrUserData).


encode_msg_pb_media_url(#pb_media_url{get = F1, put = F2, patch = F3}, Bin, TrUserData) ->
    B1 = if F1 == undefined -> Bin;
	    true ->
		begin
		  TrF1 = id(F1, TrUserData),
		  case is_empty_string(TrF1) of
		    true -> Bin;
		    false -> e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
		  end
		end
	 end,
    B2 = if F2 == undefined -> B1;
	    true ->
		begin
		  TrF2 = id(F2, TrUserData),
		  case is_empty_string(TrF2) of
		    true -> B1;
		    false -> e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
		  end
		end
	 end,
    if F3 == undefined -> B2;
       true ->
	   begin
	     TrF3 = id(F3, TrUserData),
	     case is_empty_string(TrF3) of
	       true -> B2;
	       false -> e_type_string(TrF3, <<B2/binary, 26>>, TrUserData)
	     end
	   end
    end.

encode_msg_pb_upload_media(Msg, TrUserData) -> encode_msg_pb_upload_media(Msg, <<>>, TrUserData).


encode_msg_pb_upload_media(#pb_upload_media{size = F1, url = F2}, Bin, TrUserData) ->
    B1 = if F1 == undefined -> Bin;
	    true ->
		begin
		  TrF1 = id(F1, TrUserData),
		  if TrF1 =:= 0 -> Bin;
		     true -> e_type_int64(TrF1, <<Bin/binary, 8>>, TrUserData)
		  end
		end
	 end,
    if F2 == undefined -> B1;
       true ->
	   begin
	     TrF2 = id(F2, TrUserData),
	     if TrF2 =:= undefined -> B1;
		true -> e_mfield_pb_upload_media_url(TrF2, <<B1/binary, 18>>, TrUserData)
	     end
	   end
    end.

e_mfield_pb_upload_media_url(Msg, Bin, TrUserData) -> SubBin = encode_msg_pb_media_url(Msg, <<>>, TrUserData), Bin2 = e_varint(byte_size(SubBin), Bin), <<Bin2/binary, SubBin/binary>>.

-compile({nowarn_unused_function,e_type_sint/3}).
e_type_sint(Value, Bin, _TrUserData) when Value >= 0 -> e_varint(Value * 2, Bin);
e_type_sint(Value, Bin, _TrUserData) -> e_varint(Value * -2 - 1, Bin).

-compile({nowarn_unused_function,e_type_int32/3}).
e_type_int32(Value, Bin, _TrUserData) when 0 =< Value, Value =< 127 -> <<Bin/binary, Value>>;
e_type_int32(Value, Bin, _TrUserData) -> <<N:64/unsigned-native>> = <<Value:64/signed-native>>, e_varint(N, Bin).

-compile({nowarn_unused_function,e_type_int64/3}).
e_type_int64(Value, Bin, _TrUserData) when 0 =< Value, Value =< 127 -> <<Bin/binary, Value>>;
e_type_int64(Value, Bin, _TrUserData) -> <<N:64/unsigned-native>> = <<Value:64/signed-native>>, e_varint(N, Bin).

-compile({nowarn_unused_function,e_type_bool/3}).
e_type_bool(true, Bin, _TrUserData) -> <<Bin/binary, 1>>;
e_type_bool(false, Bin, _TrUserData) -> <<Bin/binary, 0>>;
e_type_bool(1, Bin, _TrUserData) -> <<Bin/binary, 1>>;
e_type_bool(0, Bin, _TrUserData) -> <<Bin/binary, 0>>.

-compile({nowarn_unused_function,e_type_string/3}).
e_type_string(S, Bin, _TrUserData) -> Utf8 = unicode:characters_to_binary(S), Bin2 = e_varint(byte_size(Utf8), Bin), <<Bin2/binary, Utf8/binary>>.

-compile({nowarn_unused_function,e_type_bytes/3}).
e_type_bytes(Bytes, Bin, _TrUserData) when is_binary(Bytes) -> Bin2 = e_varint(byte_size(Bytes), Bin), <<Bin2/binary, Bytes/binary>>;
e_type_bytes(Bytes, Bin, _TrUserData) when is_list(Bytes) -> BytesBin = iolist_to_binary(Bytes), Bin2 = e_varint(byte_size(BytesBin), Bin), <<Bin2/binary, BytesBin/binary>>.

-compile({nowarn_unused_function,e_type_fixed32/3}).
e_type_fixed32(Value, Bin, _TrUserData) -> <<Bin/binary, Value:32/little>>.

-compile({nowarn_unused_function,e_type_sfixed32/3}).
e_type_sfixed32(Value, Bin, _TrUserData) -> <<Bin/binary, Value:32/little-signed>>.

-compile({nowarn_unused_function,e_type_fixed64/3}).
e_type_fixed64(Value, Bin, _TrUserData) -> <<Bin/binary, Value:64/little>>.

-compile({nowarn_unused_function,e_type_sfixed64/3}).
e_type_sfixed64(Value, Bin, _TrUserData) -> <<Bin/binary, Value:64/little-signed>>.

-compile({nowarn_unused_function,e_type_float/3}).
e_type_float(V, Bin, _) when is_number(V) -> <<Bin/binary, V:32/little-float>>;
e_type_float(infinity, Bin, _) -> <<Bin/binary, 0:16, 128, 127>>;
e_type_float('-infinity', Bin, _) -> <<Bin/binary, 0:16, 128, 255>>;
e_type_float(nan, Bin, _) -> <<Bin/binary, 0:16, 192, 127>>.

-compile({nowarn_unused_function,e_type_double/3}).
e_type_double(V, Bin, _) when is_number(V) -> <<Bin/binary, V:64/little-float>>;
e_type_double(infinity, Bin, _) -> <<Bin/binary, 0:48, 240, 127>>;
e_type_double('-infinity', Bin, _) -> <<Bin/binary, 0:48, 240, 255>>;
e_type_double(nan, Bin, _) -> <<Bin/binary, 0:48, 248, 127>>.

-compile({nowarn_unused_function,e_varint/3}).
e_varint(N, Bin, _TrUserData) -> e_varint(N, Bin).

-compile({nowarn_unused_function,e_varint/2}).
e_varint(N, Bin) when N =< 127 -> <<Bin/binary, N>>;
e_varint(N, Bin) -> Bin2 = <<Bin/binary, (N band 127 bor 128)>>, e_varint(N bsr 7, Bin2).

is_empty_string("") -> true;
is_empty_string(<<>>) -> true;
is_empty_string(L) when is_list(L) -> not string_has_chars(L);
is_empty_string(B) when is_binary(B) -> false.

string_has_chars([C | _]) when is_integer(C) -> true;
string_has_chars([H | T]) ->
    case string_has_chars(H) of
      true -> true;
      false -> string_has_chars(T)
    end;
string_has_chars(B) when is_binary(B), byte_size(B) =/= 0 -> true;
string_has_chars(C) when is_integer(C) -> true;
string_has_chars(<<>>) -> false;
string_has_chars([]) -> false.


decode_msg(Bin, MsgName) when is_binary(Bin) -> decode_msg(Bin, MsgName, []).

decode_msg(Bin, MsgName, Opts) when is_binary(Bin) -> TrUserData = proplists:get_value(user_data, Opts), decode_msg_1_catch(Bin, MsgName, TrUserData).

-ifdef('OTP_RELEASE').
decode_msg_1_catch(Bin, MsgName, TrUserData) ->
    try decode_msg_2_doit(MsgName, Bin, TrUserData)
    catch Class:Reason:StackTrace -> error({gpb_error,{decoding_failure, {Bin, MsgName, {Class, Reason, StackTrace}}}})
    end.
-else.
decode_msg_1_catch(Bin, MsgName, TrUserData) ->
    try decode_msg_2_doit(MsgName, Bin, TrUserData)
    catch Class:Reason ->
        StackTrace = erlang:get_stacktrace(),
        error({gpb_error,{decoding_failure, {Bin, MsgName, {Class, Reason, StackTrace}}}})
    end.
-endif.

decode_msg_2_doit(pb_media_url, Bin, TrUserData) -> id(decode_msg_pb_media_url(Bin, TrUserData), TrUserData);
decode_msg_2_doit(pb_upload_media, Bin, TrUserData) -> id(decode_msg_pb_upload_media(Bin, TrUserData), TrUserData).



decode_msg_pb_media_url(Bin, TrUserData) -> dfp_read_field_def_pb_media_url(Bin, 0, 0, id([], TrUserData), id([], TrUserData), id([], TrUserData), TrUserData).

dfp_read_field_def_pb_media_url(<<10, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> d_field_pb_media_url_get(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData);
dfp_read_field_def_pb_media_url(<<18, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> d_field_pb_media_url_put(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData);
dfp_read_field_def_pb_media_url(<<26, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> d_field_pb_media_url_patch(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData);
dfp_read_field_def_pb_media_url(<<>>, 0, 0, F@_1, F@_2, F@_3, _) -> #pb_media_url{get = F@_1, put = F@_2, patch = F@_3};
dfp_read_field_def_pb_media_url(Other, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> dg_read_field_def_pb_media_url(Other, Z1, Z2, F@_1, F@_2, F@_3, TrUserData).

dg_read_field_def_pb_media_url(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) when N < 32 - 7 -> dg_read_field_def_pb_media_url(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, F@_3, TrUserData);
dg_read_field_def_pb_media_url(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
    Key = X bsl N + Acc,
    case Key of
      10 -> d_field_pb_media_url_get(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
      18 -> d_field_pb_media_url_put(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
      26 -> d_field_pb_media_url_patch(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
      _ ->
	  case Key band 7 of
	    0 -> skip_varint_pb_media_url(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
	    1 -> skip_64_pb_media_url(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
	    2 -> skip_length_delimited_pb_media_url(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData);
	    3 -> skip_group_pb_media_url(Rest, Key bsr 3, 0, F@_1, F@_2, F@_3, TrUserData);
	    5 -> skip_32_pb_media_url(Rest, 0, 0, F@_1, F@_2, F@_3, TrUserData)
	  end
    end;
dg_read_field_def_pb_media_url(<<>>, 0, 0, F@_1, F@_2, F@_3, _) -> #pb_media_url{get = F@_1, put = F@_2, patch = F@_3}.

d_field_pb_media_url_get(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) when N < 57 -> d_field_pb_media_url_get(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, F@_3, TrUserData);
d_field_pb_media_url_get(<<0:1, X:7, Rest/binary>>, N, Acc, _, F@_2, F@_3, TrUserData) ->
    {NewFValue, RestF} = begin Len = X bsl N + Acc, <<Utf8:Len/binary, Rest2/binary>> = Rest, {id(unicode:characters_to_list(Utf8, unicode), TrUserData), Rest2} end, dfp_read_field_def_pb_media_url(RestF, 0, 0, NewFValue, F@_2, F@_3, TrUserData).

d_field_pb_media_url_put(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) when N < 57 -> d_field_pb_media_url_put(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, F@_3, TrUserData);
d_field_pb_media_url_put(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, _, F@_3, TrUserData) ->
    {NewFValue, RestF} = begin Len = X bsl N + Acc, <<Utf8:Len/binary, Rest2/binary>> = Rest, {id(unicode:characters_to_list(Utf8, unicode), TrUserData), Rest2} end, dfp_read_field_def_pb_media_url(RestF, 0, 0, F@_1, NewFValue, F@_3, TrUserData).

d_field_pb_media_url_patch(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) when N < 57 -> d_field_pb_media_url_patch(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, F@_3, TrUserData);
d_field_pb_media_url_patch(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, _, TrUserData) ->
    {NewFValue, RestF} = begin Len = X bsl N + Acc, <<Utf8:Len/binary, Rest2/binary>> = Rest, {id(unicode:characters_to_list(Utf8, unicode), TrUserData), Rest2} end, dfp_read_field_def_pb_media_url(RestF, 0, 0, F@_1, F@_2, NewFValue, TrUserData).

skip_varint_pb_media_url(<<1:1, _:7, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> skip_varint_pb_media_url(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData);
skip_varint_pb_media_url(<<0:1, _:7, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> dfp_read_field_def_pb_media_url(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData).

skip_length_delimited_pb_media_url(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) when N < 57 -> skip_length_delimited_pb_media_url(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, F@_3, TrUserData);
skip_length_delimited_pb_media_url(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, F@_3, TrUserData) -> Length = X bsl N + Acc, <<_:Length/binary, Rest2/binary>> = Rest, dfp_read_field_def_pb_media_url(Rest2, 0, 0, F@_1, F@_2, F@_3, TrUserData).

skip_group_pb_media_url(Bin, FNum, Z2, F@_1, F@_2, F@_3, TrUserData) -> {_, Rest} = read_group(Bin, FNum), dfp_read_field_def_pb_media_url(Rest, 0, Z2, F@_1, F@_2, F@_3, TrUserData).

skip_32_pb_media_url(<<_:32, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> dfp_read_field_def_pb_media_url(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData).

skip_64_pb_media_url(<<_:64, Rest/binary>>, Z1, Z2, F@_1, F@_2, F@_3, TrUserData) -> dfp_read_field_def_pb_media_url(Rest, Z1, Z2, F@_1, F@_2, F@_3, TrUserData).

decode_msg_pb_upload_media(Bin, TrUserData) -> dfp_read_field_def_pb_upload_media(Bin, 0, 0, id(0, TrUserData), id(undefined, TrUserData), TrUserData).

dfp_read_field_def_pb_upload_media(<<8, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> d_field_pb_upload_media_size(Rest, Z1, Z2, F@_1, F@_2, TrUserData);
dfp_read_field_def_pb_upload_media(<<18, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> d_field_pb_upload_media_url(Rest, Z1, Z2, F@_1, F@_2, TrUserData);
dfp_read_field_def_pb_upload_media(<<>>, 0, 0, F@_1, F@_2, _) -> #pb_upload_media{size = F@_1, url = F@_2};
dfp_read_field_def_pb_upload_media(Other, Z1, Z2, F@_1, F@_2, TrUserData) -> dg_read_field_def_pb_upload_media(Other, Z1, Z2, F@_1, F@_2, TrUserData).

dg_read_field_def_pb_upload_media(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) when N < 32 - 7 -> dg_read_field_def_pb_upload_media(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, TrUserData);
dg_read_field_def_pb_upload_media(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) ->
    Key = X bsl N + Acc,
    case Key of
      8 -> d_field_pb_upload_media_size(Rest, 0, 0, F@_1, F@_2, TrUserData);
      18 -> d_field_pb_upload_media_url(Rest, 0, 0, F@_1, F@_2, TrUserData);
      _ ->
	  case Key band 7 of
	    0 -> skip_varint_pb_upload_media(Rest, 0, 0, F@_1, F@_2, TrUserData);
	    1 -> skip_64_pb_upload_media(Rest, 0, 0, F@_1, F@_2, TrUserData);
	    2 -> skip_length_delimited_pb_upload_media(Rest, 0, 0, F@_1, F@_2, TrUserData);
	    3 -> skip_group_pb_upload_media(Rest, Key bsr 3, 0, F@_1, F@_2, TrUserData);
	    5 -> skip_32_pb_upload_media(Rest, 0, 0, F@_1, F@_2, TrUserData)
	  end
    end;
dg_read_field_def_pb_upload_media(<<>>, 0, 0, F@_1, F@_2, _) -> #pb_upload_media{size = F@_1, url = F@_2}.

d_field_pb_upload_media_size(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) when N < 57 -> d_field_pb_upload_media_size(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, TrUserData);
d_field_pb_upload_media_size(<<0:1, X:7, Rest/binary>>, N, Acc, _, F@_2, TrUserData) ->
    {NewFValue, RestF} = {begin <<Res:64/signed-native>> = <<(X bsl N + Acc):64/unsigned-native>>, id(Res, TrUserData) end, Rest}, dfp_read_field_def_pb_upload_media(RestF, 0, 0, NewFValue, F@_2, TrUserData).

d_field_pb_upload_media_url(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) when N < 57 -> d_field_pb_upload_media_url(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, TrUserData);
d_field_pb_upload_media_url(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, Prev, TrUserData) ->
    {NewFValue, RestF} = begin Len = X bsl N + Acc, <<Bs:Len/binary, Rest2/binary>> = Rest, {id(decode_msg_pb_media_url(Bs, TrUserData), TrUserData), Rest2} end,
    dfp_read_field_def_pb_upload_media(RestF, 0, 0, F@_1,
				       if Prev == undefined -> NewFValue;
					  true -> merge_msg_pb_media_url(Prev, NewFValue, TrUserData)
				       end,
				       TrUserData).

skip_varint_pb_upload_media(<<1:1, _:7, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> skip_varint_pb_upload_media(Rest, Z1, Z2, F@_1, F@_2, TrUserData);
skip_varint_pb_upload_media(<<0:1, _:7, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> dfp_read_field_def_pb_upload_media(Rest, Z1, Z2, F@_1, F@_2, TrUserData).

skip_length_delimited_pb_upload_media(<<1:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) when N < 57 -> skip_length_delimited_pb_upload_media(Rest, N + 7, X bsl N + Acc, F@_1, F@_2, TrUserData);
skip_length_delimited_pb_upload_media(<<0:1, X:7, Rest/binary>>, N, Acc, F@_1, F@_2, TrUserData) -> Length = X bsl N + Acc, <<_:Length/binary, Rest2/binary>> = Rest, dfp_read_field_def_pb_upload_media(Rest2, 0, 0, F@_1, F@_2, TrUserData).

skip_group_pb_upload_media(Bin, FNum, Z2, F@_1, F@_2, TrUserData) -> {_, Rest} = read_group(Bin, FNum), dfp_read_field_def_pb_upload_media(Rest, 0, Z2, F@_1, F@_2, TrUserData).

skip_32_pb_upload_media(<<_:32, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> dfp_read_field_def_pb_upload_media(Rest, Z1, Z2, F@_1, F@_2, TrUserData).

skip_64_pb_upload_media(<<_:64, Rest/binary>>, Z1, Z2, F@_1, F@_2, TrUserData) -> dfp_read_field_def_pb_upload_media(Rest, Z1, Z2, F@_1, F@_2, TrUserData).

read_group(Bin, FieldNum) ->
    {NumBytes, EndTagLen} = read_gr_b(Bin, 0, 0, 0, 0, FieldNum),
    <<Group:NumBytes/binary, _:EndTagLen/binary, Rest/binary>> = Bin,
    {Group, Rest}.

%% Like skipping over fields, but record the total length,
%% Each field is <(FieldNum bsl 3) bor FieldType> ++ <FieldValue>
%% Record the length because varints may be non-optimally encoded.
%%
%% Groups can be nested, but assume the same FieldNum cannot be nested
%% because group field numbers are shared with the rest of the fields
%% numbers. Thus we can search just for an group-end with the same
%% field number.
%%
%% (The only time the same group field number could occur would
%% be in a nested sub message, but then it would be inside a
%% length-delimited entry, which we skip-read by length.)
read_gr_b(<<1:1, X:7, Tl/binary>>, N, Acc, NumBytes, TagLen, FieldNum)
  when N < (32-7) ->
    read_gr_b(Tl, N+7, X bsl N + Acc, NumBytes, TagLen+1, FieldNum);
read_gr_b(<<0:1, X:7, Tl/binary>>, N, Acc, NumBytes, TagLen,
          FieldNum) ->
    Key = X bsl N + Acc,
    TagLen1 = TagLen + 1,
    case {Key bsr 3, Key band 7} of
        {FieldNum, 4} -> % 4 = group_end
            {NumBytes, TagLen1};
        {_, 0} -> % 0 = varint
            read_gr_vi(Tl, 0, NumBytes + TagLen1, FieldNum);
        {_, 1} -> % 1 = bits64
            <<_:64, Tl2/binary>> = Tl,
            read_gr_b(Tl2, 0, 0, NumBytes + TagLen1 + 8, 0, FieldNum);
        {_, 2} -> % 2 = length_delimited
            read_gr_ld(Tl, 0, 0, NumBytes + TagLen1, FieldNum);
        {_, 3} -> % 3 = group_start
            read_gr_b(Tl, 0, 0, NumBytes + TagLen1, 0, FieldNum);
        {_, 4} -> % 4 = group_end
            read_gr_b(Tl, 0, 0, NumBytes + TagLen1, 0, FieldNum);
        {_, 5} -> % 5 = bits32
            <<_:32, Tl2/binary>> = Tl,
            read_gr_b(Tl2, 0, 0, NumBytes + TagLen1 + 4, 0, FieldNum)
    end.

read_gr_vi(<<1:1, _:7, Tl/binary>>, N, NumBytes, FieldNum)
  when N < (64-7) ->
    read_gr_vi(Tl, N+7, NumBytes+1, FieldNum);
read_gr_vi(<<0:1, _:7, Tl/binary>>, _, NumBytes, FieldNum) ->
    read_gr_b(Tl, 0, 0, NumBytes+1, 0, FieldNum).

read_gr_ld(<<1:1, X:7, Tl/binary>>, N, Acc, NumBytes, FieldNum)
  when N < (64-7) ->
    read_gr_ld(Tl, N+7, X bsl N + Acc, NumBytes+1, FieldNum);
read_gr_ld(<<0:1, X:7, Tl/binary>>, N, Acc, NumBytes, FieldNum) ->
    Len = X bsl N + Acc,
    NumBytes1 = NumBytes + 1,
    <<_:Len/binary, Tl2/binary>> = Tl,
    read_gr_b(Tl2, 0, 0, NumBytes1 + Len, 0, FieldNum).

merge_msgs(Prev, New) when element(1, Prev) =:= element(1, New) -> merge_msgs(Prev, New, element(1, Prev), []).

merge_msgs(Prev, New, MsgName) when is_atom(MsgName) -> merge_msgs(Prev, New, MsgName, []);
merge_msgs(Prev, New, Opts) when element(1, Prev) =:= element(1, New), is_list(Opts) -> merge_msgs(Prev, New, element(1, Prev), Opts).

merge_msgs(Prev, New, MsgName, Opts) ->
    TrUserData = proplists:get_value(user_data, Opts),
    case MsgName of
      pb_media_url -> merge_msg_pb_media_url(Prev, New, TrUserData);
      pb_upload_media -> merge_msg_pb_upload_media(Prev, New, TrUserData)
    end.

-compile({nowarn_unused_function,merge_msg_pb_media_url/3}).
merge_msg_pb_media_url(#pb_media_url{get = PFget, put = PFput, patch = PFpatch}, #pb_media_url{get = NFget, put = NFput, patch = NFpatch}, _) ->
    #pb_media_url{get =
		      if NFget =:= undefined -> PFget;
			 true -> NFget
		      end,
		  put =
		      if NFput =:= undefined -> PFput;
			 true -> NFput
		      end,
		  patch =
		      if NFpatch =:= undefined -> PFpatch;
			 true -> NFpatch
		      end}.

-compile({nowarn_unused_function,merge_msg_pb_upload_media/3}).
merge_msg_pb_upload_media(#pb_upload_media{size = PFsize, url = PFurl}, #pb_upload_media{size = NFsize, url = NFurl}, TrUserData) ->
    #pb_upload_media{size =
			 if NFsize =:= undefined -> PFsize;
			    true -> NFsize
			 end,
		     url =
			 if PFurl /= undefined, NFurl /= undefined -> merge_msg_pb_media_url(PFurl, NFurl, TrUserData);
			    PFurl == undefined -> NFurl;
			    NFurl == undefined -> PFurl
			 end}.


verify_msg(Msg) when tuple_size(Msg) >= 1 -> verify_msg(Msg, element(1, Msg), []);
verify_msg(X) -> mk_type_error(not_a_known_message, X, []).

verify_msg(Msg, MsgName) when is_atom(MsgName) -> verify_msg(Msg, MsgName, []);
verify_msg(Msg, Opts) when tuple_size(Msg) >= 1 -> verify_msg(Msg, element(1, Msg), Opts);
verify_msg(X, _Opts) -> mk_type_error(not_a_known_message, X, []).

verify_msg(Msg, MsgName, Opts) ->
    TrUserData = proplists:get_value(user_data, Opts),
    case MsgName of
      pb_media_url -> v_msg_pb_media_url(Msg, [MsgName], TrUserData);
      pb_upload_media -> v_msg_pb_upload_media(Msg, [MsgName], TrUserData);
      _ -> mk_type_error(not_a_known_message, Msg, [])
    end.


-compile({nowarn_unused_function,v_msg_pb_media_url/3}).
-dialyzer({nowarn_function,v_msg_pb_media_url/3}).
v_msg_pb_media_url(#pb_media_url{get = F1, put = F2, patch = F3}, Path, TrUserData) ->
    if F1 == undefined -> ok;
       true -> v_type_string(F1, [get | Path], TrUserData)
    end,
    if F2 == undefined -> ok;
       true -> v_type_string(F2, [put | Path], TrUserData)
    end,
    if F3 == undefined -> ok;
       true -> v_type_string(F3, [patch | Path], TrUserData)
    end,
    ok;
v_msg_pb_media_url(X, Path, _TrUserData) -> mk_type_error({expected_msg, pb_media_url}, X, Path).

-compile({nowarn_unused_function,v_msg_pb_upload_media/3}).
-dialyzer({nowarn_function,v_msg_pb_upload_media/3}).
v_msg_pb_upload_media(#pb_upload_media{size = F1, url = F2}, Path, TrUserData) ->
    if F1 == undefined -> ok;
       true -> v_type_int64(F1, [size | Path], TrUserData)
    end,
    if F2 == undefined -> ok;
       true -> v_msg_pb_media_url(F2, [url | Path], TrUserData)
    end,
    ok;
v_msg_pb_upload_media(X, Path, _TrUserData) -> mk_type_error({expected_msg, pb_upload_media}, X, Path).

-compile({nowarn_unused_function,v_type_int64/3}).
-dialyzer({nowarn_function,v_type_int64/3}).
v_type_int64(N, _Path, _TrUserData) when -9223372036854775808 =< N, N =< 9223372036854775807 -> ok;
v_type_int64(N, Path, _TrUserData) when is_integer(N) -> mk_type_error({value_out_of_range, int64, signed, 64}, N, Path);
v_type_int64(X, Path, _TrUserData) -> mk_type_error({bad_integer, int64, signed, 64}, X, Path).

-compile({nowarn_unused_function,v_type_string/3}).
-dialyzer({nowarn_function,v_type_string/3}).
v_type_string(S, Path, _TrUserData) when is_list(S); is_binary(S) ->
    try unicode:characters_to_binary(S) of
      B when is_binary(B) -> ok;
      {error, _, _} -> mk_type_error(bad_unicode_string, S, Path)
    catch
      error:badarg -> mk_type_error(bad_unicode_string, S, Path)
    end;
v_type_string(X, Path, _TrUserData) -> mk_type_error(bad_unicode_string, X, Path).

-compile({nowarn_unused_function,mk_type_error/3}).
-spec mk_type_error(_, _, list()) -> no_return().
mk_type_error(Error, ValueSeen, Path) -> Path2 = prettify_path(Path), erlang:error({gpb_type_error, {Error, [{value, ValueSeen}, {path, Path2}]}}).


-compile({nowarn_unused_function,prettify_path/1}).
-dialyzer({nowarn_function,prettify_path/1}).
prettify_path([]) -> top_level;
prettify_path(PathR) -> list_to_atom(lists:append(lists:join(".", lists:map(fun atom_to_list/1, lists:reverse(PathR))))).


-compile({nowarn_unused_function,id/2}).
-compile({inline,id/2}).
id(X, _TrUserData) -> X.

-compile({nowarn_unused_function,v_ok/3}).
-compile({inline,v_ok/3}).
v_ok(_Value, _Path, _TrUserData) -> ok.

-compile({nowarn_unused_function,m_overwrite/3}).
-compile({inline,m_overwrite/3}).
m_overwrite(_Prev, New, _TrUserData) -> New.

-compile({nowarn_unused_function,cons/3}).
-compile({inline,cons/3}).
cons(Elem, Acc, _TrUserData) -> [Elem | Acc].

-compile({nowarn_unused_function,lists_reverse/2}).
-compile({inline,lists_reverse/2}).
'lists_reverse'(L, _TrUserData) -> lists:reverse(L).
-compile({nowarn_unused_function,'erlang_++'/3}).
-compile({inline,'erlang_++'/3}).
'erlang_++'(A, B, _TrUserData) -> A ++ B.


get_msg_defs() ->
    [{{msg, pb_media_url},
      [#field{name = get, fnum = 1, rnum = 2, type = string, occurrence = optional, opts = []}, #field{name = put, fnum = 2, rnum = 3, type = string, occurrence = optional, opts = []},
       #field{name = patch, fnum = 3, rnum = 4, type = string, occurrence = optional, opts = []}]},
     {{msg, pb_upload_media}, [#field{name = size, fnum = 1, rnum = 2, type = int64, occurrence = optional, opts = []}, #field{name = url, fnum = 2, rnum = 3, type = {msg, pb_media_url}, occurrence = optional, opts = []}]}].


get_msg_names() -> [pb_media_url, pb_upload_media].


get_group_names() -> [].


get_msg_or_group_names() -> [pb_media_url, pb_upload_media].


get_enum_names() -> [].


fetch_msg_def(MsgName) ->
    case find_msg_def(MsgName) of
      Fs when is_list(Fs) -> Fs;
      error -> erlang:error({no_such_msg, MsgName})
    end.


-spec fetch_enum_def(_) -> no_return().
fetch_enum_def(EnumName) -> erlang:error({no_such_enum, EnumName}).


find_msg_def(pb_media_url) ->
    [#field{name = get, fnum = 1, rnum = 2, type = string, occurrence = optional, opts = []}, #field{name = put, fnum = 2, rnum = 3, type = string, occurrence = optional, opts = []},
     #field{name = patch, fnum = 3, rnum = 4, type = string, occurrence = optional, opts = []}];
find_msg_def(pb_upload_media) -> [#field{name = size, fnum = 1, rnum = 2, type = int64, occurrence = optional, opts = []}, #field{name = url, fnum = 2, rnum = 3, type = {msg, pb_media_url}, occurrence = optional, opts = []}];
find_msg_def(_) -> error.


find_enum_def(_) -> error.


-spec enum_symbol_by_value(_, _) -> no_return().
enum_symbol_by_value(E, V) -> erlang:error({no_enum_defs, E, V}).


-spec enum_value_by_symbol(_, _) -> no_return().
enum_value_by_symbol(E, V) -> erlang:error({no_enum_defs, E, V}).



get_service_names() -> [].


get_service_def(_) -> error.


get_rpc_names(_) -> error.


find_rpc_def(_, _) -> error.



-spec fetch_rpc_def(_, _) -> no_return().
fetch_rpc_def(ServiceName, RpcName) -> erlang:error({no_such_rpc, ServiceName, RpcName}).


%% Convert a a fully qualified (ie with package name) service name
%% as a binary to a service name as an atom.
-spec fqbin_to_service_name(_) -> no_return().
fqbin_to_service_name(X) -> error({gpb_error, {badservice, X}}).


%% Convert a service name as an atom to a fully qualified
%% (ie with package name) name as a binary.
-spec service_name_to_fqbin(_) -> no_return().
service_name_to_fqbin(X) -> error({gpb_error, {badservice, X}}).


%% Convert a a fully qualified (ie with package name) service name
%% and an rpc name, both as binaries to a service name and an rpc
%% name, as atoms.
-spec fqbins_to_service_and_rpc_name(_, _) -> no_return().
fqbins_to_service_and_rpc_name(S, R) -> error({gpb_error, {badservice_or_rpc, {S, R}}}).


%% Convert a service name and an rpc name, both as atoms,
%% to a fully qualified (ie with package name) service name and
%% an rpc name as binaries.
-spec service_and_rpc_name_to_fqbins(_, _) -> no_return().
service_and_rpc_name_to_fqbins(S, R) -> error({gpb_error, {badservice_or_rpc, {S, R}}}).


fqbin_to_msg_name(<<"media_url">>) -> pb_media_url;
fqbin_to_msg_name(<<"upload_media">>) -> pb_upload_media;
fqbin_to_msg_name(E) -> error({gpb_error, {badmsg, E}}).


msg_name_to_fqbin(pb_media_url) -> <<"media_url">>;
msg_name_to_fqbin(pb_upload_media) -> <<"upload_media">>;
msg_name_to_fqbin(E) -> error({gpb_error, {badmsg, E}}).


-spec fqbin_to_enum_name(_) -> no_return().
fqbin_to_enum_name(E) -> error({gpb_error, {badenum, E}}).


-spec enum_name_to_fqbin(_) -> no_return().
enum_name_to_fqbin(E) -> error({gpb_error, {badenum, E}}).


get_package_name() -> undefined.


%% Whether or not the message names
%% are prepended with package name or not.
uses_packages() -> false.


source_basename() -> "media_upload.proto".


%% Retrieve all proto file names, also imported ones.
%% The order is top-down. The first element is always the main
%% source file. The files are returned with extension,
%% see get_all_proto_names/0 for a version that returns
%% the basenames sans extension
get_all_source_basenames() -> ["media_upload.proto"].


%% Retrieve all proto file names, also imported ones.
%% The order is top-down. The first element is always the main
%% source file. The files are returned sans .proto extension,
%% to make it easier to use them with the various get_xyz_containment
%% functions.
get_all_proto_names() -> ["media_upload"].


get_msg_containment("media_upload") -> [pb_media_url, pb_upload_media];
get_msg_containment(P) -> error({gpb_error, {badproto, P}}).


get_pkg_containment("media_upload") -> undefined;
get_pkg_containment(P) -> error({gpb_error, {badproto, P}}).


get_service_containment("media_upload") -> [];
get_service_containment(P) -> error({gpb_error, {badproto, P}}).


get_rpc_containment("media_upload") -> [];
get_rpc_containment(P) -> error({gpb_error, {badproto, P}}).


get_enum_containment("media_upload") -> [];
get_enum_containment(P) -> error({gpb_error, {badproto, P}}).


get_proto_by_msg_name_as_fqbin(<<"upload_media">>) -> "media_upload";
get_proto_by_msg_name_as_fqbin(<<"media_url">>) -> "media_upload";
get_proto_by_msg_name_as_fqbin(E) -> error({gpb_error, {badmsg, E}}).


-spec get_proto_by_service_name_as_fqbin(_) -> no_return().
get_proto_by_service_name_as_fqbin(E) -> error({gpb_error, {badservice, E}}).


-spec get_proto_by_enum_name_as_fqbin(_) -> no_return().
get_proto_by_enum_name_as_fqbin(E) -> error({gpb_error, {badenum, E}}).


-spec get_protos_by_pkg_name_as_fqbin(_) -> no_return().
get_protos_by_pkg_name_as_fqbin(E) -> error({gpb_error, {badpkg, E}}).



gpb_version_as_string() ->
    "4.13.0".

gpb_version_as_list() ->
    [4,13,0].
