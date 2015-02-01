%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttc socket and receiver.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttc_socket).

-author("feng@emqtt.io").

-include("emqttc_packet.hrl").

%% API
-export([connect/3, send/2, close/1, stop/1]).

-export([sockname/1, sockname_s/1, setopts/2]).

%% Internal export
-export([receiver/2]).

-define(TIMEOUT, 3000).

-define(TCPOPTIONS, [
    binary,
    {packet,    raw},
    {reuseaddr, true},
    {nodelay,   true},
    {active, 	true},
    {reuseaddr, true},
    {send_timeout,  ?TIMEOUT}]).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Connect to broker with TCP transport.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec connect(ClientPid, Host, Port) -> {ok, Socket, Receiver} | {error, term()} when
    ClientPid   :: pid(),
    Host        :: inet:ip_address() | string(),
    Port        :: inet:port_number(),
    Socket      :: inet:socket(),
    Receiver    :: pid().
connect(ClientPid, Host, Port) ->
    case gen_tcp:connect(Host, Port, ?TCPOPTIONS, ?TIMEOUT) of
        {ok, Socket} -> 
            ReceiverPid = spawn_link(?MODULE, receiver, [ClientPid, Socket]),
            gen_tcp:controlling_process(Socket, ReceiverPid),
            {ok, Socket, ReceiverPid} ;
        {error, Reason} -> 
            {error, Reason}
    end.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send Packet and Data.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec send(Socket :: inet:socket(), mqtt_packet() | binary()) -> ok.
send(Socket, Packet) when is_record(Packet, mqtt_packet) ->
    send(Socket, emqttc_serialiser:serialise(Packet));
send(Socket, Data) when is_binary(Data) ->
    erlang:port_command(Socket, Data).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Close Socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec close(Socket :: inet:socket()) -> ok.
close(Socket) ->
    gen_tcp:close(Socket).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Stop Receiver.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec stop(Receiver :: pid()) -> ok.
stop(Receiver) ->
    Receiver ! stop.

setopts(Socket, Opts) ->
    inet:setopts(Socket, Opts).

sockname(Sock) when is_port(Sock) ->
    inet:sockname(Sock).

sockname_s(Sock) ->
    case sockname(Sock) of
        {ok, {Addr, Port}} ->
            {ok, lists:flatten(io_lib:format("~s:~p", [maybe_ntoab(Addr), Port]))};
        Error ->
            Error
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
receiver(ClientPid, Socket) ->
    receiver_loop(ClientPid, Socket, emqttc_parser:new()).

receiver_loop(ClientPid, Socket, ParseState) ->
    receive
        {tcp, Socket, Data} ->
            {ok, ParseState1} = parse_received_bytes(ClientPid, Data, ParseState),
            receiver_loop(ClientPid, Socket, ParseState1);
        {tcp_closed, Socket} ->
            gen_fsm:send_all_state_event(ClientPid, tcp_closed);
        stop -> 
            gen_tcp:close(Socket), ok
    end.

parse_received_bytes(_ClientPid, <<>>, ParseState) ->
    {ok, ParseState};

parse_received_bytes(ClientPid, Data, ParseState) ->
    case emqttc_parser:parse(Data, ParseState) of
    {more, ParseState1} ->
        {ok, ParseState1};
    {ok, Packet, Rest} -> 
        gen_fsm:send_event(ClientPid, Packet),
        parse_received_bytes(ClientPid, Rest, ParseState)
    end.

maybe_ntoab(Addr) when is_tuple(Addr) -> ntoab(Addr);
maybe_ntoab(Host)                     -> Host.

ntoa({0,0,0,0,0,16#ffff,AB,CD}) ->
    inet_parse:ntoa({AB bsr 8, AB rem 256, CD bsr 8, CD rem 256});
ntoa(IP) ->
    inet_parse:ntoa(IP).

ntoab(IP) ->
    Str = ntoa(IP),
    case string:str(Str, ":") of
        0 -> Str;
        _ -> "[" ++ Str ++ "]"
    end.
