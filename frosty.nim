import std/strutils
import std/streams
import std/tables

# we'll only check hashes during debug builds
when not defined(release):
  import std/hashes

const
  frostyMagic* {.intdefine.} = 0xBADCAB ##
  ## A magic file value for our "format".

  enableLists = false

type
  FreezeError* = ValueError  ## An error raised during `freeze`. (unused)
  ThawError* = ValueError    ## An error raised during `thaw`.

  Serializer = object
    stream: Stream
    ptrs: Table[int, pointer]
    when not defined(release):
      indent: int

  Chunk = object
    p: int
    when not defined(release):
      h: Hash

template refAddr(o: typed): int =
  when o is ref:
    if o == nil: 0 else: cast[int](o)
  else:
    0

proc newSerializer(stream: Stream): Serializer {.raises: [].} =
  result = Serializer(stream: stream)

proc write[T](s: var Serializer; o: ref T)
proc read[T](s: var Serializer; o: var ref T)
proc write[T](s: var Serializer; o: T)
proc read[T](s: var Serializer; o: var T)
proc write[T](s: var Serializer; o: seq[T])
proc read[T](s: var Serializer; o: var seq[T])
proc write(s: var Serializer; o: string)
proc read(s: var Serializer; o: var string)

when enableLists:
  import std/lists

  template makeListSupportDeclarations(name: untyped): untyped =
    proc write[T](s: Serializer; o: name[T])
    proc read[T](s: Serializer; o: var name[T])

  proc write[T](s: Serializer; o: SinglyLinkedList[T])
  proc read[T](s: Serializer; o: var SinglyLinkedList[T])
  proc write[T](s: Serializer; o: DoublyLinkedList[T])
  proc read[T](s: Serializer; o: var DoublyLinkedList[T])
  proc write[T](s: Serializer; o: SinglyLinkedRing[T])
  proc read[T](s: Serializer; o: var SinglyLinkedRing[T])
  proc write[T](s: Serializer; o: DoublyLinkedRing[T])
  proc read[T](s: Serializer; o: var DoublyLinkedRing[T])

  template makeListSupport(name: untyped): untyped =
    when not compiles(len(name)):
      proc len(o: name): int {.used.} =
        for item in items(o):
          inc result

    proc write[T](s: var Serializer; o: name[T]) =
      var l = len(o)           # type inference
      s.write l
      for item in items(o):
        s.write item.value
        dec l
      assert l == 0

    proc read[T](s: var Serializer; o: var name[T]) =
      o = `init name`[T]()
      var l = len(o)
      s.read l
      while l > 0:
        var value: T
        s.read value
        o.append value
        dec l

  # generate serialize/deserialize for some linked lists and rings
  makeListSupport SinglyLinkedList
  makeListSupport DoublyLinkedList
  makeListSupport SinglyLinkedRing
  makeListSupport DoublyLinkedRing

template greatenIndent*(s: var Serializer; body: untyped): untyped =
  ## Used for debugging.
  when not defined(release):
    s.indent = s.indent + 2
  body
  when not defined(release):
    s.indent = s.indent - 2

template debung*(s: Serializer; msg: string): untyped =
  ## Used for debugging.
  when defined(debug):
    when not defined(release):
      echo spaces(s.indent) & msg

template writeComplex(s: var Serializer; o: object | tuple) =
  s.greatenIndent:
    s.debung $typeof(o) & " .. " & $refAddr(o)
    for k, val in fieldPairs(o):
      block wrote:
        when val is int:
          s.debung ".$1 $2 $3" % [ $k, $typeof(val), $val ]
        elif val is string:
          s.debung ".$1 $2 $3" % [ $k, $typeof(val), $val ]
        elif val is float:
          s.debung ".$1 $2 $3" % [ $k, $typeof(val), $val ]
        elif val is pointer:
          s.debung ".$1 $2 $3" % [ $k, $typeof(val), $val ]
        else:
          s.debung ".$1 $2 $3" % [ $k, $typeof(val), $refAddr(val) ]
        s.write val

template readComplex[T: object | tuple](s: var Serializer; o: var T) =
  for k, v in fieldPairs(o):
    s.read v

template audit(o: typed; p: typed): Hash =
  when defined(release):
    0
  else:
    when compiles(hash(o)):
      hash(o)
    elif compiles(hash(o[])):
      hash(o[])
    else:
      hash(p)

proc write(s: var Serializer; o: string) =
  write(s.stream, len(o))   # put the str len
  write(s.stream, o)        # put the str data

