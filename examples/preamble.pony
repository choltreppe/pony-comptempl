actor Main
  new create(env: Env) =>
    env.out.print(Examples.list("foo", ["ba1"; "ba2"]))