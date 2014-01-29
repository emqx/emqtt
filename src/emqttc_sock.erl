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
%%--------------------------z------------------------------------------
start_link(Sock, Client) ->
    proc_lib:start_link(?MODULE, init, [[self(), Sock, Client]]).

init([Parent, Sock, Client]) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    loop([Sock, Client]).

%% todo: check 8bit of remaining length. 
loop([Sock, Client]) ->
    case gen_tcp:recv(Sock, ?MQTT_HEADER_SIZE) of
	{ok, <<_Flags:1/binary>> = Header} ->
	    {Length, LenBin} = remaining_length(Sock, 1, 0, []),
	    case gen_tcp:recv(Sock, Length, ?BODY_RECV_TIMEOUT) of
		{ok, Body} ->
		    Bin = <<Header/binary, LenBin/binary, Body/binary>>,
		    Client ! {tcp, Sock, Bin},
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

remaining_length(Sock, Multiplier, TotalLen, LenBins) ->
    case gen_tcp:recv(Sock, 1, 100) of
	{ok, <<1:1, Len:7/unsigned-integer>> = Bin} ->
	    NewTotalLen = TotalLen + Len * Multiplier,
	    remaining_length(Sock, Multiplier * 128, NewTotalLen, 
			     [Bin | LenBins]);
	{ok, <<0:1/integer, Len:7/unsigned-integer>> = Bin} ->
	    NewTotalLen = TotalLen + Len * Multiplier,
	    LenBin = list_to_binary(lists:reverse([Bin | LenBins])),
	    {NewTotalLen, LenBin}
    end.
