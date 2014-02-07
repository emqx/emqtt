

# Module emqttc #
* [Function Index](#index)
* [Function Details](#functions)


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#code_change-4">code_change/4</a></td><td></td></tr><tr><td valign="top"><a href="#connected-2">connected/2</a></td><td></td></tr><tr><td valign="top"><a href="#connected-3">connected/3</a></td><td></td></tr><tr><td valign="top"><a href="#connecting-2">connecting/2</a></td><td></td></tr><tr><td valign="top"><a href="#connecting-3">connecting/3</a></td><td></td></tr><tr><td valign="top"><a href="#disconnect-1">disconnect/1</a></td><td>Disconnect from broker.</td></tr><tr><td valign="top"><a href="#disconnected-2">disconnected/2</a></td><td></td></tr><tr><td valign="top"><a href="#disconnected-3">disconnected/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_event-3">handle_event/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-3">handle_info/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_sync_event-4">handle_sync_event/4</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#ping-1">ping/1</a></td><td>Send ping to broker.</td></tr><tr><td valign="top"><a href="#puback-2">puback/2</a></td><td>puback.</td></tr><tr><td valign="top"><a href="#pubcomp-2">pubcomp/2</a></td><td>pubcomp.</td></tr><tr><td valign="top"><a href="#publish-2">publish/2</a></td><td></td></tr><tr><td valign="top"><a href="#publish-3">publish/3</a></td><td>publish to broker.</td></tr><tr><td valign="top"><a href="#publish-4">publish/4</a></td><td></td></tr><tr><td valign="top"><a href="#pubrec-2">pubrec/2</a></td><td>pubrec.</td></tr><tr><td valign="top"><a href="#pubrel-2">pubrel/2</a></td><td>pubrec.</td></tr><tr><td valign="top"><a href="#set_socket-2">set_socket/2</a></td><td></td></tr><tr><td valign="top"><a href="#start-0">start/0</a></td><td>start application.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td>Starts the server.</td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td>Starts the server with options.</td></tr><tr><td valign="top"><a href="#start_link-2">start_link/2</a></td><td>Starts the server with name and options.</td></tr><tr><td valign="top"><a href="#subscribe-2">subscribe/2</a></td><td>subscribe request to broker.</td></tr><tr><td valign="top"><a href="#terminate-3">terminate/3</a></td><td></td></tr><tr><td valign="top"><a href="#unsubscribe-2">unsubscribe/2</a></td><td>unsubscribe request to broker.</td></tr><tr><td valign="top"><a href="#waiting_for_connack-2">waiting_for_connack/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="code_change-4"></a>

### code_change/4 ###

`code_change(OldVsn, StateName, State, Extra) -> any()`


<a name="connected-2"></a>

### connected/2 ###

`connected(Event, State) -> any()`


<a name="connected-3"></a>

### connected/3 ###

`connected(Event, From, State) -> any()`


<a name="connecting-2"></a>

### connecting/2 ###

`connecting(Event, State) -> any()`


<a name="connecting-3"></a>

### connecting/3 ###

`connecting(Event, From, State) -> any()`


<a name="disconnect-1"></a>

### disconnect/1 ###


<pre><code>
disconnect(C) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li></ul>

Disconnect from broker.
<a name="disconnected-2"></a>

### disconnected/2 ###

`disconnected(X1, State) -> any()`


<a name="disconnected-3"></a>

### disconnected/3 ###

`disconnected(X1, From, State) -> any()`


<a name="handle_event-3"></a>

### handle_event/3 ###

`handle_event(Event, StateName, State) -> any()`


<a name="handle_info-3"></a>

### handle_info/3 ###

`handle_info(Info, StateName, State) -> any()`


<a name="handle_sync_event-4"></a>

### handle_sync_event/4 ###

`handle_sync_event(X1, From, StateName, State) -> any()`


<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`


<a name="ping-1"></a>

### ping/1 ###


<pre><code>
ping(C) -&gt; pong
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li></ul>

Send ping to broker.
<a name="puback-2"></a>

### puback/2 ###


<pre><code>
puback(C, MsgId) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>

puback.
<a name="pubcomp-2"></a>

### pubcomp/2 ###


<pre><code>
pubcomp(C, MsgId) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>

pubcomp.
<a name="publish-2"></a>

### publish/2 ###


<pre><code>
publish(C, Mqtt_msg::#mqtt_msg{}) -&gt; ok | pubrec
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li></ul>


<a name="publish-3"></a>

### publish/3 ###


<pre><code>
publish(C, Topic, Payload) -&gt; ok | {ok, MsgId}
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>Topic = binary()</code></li><li><code>Payload = binary()</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>

publish to broker.
<a name="publish-4"></a>

### publish/4 ###


<pre><code>
publish(C, Topic, Payload, Opts) -&gt; ok | {ok, MsgId}
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>Topic = binary()</code></li><li><code>Payload = binary()</code></li><li><code>Opts = [tuple()]</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>


<a name="pubrec-2"></a>

### pubrec/2 ###


<pre><code>
pubrec(C, MsgId) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>

pubrec.
<a name="pubrel-2"></a>

### pubrel/2 ###


<pre><code>
pubrel(C, MsgId) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>MsgId = non_neg_integer()</code></li></ul>

pubrec.
<a name="set_socket-2"></a>

### set_socket/2 ###

`set_socket(C, Sock) -> any()`


<a name="start-0"></a>

### start/0 ###


<pre><code>
start() -&gt; ok
</code></pre>

<br></br>


start application
<a name="start_link-0"></a>

### start_link/0 ###


<pre><code>
start_link() -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<br></br>


Starts the server
<a name="start_link-1"></a>

### start_link/1 ###


<pre><code>
start_link(Opts::[tuple()]) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<br></br>


Starts the server with options.
<a name="start_link-2"></a>

### start_link/2 ###


<pre><code>
start_link(Name::atom(), Opts::[tuple()]) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<br></br>


Starts the server with name and options.
<a name="subscribe-2"></a>

### subscribe/2 ###


<pre><code>
subscribe(C, Topics) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>Topics = [{binary(), non_neg_integer()}]</code></li></ul>

subscribe request to broker.
<a name="terminate-3"></a>

### terminate/3 ###

`terminate(Reason, StateName, State) -> any()`


<a name="unsubscribe-2"></a>

### unsubscribe/2 ###


<pre><code>
unsubscribe(C, Topics) -&gt; ok
</code></pre>

<ul class="definitions"><li><code>C = pid() | atom()</code></li><li><code>Topics = [{binary(), non_neg_integer()}]</code></li></ul>

unsubscribe request to broker.
<a name="waiting_for_connack-2"></a>

### waiting_for_connack/2 ###

`waiting_for_connack(Event, State) -> any()`


