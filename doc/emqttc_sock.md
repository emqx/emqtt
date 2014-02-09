

# Module emqttc_sock #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)


.
Copyright (c) (C) 2014, HIROE Shin

__Authors:__ HIROE Shin ([`shin@HIROE-no-MacBook-Pro.local`](mailto:shin@HIROE-no-MacBook-Pro.local)).
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#start_link-3">start_link/3</a></td><td>start socket server.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="start_link-3"></a>

### start_link/3 ###


<pre><code>
start_link(Host, Port, Client) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<ul class="definitions"><li><code>Host = binary() | <a href="inet.md#type-ip_address">inet:ip_address()</a></code></li><li><code>Port = <a href="inet.md#type-port_number">inet:port_number()</a></code></li><li><code>Client = atom()</code></li></ul>

start socket server.
