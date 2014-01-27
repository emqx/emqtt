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

-define(MQTT_HEADER_SIZE, 2).
-define(BODY_RECV_TIMEOUT, 1000).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
start_link(Sock, Client) ->
    spawn_link(?MODULE, loop, [[Sock, Client]]).

%% todo: check 8bit of remaining length. 
loop([Sock, Client]) ->
    case gen_tcp:recv(Sock, ?MQTT_HEADER_SIZE) of
	{ok, <<_Flags:1/binary, Length:8/integer>> = Header} ->
	    case gen_tcp:recv(Sock, Length, ?BODY_RECV_TIMEOUT) of
		{ok, Body} ->
		    Client ! {tcp, Sock, <<Header/binary, Body/binary>>},
		    loop([Sock, Client]);
		{error, Reason} ->
		    Client ! {tcp, error, Reason},
		    loop([Sock, Client])
	    end;
	{error, Reason1} ->
	    Client ! {tcp, error, Reason1},
	    loop([Sock, Client])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
