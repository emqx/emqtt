

# Module emqttc_childno #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)


.
Copyright (c) (C) 2014, HIROE Shin

__Behaviours:__ [`gen_server`](gen_server.md).

__Authors:__ HIROE Shin ([`shin@HIROE-no-MacBook-Pro.local`](mailto:shin@HIROE-no-MacBook-Pro.local)).
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#get-0">get/0</a></td><td>Get next child no.</td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td>Starts the server.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="get-0"></a>

### get/0 ###


<pre><code>
get() -&gt; non_neg_integer()
</code></pre>

<br></br>


Get next child no.
<a name="start_link-1"></a>

### start_link/1 ###


<pre><code>
start_link(Ets::<a href="ets.md#type-tid">ets:tid()</a>) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>

<br></br>


Starts the server
