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
-module(emqttc_reconnect).

-author('feng@emqtt.io').

-export([new/0, new/1, new/2, execute/2, reset/1]).

%% 4 seconds
-define(MIN_INTERVAL, 4000).

%% 2 minutes
-define(MAX_INTERVAL, 120000).

-define(IS_MAX_RETRIES(Max), (is_integer(Max) orelse Max =:= infinity)).

-record(reconnect, {
          min_interval  = ?MIN_INTERVAL, 
          max_interval  = ?MAX_INTERVAL,
          max_retries   = infinity, 
          interval      = ?MIN_INTERVAL, 
          retries       = 0, 
          timer }).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type reconnect() :: #reconnect{}.

-export_type([reconnect/0]).

%%TODO:...
-spec new() -> reconnect().

-spec new(Interval) -> reconnect() when
      Interval  :: non_neg_integer() | {non_neg_integer(), non_neg_integer()}.

-spec new(Interval, MaxRetries) -> reconnect() when
      Interval      :: non_neg_integer(),
      MaxRetries    :: non_neg_integer().    

-spec execute(Reconn, TimeoutMsg) -> {stop, any()} | {ok, reconnect()} when
      Reconn     :: reconnect(),
      TimeoutMsg :: tuple().
    
-spec reset(reconnect()) -> reconnect().

-endif.

%%----------------------------------------------------------------------------

%%----------------------------------------------------------------------------
%% @doc create a reconnect object
%%----------------------------------------------------------------------------
new() ->
    new(?MIN_INTERVAL).

new(Interval) when is_integer(Interval) ->
    new(Interval, infinity);

new({Interval, MaxRetries}) when is_integer(Interval), ?IS_MAX_RETRIES(MaxRetries) ->
    new(Interval, MaxRetries).

new(Interval, MaxRetries) when is_integer(Interval), ?IS_MAX_RETRIES(MaxRetries) ->
    #reconnect{ min_interval = Interval, max_retries = MaxRetries }.

%%----------------------------------------------------------------------------
%% @doc execute reconnect 
%%----------------------------------------------------------------------------
execute(#reconnect{retries = Retries, max_retries = MaxRetries}, _TimoutMsg) when 
    MaxRetries =/= infinity andalso (Retries > MaxRetries) ->
    {stop, retries_exhausted};

execute(Reconn=#reconnect{min_interval = MinInterval, 
                          max_interval = MaxInterval, 
                          interval     = Interval, 
                          retries      = Retries,
                          timer        = Timer }, TimeoutMsg) ->
    % cancel timer first...
    cancel(Timer),
    % power
    Interval1 = Interval * 2,
    Interval2 =
    if 
        Interval1 > MaxInterval -> MinInterval;
        true -> Interval1
    end,
    NewTimer = erlang:send_after(Interval2, self(), TimeoutMsg),
    {ok, Reconn#reconnect{ interval = Interval2, retries = Retries+1, timer = NewTimer }}.
    
%%----------------------------------------------------------------------------
%% @doc reset reconnect
%%----------------------------------------------------------------------------
reset(Reconn = #reconnect{min_interval = MinInterval, timer = Timer}) ->
    cancel(Timer),
    Reconn#reconnect{interval = MinInterval, retries = 0, timer = undefined}.

cancel(undefined) ->ok;
cancel(Timer) when is_reference(Timer) -> erlang:cancel_timer(Timer).


