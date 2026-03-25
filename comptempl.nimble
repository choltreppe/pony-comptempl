version       = "0.1.0"
author        = "Joel Lienhard"
description   = "jinja-like templates compiled to simple pony functions"
license       = "MIT"
srcDir        = "src"
bin           = @["comptempl"]

requires "nim >= 2.2.8"
requires "fusion"