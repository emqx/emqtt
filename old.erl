
%pubrel/2, 
%puback/2, 
%pubrec/2, 
%pubcomp/2, 


%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that disconnecting from MQTT broker.
%% @end
%%--------------------------------------------------------------------
disconnected(timeout, State) ->
    timer:sleep(5000),
    {next_state, connecting, State, 0};

disconnected({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    case send_connect(NewState) of
	ok ->
	    {next_state, waiting_for_connack, NewState};
	{error, _Reason} ->
	    {next_state, disconnected, State}
    end;

disconnected({subscribe, NewTopics}, State=#state{topics = Topics} ) ->
    {next_state, disconnected, State#state{topics = Topics ++ NewTopics}};    

disconnected({add_event_handler, Handler, Args}, 
	     State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

disconnected(_, State) ->
    {next_state, disconnected, State}.

connecting({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    case send_connect(NewState) of
	ok ->
	    {next_state, waiting_for_connack, NewState};
	{error, _Reason} ->
	    {next_state, disconnected, State}
    end;

connecting({subscribe, NewTopics}, State=#state{topics = Topics}) ->
    {next_state, connecting, State#state{topics = Topics ++ NewTopics}};    

connecting({add_event_handler, Handler, Args}, 
	   State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

waiting_for_connack({set_socket, Sock}, State) ->
    {next_state, waiting_for_connack, State#state{sock = Sock}};

waiting_for_connack({add_event_handler, Handler, Args},
		    State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

connected({set_socket, Sock}, State) ->
    {next_state, connected, State#state{sock = Sock}};


%%--------------------------------------------------------------------
%% @private
%% @doc Sync message handler for state that disconnecting from MQTT broker.
%% @end
%%--------------------------------------------------------------------
disconnected(_, _From, State) ->
    {next_state, disconnected, State}.


%%--------------------------------------------------------------------
%% @doc pubrec.
%% @end
%%--------------------------------------------------------------------
-spec pubrel(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubrel(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:sync_send_event(C, {pubrel, MsgId}).

%%--------------------------------------------------------------------
%% @doc puback.
%% @end
%%--------------------------------------------------------------------
-spec puback(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().      
puback(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {puback, MsgId}).

%%--------------------------------------------------------------------
%% @doc pubrec.
%% @end
%%--------------------------------------------------------------------
-spec pubrec(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubrec(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {pubrec, MsgId}).

%%--------------------------------------------------------------------
%% @doc pubcomp.
%% @end
%%--------------------------------------------------------------------
-spec pubcomp(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubcomp(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {pubcomp, MsgId}).

%%TODO: remove later...
set_socket(Client, Sock) ->
    gen_fsm:send_event(Client, {set_socket, Sock}).

%%--------------------------------------------------------------------
%% @doc Add subscribe event handler.
%% @end
%%--------------------------------------------------------------------
-spec add_event_handler(C, Handler) -> ok when
      C :: pid | atom(),
      Handler :: atom().
add_event_handler(C, Handler) ->
    add_event_handler(C, Handler, []).

-spec add_event_handler(C, Handler, Args) -> ok when
      C :: pid | atom(),
      Handler :: atom(),
      Args :: [term()].
add_event_handler(C, Handler, Args) ->
    gen_fsm:send_event(C, {add_event_handler, Handler, Args}).

connected({puback, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBACK, MsgId),
    {next_state, connected, State};

connected({pubrec, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBREC, MsgId),
    {next_state, connected, State};

connected({pubcomp, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBCOMP, MsgId),
    {next_state, connected, State};


connected({add_event_handler, Handler, Args},
	  State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    
