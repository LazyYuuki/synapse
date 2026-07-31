# Mix Project Foundation

## Purpose

This guide explains the initial Mix and OTP structure of Synapse, why each generated file exists, and where Provider implementation will begin.

It complements Elixir's [Introduction to Mix](https://hexdocs.pm/elixir/introduction-to-mix.html) with decisions specific to Synapse.

## Tested Runtime

The initial project was created and verified with:

```text
Elixir 1.20.2
Erlang/OTP 28.5.0.3
Mix 1.20.2
```

`mix.exs` targets Elixir 1.20 within the 1.x series. The active Nix profile uses the `beam28Packages.elixir_1_20` package, which currently provides Elixir 1.20.2 and Erlang/OTP 28.5.0.3.

The official Mix and OTP guide supports older versions, but Synapse deliberately starts on the latest available Elixir and OTP toolchain so the implementation can learn and use current language, standard-library, compiler, and documentation capabilities.

## Project Files

```text
mix.exs
.formatter.exs
.gitignore
lib/
  synapse.ex
  synapse/
    application.ex
test/
  test_helper.exs
  synapse_application_test.exs
```

### `mix.exs`

`Synapse.MixProject` describes the project to Mix. It declares the application name and version, supported Elixir version, OTP application callback module, dependencies, and ExDoc configuration.

`mix.exs` is evaluated by the build tool. Application code under `lib/` must not use `Mix.env/0` because Mix is not expected to be present in a production release.

### `.formatter.exs`

The formatter configuration tells `mix format` which Elixir source and script files belong to the project. Formatting is mechanical verification, not a stylistic decision made independently in each module.

### `lib/synapse.ex`

`Synapse` is the public namespace and ExDoc entry point for application modules. It deliberately has no placeholder `hello/0` function because Synapse does not yet have a meaningful product API.

### `lib/synapse/application.ex`

`Synapse.Application` implements the `Application` behaviour. The OTP application controller calls `start/2`, which starts the named `Synapse.Supervisor` root supervisor.

The root supervisor currently has no children. An empty supervisor is intentional: a module should become a supervised process only when it owns lifecycle, mutable state, cancellation, or fault isolation. Provider request encoding and SSE parsing will be pure modules, not GenServers.

### `test/test_helper.exs`

Mix loads this script before the test suite. It starts ExUnit, which discovers test modules under `test/`.

### `test/synapse_application_test.exs`

The bootstrap test verifies that Mix starts the OTP application, the named root supervisor exists, and no accidental children have been introduced.

## Startup Sequence

```text
mix or release starts :synapse
  -> OTP application controller calls Synapse.Application.start/2
  -> Synapse.Application starts Synapse.Supervisor
  -> supervisor starts declared component children
```

The Provider currently runs through focused tests and direct function calls. Its Tokamak transport owns a monitored temporary request worker; Runtime will later add supervised operation processes above that established ownership boundary.

## Dependencies

### Req

Req is the HTTP client boundary selected for Tokamak requests. It brings Finch as its transport stack. Provider code owns request encoding, stream processing, cancellation, and error normalization rather than leaking Req responses into the Agent Loop.

### ExDoc

ExDoc generates the local documentation site. The README, architecture documents, implementation plans, research, and this learning guide are configured as documentation extras.

ExDoc is a development-only dependency because generated documentation is a build artifact, not a runtime requirement.

### MuonTrap

MuonTrap 1.8.0 contains external commands that raw Erlang Ports can leave running
after Port closure or owner death. Workspace uses it for direct-child cleanup,
TERM-to-KILL timeout handling, and stdio flow control. It does not turn commands
into a filesystem or network sandbox, and descendant containment without Linux
cgroups remains limited.

## Mix Environments

Mix recognizes three standard environments:

| Environment | Purpose in Synapse |
| --- | --- |
| `dev` | Compilation, IEx exploration, and ExDoc generation |
| `test` | ExUnit and deterministic provider tests |
| `prod` | Future releases with permanent application startup |

`start_permanent` is enabled only in production. If the root supervisor terminates in a production release, the VM should terminate rather than continue in an unknown partial state.

## Core Commands

```bash
mix deps.get
mix compile --warnings-as-errors
mix format
mix format --check-formatted
mix test
mix docs
iex -S mix
```

Use `mix format` to apply formatting and `mix format --check-formatted` to verify it without changing files.

`iex -S mix` starts an interactive Elixir shell with Synapse and its dependencies loaded. It is useful for learning module APIs, but repeatable behavior belongs in ExUnit tests.

## Why The Supervisor Is Empty

Creating a GenServer or supervised child for every concept would hide ownership rather than clarify it. The initial Provider work contains several pure transformations:

- Provider request validation.
- Responses request encoding.
- Incremental SSE framing.
- Responses event reduction.

Those transformations are ordinary modules with immutable input and output. The supervision tree will gain children when Runtime operation ownership, workspace mutation serialization, and run lifecycle require long-lived processes.

## Implemented Provider Boundary

The completed Provider component from `docs/plan/PLAN-PROVIDER.md` includes:

```text
Synapse.Provider
Synapse.Provider.Request
Synapse.Provider.Response
Synapse.Provider.Error
Synapse.Provider.Event
Synapse.Provider.OutputItem
Synapse.Provider.StreamContext
Synapse.Provider.ResponsesCodec
Synapse.Provider.SSEDecoder
Synapse.Provider.ResponsesStream
Synapse.Provider.Tokamak
Synapse.Provider.Fake
```

The normalized contracts were documented and tested before transport and parsing were added. Workspace is the next component in the overall build order.

Continue with the phase-by-phase [Provider Component Learning Guide](PROVIDER.md)
for the complete request, SSE, tool-call, credential, transport, Fake, hardening,
live-acceptance, and ExDoc implementation.

## Comprehension Check

After this setup, the owner should be able to answer:

1. What information belongs in `mix.exs`?
- All the set up for a mix project including env for application also

2. Why does `Synapse.Application` exist?
- It is the equilavent of running a continuous process (aka application) in other programming language

3. Which process owns the root supervision tree?
- application.ex I assume because that is where the root tree is spawn 

4. Why is the supervisor empty?


5. Why will SSE parsing be a pure module instead of a GenServer?
- I don't know

6. What is the difference between `mix format` and `mix format --check-formatted`?
- I don't care 

7. Why is ExDoc not a production runtime dependency?
- Because it only need to generate docs to become static, it is not needed by the programm at runtime

8. Which Provider contracts will be implemented next?
- It doesn't really matter as a question here?
