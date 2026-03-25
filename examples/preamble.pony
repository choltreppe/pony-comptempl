actor Main
  new create(env: Env) =>
    env.out.print(Examples.list(["ba1"; "ba2"], "foo"))
    env.out.print(Examples.complex("some text"))
    env.out.print(Examples.complex(42))
    env.out.print(Examples.complex([1; 1; 2; 3; 5; 8]))
    env.out.print(Examples.if_example(-3))
    env.out.print(Examples.login_form())