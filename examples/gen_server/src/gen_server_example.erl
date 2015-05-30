-module(gen_server_example).

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, stop/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {mqttc, seq}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:call(?SERVER, stop).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, C} = emqttc:start_link([{host, "localhost"}, 
                                 {client_id, <<"simpleClient">>},
                                 {reconnect, 3},
                                 {logger, {console, info}}]),
    %% The pending subscribe
    emqttc:subscribe(C, <<"TopicA">>, 1),
    {ok, #state{mqttc = C, seq = 1}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Publish Messages
handle_info(publish, State = #state{mqttc = C, seq = I}) ->
    Payload = list_to_binary(["hello...", integer_to_list(I)]),
    emqttc:publish(C, <<"TopicA">>, Payload, [{qos, 1}]),
    emqttc:publish(C, <<"TopicB">>, Payload, [{qos, 2}]),
    erlang:send_after(3000, self(), publish),
    {noreply, State#state{seq = I+1}};

%% Receive Messages
handle_info({publish, Topic, Payload}, State) ->
    io:format("Message from ~s: ~p~n", [Topic, Payload]),
    {noreply, State};

%% Client connected
handle_info({mqttc, C, connected}, State = #state{mqttc = C}) ->
    io:format("Client ~p is connected~n", [C]),
    emqttc:subscribe(C, <<"TopicA">>, 1),
    emqttc:subscribe(C, <<"TopicB">>, 2),
    self() ! publish,
    {noreply, State};

%% Client disconnected
handle_info({mqttc, C,  disconnected}, State = #state{mqttc = C}) ->
    io:format("Client ~p is disconnected~n", [C]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

