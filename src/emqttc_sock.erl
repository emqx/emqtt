%%%-------------------------------------------------------------------
%%% @author HIROE Shin <shin@HIROE-no-MacBook-Pro.local>
%%% @copyright (C) 2014, HIROE Shin
%%% @doc
%%%
%%% @end
%%% Created : 27 Jan 2014 by HIROE Shin <shin@HIROE-no-MacBook-Pro.local>
%%%-------------------------------------------------------------------
-module(emqttc_sock).

%% API
-export([start_link/2, loop/1]).
-export([init/1]).

-define(MQTT_HEADER_SIZE, 1).
-define(BODY_RECV_TIMEOUT, 1000).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc start socket server.
%% @end
%%--------------------------------------------------------------------
start_link(Sock, Client) ->
    proc_lib:start_link(?MODULE, init, [[self(), Sock, Client]]).

init([Parent, Sock, Client]) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    loop([Sock, Client]).

loop([Sock, Client]) ->
    case gen_tcp:recv(Sock, ?MQTT_HEADER_SIZE) of
	{ok, Header} ->
	    case remaining_length(Sock) of
		0 ->
		    Client ! {tcp, Sock, Header},
		    loop([Sock, Client]);
		Length ->
		    case gen_tcp:recv(Sock, Length, ?BODY_RECV_TIMEOUT) of
			{ok, Body} ->
			    Client ! {tcp, Sock, <<Header/binary,Body/binary>>},
			    loop([Sock, Client]);
			{error, Reason} ->
			    Client ! {tcp, error, Reason},
			    erlang:error({socket_error, Reason})
		    end
		end;
	{error, Reason1} ->
	    Client ! {tcp, error, Reason1},
	    erlang:error({socket_error, Reason1})
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Get payload part length.
%%
%% top of bit is continue flag.
%% 0 -> last byte.
%% 1 -> next byte is exist.
%% @end
%%--------------------------------------------------------------------
-spec remaining_length(gen_tcp:socket()) -> non_neg_integer(). 
remaining_length(Sock) ->
    remaining_length(Sock, 1, 0).

remaining_length(Sock, Multiplier, TotalLen) ->
    case gen_tcp:recv(Sock, 1, 100) of
	{ok, <<1:1, Len:7/unsigned-integer>>} ->
	    NewTotalLen = TotalLen + Len * Multiplier,
	    remaining_length(Sock, Multiplier * 128, NewTotalLen);
	{ok, <<0:1/integer, Len:7/unsigned-integer>>} ->
	    TotalLen + Len * Multiplier
    end.
