

# Module emqttc_event #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)


.
Copyright (c) (C) 2014, HIROE Shin

__Behaviours:__ [`gen_event`](gen_event.md).

__Authors:__ HIROE Shin ([`shin@HIROE-no-MacBook-Pro.local`](mailto:shin@HIROE-no-MacBook-Pro.local)).
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_handler-1">add_handler/1</a></td><td>Adds an event handler.</td></tr><tr><td valign="top"><a href="#add_handler-3">add_handler/3</a></td><td>Adds an event handler.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td>
Creates an event manager.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_handler-1"></a>

### add_handler/1 ###


<pre><code>
add_handler(Pid::pid()) -&gt; ok | {'EXIT', term()} | term()
</code></pre>
<br />

Adds an event handler
<a name="add_handler-3"></a>

### add_handler/3 ###


<pre><code>
add_handler(Pid, Module, Args) -&gt; ok | {'EXIT', Reason} | term()
</code></pre>

<ul class="definitions"><li><code>Pid = pid()</code></li><li><code>Module = atom()</code></li><li><code>Args = [term()]</code></li><li><code>Reason = term()</code></li></ul>

Adds an event handler
<a name="start_link-0"></a>

### start_link/0 ###


<pre><code>
start_link() -&gt; {ok, Pid} | {error, Error}
</code></pre>
<br />


Creates an event manager

