%%------------------------------------------------------------------------------
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
-module(emqttc_keepalive).

-author('feng@emqtt.io').

-export([new/3, resume/1, cancel/1]).

%%TODO: refactor socket keepalive...
-record(keepalive, {socket, send_oct, timeout_sec, timeout_msg, timer_ref}).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type keepalive() -> #keepalive{}.

-spec new(Socket, TimeoutSec, TimeoutMsg) -> KeepAlive when
      Socket        :: inet:socket(),
      TimeoutSec    :: non_neg_integer(),
      TimeoutMsg    :: tuple(),
      KeepAlive     :: keepalive().

-spec resume(KeepAlive) -> timeout | {resumed, KeepAlive} when 
      KeepAlive  :: keepalive().

-spec cancel(keepalive() | undefined | reference()) -> any().

-endif.

%%----------------------------------------------------------------------------

%%----------------------------------------------------------------------------
%% @doc create a keepalive.
%%----------------------------------------------------------------------------
new(Socket, TimeoutSec, TimeoutMsg) when TimeoutSec > 0 ->
    {ok, [{send_oct, SendOct}]} = inet:getstat(Socket, [send_oct]),
	Ref = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
	#keepalive { socket      = Socket, 
                 send_oct    = SendOct, 
                 timeout_sec = TimeoutSec, 
                 timeout_msg = TimeoutMsg,
                 timer_ref   = Ref }.

%%----------------------------------------------------------------------------
%% @doc try to resume keepalive, called when timeout.
%%----------------------------------------------------------------------------
resume(KeepAlive = #keepalive { socket      = Socket, 
                                send_oct    = SendOct, 
                                timeout_sec = TimeoutSec, 
                                timeout_msg = TimeoutMsg, 
                                timer_ref   = Ref }) ->
    {ok, [{send_oct, NewSendOct}]} = inet:getstat(Socket, [send_oct]),
    if
        NewSendOct =:= SendOct -> 
            timeout;
        true ->
            %need?
            cancel(Ref),
            NewRef = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
            {resumed, KeepAlive#keepalive { send_oct = NewSendOct, timer_ref = NewRef }}
    end.

%%----------------------------------------------------------------------------
%% @doc cancel keepalive
%%----------------------------------------------------------------------------
cancel(#keepalive { timer_ref = Ref }) ->
    cancel(Ref);
cancel(undefined) -> 
	undefined;
cancel(Ref) -> 
	catch erlang:cancel_timer(Ref).