proc read(s: var Serializer; o: var string) =
  var l = len(o)            # type inference
  read(s.stream, l)         # get the str len
  o = readStr(s.stream, l)  # get the str data
  assert o.len == l

proc write[T](s: var Serializer; o: ref T) =
  # compute p and store it
  var g = Chunk(p: refAddr(o))
  s.debung $typeof(o) & " " & $g.p
  # if it's nonzero, also compute hash
  if g.p != 0:
    when not defined(release):
      g.h = audit(o, g.p)
      assert g.h != 0

  # write the preamble
  s.write g
  if g.p != 0:
    if g.p notin s.ptrs:
      # we haven't written the value for this address yet,
      # so record that this memory was seen,
      s.ptrs[g.p] = cast[pointer](o)
      # and write it now
      s.write o[]

proc read[T](s: var Serializer; o: var ref T) =
  var
    g: Chunk
  s.read g
  if g.p == 0:
    o = nil
  else:
    if g.p in s.ptrs:
      o = cast[ref T](s.ptrs[g.p])
    else:
      o = new (ref T)
      s.ptrs[g.p] = cast[pointer](o)
      s.read o[]
    when not defined(release):
      assert g.h == audit(o, g.p)

proc write[T](s: var Serializer; o: seq[T]) =
  runnableExamples:
    # start with some data
    var q = @[1, 1, 2, 3, 5]
    # prepare a string
    var s: string
    # write the data into the string
    s.freeze q
    # check that it matches our expectation
    assert len(s) == sizeof(frostyMagic) + sizeof(0) + 5*sizeof(0)
    # prepare a new seq to hold some data
    var l: seq[int]
    # populate the seq using the string as input
    s.thaw l
    # confirm that the two sequences of data match
    assert l == q

  s.write len(o)
  for item in items(o):
    s.write item

proc read[T](s: var Serializer; o: var seq[T]) =
  var l = len(o)          # type inference
  s.read l                # get the len of the seq
  o.setLen(l)             # pre-alloc the sequence
  for item in mitems(o):  # iterate over mutable items
    s.read item           # read into the item

# simple types are, uh, simple
proc write[T](s: var Serializer; o: T) =
  when T is object:
    writeComplex(s, o)
  elif T is tuple:
    writeComplex(s, o)
  else:
    write(s.stream, o)

proc read[T](s: var Serializer; o: var T) =
  when T is object:
    readComplex(s, o)
  elif T is tuple:
    readComplex(s, o)
  else:
    read(s.stream, o)

proc freeze*[T](o: T; stream: Stream) =
  ## Write `o` into `stream`.
  ##
  ## A "magic" value will be written, first.
  var s = newSerializer(stream)
  s.write frostyMagic
  s.write o

proc freeze*[T](o: T; str: var string) =
  ## Write `o` into `str`.
  ##
  ## A "magic" value will prefix the result.
  runnableExamples:
    import uri
    # start with some data
    var q = parseUri"https://github.org/nim-lang/Nim"
    # prepare a string
    var s: string
    # write the data into the string
    freeze(q, s)
    # prepare a new url object
    var url: Uri
    # populate the url using the string as input
    thaw(s, url)
    # confirm that two objects match
    assert url == q

  var ss = newStringStream(str)
  freeze(o, ss)
  setPosition(ss, 0)
  str = readAll(ss)
  close ss

proc freeze*[T](o: T): string =
  ## Turn `o` into a string.
  ##
  ## A "magic" value will prefix the result.
  runnableExamples:
    import uri
    # start with some data
    var q = parseUri"https://github.org/nim-lang/Nim"
    # freeze `q` into `s`
    var s = freeze(q)
    # thaw `s` into `u`
    var u = thaw[Uri](s)
    # confirm that two objects match
    assert u == q
  freeze(o, result)

proc thaw*[T](stream: Stream; o: var T) =
  ## Read `o` from `stream`.
  ##
  ## First, a "magic" value will be read.  A `ThawError`
  ## will be raised if the magic value is not as expected.
  var version: int
  stream.read version
  if version != frostyMagic:
    raise newException(ThawError, "expected magic " & $frostyMagic)
  else:
    var s = newSerializer(stream)
    s.read o

proc thaw*[T](str: string; o: var T) =
  ## Read `o` from `str`.
  ##
  ## A "magic" value must prefix the input string.
  var ss = newStringStream(str)
  thaw(ss, o)
  close ss

proc thaw*[T](str: string): T =
  ## Read value of `T` from `str`.
  ##
  ## A "magic" value must prefix the input string.
  thaw[T](str, result)