# CompTempl
precompiled html templates for the pony programming language

## Usage

Simply put all your templates in one folder (lets say `src/templates`).
Then you run `comptempl src/templates`
and `src/templates.pony` will be generated,
with all your templates compiled to simple functions bundled in `primitive Templates`
(the primitive name is a PascalCase version of the folders name)

## Syntax

All templates (except partials, explained later) need to start with a function head definition
```
{% fun example_template(a: String, b: Int) %}
```
You don't need to give a return type, its always `String`

### Interpolation

inject values with `{{ }}`
```
<h1>{{title}}</h1>
```
You can use any valid pony code here

### Control Flow

You can use `for`, `if` and `match` expressions
```
{% match some_value %}
{| let arr: Array[U8] |}
  <ul>
    {% for x in arr.values() %}
      <li> {{ x.string() }} </li>
    {% end %}
  </ul>
{| let i: ISize |}
  the number is
  {% if i < 0 %}
    negative
  {% elseif i == 0 %}
    zero
  {% elseif i % 2 == 0 %}
    positive and even
  {% else %}
    {{ i.string() }}
  {% end %}
{% end %}
```

### Inheritance

You can extend templates, and use named blocks to replace parts in the parent template.
Note that blocks get replaced not filled, so you can give default contents

**templates/base.html** (should probably be partial. explained in next section)
```
{% fun base() %}
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{% block title %} default title {% end %}</title>
</head>
<body>
  {% block content %} {%end%}
</body>
</html>
```

**templates/home.html**
```
{% fun home(username: String) %}
{% extends base.html %}

{% block title %} Home {% end %}

{% block content %}
  <h1>Home</h1>
  Hi {{ username }}
{%end%}
```

### Partials

So most of the time, if you extend a template you dont want to use the base template on its own.
For that case you can define it als a partial, by starting the filename with `_` and omitting the `fun` declaration

**templates/_base.html**
```
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{% block title %} default title {% end %}</title>
</head>
<body>
  {% block content %} {%end%}
</body>
</html>
```

### Includes (composition)

You can include other templates anywhere inside a templates.

```
<div id="articles">
  {% for (title, content) in articles.values() %}
    {% include _card.html %}
  {% end %}
</div>
```

**templates/_card.html**
```
<div class="card">
  <div class="title">{{ title }}</div>
  <div class="content">{{ content }}</div>
</div>
```
