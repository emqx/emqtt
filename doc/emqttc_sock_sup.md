

# Module emqttc_sock_sup #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)


.
Copyright (c) (C) 2014, HIROE Shin

__Behaviours:__ [`supervisor`](supervisor.md).

__Authors:__ HIROE Shin ([`shin@HIROE-no-MacBook-Pro.local`](mailto:shin@HIROE-no-MacBook-Pro.local)).
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td>Starts the supervisor.</td></tr><tr><td valign="top"><a href="#start_sock-3">start_sock/3</a></td><td>Start socket child.</td></tr><tr><td valign="top"><a href="#stop_sock-2">stop_sock/2</a></td><td>Stop socket child.</td></tr><tr><td valign="top"><a href="#terminate_sock-1">terminate_sock/1</a></td><td>Terminate child.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="start_link-0"></a>

### start_link/0 ###


<pre><code>
start_link() -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<br></br>


Starts the supervisor
<a name="start_sock-3"></a>

### start_sock/3 ###


<pre><code>
start_sock(ChildNo, Sock, Client) -&gt; <a href="supervisor.md#type-start_child_ret">supervisor:start_child_ret()</a>
</code></pre>

<ul class="definitions"><li><code>ChildNo = non_neg_integer()</code></li><li><code>Sock = <a href="gen_tcp.md#type-socket">gen_tcp:socket()</a></code></li><li><code>Client = pid()</code></li></ul>

Start socket child.
<a name="stop_sock-2"></a>

### stop_sock/2 ###


<pre><code>
stop_sock(Pid::pid(), Sock::<a href="gen_tcp.md#type-socket">gen_tcp:socket()</a>) -&gt; ok
</code></pre>

<br></br>


Stop socket child.
<a name="terminate_sock-1"></a>

### terminate_sock/1 ###


<pre><code>
terminate_sock(ChildNo) -&gt; ok | {error, Error}
</code></pre>

<ul class="definitions"><li><code>ChildNo = non_neg_integer()</code></li><li><code>Error = term()</code></li></ul>

Terminate child
