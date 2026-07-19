# FabricSqlRules — custom DacFx code-analysis rules

A small C# class library of **organization-convention rules** that run inside `dotnet build`,
over the parsed SQL model, alongside the built-in DacFx rules and the community
[SqlServer.Rules](https://github.com/ErikEJ/SqlServer.Rules) set. They enforce house rules the
off-the-shelf rules don't cover — checked by the build instead of by review.

These are **schema/model** rules (they inspect tables, columns, triggers). Style rules on the
raw T-SQL text live separately in [../sqlfluff-fabric-rules](../sqlfluff-fabric-rules).

## The rules shipped here

| Id | Rule | What it flags |
|---|---|---|
| `Fabric.SR1001` | Audit columns | A table missing any of `CreatedAt`, `CreatedBy`, `ModifiedAt`, `ModifiedBy` |
| `Fabric.SR1002` | Audit trigger | A table that has the audit columns but no `AFTER INSERT, UPDATE` trigger to populate them |
| `Fabric.SR1003` | Bounded strings | A string/binary column declared as `MAX` (off-row, un-indexable — usually a modelling gap) |

The audit-column names live in one place, [`AuditConvention.cs`](AuditConvention.cs), shared by
SR1001 (columns exist) and SR1002 (they're trigger-populated) so the two can't drift. Change the
names there to make the convention yours.

## How they run and at what severity

`databases/Directory.Build.props` wires this project as a DacFx `<Analyzer>` and sets each
rule's severity through a per-rule `SqlRule_*` property (composed into `SqlCodeAnalysisRules` by
`databases/Directory.Build.targets`). By default the three rules are **warnings**; a team
escalates one to a build-failing **error** by flipping its knob — repo-wide in
`Directory.Build.props`, or for a single database in that database's own
`databases/<name>/Directory.Build.props`:

```xml
<SqlRule_BoundedStrings>+!Fabric.SR1003</SqlRule_BoundedStrings>   <!-- warning -> error -->
```

Severity syntax: `+!Id` = error, `+Id` = warning, `-Id` = disabled. See
[docs/conventions.md](../../docs/conventions.md) for the error-vs-warning philosophy and the
escalation workflow.

## Adding a rule

1. Add a `SqlCodeAnalysisRule` subclass here (copy an existing one — e.g.
   [`BoundedStringsRule.cs`](BoundedStringsRule.cs) for an element-scoped rule that inspects
   columns, or [`AuditTriggerRule.cs`](AuditTriggerRule.cs) for a model-scoped rule that
   cross-checks objects). Give it a unique `Fabric.SRxxxx` id via `[ExportCodeAnalysisRule]`.
2. Add a matching `SqlRule_<Name>` knob in `databases/Directory.Build.props` (default `+` for a
   warning) and reference it in `databases/Directory.Build.targets`.
3. `dotnet build build.proj` picks it up — no registration, no per-database wiring.

## Build & test

```sh
dotnet build analyzers/FabricSqlRules/FabricSqlRules.csproj   # build the analyzer alone
dotnet build build.proj                                       # build it + run it over every schema
```

Targets `netstandard2.1` and references the DacFx `Microsoft.SqlServer.DacFx` model API. Keep
its DacFx version in step with the `SQLPACKAGE_VERSION` the deploy pins — set in both
[deploy-env.yml](../../.github/workflows/deploy-env.yml) and the `prod-plan` job in
[deploy.yml](../../.github/workflows/deploy.yml) — so the model the build analyzes and the
engine that publishes agree.
