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
-export([start_link/3, loop/3]).
-export([init/1]).

-define(MQTT_HEADER_SIZE, 1).
-define(BODY_RECV_TIMEOUT, 1000).
-define(TIMEOUT, 3000).
-define(RECONNECT_INTERVAL, 3000).
-define(SOCKET_SEND_INTERVAL, 3000).
-define(TCPOPTIONS, [binary,
		     {packet,    raw},
		     {reuseaddr, true},
		     {nodelay,   true},
		     {active, 	false},
		     {reuseaddr, true},
		     {send_timeout,  3000}]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc start socket server.
%% @end
%%--------------------------------------------------------------------
-spec start_link(Host, Port, Client) -> {ok, pid()} |
					ignore |
					{error, term()} when
      Host :: binary() | inet:ip_address(),
      Port :: inet:port_number(),
      Client :: atom().
start_link(Host, Port, Client) ->
    proc_lib:start_link(?MODULE, init, [[self(), Host, Port, Client]]).

%%--------------------------------------------------------------------
%% @private
%% @doc Process init.
%% @end
%%--------------------------------------------------------------------
init([Parent, Host, Port, Client]) ->
    {ok, Sock, TRef} = connect(Host, Port, Client),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Sock, Client, TRef).

%%--------------------------------------------------------------------
%% @private
%% @doc Connect to MQTT broker.
%% @end
%%--------------------------------------------------------------------
-spec connect(Host, Port, Client) -> {ok, Sock} | {error, Reason} when
      Host :: inet:ip_address() | list(),
      Port :: inet:port_number(),
      Client :: atom(),
      Sock :: gen_tcp:socket(),
      Reason :: atom().
connect(Host, Port, Client) ->
    case gen_tcp:connect(Host, Port, ?TCPOPTIONS, ?TIMEOUT) of
	{ok, Sock} ->
	    {ok, TRef} = timer:apply_interval(?SOCKET_SEND_INTERVAL, 
					      emqttc, set_socket,
					      [Client, Sock]),
	    {ok, Sock, TRef};
	{error, Reason} ->
	    io:format("---tcp connection failure: ~p~n", 
		      [Reason]),
	    timer:sleep(?RECONNECT_INTERVAL),
	    {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Socket read loop.
%% @end
%%--------------------------------------------------------------------
-spec loop(Sock, Client, TRef) -> ok when
      Sock :: gen_tcp:socket(),
      Client :: atom(),
      TRef :: timer:tref().
loop(Sock, Client, TRef) ->
    case gen_tcp:recv(Sock, ?MQTT_HEADER_SIZE) of
	{ok, Header} ->
	    case forward_msg(Header, Sock, Client) of
		ok ->
		    loop(Sock, Client, TRef);
		{error, Reason} ->
		    terminate(Reason, Client, TRef)
	    end;		    
	{error, Reason1} ->
	    terminate(Reason1, Client, TRef)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Read and forward data to emqttc.
%% @end
%%--------------------------------------------------------------------
-spec forward_msg(Header, Sock, Client) -> ok | {error, Reason} when
      Header :: binary(),
      Sock :: gen_tcp:socket(),
      Client :: atom(),
      Reason :: term().
forward_msg(Header, Sock, Client) ->
    case remaining_length(Sock) of
	0 ->
	    maybe_send_message(Client, {tcp, Sock, Header});
	Length ->
	    case gen_tcp:recv(Sock, Length, ?BODY_RECV_TIMEOUT) of
		{ok, Body} ->
		    Data = {tcp, Sock, <<Header/binary,Body/binary>>},
		    maybe_send_message(Client, Data),
		    ok;
		{error, Reason} ->
		    {error, Reason}
	    end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Send message to emqttc process if process is alive.
%% @end
%%--------------------------------------------------------------------
-spec maybe_send_message(Client, Data) -> ok | ignore when
      Client :: atom() | pid(),
      Data :: term().
maybe_send_message(Client, Data) when is_atom(Client) ->
    case whereis(Client) of
	undefined ->
	    ignore;
	Pid when is_pid(Pid) -> 
	    maybe_send_message(Pid, Data)
    end;

maybe_send_message(Pid, Data) when is_pid(Pid) ->
    Pid ! Data.


%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec terminate(Reason, Client, TRef) -> ok when
      Reason :: term(),
      Client :: atom(),
      TRef :: timer:tref().
terminate(Reason, Client, TRef) ->
    timer:cancel(TRef),
    maybe_send_message(Client, {tcp, error, Reason}),
    timer:sleep(?RECONNECT_INTERVAL),
    ok.

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
