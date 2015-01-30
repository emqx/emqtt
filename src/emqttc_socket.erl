%%-----------------------------------------------------------------------------
%% Copyright (c) 2012-2015, Feng Lee <feng@emqtt.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------

%%TODO: should use esockd....

-module(emqttc_socket).

-export([connect/2, send/2, close/1]).

-export([sockname/1, sockname_s/1, setopts/2]).

-define(TIMEOUT, 3000).
-define(RECONNECT_INTERVAL, 3000).
-define(SOCKET_SEND_INTERVAL, 3000).

-define(TCPOPTIONS, [ binary, 
                     {packet,    raw}, 
                     {reuseaddr, true}, 
                     {nodelay,   true}, 
                     {active, 	 once}, 
                     {reuseaddr, true}, 
                     {send_timeout,  3000} ]).

connect(Host, Port) ->
    case gen_tcp:connect(Host, Port, ?TCPOPTIONS, ?TIMEOUT) of
	{ok, Sock} -> {ok, Sock};
	{error, Reason} -> {error, Reason}
    end.

send(Socket, Data) ->
    erlang:port_command(Socket, Data).

close(Socket) ->
    gen_tcp:close(Socket).

setopts(Socket, Opts) ->
    inet:setopts(Socket, Opts).

sockname(Sock) when is_port(Sock) -> inet:sockname(Sock).

sockname_s(Sock) ->
    case sockname(Sock) of
        {ok, {Addr, Port}} ->
            {ok, lists:flatten(io_lib:format("~s:~p", [maybe_ntoab(Addr), Port]))};
        Error -> 
            Error
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


