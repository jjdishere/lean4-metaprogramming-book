import Lean
open Lean Elab Command Term
/-!
# Elaboration

The elaborator is the component in charge of turning the user facing
`Syntax` into something rest of the compiler can work with. Most of the
time this means translating `Syntax` into `Expr`s but there are also
other use cases such as `#check` or `#eval`. Hence the elaborator is
quite a large piece of code, it lives
[here](https://github.com/leanprover/lean4/blob/master/src/Lean/Elab).
-/

/-!
## Command elaboration
A command is the highest level kind of `Syntax`, a Lean file is made
up of a list of commands, The most commonly used ones being declarations,
for example:
- `def`
- `inductive`
- `structure`
but there are also other ones, most notably `#check`, `#eval` and friends.

### The Monad stack
Like almost all meta things, command elaboration is based on a Monad stack,
it lives [here](https://github.com/leanprover/lean4/blob/master/src/Lean/Elab/Command.lean):
-/
namespace CommandPlayground

structure State where
  env            : Environment
  messages       : MessageLog := {}
  scopes         : List Scope := [{ header := "" }]
  nextMacroScope : Nat := firstFrontendMacroScope + 1
  maxRecDepth    : Nat
  nextInstIdx    : Nat := 1
  ngen           : NameGenerator := {}
  infoState      : InfoState := {}
  traceState     : TraceState := {}
  deriving Inhabited

structure Context where
  fileName       : String
  fileMap        : FileMap
  currRecDepth   : Nat := 0
  cmdPos         : String.Pos := 0
  macroStack     : MacroStack := []
  currMacroScope : MacroScope := firstFrontendMacroScope
  ref            : Syntax := Syntax.missing
  tacticCache?   : Option (IO.Ref Tactic.Cache)

abbrev CommandElabCoreM (ε) := ReaderT Context $ StateRefT State $ EIO ε
abbrev CommandElabM := CommandElabCoreM Exception
abbrev CommandElab  := Syntax → CommandElabM Unit

end CommandPlayground
/-!
As you can see it's a very normal monad stack for meta world, it provides us
with some `Context` to work with as well as a `State` to modify and is capable
of throwing `Exception`s. A thing that is different though, is that the type of
command elaborators, `CommandElab`, is a function from the user `Syntax` to
a `Unit` value wrapped inside the `CommandElabM` monad. This means that we are
executing command elaborators merely for the sake of their effect on their state,
so lets take a closer look at its fields:
- `env` provides us with an `Environment`, one of the most central datastructures
  in the Lean compiler, this is where all declarations and many other things are stored.
  So if a user makes a new declaration via, for example, a `def`, this is
  where its value will be stored.
- `messages` contains all the messages generated by a command, this is how
  `#eval` tells us the output of something we gave it.
- `scopes` Is the means by which Lean manages (surprise) scopes,
  here things like values bound by the `variable` command, the current
  namespace etc. are stored.
- `nextMacroScope` is relevant for macro expansion which will be discussed
  at length in another section.
- `maxRecDepth` is the maximum amount of times we may recurse into other
  elaborators during execution so we break at some point. 
- `nextInstIdx` is used to generate automatically named `instance`s
- `ngen` is used to generate new unique names
- `infoState` is used for `InfoTree` generation which in turn is related
  to the Lean LSP integration.
- `traceState` is similar to `messages` but only used for the Lean internal
  `trace` infrastructure.
As explained before there is also some read only `Context` we have access to,
its fields are not that important but lets take a quick look:
- `fileName`, quite obviously the name of the file this command is being elaborated in
- `fileMap`, contains informations about the source code of the file that is being elaborated
- `currRecDepth` the value that is capped by `maxRecDepth`
- `cmdPos` the position of the command that is being elaborted
- `macroStack`, `currMacroScope` again used for macro expansion, discussed later on
- `ref`, describes the syntactic position of the command that is being elaborated,
  most commonly used for positioning of error messages
- `tacticCache?`, quite obviously a cache for tactic evaluation

### How it works
Now that we understand the type of command elaborators let's take a closer
look to how the elaboration process actually works. The entry point for the
Lean compiler is `elabCommandTopLevel` but as its doc string says its an:
"`elabCommand` wrapper that should be used for the initial invocation, not
for recursive calls after macro expansion etc." So the function we are
actually interested in is `elabCommand`. The way it works is rather simple:
1. If we are elaborating a `Syntax` with a list of commands simply elaborate all of them
   in order.
2. Otherwise check whether any macros can be applied to the current `Syntax` via
   `expandMacroImpl?`. If we find a macro that does apply and does not throw an
   error we recursively elaborate the resulting command `Syntax` with `elabCommand`
3. If no macro can be applied we search for all `CommandElab`s that have been
   registered for the `SyntaxKind` of the `Syntax` we are elaborating, using the `commandElabAttribute`.
   All of these `CommandElab` are then tried in order until one of them does not throw an
   `unsupportedSyntaxException`, this indicates that the elaborator "feels responsible"
   for this specific `Syntax` construct. Note that it can still throw a regular
   error to indicate to the user that something is wrong. If no responsible
   elaborator is found the command elaboration is aborted with a `unexpected syntax`
   error message.
Note that this is just a rough description that doesnt go into the details about things like
`InfoTree` handling, since they are not relevant for a general understanding of what is going on.

### Making our own
Now that we know both what a `CommandElab` is and how they are used we can
start into looking to write our own. The steps for this are:
1. Declaring our Syntax
2. Declaring the elaborator
3. Registering the elaborator as responsible for the syntax via `commandElabAttribute`
Lets see how this is done
-/
syntax (name := mycommand1) "#mycommand1" : command -- declare the syntax

@[commandElab mycommand1] def mycommand1Impl : CommandElab := fun stx => do -- declare and register the elaborator
  logInfo "Hello World"

#mycommand1 -- Hello World

/-!
You might think that this is a little boiler-platey and it turns out the Lean
devs did as well so they added a macro for this!
-/
elab "#mycommand2" : command =>
  logInfo "Hello World"

#mycommand2 -- Hello World

/-!
Note that due to the fact that command elaboration supports multiple
registered elaborators for the same syntax we can in fact overload
syntax if we want to.
-/
@[commandElab mycommand1] def myNewImpl : CommandElab := fun stx => do
  logInfo "new!"

#mycommand1 -- new!

/-!
Furthermore it is also possible to only overload parts of syntax by
throwing an `unsupportedSyntaxException` in the cases we want the default
handler to deal with or just letting the `elab` command handle it
-/

/-
Note that this is not extending the original #check syntax but adding a new SyntaxKind
for this specific syntax construct, however it behaves basically the same to the user.
-/
elab "#check" "mycheck" : command => do
  logInfo "Got ya!"

@[commandElab Lean.Parser.Command.check] def mySpecialCheck : CommandElab := fun stx => do
  if let some str := stx[1].isStrLit? then
    logInfo s!"Specially elaborated string literal!: {str} : String"
  else
    throwUnsupportedSyntax

#check mycheck -- Got ya!
#check "Hello" -- Specially elaborated string literal!: Hello : String
#check Nat.add -- Nat.add : Nat → Nat → Nat

/-!
As a final mini project for this section let's build a command elaborator
that is actually useful. It will take a command and use the same mechanisms
as `elabCommand` to tell us which macros or elaborators are relevant to the
command we gave it (we will not go through the effort of actually reimplementing
`elabCommand` though).
-/
elab "#findCElab " c:command : command => do
  let macroRes ← liftMacroM <| expandMacroImpl? (←getEnv) c
  match macroRes with
  | some (name, _) => logInfo s!"Next step is a macro: {name.toString}"
  | none =>
    let kind := c.getKind
    let elabs := commandElabAttribute.getEntries (←getEnv) kind
    match elabs with
    | [] => logInfo s!"There is no elaborators for your syntax, looks like its bad :("
    | _ => logInfo s!"Your syntax may be elaborated by: {elabs.map (fun el => el.declName.toString)}"

#findCElab def lala := 12 -- Your syntax may be elaborated by: [Lean.Elab.Command.elabDeclaration]
#findCElab abbrev lolo := 12 -- Your syntax may be elaborated by: [Lean.Elab.Command.elabDeclaration]
#findCElab #check foo -- even our own syntax!: Your syntax may be elaborated by: [mySpecialCheck, Lean.Elab.Command.elabCheck]
#findCElab open Hi -- Your syntax may be elaborated by: [Lean.Elab.Command.elabOpen]
#findCElab namespace Foo -- Your syntax may be elaborated by: [Lean.Elab.Command.elabNamespace]
#findCElab #findCElab open Bar -- even itself!: Your syntax may be elaborated by: [«_aux_lean_elaboration___elabRules_command#findCElab__1»]

/-!
## Term elaboration
A term is a `Syntax` object that represents some sort of `Expr`.
Term elaborators are the ones, that do the work for most of the code we write,
most notably they elaborate all the values of things like definitions,
types (since these are also just `Expr`) etc.

### The monad stack
Like the previous command elaboration, term elaboration is also built
upon a `ReaderT Context StateT State` stack named `TermElabM` that lives
[here](https://github.com/leanprover/lean4/blob/master/src/Lean/Elab/Term.lean).
 Unlike command elaboration it is not based on the `EIO` monad though,
it is built on top of `MetaM`, meaning that we can execute arbitrary
meta programs with it. As before we can take a look at the `Context`
and `State` type. The `Context` type's fields are well documented already
so I encourage you to check those out yourself (TODO: Link to rendered docs of compiler),
note that:
- a lot of these fields are very feature specific and not too relevant for us
- require a basic understanding of how term elaboration works in order to understand
  their explanation
so don't worry if you do not understand them yet, it will make sense in a moment.
The fields of `State` however are not as well documented so let's take a look:
-/
namespace TermPlayground

structure State where
  levelNames        : List Name       := []
  syntheticMVars    : List SyntheticMVarDecl := []
  mvarErrorInfos    : MVarIdMap MVarErrorInfo := {}
  messages          : MessageLog := {}
  letRecsToLift     : List LetRecToLift := []
  infoState         : InfoState := {}

abbrev TermElabM := ReaderT Term.Context $ StateRefT State MetaM
abbrev TermElab  := Syntax → Option Expr → TermElabM Expr

end TermPlayground
/-!
Luckily we already know the purpose of `infoState` and `messages`
from command elaboration so we can just ignore them, the rest of them
are:
- `levelNames`, a list of names of universe levels that the elaboration procedure
  has created up to this point
- `letRecsToLift`: TODO, I suspect it has something to do with `let rec` bindings
- `syntheticMVars` and `mvarErrorInfos` these two are, what sets term elaboration
  significantly apart from the simpler command elaboration. They contain information
  related to so called "synthetic meta variables" which we will discuss below.

There is also another interesting difference to command elaboration, recall
that `CommandElab` was a function from `Syntax` to `CommandElabM Unit` so we
execute them merely for their effect on the `State`. As you can see this is
different with `TermElab`. It takes the `Syntax` object to elaborate,
optionally the expected type of the `Syntax` in form of an `Expr`
and returns a `TermElabM Expr`, hence we dont execute them merely for their
effect on `State` but also because they return the `Expr` that the `Syntax`
represents.

### How it works
The entry point for term elaboration is the function `elabTerm`, it takes
the `Syntax` to elaborate an `Option Expr` for the type, a few optional
arguments that are documented but not too relevant to us, and returns a
`TermElabM Expr`. The basic idea of term elaboration is also the same as
command elaboration, expand macros and recurse or run term elaborators
that have been registerted for the `Syntax` (which might recurse into `elabTerm` again)
until we are done. There is however two significant things that set it apart.
The first is quite obvious, it can run `MetaM` code which is a huge increase in possiblities,
the second requires a little more explanation.

#### Postponing and synthetic meta variables
A term elaborator may throw `Except.postpone`, this indicates it requires more
information to continue its work. In order to represent this missing information
Lean uses so called synthetic meta variables, as you know from before metavariables
are holes in `Expr`s that are waiting to be filled. The special thing about synthetic
ones is, that they have a certain way associated that is to be used to solve them,
the `SyntheticMVarKind`, right now there are four of these:
- `typeClass`, the meta variable should be solved with typeclass synthesis
- `coe`, the meta variable should be solved via coercion (a special case of typeclass)
- `tactic`, the meta variable is a tactic term taht should be solved by running the tactic
- `postponed`, the ones that are created at `Except.postpone`
Once such a synthetic meta variable is created, the next higher level term elaborator will continue.
At some point execution of the term elaborator that postponed execution will be resumed,
in hopes that it can now complete its execution. We can try to see this in
action with the following example:
-/
#check set_option trace.Elab.postpone true in List.foldr .add 0 [1,2,3] -- [Elab.postpone] .add : ?m.5695 → ?m.5696 → ?m.5696

/-!
What happened here is that the elaborator for function applications started
at `List.foldr` which is a generic function so it created meta variables
for the implicit type parameters. Then it attempted to elaborate the first argument `.add`.

In case you dont know how `.name` works, the basic idea is that quite
often (like in this case) Lean should be able to infer the output type
of a function (in this case `Nat`), the `.name` feature will then simply
search for a function named `name` in the namespace `Nat`. This is especially
useful when you want to use constructors of a type without referring to its
namespace or opening it but can also be used like above.

Now back to our example, while Lean does at this point already know that `.add`
needs to have type: `?m1 → ?m2 → ?m2` (where `?x` is notation for a meta variable)
the elaborator for `.add` does need to know the actual value of `?m2` so the
term elaborator postpones execution (by internally creating a synthetic meta variable
in place of `.add`), the elaboration of the other two arguments then yields the fact that
`?m2` has to be `Nat` so once the `.add` elaborator is continued it can work with
this information to complete elaboration.

We can also easily provoke cases where this does not work out, for example:
-/

/-
[Elab.postpone] .add : ?m.5808 → ?m.5809 → ?m.5809
invalid dotted identifier notation, expected type is not of the form (... → C ...) where C is a constant
  ?m.5808 → ?m.5809 → ?m.5809
-/
#check set_option trace.Elab.postpone true in List.foldr .add

/-!
In this case `.add` first postponed its execution, then got called again
but didn't have enough information to finish elaboration and thus failed.

### Making our own
Back in the intro chapter there was an example of a command that mentioned
some term elaboration, we do now have all the tools necessary to understand
what it does and implement it ourselves.
-/

def assertTypeBackend (termStx : Syntax) (typeStx : Syntax): TermElabM Unit := do
  try
    -- `elabType` is `elabTerm` wrapper, ensuring the result has type `Sort u`
    let type ← elabType typeStx 
    -- `elabTermEnsuringType` is `elabTerm` wrapper, ensuring the result has the desired type
    let term ← elabTermEnsuringType termStx type
    /-
      We also add `synthesizeSyntheticMVarsNoPostponing`, which forces Lean to
      elaborate metavariables right away. Without this line, `#assertType 5  : ?_`
      would result in `success`.
    -/
    synthesizeSyntheticMVarsNoPostponing
    -- If we didn't error yet everything is fine
    logInfo "success"
  catch | _ => throwError "failure"

elab "#assertType" termStx:term " : " typeStx:term : command =>
  liftTermElabM `assertTypeCmd (assertTypeBackend termStx typeStx)

#assertType 5  : Nat -- success
#assertType [] : Nat -- failure
#assertType List.foldr .add 0 [1,2,3] : Nat -- success

/-!
The only new thing here, is the wrapper and helper functions, we will
not attempt to make an exhaustive list of them here since they are evolving
but you can browse the documentation to see what's there (TODO: Link).
-/
